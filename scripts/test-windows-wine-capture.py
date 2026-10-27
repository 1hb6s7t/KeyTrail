#!/usr/bin/env python3
"""Isolated production Raw Input experiment; no Engine injection, secret or clipboard reads.

Start without --demo. Review the initial screenshot, then use --exercise-reviewed-sha.
Use --dashboard only after pausing. Review the paused screenshot and use
--quit-reviewed-sha for a normal visible Quit click. --finish only ends the temporary
experiment and never counts as normal UI Quit. SQLite evidence is distinct from
viewer proof.
"""
import argparse
import ast
import base64
import datetime
import hashlib
import json
import pathlib
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "artifacts/KeyTrail-Windows-v1.2"
IMAGE = "keytrail-wine-ui:1.2"

INSPECTOR = r'''
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>
static void key(const char *name){putchar(34);fputs(name,stdout);putchar(34);putchar(58);}
static void str(const WCHAR *s){char b[16384]={0};WideCharToMultiByte(CP_UTF8,0,s,-1,b,sizeof b,NULL,NULL);putchar(34);for(unsigned char*p=(unsigned char*)b;*p;p++){if(*p==34||*p==92){putchar(92);putchar(*p);}else if(*p==13){putchar(92);putchar(114);}else if(*p==10){putchar(92);putchar(110);}else if(*p<32){putchar(92);printf("u%04x",*p);}else putchar(*p);}putchar(34);}
int main(void){
 HWND w=FindWindowW(L"KeyTrailResident12",NULL);
 if(!w){putchar(123);key("found");fputs("false}",stdout);putchar(10);return 2;}
 WCHAR title[256]={0},status[4096]={0},statusClass[128]={0};GetWindowTextW(w,title,256);
 HWND statusControl=GetDlgItem(w,205);GetClassNameW(statusControl,statusClass,128);
 /* Only the known nonsecret read-only status control. GetWindowText cannot
    retrieve another process's EDIT text; bounded WM_GETTEXT is read-only. */
 if(lstrcmpiW(statusClass,L"Edit")==0 && (GetWindowLongPtrW(statusControl,GWL_STYLE)&ES_READONLY)){
  DWORD_PTR length=0;if(!SendMessageTimeoutW(statusControl,WM_GETTEXT,4096,(LPARAM)status,SMTO_ABORTIFHUNG,1000,&length))return 3;
 }else GetWindowTextW(statusControl,status,4096);
 putchar(123);key("found");fputs("true,",stdout);key("visible");fputs(IsWindowVisible(w)?"true,":"false,",stdout);key("title");str(title);putchar(44);key("status");str(status);putchar(44);key("controls");putchar(91);
 int ids[]={101,102,107,205};
 for(int i=0;i<4;i++){HWND b=GetDlgItem(w,ids[i]);WCHAR label[256]={0},cls[128]={0};RECT r={0};GetWindowTextW(b,label,256);GetClassNameW(b,cls,128);GetWindowRect(b,&r);if(i)putchar(44);putchar(123);key("id");printf("%d,",ids[i]);key("visible");fputs(IsWindowVisible(b)?"true,":"false,",stdout);key("label");str(label);putchar(44);key("class");str(cls);putchar(44);key("style");printf("%lu,",(unsigned long)GetWindowLongPtrW(b,GWL_STYLE));key("rect");printf("[%ld,%ld,%ld,%ld]}",r.left,r.top,r.right,r.bottom);}
 fputs("]}",stdout);putchar(10);return 0;
}
'''

BASE = r'''
import base64,ctypes,hashlib,json,os,pathlib,sqlite3,struct,subprocess,time,urllib.request,urllib.error,zlib
wine='/usr/lib/wine/wine64'
os.makedirs('/tmp/home',exist_ok=True);os.makedirs('/tmp/keytrail-wine',mode=0o700,exist_ok=True);os.environ['DISPLAY']=':99'
display=subprocess.Popen(['Xvfb',':99','-screen','0','1280x1024x24','-nolisten','tcp','-ac'])
for _ in range(100):
 if pathlib.Path('/tmp/.X11-unix/X99').exists():break
 time.sleep(.1)
assert subprocess.run([wine,'wineboot.exe','--init'],timeout=90).returncode==0
'''

