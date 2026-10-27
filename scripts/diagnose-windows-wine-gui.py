#!/usr/bin/env python3
"""Narrow, read-only release GUI diagnosis. Does not alter the frozen test evidence."""
import datetime
import hashlib
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
IMAGE = "keytrail-wine:1.2"
STAMP = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
OUT = ROOT / "artifacts/windows-wine-gui-diagnostic" / STAMP
APP = ROOT / "artifacts/KeyTrail-Windows-v1.2"

WORKER = r'''
import ctypes,ctypes.util,hashlib,json,os,pathlib,subprocess,time
wine='/usr/lib/wine/wine64'
os.makedirs('/tmp/home',exist_ok=True);os.makedirs('/tmp/keytrail-wine',mode=0o700,exist_ok=True)
os.environ['DISPLAY']=':99'
display=subprocess.Popen(['Xvfb',':99','-screen','0','1280x1024x24','-nolisten','tcp','-ac'])
for _ in range(100):
 if pathlib.Path('/tmp/.X11-unix/X99').exists():break
 if display.poll() is not None:raise RuntimeError('Xvfb exited')
 time.sleep(.1)
else:raise RuntimeError('No X11 socket')
boot=subprocess.run([wine,'wineboot.exe','--init'],timeout=90)
print('BOOT='+str(boot.returncode),flush=True)
if boot.returncode:raise RuntimeError('Wine bootstrap failed')
include=';'.join(['user32.RegisterClassW','user32.LoadCursorW','user32.CreateWindowExW','user32.SetWindowLongPtrW','user32.SetWindowTextW','user32.ShowWindow','user32.GetMessageW','user32.MessageBoxW','wtsapi32.WTSRegisterSessionNotification','shell32.Shell_NotifyIconW'])
reg=subprocess.run([wine,'reg.exe','add',r'HKCU\Software\Wine\Debug','/v','RelayInclude','/t','REG_SZ','/d',include,'/f'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
print('RELAY_CONFIG='+str(reg.returncode),flush=True)
if reg.returncode:raise RuntimeError('Cannot configure bounded relay trace')
class Attributes(ctypes.Structure):
 _fields_=[('x',ctypes.c_int),('y',ctypes.c_int),('width',ctypes.c_int),('height',ctypes.c_int),('border_width',ctypes.c_int),('depth',ctypes.c_int),('visual',ctypes.c_void_p),('root',ctypes.c_ulong),('class_',ctypes.c_int),('bit_gravity',ctypes.c_int),('win_gravity',ctypes.c_int),('backing_store',ctypes.c_int),('backing_planes',ctypes.c_ulong),('backing_pixel',ctypes.c_ulong),('save_under',ctypes.c_int),('colormap',ctypes.c_ulong),('map_installed',ctypes.c_int),('map_state',ctypes.c_int),('all_event_masks',ctypes.c_long),('your_event_mask',ctypes.c_long),('do_not_propagate_mask',ctypes.c_long),('override_redirect',ctypes.c_int),('screen',ctypes.c_void_p)]
def windows():
 x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p
 x.XDefaultRootWindow.argtypes=[ctypes.c_void_p];x.XDefaultRootWindow.restype=ctypes.c_ulong
 x.XQueryTree.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),ctypes.POINTER(ctypes.c_uint)]
 x.XFetchName.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_void_p)];x.XFree.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
 x.XGetWindowAttributes.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(Attributes)]
 x.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int];x.XInternAtom.restype=ctypes.c_ulong
 x.XGetWindowProperty.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_long,ctypes.c_long,ctypes.c_int,ctypes.c_ulong,ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_void_p)]
 d=x.XOpenDisplay(None)
 if not d:return {'displayOpened':False,'windows':[]}
 found=[]
 def walk(w,depth):
  if len(found)>300:return
  label=ctypes.c_void_p();name=''
  if x.XFetchName(d,w,ctypes.byref(label)) and label.value:name=ctypes.string_at(label).decode('utf-8','replace');x.XFree(label)
  atom=x.XInternAtom(d,b'_NET_WM_NAME',0);actual=ctypes.c_ulong();fmt=ctypes.c_int();n=ctypes.c_ulong();remaining=ctypes.c_ulong();data=ctypes.c_void_p();utf8=''
  if x.XGetWindowProperty(d,w,atom,0,1024,0,0,ctypes.byref(actual),ctypes.byref(fmt),ctypes.byref(n),ctypes.byref(remaining),ctypes.byref(data))==0 and data.value:
   if fmt.value==8:utf8=ctypes.string_at(data,n.value).decode('utf-8','replace')
   x.XFree(data)
  a=Attributes();x.XGetWindowAttributes(d,w,ctypes.byref(a))
  found.append({'id':w,'depth':depth,'name':name,'utf8Name':utf8,'mapState':a.map_state,'rect':[a.x,a.y,a.width,a.height]})
  if depth>=2:return
  root=ctypes.c_ulong();parent=ctypes.c_ulong();children=ctypes.POINTER(ctypes.c_ulong)();count=ctypes.c_uint()
  if x.XQueryTree(d,w,ctypes.byref(root),ctypes.byref(parent),ctypes.byref(children),ctypes.byref(count)):
   for i in range(min(count.value,300)):walk(children[i],depth+1)
   if children:x.XFree(children)
 try:walk(x.XDefaultRootWindow(d),0)
 finally:x.XCloseDisplay(d)
 return {'displayOpened':True,'windows':found}
trace=open('/tmp/gui-relay.log','w+')
env=os.environ.copy();env['WINEDEBUG']='+relay,+winediag,+seh'
process=subprocess.Popen([wine,r'Z:\app\keytrail-windows.exe','--demo'],stdout=trace,stderr=subprocess.STDOUT,env=env)
start=time.monotonic();phases=[]
try:
 for second in [10,30,60,90]:
  while time.monotonic()-start<second and process.poll() is None:time.sleep(.2)
  trace.flush();text=pathlib.Path('/tmp/gui-relay.log').read_text(errors='replace')
  settings=[]
  for p in pathlib.Path('/tmp/keytrail-wine/drive_c/users').rglob('settings.json'):
   if 'KeyTrail-Demo-v1.2'in str(p):
    v=json.loads(p.read_text());settings.append({key:v.get(key)for key in ['syncEnabled','textEnabled','textSyncEnabled','launchAtLogin']})
  phase={'seconds':round(time.monotonic()-start,2),'processExit':process.poll(),'settings':settings,'files':[{'name':p.name,'bytes':p.stat().st_size}for p in pathlib.Path('/tmp/keytrail-wine/drive_c/users').rglob('*.sqlite')], 'x11':windows(),'processes':subprocess.run(['ps','-eo','pid,ppid,comm,stat,wchan'],text=True,stdout=subprocess.PIPE).stdout,'tcp':pathlib.Path('/proc/net/tcp').read_text(),'traceBytes':len(text.encode()),'lastCalls':[line for line in text.splitlines()if any(k in line for k in ['RegisterClass','LoadCursor','CreateWindow','SetWindow','ShowWindow','GetMessage','MessageBox','WTSRegister','Shell_Notify'])][-60:]}
  phases.append(phase);print('PHASE='+json.dumps(phase),flush=True)
  if process.poll()is not None:break
 print('TRACE_BEGIN',flush=True);print(pathlib.Path('/tmp/gui-relay.log').read_text(errors='replace')[-2*1024*1024:],flush=True);print('TRACE_END',flush=True)
 print('DIAG_RESULT='+json.dumps({'phases':phases,'windowObserved':any('DEMO'in (w['name']+w['utf8Name'])for p in phases for w in p['x11']['windows']),'productModified':False,'inputInjected':False,'uiCommandsSent':False,'clipboardRead':False,'allPrefixDataTemporary':True}),flush=True)
finally:
 if process.poll()is None:
  process.terminate()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.kill();process.wait()
 subprocess.run(['/usr/lib/wine/wineserver64','-k'],timeout=10)
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True)
    inspect = subprocess.run(["docker", "image", "inspect", IMAGE], check=True, text=True, stdout=subprocess.PIPE)
    image_id = json.loads(inspect.stdout)[0]["Id"]
    name = "keytrail-wine-gui-" + uuid.uuid4().hex[:10]
    command = ["docker", "run", "--rm", "--name", name, "--platform", "linux/amd64", "--network", "none",
               "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,exec,size=1073741824,mode=1777",
               "-e", "HOME=/tmp/home", "-e", "WINEPREFIX=/tmp/keytrail-wine", "--mount", f"type=bind,src={APP},dst=/app,readonly",
               IMAGE, "python3", "-u", "-c", WORKER]
    started = time.monotonic()
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=230)
        code, output = result.returncode, result.stdout
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        diagnostic = subprocess.run(["docker", "exec", name, "ps", "-eo", "pid,ppid,comm,stat,wchan"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
        output += "\nTIMEOUT_PROCESS_DIAGNOSTIC\n" + diagnostic.stdout
        subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, timeout=15)
        code = 124
    (OUT / "relay.log").write_text(output)
    summaries = [line[len("DIAG_RESULT="):] for line in output.splitlines() if line.startswith("DIAG_RESULT=")]
    report = {"imageId": image_id, "exeSHA256": sha(APP / "keytrail-windows.exe"),
              "containerExitCode": code, "elapsedSeconds": round(time.monotonic() - started, 3),
              "compatibilityLayer": "Wine/Linux amd64 CPU emulation, not a Windows kernel", "result": json.loads(summaries[-1]) if summaries else None}
    (OUT / "diagnostic.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"output": str(OUT), "exitCode": code, "hasPhases": report["result"] is not None}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
