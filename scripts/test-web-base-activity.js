/* Real synthetic service: mandatory keyboard/mouse/union metrics survive fun OFF. */
'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process'),net=require('node:net'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {chromium,webkit}=require('playwright');
const root=path.resolve(__dirname,'..'),art=path.join(root,'artifacts'),out=path.join(art,'base-activity-web');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
async function main(){
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'keytrail-base-activity-'));fs.mkdirSync(out,{recursive:true});
 let child,browser;const profiles=[],embeddedWebSHA256={};
 try{
  const port=await new Promise(resolve=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p))})});
  const account={id:'base-activity-fixture',deviceId:'fixture-only',collectorToken:crypto.randomBytes(32).toString('hex'),viewerToken:crypto.randomBytes(32).toString('hex')};
  const config=path.join(temp,'config.json');fs.writeFileSync(config,JSON.stringify({bind:`127.0.0.1:${port}`,dataDir:path.join(temp,'data'),demoData:true,accounts:[account]}),{mode:0o600});
  child=cp.spawn(path.join(root,'rust/target/release/keytrail-server'),['serve',config],{stdio:'ignore'});const origin=`http://127.0.0.1:${port}`;
  async function api(route,body,collector=false){const r=await fetch(origin+route,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${collector?account.collectorToken:account.viewerToken}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});assert.equal(r.status,200);const j=await r.json();assert.equal(j.ok,true);return j.result}
  let ready=false;for(let i=0;i<100;i++){try{await api('/api/status');ready=true;break}catch{}assert.equal(child.exitCode,null);await new Promise(r=>setTimeout(r,50))}assert.ok(ready);
  for(const name of fs.readdirSync(path.join(root,'web'))){const actual=Buffer.from(await(await fetch(origin+'/'+name)).arrayBuffer()),expected=fs.readFileSync(path.join(root,'web',name));assert.deepEqual(actual,expected);embeddedWebSHA256[name]=hash(actual)}assert.equal(Object.keys(embeddedWebSHA256).length,8);
  const start=1704067200,end=start+120,mask=(offset,length)=>(((1n<<BigInt(length))-1n)<<BigInt(offset)).toString();
  const records=[{keys:1,keyCounts:{A:1},keyboardMask:mask(0,30),mouseMask:mask(20,40)},{keys:2,keyCounts:{B:2},keyboardMask:mask(0,10),mouseMask:mask(10,20)}];
  const changes=records.map((record,i)=>({revision:i+1,minute:start+i*60,deleted:false,record:{leftClicks:1,rightClicks:0,middleClicks:0,distance:10,scroll:1,...record}}));
  await api('/api/sync',{deviceId:account.deviceId,changes},true);
  const summary=await api('/api/query',{op:'summary',start,end});assert.deepEqual([summary.keyboardActiveSeconds,summary.mouseActiveSeconds,summary.totalActiveSeconds],[40,60,90]);
  for(const [engine,launcher]of[['chromium',chromium],['webkit',webkit]]){
   browser=await launcher.launch({headless:true,...(engine==='chromium'&&process.env.KEYTRAIL_CHROMIUM_EXECUTABLE?{executablePath:process.env.KEYTRAIL_CHROMIUM_EXECUTABLE}:{})});
   const page=await browser.newPage({viewport:{width:1200,height:1000},locale:'zh-CN',timezoneId:'Asia/Shanghai'}),errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(origin);
   await page.locator('#token').fill(account.viewerToken);await page.getByRole('button',{name:'连接',exact:true}).click();await page.locator('#dashboard').waitFor({state:'visible'});await page.waitForFunction(()=>!document.querySelector('#refresh').disabled);
   async function applyRange(a,b){await page.locator('#preset').selectOption('custom');await page.evaluate(({a,b})=>{document.querySelector('#start').value=localInput(new Date(a*1000));document.querySelector('#end').value=localInput(new Date(b*1000));},{a,b});await page.getByRole('button',{name:'查看',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('#refresh').disabled)}
   async function values(expected){const data=await page.locator('#metrics article').evaluateAll(items=>Object.fromEntries(items.map(el=>[el.querySelector('small').textContent,el.querySelector('strong').textContent])));assert.equal(Object.keys(data).length,6);for(const[k,v]of Object.entries(expected))assert.equal(data[k],v);assert.equal(await page.locator('#metrics').isVisible(),true)}
   await applyRange(start,end);const expected={'键盘活跃时间':'0.7 分钟','鼠标活跃时间':'1 分钟','联合活跃时间':'1.5 分钟'};await values(expected);
   assert.equal(await page.getByRole('heading',{name:'趣味视角',exact:true}).isVisible(),true);await page.locator('#fun-toggle').uncheck();await values(expected);assert.equal(await page.getByRole('heading',{name:'趣味视角',exact:true}).isVisible(),false);assert.equal(await page.locator('#interaction').isVisible(),false);
   const report=await page.locator('#report').textContent();assert.match(report,/键盘活跃 0.7 分钟；鼠标活跃 1 分钟；键鼠联合活跃 1.5 分钟/);assert.equal(report.includes('BPM'),false);
   const downloaded=page.waitForEvent('download');await page.locator('#export-report').click();const download=await downloaded;assert.equal(fs.readFileSync(await download.path(),'utf8'),report);
   assert.equal(await page.locator('#metrics').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length),3);
   await page.screenshot({path:path.join(out,engine+'-desktop.png'),fullPage:true});
   await page.setViewportSize({width:390,height:844});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert.equal(await page.locator('#metrics').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length),2);await values(expected);await page.screenshot({path:path.join(out,engine+'-mobile.png'),fullPage:true});
   await applyRange(end,end+60);await values({'键盘活跃时间':'0 分钟','鼠标活跃时间':'0 分钟','联合活跃时间':'0 分钟'});assert.match(await page.locator('#report').textContent(),/键盘活跃 0 分钟；鼠标活跃 0 分钟；键鼠联合活跃 0 分钟/);
   assert.deepEqual(errors,[]);profiles.push({engine,browserVersion:browser.version(),asymmetricActivitySeconds:[40,60,90],baseCards:6,funOffKeepsAllActivity:true,funOffHidesEntireFunPanel:true,reportAndDownloadedTXTMatch:true,emptyRangeClearsAllValues:true,desktopColumns:3,mobileColumns:2,mobileOverflow:false});await browser.close();browser=null;
  }
  const result={passed:true,synthetic:true,embeddedWebSHA256,profiles,scope:'Actual Rust replica and browser rendering; no input capture, mobile OS or physical-device claim.'};fs.writeFileSync(path.join(art,'v1.2-web-base-activity-verification.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
 }finally{
  if(browser)await browser.close();if(child&&child.exitCode===null){child.kill('SIGTERM');await new Promise(resolve=>{child.once('exit',resolve);setTimeout(()=>{if(child.exitCode===null)child.kill('SIGKILL');resolve()},5000).unref()})}fs.rmSync(temp,{recursive:true,force:true});
 }
}
main().catch(e=>{console.error(e.stack||e);process.exitCode=1});