COMMON = r'''
def inspect():
 p=subprocess.run(['/usr/lib/wine/wine64',r'Z:\tools\capture-inspect.exe'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=10)
 assert p.returncode==0,'main window not inspectable'
 v=json.loads(p.stdout);assert v['found'] and 'local collector'in v['title'] and 'DEMO'not in v['title'];return v
def control(state,id):return next(c for c in state['controls']if c['id']==id)
def click(id,labels):
 s=inspect();c=control(s,id);assert s['visible']and c['visible']and c['class'].lower()=='button'and c['label']in labels,c
 l,t,r,b=c['rect'];assert 0<=l<r<=1280 and 0<=t<b<=1024
 x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p;x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
 q=ctypes.CDLL('libXtst.so.6');q.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong];q.XTestFakeButtonEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
 d=x.XOpenDisplay(b':99');assert d;q.XTestFakeMotionEvent(d,0,(l+r)//2,(t+b)//2,0);q.XTestFakeButtonEvent(d,1,1,0);q.XTestFakeButtonEvent(d,1,0,0);x.XFlush(d);x.XCloseDisplay(d)
 return {'control':id,'label':c['label'],'point':[(l+r)//2,(t+b)//2],'method':'XTEST ordinary pointer','SendMessage':False,'WM_COMMAND':False}
def keys(text):
 x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p;x.XStringToKeysym.argtypes=[ctypes.c_char_p];x.XStringToKeysym.restype=ctypes.c_ulong;x.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x.XKeysymToKeycode.restype=ctypes.c_ubyte;x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
 q=ctypes.CDLL('libXtst.so.6');q.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
 d=x.XOpenDisplay(b':99');assert d
 for char in text:
  code=x.XKeysymToKeycode(d,x.XStringToKeysym(char.encode()));assert code
  q.XTestFakeKeyEvent(d,code,1,0);x.XFlush(d);time.sleep(.06);q.XTestFakeKeyEvent(d,code,0,0);x.XFlush(d);time.sleep(.06)
 x.XCloseDisplay(d)
def db_snapshot():
 files=[p for p in pathlib.Path('/tmp/keytrail-wine/drive_c/users').rglob('aggregates.sqlite')if p.parent.name=='KeyTrail'];assert len(files)==1
 path=files[0]
 with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=5)as db:
  db.execute('PRAGMA query_only=ON');db.execute('BEGIN')
  rows=db.execute('SELECT keys,left_clicks,right_clicks,middle_clicks,distance,keyboard_mask,mouse_mask FROM minutes').fetchall()
  hist=dict(db.execute('SELECT label,SUM(count)FROM key_histograms GROUP BY label'))
  result={'minuteRows':len(rows),'keyPresses':sum(r[0]for r in rows),'leftClicks':sum(r[1]for r in rows),'rightClicks':sum(r[2]for r in rows),'middleClicks':sum(r[3]for r in rows),'cursorDisplayPoints':sum(r[4]for r in rows),'keyboardActiveSeconds':sum(int(r[5]).bit_count()for r in rows),'mouseActiveSeconds':sum(int(r[6]).bit_count()for r in rows),'totalActiveSeconds':sum((int(r[5])|int(r[6])).bit_count()for r in rows),'histogram':hist,'readOnly':True,'queryOnly':True}
 with sqlite3.connect((path.parent/'text-archive.sqlite').as_uri()+'?mode=ro',uri=True)as db:
  result['textRecordCount']=db.execute('SELECT COUNT(*)FROM text_records').fetchone()[0]
 return result
def screenshot_to(name):
 value=screenshot();pathlib.Path('/tmp/ui-before.png').rename('/tmp/'+name);return value
'''

