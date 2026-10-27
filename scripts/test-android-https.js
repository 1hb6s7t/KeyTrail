/* Actual Android Chrome trust of a temporary CA installed ONLY via Settings UI.
   NODE_PATH=<runtime>/node_modules node scripts/test-android-https.js
   No root, trust-file writes, certificate-warning bypass or host CA installation.
   Shared AVD/serial proxy lifecycle comes from test-android-os-web.js. */
'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),https=require('node:https'),crypto=require('node:crypto'),readline=require('node:readline'),assert=require('node:assert/strict');
const {runScenario}=require('./test-android-os-web.js');
const root=path.resolve(__dirname,'..');
runScenario({artifactStem:'v1.2-android-https',directory:'android-https',scenario:async({device,ownADB,temporary,out,result,checkpoint,sleep,bounded,registerSecret})=>{
 result.scope='Actual Android OS Chrome certificate validation through shipped nginx TLS fragment and synthetic viewer; no external hostname/VPN/physical-device claim';
 result.hostTrustChanged=false;result.certificateWarningsBypassed=false;result.ignoreHTTPSErrors=false;result.androidUserCAInstalled=false;
 const assetNames=['index.html','app.js','metrics.js','text.js','csv.js','style.css','sw.js','manifest.webmanifest'];
 const expectedAssets=Object.fromEntries(assetNames.map(name=>[name,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'web',name))).digest('hex')]));result.expectedWebSHA256=expectedAssets;
 const privateDir=path.join(temporary,'tls');fs.mkdirSync(privateDir,{mode:0o700});
 const account={id:'android-tls',deviceId:'android-tls-device',collectorToken:crypto.randomBytes(32).toString('hex'),viewerToken:crypto.randomBytes(32).toString('hex')};registerSecret(account.collectorToken);registerSecret(account.viewerToken);
 fs.writeFileSync(path.join(privateDir,'config.json'),JSON.stringify({bind:'127.0.0.1:8787',dataDir:'/state/data',demoData:true,accounts:[account]}),{mode:0o600});
 const stderr=fs.openSync(path.join(out,'tls-fixture.log'),'w'),helper=cp.spawn('/usr/bin/python3',[path.join(root,'scripts/fixtures/android_https_fixture.py'),privateDir],{stdio:['pipe','pipe',stderr]}),events=[],waiters=[];
 const lines=readline.createInterface({input:helper.stdout});lines.on('line',line=>{try{events.push(JSON.parse(line));for(const resolve of waiters.splice(0))resolve()}catch{}});
 const nextEvent=async(name,timeout=60000)=>bounded((async()=>{while(true){const error=events.find(e=>e.event==='error');if(error&&name!=='stopped')throw Error(error.message);const index=events.findIndex(e=>e.event===name);if(index>=0)return events.splice(index,1)[0];if(helper.exitCode!==null)throw Error('TLS helper exited');await new Promise(resolve=>waiters.push(resolve))}})(),timeout,'TLS fixture '+name);
 let context,port;
 try{
  const ready=await nextEvent('ready');result.tlsFixture={images:ready.images,nginxFragmentSHA256:ready.nginxFragmentSHA256,origin:ready.origin,verifiedTLSAssets:ready.verifiedTLSAssets,embeddedWebSHA256:ready.embeddedWebSHA256};port=ready.port;
  const ca=fs.readFileSync(ready.caPath);result.caCertificateSHA256=crypto.createHash('sha256').update(ca).digest('hex');
  const request=(endpoint,body,collector=false)=>new Promise((resolve,reject)=>{const raw=body?Buffer.from(JSON.stringify(body)):null;const req=https.request(ready.origin+endpoint,{ca,rejectUnauthorized:true,method:raw?'POST':'GET',headers:{Authorization:'Bearer '+(collector?account.collectorToken:account.viewerToken),...(raw?{'Content-Type':'application/json','Content-Length':raw.length}:{})}},response=>{const chunks=[];response.on('data',data=>chunks.push(data));response.on('end',()=>{const bytes=Buffer.concat(chunks);if(endpoint.startsWith('/api/')){try{const value=JSON.parse(bytes);if(response.statusCode!==200||!value.ok)throw Error('TLS fixture API '+response.statusCode);resolve(value.result)}catch(error){reject(error)}}else resolve(bytes)})});req.setTimeout(5000,()=>req.destroy(Error('TLS host request timeout')));req.on('error',reject);if(raw)req.write(raw);req.end()});
  let readyOK=false;for(let i=0;i<80;i++){try{await request('/api/status');readyOK=true;break}catch{}await sleep(100)}assert.ok(readyOK,'Verified host TLS fixture readiness');
  ownADB(['reverse',`tcp:${port}`,`tcp:${port}`]);
  context=await bounded(device.launchBrowser({pkg:'com.android.chrome',viewport:null,acceptDownloads:true}),45000,'Android TLS Chrome launch');let page=await context.newPage();page.setDefaultTimeout(20000);
  let rejected=false;try{await page.goto(ready.origin+'/api/status',{timeout:15000})}catch(error){result.beforeInstallError=String(error).split('\n')[0];rejected=/ERR_CERT_AUTHORITY_INVALID/.test(String(error))}assert.ok(rejected,'Fresh Android Chrome must reject the unknown temporary CA');checkpoint('Android Chrome rejects untrusted CA before Settings installation');fs.writeFileSync(path.join(out,'before-ca-install.png'),await device.screenshot());
  // Only a PUBLIC CA certificate enters Downloads; keys never enter Android.
  await device.push(ca,'/sdcard/Download/KeyTrail-Android-TLS-CA.crt');
  const initialNativeButton=await bounded(device.info({clazz:'android.widget.Button'}),30000,'Official UiAutomator driver initialization');result.driverInitialized={pkg:initialNativeButton.pkg,clazz:initialNativeButton.clazz,text:initialNativeButton.text};result.uiSteps=[];result.settingsScrollActions=0;
  const shot=async(name)=>fs.writeFileSync(path.join(out,name+'.png'),await device.screenshot());
  const info=async(selector)=>{try{return await bounded(device.info(selector),2000,'Native control info')}catch{return null}};
  const tapNames=async(names,label,scroll=true)=>{
   for(let pass=0;pass<(scroll?7:1);pass++){
    for(const text of names){const found=await info({text});if(found){assert.equal(found.text,text);result.uiSteps.push({label,text:found.text,pkg:found.pkg,res:found.res,bounds:found.bounds});if(label==='install-anyway'){const {x,y,width,height}=found.bounds;ownADB(['shell',`input touchscreen tap ${Math.round(x+width/2)} ${Math.round(y+height/2)}`]);result.uiSteps[result.uiSteps.length-1].inputMethod='Android standard touchscreen tap at observed button center'}else await device.tap({text},{timeout:5000});await sleep(label==='install-anyway'?2000:700);await shot('ui-'+result.uiSteps.length);console.log('Normal UI tap:',label,found.text);return found}}
    if(!scroll||pass===6)break;
    const list=await info({scrollable:true});
    if(!list||!['com.android.settings','com.google.android.permissioncontroller','com.android.permissioncontroller'].includes(list.pkg))break;
    const {x,y,width,height}=list.bounds,from={x:Math.round(x+width/2),y:Math.round(y+height*.85)},to={x:Math.round(x+width/2),y:Math.round(y+height*.2)};
    result.settingsScrollActions++;result.uiSteps.push({label:'normal-android-input-touchscreen-swipe',pkg:list.pkg,res:list.res,bounds:list.bounds,from,to});
    ownADB(['shell',`input touchscreen swipe ${from.x} ${from.y} ${to.x} ${to.y} 500`]);await sleep(700);await shot('scroll-'+result.settingsScrollActions);console.log('Normal Settings upward swipe',result.settingsScrollActions);
   }
   await shot('blocked-'+label);throw Error('Normal Settings UI control unavailable: '+label);
  };
  // This launches the standard public Settings intent; every trust change below
  // is a visible native UI tap, never KeyChain/locksettings/content shell writes.
  await device.shell('am start -a android.settings.SETTINGS');await sleep(10000);await shot('settings-start');
  await tapNames(['Security & privacy'],'security-privacy');await sleep(5000);
  await tapNames(['More security & privacy','More security settings'],'more-security');
  await tapNames(['Encryption & credentials'],'encryption-credentials');
  await tapNames(['Install a certificate'],'install-certificate');
  await tapNames(['CA certificate'],'ca-certificate');
  await tapNames(['INSTALL ANYWAY','Install anyway'],'install-anyway',false);
  const downloadItem=await info({text:'KeyTrail-Android-TLS-CA.crt'});
  if(!downloadItem){const menu=await info({desc:'Show roots'});if(menu)await device.tap({desc:'Show roots'},{timeout:5000});await tapNames(['Downloads'],'downloads',false)}
  await tapNames(['KeyTrail-Android-TLS-CA.crt'],'certificate-file',false);
  // A protected credential/PIN page is not bypassed. Capture its current state;
  // success must be demonstrated by normal Chrome verification below.
  await sleep(1000);await shot('after-certificate-selection');
  await context.close();context=await bounded(device.launchBrowser({pkg:'com.android.chrome',viewport:null,acceptDownloads:true}),45000,'Chrome after CA UI');page=await context.newPage();page.setDefaultTimeout(20000);
  const response=await page.goto(ready.origin+'/api/status',{timeout:20000});assert.equal(response.status(),401);const security=await response.securityDetails();assert.ok(security&&/^TLS/.test(security.protocol));assert.ok(security.issuer.includes('KeyTrail Android temporary CA'));result.androidUserCAInstalled=true;result.chromeTLS=security;result.secureContext=await page.evaluate(()=>isSecureContext);assert.ok(result.secureContext);checkpoint('Normal Android Settings CA installation permits verified Chrome TLS connection');await shot('trusted-chrome-tls');
  result.embeddedWebSHA256={};for(const name of assetNames){const bytes=await request(name==='index.html'?'/':'/'+name);result.embeddedWebSHA256[name]=crypto.createHash('sha256').update(bytes).digest('hex');assert.equal(result.embeddedWebSHA256[name],expectedAssets[name],'TLS image must embed frozen current source '+name);assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'web',name))).digest('hex'),expectedAssets[name],'Source changed during Android TLS run '+name)}checkpoint('All eight TLS resources match source hashes frozen before fixture start');
  const end=Math.floor(Date.now()/60000)*60+60,start=end-180,changes=Array.from({length:3},(_,i)=>({revision:i+1,minute:start+i*60,deleted:false,record:{keys:i+1,leftClicks:1,rightClicks:0,middleClicks:0,distance:10,scroll:1,keyboardMask:'3',mouseMask:'2',keyCounts:{A:i+1}}}));await request('/api/sync',{deviceId:account.deviceId,changes},true);
  await page.goto(ready.origin);const apiURLs=[];page.on('request',request=>{if(new URL(request.url()).pathname.startsWith('/api/'))apiURLs.push(request.url())});
  await page.locator('#token').fill(account.viewerToken);await page.getByRole('button',{name:'连接',exact:true}).click();await page.locator('#dashboard').waitFor({state:'visible'});const idle=()=>page.waitForFunction(()=>!document.querySelector('#refresh').disabled);await idle();
  await page.evaluate(({start,end})=>{document.getElementById('start').value=localInput(new Date(start*1000));document.getElementById('end').value=localInput(new Date(end*1000));document.getElementById('preset').value='custom'},{start,end});await page.locator('#range-form button').click();await idle();
  const summary=await request('/api/query',{op:'summary',start,end});assert.equal(summary.keyPresses,6);assert.equal(summary.keyboardActiveSeconds,6);assert.equal(summary.mouseActiveSeconds,3);assert.equal(summary.totalActiveSeconds,6);assert.match(await page.locator('#metrics').textContent(),/键盘活跃/);assert.match(await page.locator('#metrics').textContent(),/鼠标活跃/);await page.locator('#fun-toggle').uncheck();assert.match(await page.locator('#metrics').textContent(),/键盘活跃/);assert.match(await page.locator('#metrics').textContent(),/鼠标活跃/);assert.ok(apiURLs.length>0&&apiURLs.every(url=>url.startsWith(ready.origin+'/api/')));result.summary=summary;result.allViewerAPIRequestsHTTPS=true;checkpoint('Viewer login, exact summary and fun-off independent activity metrics traverse actual TLS');
  const expected=await request('/api/query',{op:'exportPage',start,end,limit:500});assert.equal(expected.hasMore,false);await page.locator('#export-csv').click();let exists=false;for(let i=0;i<60;i++){const files=ownADB(['shell','find /sdcard/Download -maxdepth 1 -type f -print']).split('\n');if(files.includes('/sdcard/Download/KeyTrail-minutes.csv')){exists=true;break}await sleep(500)}assert.ok(exists,'Real Android TLS CSV must be saved');const target=path.join(out,'KeyTrail-minutes.csv');ownADB(['pull','/sdcard/Download/KeyTrail-minutes.csv',target]);const bytes=fs.readFileSync(target);assert.ok(bytes.equals(Buffer.from(expected.header+expected.csv)));result.csv={bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),rows:3,keys:6,exactCoreBytes:true,actualAndroidDownloads:true};checkpoint('CSV over trusted TLS saved in Android Downloads and matches complete Core bytes');await shot('tls-viewer-complete');
  await page.locator('#refresh').click();await idle();assert.equal(await page.evaluate(()=>snapshot.s.keyPresses),6);assert.equal(await page.locator('#preset').inputValue(),'custom');
  result.mobileLayout=await page.evaluate(()=>({width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth}));assert.ok(result.mobileLayout.scrollWidth<=result.mobileLayout.width+1,'Phone page must not overflow horizontally');
  const reportText=await page.locator('#report').textContent();assert.ok(reportText.length>0);await page.locator('#export-report').click();let reportSaved=false;for(let i=0;i<60;i++){if(ownADB(['shell','find /sdcard/Download -maxdepth 1 -type f -print']).split('\n').includes('/sdcard/Download/KeyTrail-report.txt')){reportSaved=true;break}await sleep(500)}assert.ok(reportSaved,'Real Android TLS report must be saved');const reportTarget=path.join(out,'KeyTrail-report.txt');ownADB(['pull','/sdcard/Download/KeyTrail-report.txt',reportTarget]);const reportBytes=fs.readFileSync(reportTarget);assert.equal(reportBytes.toString('utf8'),reportText);result.reportTXT={bytes:reportBytes.length,sha256:crypto.createHash('sha256').update(reportBytes).digest('hex'),sameAsRenderedReport:true,actualAndroidDownloads:true};await page.screenshot({path:path.join(out,'trusted-https-mobile-page.png'),fullPage:true});checkpoint('Trusted HTTPS mobile refresh, fixed custom range, layout and actual report download verified');
  await page.locator('#disconnect').click();assert.equal(await page.locator('#dashboard').isVisible(),false);assert.equal(await page.locator('#token').inputValue(),'');assert.equal(await page.locator('#report').textContent(),'');assert.equal(await page.locator('#text-results .text-entry').count(),0);result.disconnectClearsCredentialsAndReport=true;checkpoint('Disconnect clears in-memory credentials, report and text results');result.passed=true;
 }finally{
  if(context)try{await bounded(context.close(),5000,'TLS context close')}catch{}
  if(port)try{ownADB(['reverse','--remove',`tcp:${port}`])}catch{}
  if(helper.exitCode===null){helper.stdin.write(JSON.stringify({action:'stop'})+'\n');try{const stopped=await nextEvent('stopped',45000);result.tlsCleanup=stopped.cleanup}catch(error){result.tlsCleanupError=String(error);helper.kill('SIGTERM')}}
  await bounded(new Promise(resolve=>helper.exitCode!==null?resolve():helper.once('exit',resolve)),5000,'TLS helper exit').catch(()=>helper.kill('SIGTERM'));lines.close();fs.closeSync(stderr);
  result.passed=result.passed&&!!result.tlsCleanup&&Object.values(result.tlsCleanup).every(Boolean);
 }
}}).then(result=>{process.exit(result.passed?0:1)}).catch(error=>{console.error(String(error));process.exit(1)});
