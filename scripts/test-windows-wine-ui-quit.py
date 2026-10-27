#!/usr/bin/env python3
"""Two-stage visible demo Quit test: inspect/screenshot, then explicitly reviewed XTEST click."""
import argparse
import ast
import base64
import hashlib
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts/windows-wine-gui-followup/ui-quit"
TOOLS = ROOT / "artifacts/windows-wine-gui-followup/tools"
APP = ROOT / "artifacts/KeyTrail-Windows-v1.2"
IMAGE = "keytrail-wine-ui:1.2"

PREFIX = r'''
import ctypes,hashlib,json,os,pathlib,struct,subprocess,time,urllib.request,urllib.error,zlib
wine='/usr/lib/wine/wine64'
os.makedirs('/tmp/home',exist_ok=True);os.makedirs('/tmp/keytrail-wine',mode=0o700,exist_ok=True)
os.environ['DISPLAY']=':99'
display=subprocess.Popen(['Xvfb',':99','-screen','0','1280x1024x24','-nolisten','tcp','-ac'])
for _ in range(100):
 if pathlib.Path('/tmp/.X11-unix/X99').exists():break
 time.sleep(.1)
boot=subprocess.run([wine,'wineboot.exe','--init'],timeout=90)
assert boot.returncode==0
'''

BODY = r'''
class Image(ctypes.Structure):
 _fields_=[('width',ctypes.c_int),('height',ctypes.c_int),('xoffset',ctypes.c_int),('format',ctypes.c_int),('data',ctypes.c_void_p),('byte_order',ctypes.c_int),('bitmap_unit',ctypes.c_int),('bitmap_bit_order',ctypes.c_int),('bitmap_pad',ctypes.c_int),('depth',ctypes.c_int),('bytes_per_line',ctypes.c_int),('bits_per_pixel',ctypes.c_int),('red_mask',ctypes.c_ulong),('green_mask',ctypes.c_ulong),('blue_mask',ctypes.c_ulong),('obdata',ctypes.c_void_p)]
def screenshot():
 x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p
 x.XDefaultRootWindow.argtypes=[ctypes.c_void_p];x.XDefaultRootWindow.restype=ctypes.c_ulong
 x.XGetImage.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint,ctypes.c_ulong,ctypes.c_int];x.XGetImage.restype=ctypes.POINTER(Image)
 x.XDestroyImage.argtypes=[ctypes.POINTER(Image)];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
 d=x.XOpenDisplay(None);assert d
 image=x.XGetImage(d,x.XDefaultRootWindow(d),0,0,1280,1024,ctypes.c_ulong(-1).value,2);assert image
 try:
  a=image.contents;assert a.bits_per_pixel==32 and a.byte_order==0 and a.red_mask==0xff0000 and a.green_mask==0xff00 and a.blue_mask==0xff
  pixels=ctypes.string_at(a.data,a.bytes_per_line*a.height);rows=[]
  for y in range(a.height):
   raw=pixels[y*a.bytes_per_line:y*a.bytes_per_line+a.width*4];rgb=bytearray(a.width*3)
   rgb[0::3]=raw[2::4];rgb[1::3]=raw[1::4];rgb[2::3]=raw[0::4];rows.append(b'\0'+rgb)
  def chunk(tag,data):return struct.pack('!I',len(data))+tag+data+struct.pack('!I',zlib.crc32(tag+data)&0xffffffff)
  png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',a.width,a.height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b'')
  pathlib.Path('/tmp/ui-before.png').write_bytes(png)
  return hashlib.sha256(png).hexdigest()
 finally:x.XDestroyImage(image);x.XCloseDisplay(d)
def inspect():
 p=subprocess.run([wine,r'Z:\tools\keytrail-ui-inspect.exe'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=10)
 data=json.loads(p.stdout);data['inspectorExitCode']=p.returncode;assert p.returncode==0,data
 assert data['windowVisible'] and data['quitVisible'] and data['quitTitle']=='Quit KeyTrail' and data['quitClass'].lower()=='button' and 'DEMO'in data['mainTitle']
 return data
app=subprocess.Popen([wine,r'Z:\app\keytrail-windows.exe','--demo'])
started=time.monotonic();ready=None
try:
 for _ in range(120):
  assert app.poll()is None,'demo exited before readiness'
  visible=[w for w in windows()['windows']if 'DEMO'in(w['name']+w['utf8Name']) and w['mapState']==2 and w['rect'][2]>=300 and w['rect'][3]>=300]
  if visible:
   control=inspect();ports=[]
   for line in pathlib.Path('/proc/net/tcp').read_text().splitlines()[1:]:
    f=line.split()
    if f[3]=='0A'and f[1].split(':')[0]=='0100007F':ports.append(int(f[1].split(':')[1],16))
   assert len(ports)==1
   with urllib.request.urlopen('http://127.0.0.1:'+str(ports[0])+'/',timeout=3)as response:assert response.status==200
   ready={'window':visible[0],'controls':control,'loopbackPort':ports[0],'screenshotSHA256':screenshot(),'appLinuxPid':app.pid,'inputMethod':'none yet; wait for externally reviewed screenshot','clipboardRead':False,'uiCommandsSent':False}
   pathlib.Path('/tmp/ui-ready.json').write_text(json.dumps(ready));print('UI_READY='+json.dumps(ready),flush=True);break
  time.sleep(.5)
 assert ready,'no visible demo window'
 deadline=time.monotonic()+180
 while app.poll()is None and time.monotonic()<deadline:time.sleep(.1)
 exit_code=app.poll();clicked=pathlib.Path('/tmp/ui-click.json')
 click=json.loads(clicked.read_text())if clicked.exists()else None
 http_stopped=False
 try:urllib.request.urlopen('http://127.0.0.1:'+str(ready['loopbackPort'])+'/',timeout=2).close()
 except urllib.error.URLError:http_stopped=True
 result={'visibleDemoAndQuitInspected':True,'ready':ready,'click':click,'applicationExitCode':exit_code,'gracefulUIQuitVerified':exit_code==0 and click is not None,'httpStopped':http_stopped,'hardwareMouseVerified':False,'captureOrLoginOptInsChanged':False,'clipboardRead':False,'uiCommandsSent':False,'elapsedSeconds':round(time.monotonic()-started,3)}
 print('UI_RESULT='+json.dumps(result),flush=True)
 passed=result['gracefulUIQuitVerified']and http_stopped
finally:
 if app.poll()is None:
  app.terminate()
  try:app.wait(timeout=5)
  except subprocess.TimeoutExpired:app.kill();app.wait()
 subprocess.run(['/usr/lib/wine/wineserver64','-k'],timeout=10)
raise SystemExit(0 if passed else 1)
'''