RUN = r'''
app=subprocess.Popen([wine,r'Z:\app\keytrail-windows.exe'])
started=time.monotonic();ready=None
try:
 for _ in range(120):
  assert app.poll()is None
  try:
   state=inspect()
   if state['visible']:break
  except Exception:pass
  time.sleep(.5)
 else:raise RuntimeError('production main window not visible')
 defaults=[]
 for p in pathlib.Path('/tmp/keytrail-wine/drive_c/users').rglob('settings.json'):
  if p.parent.name=='KeyTrail':
   v=json.loads(p.read_text());defaults.append({k:v.get(k)for k in ['syncEnabled','textEnabled','textSyncEnabled','launchAtLogin']})
 assert len(defaults)==1 and all(v is False for v in defaults[0].values())
 ports=[int(f[1].split(':')[1],16)for f in (line.split()for line in pathlib.Path('/proc/net/tcp').read_text().splitlines()[1:])if f[3]=='0A'and f[1].split(':')[0]=='0100007F'];assert len(ports)==1
 ready={'loopbackPort':ports[0],'initialUI':state,'initialDB':db_snapshot(),'defaults':defaults[0],'screenshotSHA256':screenshot_to('capture-initial.png'),'productionPath':True,'demoArgument':False,'clipboardRead':False,'EngineInjected':False}
 assert ready['initialDB']['keyPresses']==0 and ready['initialDB']['textRecordCount']==0
 pathlib.Path('/tmp/capture-ready.json').write_text(json.dumps(ready));print('CAPTURE_READY='+json.dumps(ready),flush=True)
 deadline=time.monotonic()+180
 while time.monotonic()<deadline and not pathlib.Path('/tmp/capture-finish').exists()and app.poll()is None:time.sleep(.2)
 http_stopped=False
 try:urllib.request.urlopen('http://127.0.0.1:'+str(ready['loopbackPort'])+'/',timeout=2).close()
 except urllib.error.URLError:http_stopped=True
 result={'ready':ready,'exercise':None,'dashboard':None,'normalQuit':None,'statusScroll':None,'httpStoppedBeforeCleanup':http_stopped,'appExitBeforeCleanup':app.poll(),'cleanupIsForcedNotUIQuit':app.poll()is None,'hardwareInputVerified':False,'WindowsKernelVerified':False,'secretsRead':False,'EngineInjected':False,'elapsedSeconds':round(time.monotonic()-started,3)}
 for field,name in [('exercise','capture-exercise.json'),('dashboard','capture-dashboard.json'),('normalQuit','capture-quit.json'),('statusScroll','capture-status-scroll.json')]:
  p=pathlib.Path('/tmp/'+name)
  if p.exists():result[field]=json.loads(p.read_text())
 result['normalUIQuitVerified']=result['appExitBeforeCleanup']==0 and result['normalQuit']is not None
 e=result['exercise']or{}
 result['shortWorkflowPassed']=bool(e.get('expectedUVWEachOne')and e.get('expectedTotalKeysThree')and e.get('pausedXYZDidNotChangeDB')and e.get('textRecordingStayedOff')and result['normalUIQuitVerified']and http_stopped)
 for name in ['capture-initial.png','capture-paused.png','capture-status-bottom.png','capture-dashboard.png']:
  file=pathlib.Path('/tmp/'+name)
  if file.exists():print('CAPTURE_FILE64='+json.dumps({'name':name,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'base64':base64.b64encode(file.read_bytes()).decode()}),flush=True)
 # Only the synthetic aggregate database is exported, never configuration/key/text files.
 if e.get('captureStarted'):
  file=next(p for p in pathlib.Path('/tmp/keytrail-wine/drive_c/users').rglob('aggregates.sqlite')if p.parent.name=='KeyTrail')
  print('CAPTURE_FILE64='+json.dumps({'name':'capture-statistics.sqlite','sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'base64':base64.b64encode(file.read_bytes()).decode()}),flush=True)
 print('CAPTURE_RESULT='+json.dumps(result),flush=True)
finally:
 if app.poll()is None:
  app.terminate()
  try:app.wait(timeout=5)
  except subprocess.TimeoutExpired:app.kill();app.wait()
 subprocess.run(['/usr/lib/wine/wineserver64','-k'],timeout=10)
raise SystemExit(0 if result['shortWorkflowPassed']else 1)
'''

EXERCISE = r'''
import sys
ready=json.loads(pathlib.Path('/tmp/capture-ready.json').read_text());assert ready['screenshotSHA256']==sys.argv[1]
events=[click(101,['Start collection'])];deadline=time.monotonic()+5
while time.monotonic()<deadline:
 s=inspect()
 if 'Collecting physical input'in s['status']and control(s,101)['label']=='Pause collection':break
 time.sleep(.2)
else:
 result={'captureStarted':False,'blockedUI':inspect(),'inputInjected':False,'events':events,'scope':'No input sent or backend bypass after OS registration/capture refusal.'}
 pathlib.Path('/tmp/capture-exercise.json').write_text(json.dumps(result));print(json.dumps(result));raise SystemExit(2)
keys('uvw');events.append({'method':'XTEST key down/up','fixture':'uvw','physicalHardware':False});time.sleep(2.2)
events.append(click(101,['Pause collection']));time.sleep(.5);paused=inspect();assert control(paused,101)['label']=='Start collection'
after=db_snapshot();keys('xyz');time.sleep(2.2);still=db_snapshot()
result={'captureStarted':True,'events':events,'pausedUI':paused,'afterPauseDB':after,'afterPausedXYZDB':still,'expectedUVWEachOne':all(after['histogram'].get(k)==1 for k in ['U','V','W']),'expectedTotalKeysThree':after['keyPresses']==3,'pausedXYZDidNotChangeDB':after==still,'textRecordingStayedOff':after['textRecordCount']==0 and still['textRecordCount']==0,'postPauseScreenshotSHA256':screenshot_to('capture-paused.png'),'EngineInjected':False,'clipboardRead':False,'hardwareInputVerified':False,'scope':'Actual production RegisterRawInputDevices/WM_INPUT/normal timer flush/SQLite path in Wine; XTEST input only, not Windows hardware proof.'}
pathlib.Path('/tmp/capture-exercise.json').write_text(json.dumps(result));print(json.dumps(result))
raise SystemExit(0 if result['expectedUVWEachOne']and result['expectedTotalKeysThree']and result['pausedXYZDidNotChangeDB']else 1)
'''

