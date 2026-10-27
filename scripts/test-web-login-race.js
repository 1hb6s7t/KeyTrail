/* Delayed real status responses exercise login/reconnect generations.
   Synthetic replica only; no collector, stored credentials, or real data.
   --expect-old-bug records the pre-fix public UI failure instead of passing it. */
'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),net=require('node:net'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {chromium,webkit}=require('playwright');
const root=path.resolve(__dirname,'..'),old=process.argv.includes('--expect-old-bug'),artifact=path.join(root,'artifacts',old?'v1.2-web-login-race-before.json':'v1.2-web-login-race-verification.json');
const result={synthetic:true,oldBugExpected:old,profiles:[],passed:false};
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve}};
(async()=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'keytrail-login-race-'));let child,browser;
 try{
  const port=await new Promise(resolve=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p))})});
  const account={id:'login-fixture',deviceId:'login-fixture-device',collectorToken:crypto.randomBytes(32).toString('hex'),viewerToken:crypto.randomBytes(32).toString('hex')};
  const config=path.join(temp,'config.json');fs.writeFileSync(config,JSON.stringify({bind:`127.0.0.1:${port}`,dataDir:path.join(temp,'data'),demoData:true,accounts:[account]}),{mode:0o600});
  child=cp.spawn(path.resolve(process.env.KEYTRAIL_SERVER||path.join(root,'rust/target/debug/keytrail-server')),['serve',config],{stdio:['ignore','ignore','ignore']});
  const origin=`http://127.0.0.1:${port}`;let ready=false;for(let i=0;i<100;i++){try{if((await fetch(origin+'/')).ok){ready=true;break}}catch{}await new Promise(r=>setTimeout(r,50))}assert.ok(ready);
  result.embeddedWebSHA256={};for(const name of['index.html','app.js','metrics.js','text.js','csv.js','style.css','sw.js','manifest.webmanifest']){const bytes=Buffer.from(await(await fetch(origin+'/'+name)).arrayBuffer());assert.ok(bytes.equals(fs.readFileSync(path.join(root,'web',name))),'stale embedded '+name);result.embeddedWebSHA256[name]=crypto.createHash('sha256').update(bytes).digest('hex')}
  for(const engine of old?[chromium]:[chromium,webkit]){
   browser=await engine.launch({headless:true,...(engine===chromium&&process.env.KEYTRAIL_CHROMIUM_EXECUTABLE?{executablePath:process.env.KEYTRAIL_CHROMIUM_EXECUTABLE}:{})});const context=await browser.newContext({locale:'zh-CN',timezoneId:'Asia/Shanghai'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
   const requests=[];page.on('request',r=>{if(r.url().includes('/api/'))requests.push(new URL(r.url()).pathname)});
   const started=deferred(),release=deferred();let first=true;
   await page.route('**/api/status',async route=>{if(first){first=false;started.resolve();await release.promise}await route.continue()});
   await page.goto(origin);await page.locator('#token').fill('f'.repeat(64));await page.locator('#login-form button').click();await started.promise;
   if(old){
    await page.locator('#token').fill(account.viewerToken);await page.locator('#login-form button').click();release.resolve();
    await page.waitForResponse(r=>r.url().endsWith('/api/status')&&r.status()===401);await page.waitForTimeout(150);
    await page.locator('#token').fill(account.viewerToken);await page.locator('#login-form button').click();await page.waitForTimeout(250);
    assert.equal(requests.filter(p=>p==='/api/status').length,1);assert.equal(await page.locator('#dashboard').isVisible(),false);assert.equal(await page.locator('#refresh').isDisabled(),true);
    result.profiles.push({engine:engine.name(),oldBugReproduced:true,attempts:3,statusRequests:1,dashboardHidden:true,refreshStayedDisabled:true});
   }else{
    assert.equal(await page.locator('#login-form button').isDisabled(),true);assert.equal(await page.locator('#token').isDisabled(),true);
    // A queued submit must be ignored before credential/generation mutation.
    await page.locator('#login-form').dispatchEvent('submit');release.resolve();await page.waitForFunction(()=>!document.querySelector('#token').disabled);
    assert.match(await page.locator('#notice').textContent(),/凭据无效/);assert.equal(requests.filter(p=>p==='/api/status').length,1);
    await page.locator('#token').fill(account.viewerToken);await page.locator('#login-form button').click();await page.locator('#dashboard').waitFor({state:'visible'});await page.waitForFunction(()=>!document.querySelector('#refresh').disabled);
    assert.match(await page.locator('#status').textContent(),/login-fixture-device/);
    // Disconnect during a slow visible refresh, then reconnect. The stale
    // status must not launch new queries or overwrite the new session.
    await page.unroute('**/api/status');const staleStarted=deferred(),staleRelease=deferred();let delayNext=true;
    await page.route('**/api/status',async route=>{if(delayNext){delayNext=false;staleStarted.resolve(route.request());await staleRelease.promise;await route.continue()}else await route.continue()});
    await page.locator('#refresh').click();const staleRequest=await staleStarted.promise;await page.locator('#disconnect').click();assert.equal(await page.locator('#token').isDisabled(),false);assert.equal(await page.locator('#refresh').isDisabled(),false);
    await page.locator('#token').fill(account.viewerToken);await page.locator('#login-form button').click();await page.locator('#dashboard').waitFor({state:'visible'});await page.waitForFunction(()=>!document.querySelector('#refresh').disabled);
    const count=requests.filter(p=>p==='/api/query').length;const staleFinished=page.waitForEvent('requestfinished',{predicate:request=>request===staleRequest});staleRelease.resolve();await staleFinished;await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));assert.equal(requests.filter(p=>p==='/api/query').length,count);assert.match(await page.locator('#status').textContent(),/login-fixture-device/);
    await page.locator('#refresh').click();await page.waitForFunction(()=>!document.querySelector('#refresh').disabled);assert.equal(await page.locator('#dashboard').isVisible(),true);
    assert.deepEqual(errors,[]);result.profiles.push({engine:engine.name(),browserVersion:browser.version(),doubleSubmitGuard:true,invalidLoginRestoresControls:true,retrySucceedsWithoutReload:true,disconnectReenablesControls:true,staleStatusDoesNotQueryNewSession:true,subsequentRefreshSucceeds:true});
   }
   await browser.close();browser=null;
  }
  result.passed=true;
 }catch(error){result.error=String(error);process.exitCode=1}
 finally{if(browser)await browser.close();if(child){child.kill('SIGTERM');await new Promise(resolve=>{if(child.exitCode!==null)return resolve();child.once('exit',resolve)})}fs.rmSync(temp,{recursive:true,force:true});fs.writeFileSync(artifact,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2))}
})();