CLICK = r'''
import ctypes,hashlib,json,pathlib,subprocess,sys
ready=json.loads(pathlib.Path('/tmp/ui-ready.json').read_text());assert hashlib.sha256(pathlib.Path('/tmp/ui-before.png').read_bytes()).hexdigest()==sys.argv[1]
p=subprocess.run(['/usr/lib/wine/wine64',r'Z:\tools\keytrail-ui-inspect.exe'],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10);assert p.returncode==0
now=json.loads(p.stdout);old=ready['controls']
for field in ['windowHandle','ownerWindowsPid','mainTitle','quitHandle','quitTitle','quitClass','mainRect','quitRect']:assert now[field]==old[field],field
assert now['windowVisible']and now['quitVisible']and now['quitTitle']=='Quit KeyTrail'
left,top,right,bottom=now['quitRect'];assert 0<=left<right<=1280 and 0<=top<bottom<=1024
px=(left+right)//2;py=(top+bottom)//2
x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p;x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
t=ctypes.CDLL('libXtst.so.6');t.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong];t.XTestFakeButtonEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
d=x.XOpenDisplay(b':99');assert d
assert t.XTestFakeMotionEvent(d,0,px,py,0);assert t.XTestFakeButtonEvent(d,1,1,0);assert t.XTestFakeButtonEvent(d,1,0,0);x.XFlush(d);x.XCloseDisplay(d)
event={'method':'XTEST synthetic pointer click on normally visible Quit KeyTrail button','point':[px,py],'button':1,'screenshotReviewedSHA256':sys.argv[1],'targetWindowHandle':now['windowHandle'],'targetQuitHandle':now['quitHandle'],'hardwareMouseTest':False,'SendMessageUsed':False,'WM_COMMANDInjected':False,'clipboardRead':False}
pathlib.Path('/tmp/ui-click.json').write_text(json.dumps(event));print(json.dumps(event))
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    global OUT, APP, TOOLS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--click-reviewed-sha", help="Only after viewing ui-before.png, send one ordinary XTEST pointer click")
    parser.add_argument("--output-directory", type=pathlib.Path, default=OUT)
    parser.add_argument("--app-directory", type=pathlib.Path, default=APP)
    args = parser.parse_args()
    OUT = args.output_directory.resolve()
    APP = args.app_directory.resolve()
    TOOLS = OUT.parent / "tools"
    if args.click_reviewed_sha:
        run = json.loads((OUT / "run.json").read_text())
        assert sha(OUT / "ui-before.png") == args.click_reviewed_sha
        return subprocess.run(["docker", "exec", "-e", "DISPLAY=:99", run["containerName"], "python3", "-c", CLICK, args.click_reviewed_sha]).returncode
    OUT.mkdir(parents=True, exist_ok=False)
    TOOLS.mkdir(parents=True, exist_ok=True)
    compile_result = subprocess.run(["docker", "run", "--rm", "--network", "none", "-i", "keytrail-windows-builder:1.2", "sh", "-c", "x86_64-w64-mingw32-gcc -O2 -x c - -o /tmp/keytrail-ui-inspect.exe -luser32 && base64 -w0 /tmp/keytrail-ui-inspect.exe"], input=(ROOT / "scripts/windows-wine-ui-inspect.c").read_bytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    (TOOLS / "keytrail-ui-inspect.exe").write_bytes(base64.b64decode(compile_result.stdout, validate=True))
    helpers_module = ast.parse((ROOT / "scripts/diagnose-windows-wine-gui.py").read_text())
    diag = next(ast.literal_eval(node.value) for node in helpers_module.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "WORKER" for t in node.targets))
    helpers = diag[diag.index("class Attributes("):diag.index("trace=open('/tmp/gui-relay.log'")]
    worker = PREFIX + helpers + BODY
    name = "keytrail-wine-ui-" + uuid.uuid4().hex[:10]
    image = json.loads(subprocess.run(["docker", "image", "inspect", IMAGE], text=True, stdout=subprocess.PIPE, check=True).stdout)[0]
    run = {"containerName": name, "uiImage": IMAGE, "uiImageId": image["Id"], "PETestsRerunInUIChildImage": False, "exeSHA256": sha(APP / "keytrail-windows.exe"), "inspectorSHA256": sha(TOOLS / "keytrail-ui-inspect.exe"), "compatibilityLayer": "Wine/Linux amd64 CPU emulation with XTEST; not a Windows kernel or physical mouse", "readOnlyMounts": True, "externalNetwork": False}
    (OUT / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    command = ["docker", "run", "--rm", "--name", name, "--platform", "linux/amd64", "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,exec,size=1073741824,mode=1777", "-e", "HOME=/tmp/home", "-e", "WINEPREFIX=/tmp/keytrail-wine", "--mount", f"type=bind,src={APP},dst=/app,readonly", "--mount", f"type=bind,src={TOOLS},dst=/tools,readonly", IMAGE, "python3", "-u", "-c", worker]
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        code, output = result.returncode, result.stdout
    except subprocess.TimeoutExpired as error:
        code = 124; output = error.stdout or b""
        if isinstance(output, bytes):output = output.decode("utf-8", "replace")
        subprocess.run(["docker", "rm", "-f", name], timeout=10, stdout=subprocess.DEVNULL)
    (OUT / "ui-quit.log").write_text(output)
    rows = [line.strip()[len("UI_RESULT="):] for line in output.splitlines() if line.strip().startswith("UI_RESULT=")]
    run.update(containerExitCode=code, result=json.loads(rows[-1]) if rows else None, summaryExtractionPassed=bool(rows))
    (OUT / "verification.json").write_text(json.dumps(run, indent=2) + "\n")
    print(json.dumps({"output": str(OUT), "exitCode": code, "result": run["result"]}))
    # A zero container status alone is not a complete UI result.
    return code if code else (0 if rows and run["result"]["gracefulUIQuitVerified"] and run["result"]["httpStopped"] else 1)


if __name__ == "__main__":
    raise SystemExit(main())