DASHBOARD = r'''
s=inspect();assert control(s,101)['label']=='Start collection','dashboard check must run while paused'
event=click(102,['Open dashboard']);time.sleep(3)
ports=[]
for line in pathlib.Path('/proc/net/tcp').read_text().splitlines()[1:]:
 f=line.split()
 if f[3]=='0A'and f[1].split(':')[0]=='0100007F':ports.append(int(f[1].split(':')[1],16))
responses=[]
for port in ports:
 origin='http://127.0.0.1:'+str(port)
 try:
  with urllib.request.urlopen(origin+'/',timeout=3)as response:body=response.read(2*1024*1024);page=response.status
  try:urllib.request.urlopen(origin+'/api/status',timeout=3);status=200
  except urllib.error.HTTPError as error:status=error.code
  responses.append({'port':port,'pageStatus':page,'loginFormPresent':b'login-form'in body,'apiWithoutCredential':status})
 except Exception as error:responses.append({'port':port,'error':type(error).__name__})
result={'normalOpenDashboardButton':event,'windows':windows(),'loopbackResponses':responses,'authenticatedViewerVerified':False,'credentialBoundary':'Normal UI supplies ephemeral viewer credential only by explicit clipboard copy. Clipboard/memory/settings-secret reads and token bypass are prohibited, so authenticated browser statistics are not claimed.','screenshotSHA256':screenshot_to('capture-dashboard.png'),'processes':subprocess.run(['ps','-eo','pid,ppid,comm,stat'],stdout=subprocess.PIPE,text=True).stdout,'clipboardRead':False,'EngineInjected':False}
pathlib.Path('/tmp/capture-dashboard.json').write_text(json.dumps(result));print(json.dumps(result))
'''


STATUS_BOTTOM = r'''
import sys
exercise=json.loads(pathlib.Path('/tmp/capture-exercise.json').read_text());assert exercise['postPauseScreenshotSHA256']==sys.argv[1]
s=inspect();assert control(s,101)['label']=='Start collection'
c=control(s,205);assert c['visible']and c['class'].lower()=='edit'and c['style']&0x800 and c['style']&0x200000 and c['style']&4
l,t,r,b=c['rect'];assert 0<=l<r<=1280 and 0<=t<b<=1024
x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p;x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p];x.XStringToKeysym.argtypes=[ctypes.c_char_p];x.XStringToKeysym.restype=ctypes.c_ulong;x.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x.XKeysymToKeycode.restype=ctypes.c_ubyte
q=ctypes.CDLL('libXtst.so.6');q.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong];q.XTestFakeButtonEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong];q.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
d=x.XOpenDisplay(b':99');assert d
q.XTestFakeMotionEvent(d,0,l+20,t+20,0);q.XTestFakeButtonEvent(d,1,1,0);q.XTestFakeButtonEvent(d,1,0,0);x.XFlush(d)
ctrl=x.XKeysymToKeycode(d,x.XStringToKeysym(b'Control_L'));end=x.XKeysymToKeycode(d,x.XStringToKeysym(b'End'));assert ctrl and end
q.XTestFakeKeyEvent(d,ctrl,1,0);q.XTestFakeKeyEvent(d,end,1,0);q.XTestFakeKeyEvent(d,end,0,0);q.XTestFakeKeyEvent(d,ctrl,0,0);x.XFlush(d);x.XCloseDisplay(d);time.sleep(1.5)
after=db_snapshot();assert after==exercise['afterPausedXYZDB']
result={'statusControlClass':c['class'],'readOnly':bool(c['style']&0x800),'multiline':bool(c['style']&4),'verticalScroll':bool(c['style']&0x200000),'ordinaryPointerAndCtrlEnd':True,'SendMessage':False,'WM_COMMAND':False,'clipboardRead':False,'pausedDBUnchanged':True,'screenshotSHA256':screenshot_to('capture-status-bottom.png')}
pathlib.Path('/tmp/capture-status-scroll.json').write_text(json.dumps(result));print(json.dumps(result))
'''

