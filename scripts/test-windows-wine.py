#!/usr/bin/env python3
"""Execute Windows PE fixtures in an isolated Wine container; never claim a Windows kernel."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
DEPS = ROOT / "rust/target-windows/x86_64-pc-windows-gnu/debug/deps"
APP = ARTIFACTS / "KeyTrail-Windows-v1.2"
OUTPUT = ARTIFACTS

# Runs inside Xvfb in an ephemeral, network-disabled container. Only selected
# settings booleans and window titles leave the synthetic prefix; never keys.
WORKER = r'''
import ctypes,hashlib,json,os,pathlib,subprocess,sys,time,urllib.request,urllib.error
wine='/usr/lib/wine/wine64'
os.makedirs('/tmp/home',exist_ok=True)
os.makedirs(os.environ['WINEPREFIX'],mode=0o700,exist_ok=True)
os.makedirs('/src',exist_ok=True)
started=time.monotonic()
display=subprocess.Popen(['Xvfb',':99','-screen','0','1280x1024x24','-nolisten','tcp','-ac'])
os.environ['DISPLAY']=':99'
for _ in range(100):
 if pathlib.Path('/tmp/.X11-unix/X99').exists():break
 if display.poll() is not None:raise RuntimeError('Xvfb exited before becoming ready')
 time.sleep(.1)
else:raise RuntimeError('Xvfb socket did not become ready')
print('XVFB_SOCKET_READY',flush=True)
boot=subprocess.run([wine,'wineboot.exe','--init'],timeout=90)
print('WINE_BOOT_EXIT='+str(boot.returncode),flush=True)
if boot.returncode:sys.exit(boot.returncode)
mode=sys.argv[1]
if mode=='test':
 executable='Z:\\tests\\'+sys.argv[2]
 listed=subprocess.run([wine,executable,'--list'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 print(listed.stdout,flush=True)
 if listed.returncode:sys.exit(listed.returncode)
 expected=sum(line.endswith(': test') for line in listed.stdout.splitlines())
 if expected==0:raise RuntimeError('Selected PE executable lists no tests')
 print('PE_LIST_COUNT='+str(expected),flush=True)
 result=subprocess.run([wine,executable,'--test-threads=1'],timeout=300)
 print('PE_EXIT='+str(result.returncode),flush=True)
 sys.exit(result.returncode)
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
def release_api_checks():
 expected=json.loads(sys.argv[2]);ports=[]
 for line in pathlib.Path('/proc/net/tcp').read_text().splitlines()[1:]:
  fields=line.split()
  if fields[3]=='0A' and fields[1].split(':')[0]=='0100007F':ports.append(int(fields[1].split(':')[1],16))
 result={'loopbackListeners':len(ports),'identifiedDemoServer':False,'unauthenticatedRefusals':{},'staticAssets':{},'authenticatedNativeRoutesVerified':False,'authenticatedUnavailableReason':'Viewer credential is ephemeral and requires the normal native UI; no UI commands, clipboard reads, memory dumps or token-model changes are used.'}
 for port in ports:
  origin='http://127.0.0.1:'+str(port)
  try:
   with urllib.request.urlopen(origin+'/',timeout=3)as response:body=response.read(2*1024*1024)
   if hashlib.sha256(body).hexdigest()!=expected['index.html']:continue
   result['identifiedDemoServer']=True
   for name,checksum in expected.items():
    path='/' if name=='index.html'else'/'+name
    with urllib.request.urlopen(origin+path,timeout=3)as response:actual=response.read(2*1024*1024)
    result['staticAssets'][name]={'sha256':hashlib.sha256(actual).hexdigest(),'matches':hashlib.sha256(actual).hexdigest()==checksum}
   for path,body in [('/api/status',None),('/api/query',{'op':'summary','start':0,'end':60}),('/api/text-query',{'start':0,'end':60,'offset':0,'limit':1})]:
    request=urllib.request.Request(origin+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    try:
     with urllib.request.urlopen(request,timeout=3)as response:code=response.status;headers=response.headers;payload=response.read(4096)
    except urllib.error.HTTPError as error:code=error.code;headers=error.headers;payload=error.read(4096)
    envelope=json.loads(payload)
    result['unauthenticatedRefusals'][path]={'status':code,'refused':code==401 and envelope.get('ok')is False,'noStore':headers.get('Cache-Control')=='no-store','noCORS':headers.get('Access-Control-Allow-Origin')is None}
   break
  except Exception as error:result['error']=type(error).__name__+': '+str(error)
 result['passed']=result['identifiedDemoServer'] and len(result['staticAssets'])==8 and all(value['matches']for value in result['staticAssets'].values()) and len(result['unauthenticatedRefusals'])==3 and all(value['refused'] and value['noStore'] and value['noCORS']for value in result['unauthenticatedRefusals'].values())
 return result
process=subprocess.Popen([wine,'Z:\\app\\keytrail-windows.exe','--demo'])
observed={};settings=None;live=False
def visible_demo(w):
 x,y,width,height=w['rect']
 return 'DEMO' in (w['name']+w['utf8Name']) and w['mapState']==2 and 0<=x<1280 and 0<=y<1024 and 300<=width<=1280 and 300<=height<=1024
try:
 for _ in range(120):
  if process.poll() is not None:break
  for w in windows()['windows']:
   if 'KeyTrail' in (w['name']+w['utf8Name']):observed[str(w['id'])]=w
  for file in pathlib.Path('/tmp/keytrail-wine/drive_c/users').rglob('settings.json'):
   if 'KeyTrail-Demo-v1.2' in str(file):
    value=json.loads(file.read_text());settings={key:value.get(key)for key in ['syncEnabled','textEnabled','textSyncEnabled','launchAtLogin']}
  if any(visible_demo(w)for w in observed.values()) and settings is not None:
   time.sleep(5);live=process.poll() is None;break
  time.sleep(.5)
 result={'processStayedAlive':process.poll() is None,'demoWindowObserved':any(visible_demo(w)for w in observed.values()),'windowTitles':[w['utf8Name']or w['name']for w in observed.values()],'windowEvidence':list(observed.values()),'demoSettings':settings,'allOptInsOff':settings is not None and all(value is False for value in settings.values()),'unexpectedExitCode':process.poll(),'releaseAPIChecks':release_api_checks(),'gracefulQuitVerified':False,'inputInjected':False,'network':'container --network none; loopback only','runtimeSeconds':round(time.monotonic()-started,3)}
 print('DEMO_RESULT='+json.dumps(result),flush=True)
 ok=result['processStayedAlive'] and result['demoWindowObserved'] and result['allOptInsOff']
finally:
 if process.poll() is None:
  process.terminate()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.kill();process.wait()
 subprocess.run(['/usr/lib/wine/wineserver64','-k'],timeout=10)
sys.exit(0 if ok else 1)
'''


def execute(command, **kwargs):
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def container_case(image, label, mode, filename=None):
    name = "keytrail-wine-" + uuid.uuid4().hex[:12]
    command = ["docker", "run", "--rm", "--name", name, "--platform", "linux/amd64",
               "--network", "none", "--read-only", "--cap-drop", "ALL",
               "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,exec,size=1073741824,mode=1777",
               "-e", "HOME=/tmp/home", "-e", "WINEPREFIX=/tmp/keytrail-wine",
               "--mount", f"type=bind,src={APP},dst=/app,readonly", "--workdir", "/src"]
    if filename:
        command += ["--mount", f"type=bind,src={DEPS},dst=/tests,readonly",
                    "--mount", f"type=bind,src={ROOT / 'rust/keytrail-windows/tests'},dst=/src/rust/keytrail-windows/tests,readonly"]
    command += [image, "python3", "-u", "-c", WORKER, mode]
    if filename:
        command.append(filename)
    else:
        command.append(json.dumps({p.name:sha(p) for p in (ROOT / 'web').iterdir() if p.is_file()}))
    started = time.monotonic()
    timed_out = False
    try:
        result = execute(command, timeout=420)
        output, code = result.stdout, result.returncode
    except subprocess.TimeoutExpired as error:
        timed_out = True
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        # No user data is mounted; inspect only live processes and socket handles.
        diagnostic = execute(["docker", "exec", name, "sh", "-c", "ps -ef; cat /proc/net/tcp; cat /proc/net/tcp6"], timeout=15)
        output += "\nTIMEOUT_DIAGNOSTIC\n" + diagnostic.stdout
        execute(["docker", "rm", "-f", name], timeout=15)
        code = 124
    path = OUTPUT / f"v1.2-windows-wine-{label}.log"
    path.write_text(output)
    item = {"name": label, "dockerExitCode": code, "timedOut": timed_out,
            "elapsedSeconds": round(time.monotonic() - started, 3), "log": str(path)}
    if filename:
        item.update(exe=filename, exeSHA256=sha(DEPS / filename))
        listed = re.search(r"^PE_LIST_COUNT=(\d+)$", output, re.MULTILINE)
        item["expectedTests"] = int(listed[1]) if listed else None
        counts = re.search(r"test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored", output)
        item["passedTests"] = int(counts[1]) if counts else None
        item["failedTests"] = int(counts[2]) if counts else None
        item["ignoredTests"] = int(counts[3]) if counts else None
        pe = re.search(r"PE_EXIT=(-?\d+)", output)
        item["peExitCode"] = int(pe[1]) if pe else None
    else:
        item["exeSHA256"] = sha(APP / "keytrail-windows.exe")
        demo = re.search(r"DEMO_RESULT=(.+)", output)
        item["demo"] = json.loads(demo[1]) if demo else None
    print(json.dumps(item), flush=True)
    return item


def select_test_executables(directory, overrides):
    crates = ("keytrail_core", "keytrail_server", "keytrail_windows")
    chosen = {}
    for value in overrides:
        crate, separator, filename = value.partition("=")
        if not separator or crate not in crates or pathlib.Path(filename).name != filename or not filename.startswith(crate + "-") or not filename.endswith(".exe"):
            raise ValueError("--test-executable requires keytrail_core/keytrail_server/keytrail_windows=FILENAME.exe")
        if crate in chosen:
            raise ValueError(f"Duplicate PE selection for {crate}")
        chosen[crate] = directory / filename
    for crate in crates:
        choices = [chosen[crate]] if crate in chosen else sorted(directory.glob(crate + "-*.exe"))
        if len(choices) != 1 or not choices[0].is_file():
            raise ValueError(f"Expected one built {crate} PE test in {directory}; build with scripts/package-windows.sh, then use --test-executable {crate}=FILENAME.exe if multiple variants exist")
        chosen[crate] = choices[0]
    return {crate: chosen[crate] for crate in crates}


def main():
    global OUTPUT, APP, DEPS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="keytrail-wine:1.2")
    parser.add_argument("--demo-only", action="store_true", help="Run only demo smoke; do not claim any PE test groups were verified")
    parser.add_argument("--deps-directory", type=pathlib.Path, default=DEPS)
    parser.add_argument("--test-executable", action="append", default=[], metavar="CRATE=FILENAME",
                        help="Select a built PE test by exact filename when stale feature variants exist")
    parser.add_argument("--app-directory", type=pathlib.Path, default=APP)
    parser.add_argument("--output-directory", type=pathlib.Path, default=ARTIFACTS, help="Use a new directory to preserve previously frozen evidence")
    args = parser.parse_args()
    OUTPUT = args.output_directory.resolve()
    APP = args.app_directory.resolve()
    DEPS = args.deps_directory.resolve()
    selected = select_test_executables(DEPS, args.test_executable) if not args.demo_only else {}
    if not (APP / "keytrail-windows.exe").is_file():
        parser.error("Missing release executable; run scripts/package-windows.sh or pass --app-directory")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    ARTIFACTS.mkdir(exist_ok=True)
    image = json.loads(execute(["docker", "image", "inspect", args.image], check=True).stdout)[0]
    version = execute(["docker", "run", "--rm", "--platform", "linux/amd64", "--network", "none", args.image, "/usr/lib/wine/wine64", "--version"], check=True).stdout.strip()
    result = {"compatibilityLayer": "Wine, not a Windows kernel or hardware/driver environment", "image": args.image,
              "imageId": image["Id"], "architecture": image["Architecture"], "wineVersion": version,
              "mountPolicy": "PE test directory, synthetic fixtures and release app only; all read-only; temporary prefix and no external network",
              "groups": [], "realInputOrPermissionChanges": False}
    result["scope"] = "demo-only" if args.demo_only else "PE tests and demo smoke"
    for crate, executable in selected.items():
        item = container_case(args.image, crate, "test", executable.name)
        item["executionRetainedByUnchangedHash"] = False
        item["passed"] = (item["dockerExitCode"] == 0 and item["peExitCode"] == 0
                          and item["expectedTests"] is not None and item["expectedTests"] > 0
                          and item["passedTests"] == item["expectedTests"]
                          and item["failedTests"] == 0 and item["ignoredTests"] == 0)
        result["groups"].append(item)
    result["demoSmoke"] = container_case(args.image, "demo", "demo")
    result["allPEGroupsPassed"] = all(item["passed"] for item in result["groups"]) if selected else None
    result["totalPEPassedTests"] = sum(item["passedTests"] or 0 for item in result["groups"])
    result["demoSmokePassed"] = result["demoSmoke"]["dockerExitCode"] == 0
    result["partialReleaseAPIChecksPassed"] = bool((result["demoSmoke"].get("demo") or {}).get("releaseAPIChecks", {}).get("passed"))
    result["unverified"] = ["Windows-kernel/hardware Raw Input reception", "UI Automation TextEdit/IME/provider coverage", "Windows DPAPI account boundary", "Windows kernel lock/sleep/RDP and monitor DPI", "Private remote HTTPS", "Hardware memory/power", "Graceful UI Quit"]
    (OUTPUT / "v1.2-windows-wine-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if (args.demo_only or result["allPEGroupsPassed"]) and result["demoSmokePassed"] and result["partialReleaseAPIChecksPassed"] else 1


if __name__ == "__main__":
    sys.exit(main())