QUIT = r'''
import sys
exercise=json.loads(pathlib.Path('/tmp/capture-exercise.json').read_text());assert exercise['postPauseScreenshotSHA256']==sys.argv[1]
s=inspect();assert control(s,101)['label']=='Start collection','Quit check must begin paused'
event=click(107,['Quit KeyTrail']);event['reviewedPausedScreenshotSHA256']=sys.argv[1];event['method']='XTEST ordinary visible Quit button pointer click'
pathlib.Path('/tmp/capture-quit.json').write_text(json.dumps(event));print(json.dumps(event))
'''

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def literal(path, name):
    module = ast.parse(path.read_text())
    return next(ast.literal_eval(n.value) for n in module.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in n.targets))


def main():
    global APP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", "--output-directory", dest="output", type=pathlib.Path)
    parser.add_argument("--app-directory", type=pathlib.Path, default=APP)
    parser.add_argument("--quit-reviewed-sha")
    parser.add_argument("--status-bottom-reviewed-sha")
    parser.add_argument("--exercise-reviewed-sha")
    parser.add_argument("--dashboard", action="store_true")
    parser.add_argument("--finish", action="store_true")
    args = parser.parse_args()
    APP = args.app_directory.resolve()
    out = (args.output or ROOT / "artifacts" / ("windows-capture-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))).resolve()
    helpers = literal(ROOT / "scripts/diagnose-windows-wine-gui.py", "WORKER")
    helpers = helpers[helpers.index("class Attributes("):helpers.index("trace=open('/tmp/gui-relay.log'")]
    image_helpers = literal(ROOT / "scripts/test-windows-wine-ui-quit.py", "BODY")
    image_helpers = image_helpers[image_helpers.index("class Image("):image_helpers.index("def inspect():")]
    if args.exercise_reviewed_sha or args.dashboard or args.finish or args.quit_reviewed_sha or args.status_bottom_reviewed_sha:
        run = json.loads((out / "run.json").read_text());name = run["containerName"]
        if args.finish:
            return subprocess.run(["docker", "exec", name, "touch", "/tmp/capture-finish"]).returncode
        if args.exercise_reviewed_sha:assert sha(out / "capture-initial.png") == args.exercise_reviewed_sha
        if args.quit_reviewed_sha:assert sha(out / "capture-paused.png") == args.quit_reviewed_sha
        if args.status_bottom_reviewed_sha:assert sha(out / "capture-paused.png") == args.status_bottom_reviewed_sha
        code = "import ctypes,hashlib,json,pathlib,sqlite3,struct,subprocess,time,urllib.request,urllib.error,zlib\n" + helpers + image_helpers + COMMON + (EXERCISE if args.exercise_reviewed_sha else (QUIT if args.quit_reviewed_sha else (STATUS_BOTTOM if args.status_bottom_reviewed_sha else DASHBOARD)))
        command = ["docker", "exec", "-e", "DISPLAY=:99", name, "python3", "-u", "-c", code]
        if args.exercise_reviewed_sha:command.append(args.exercise_reviewed_sha)
        if args.quit_reviewed_sha:command.append(args.quit_reviewed_sha)
        if args.status_bottom_reviewed_sha:command.append(args.status_bottom_reviewed_sha)
        action = subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (out / ('quit-command.log' if args.quit_reviewed_sha else ('exercise-command.log' if args.exercise_reviewed_sha else ('status-scroll-command.log' if args.status_bottom_reviewed_sha else 'dashboard-command.log')))).write_text(action.stdout)
        print(action.stdout,end='')
        if args.exercise_reviewed_sha and action.returncode==0:
            for remote,local in [('capture-exercise.json','exercise.json')]:
                saved=subprocess.run(['docker','exec',name,'cat','/tmp/'+remote],stdout=subprocess.PIPE,check=True);(out/local).write_bytes(saved.stdout)
            saved=subprocess.run(['docker','exec',name,'base64','-w0','/tmp/capture-paused.png'],stdout=subprocess.PIPE,check=True);(out/'capture-paused.png').write_bytes(base64.b64decode(saved.stdout,validate=True))
        if args.status_bottom_reviewed_sha and action.returncode==0:
            for name in ['capture-status-bottom.png','capture-status-scroll.json']:
                saved=subprocess.run(['docker','exec',run['containerName'],'cat','/tmp/'+name],stdout=subprocess.PIPE,check=True);(out/name).write_bytes(saved.stdout)
        return action.returncode
    out.mkdir(parents=True, exist_ok=False);tools = out / "tools";tools.mkdir()
    (tools / "capture-inspect.c").write_text(INSPECTOR)
    built = subprocess.run(["docker", "run", "--rm", "--network", "none", "-i", "keytrail-windows-builder:1.2", "sh", "-c", "x86_64-w64-mingw32-gcc -Wall -Werror -O2 -x c - -o /tmp/inspect.exe -luser32 && base64 -w0 /tmp/inspect.exe"], input=INSPECTOR.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    (tools / "capture-inspect.exe").write_bytes(base64.b64decode(built.stdout, validate=True))
    name = "keytrail-capture-" + uuid.uuid4().hex[:10]
    image = json.loads(subprocess.run(["docker", "image", "inspect", IMAGE], stdout=subprocess.PIPE, text=True, check=True).stdout)[0]
    run = {"containerName": name, "image": IMAGE, "imageId": image["Id"], "productionEXESHA256": sha(APP / "keytrail-windows.exe"), "nativeSourceSHA256": sha(ROOT / "rust/keytrail-windows/src/native.rs"), "textCaptureSourceSHA256":sha(ROOT / "rust/keytrail-windows/src/text_capture.rs"), "textCoordinatorSourceSHA256":sha(ROOT / "rust/keytrail-windows/src/text_snapshot.rs"), "inspectorSHA256": sha(tools / "capture-inspect.exe"), "normalArgs": [], "demo": False, "network": "none", "hostUserDirectoriesMounted": False, "inputMethod": "XTEST synthetic ordinary UI/key events", "compatibilityLayerNotWindowsKernel": True}
    (out / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    worker = BASE + helpers + image_helpers + COMMON + RUN
    command = ["docker", "run", "--rm", "--name", name, "--platform", "linux/amd64", "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,exec,size=1073741824,mode=1777", "-e", "HOME=/tmp/home", "-e", "WINEPREFIX=/tmp/keytrail-wine", "--mount", f"type=bind,src={APP},dst=/app,readonly", "--mount", f"type=bind,src={tools},dst=/tools,readonly", IMAGE, "python3", "-u", "-c", worker]
    try:
        process = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=360)
        code, output = process.returncode, process.stdout
    except subprocess.TimeoutExpired as error:
        code = 124;output = error.stdout or b""
        if isinstance(output, bytes):output = output.decode("utf-8", "replace")
        subprocess.run(["docker", "rm", "-f", name], timeout=10, stdout=subprocess.DEVNULL)
    saved_files=[];plain=[]
    for line in output.splitlines():
        if line.strip().startswith('CAPTURE_FILE64='):
            item=json.loads(line.strip()[len('CAPTURE_FILE64='):]);assert item['name']in ['capture-initial.png','capture-paused.png','capture-status-bottom.png','capture-dashboard.png','capture-statistics.sqlite']
            payload=base64.b64decode(item['base64'],validate=True);assert hashlib.sha256(payload).hexdigest()==item['sha256'];(out/item['name']).write_bytes(payload);saved_files.append({'name':item['name'],'sha256':item['sha256'],'bytes':len(payload)})
            plain.append('EXPORTED_SYNTHETIC_FILE='+json.dumps(saved_files[-1]))
        else:plain.append(line)
    (out / "capture.log").write_text('\n'.join(plain)+'\n')
    rows = [line.strip()[len("CAPTURE_RESULT="):] for line in output.splitlines() if line.strip().startswith("CAPTURE_RESULT=")]
    run.update(containerExitCode=code, result=json.loads(rows[-1]) if rows else None, exportedSyntheticFiles=saved_files)
    (out / "verification.json").write_text(json.dumps(run, indent=2) + "\n")
    print(json.dumps({"output": str(out), "containerExitCode": code, "hasResult": bool(rows)}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
