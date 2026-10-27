'use strict';
/* Read-only, bounded CSV export. Core cursors freeze database identity, version and exact range. */
(()=>{
 const id=x=>document.getElementById(x),encoder=new TextEncoder(),MAX_BYTES=4*1024*1024,MAX_PAGES=4;
 let run=0,working=false,state=null;
 const message=(text,error=false)=>{id('csv-export-status').textContent=text;id('csv-export-status').classList.toggle('error',error)};
 function controls(){id('export-csv').disabled=working||!!(state&&!state.complete);id('csv-export-next').disabled=working||!state||state.complete;id('csv-export-cancel').disabled=!state||state.complete;id('csv-export-manifest').disabled=working||!state?.complete||state.parts.length<2;}
 const scopeText=x=>`${new Date(x.start*1000).toLocaleString()}（含）–${new Date(x.end*1000).toLocaleString()}（不含）`;
 function identity(source){if(typeof source.replicaId!=='string'||typeof source.deviceId!=='string')throw Error('统计来源身份无效。');return JSON.stringify([source.accountId??null,source.replicaId,source.deviceId,source.localOnly===true,source.demoData===true])}
 function current(ticket,connection){if(ticket!==run||connection!==sessionGeneration||!state)throw Error('CSV 导出已取消或连接已改变。')}
 async function verify(ticket,connection){current(ticket,connection);const source=await api('/api/status');current(ticket,connection);if(identity(source)!==state.source)throw Error('统计来源或账户已变化，CSV 导出已失效，请重新开始。');if(state.snapshot){await query({op:'exportValidate',snapshot:state.snapshot});current(ticket,connection)}}
 function abandon(text,error=false){run++;working=false;state=null;controls();message(text,error)}
 function fail(e,ticket){if(ticket!==run)return;abandon(`${e.name==='AbortError'?'连接超时':e.message} 导出未完成，先前下载分片不能当作完整导出，请重新开始。`,true)}
 async function exportPart(reset){if(working||(!reset&&!state))return;const ticket=++run,connection=sessionGeneration;working=true;controls();try{
  if(reset){if(!snapshot)throw Error('请先应用要导出的统计范围。');const range={...snapshot.r};state={...range,connection,cursor:null,snapshot:null,source:null,header:null,totalRows:null,rows:0,parts:[],complete:false,name:`KeyTrail-minutes-${Date.now()}-${crypto.randomUUID().slice(0,8)}`};const source=await api('/api/status');current(ticket,connection);state.source=identity(source);}
  await verify(ticket,connection);let chunks=[],rows=0,size=state.header===null?0:encoder.encode(state.header).length,hasMore=true;
  for(let i=0;i<MAX_PAGES&&hasMore;i++){
   current(ticket,connection);const request={op:'exportPage',start:state.start,end:state.end,limit:500};if(state.cursor)request.cursor=state.cursor;
   const page=await query(request);current(ticket,connection);const checked=KeyTrailMetrics.validateCSVPage(page,state);if(state.snapshot===null){state.snapshot=page.snapshot;state.header=page.header;state.totalRows=page.totalRows;size=encoder.encode(page.header).length;}
   if(size+checked.bytes>MAX_BYTES)throw Error('CSV 分片超过客户端有界预算，未下载部分内容。');chunks.push(page.csv);rows+=page.rowCount;size+=checked.bytes;state.rows+=page.rowCount;state.cursor=page.nextCursor;hasMore=page.hasMore;
   message(`CSV 完整导出尚未完成：冻结范围 ${scopeText(state)}；已读取 ${state.rows} / ${state.totalRows} 行，当前片 ${rows} 行。`);
  }
  if(!hasMore&&state.rows!==state.totalRows)throw Error('CSV 最后一页行数不完整。');await verify(ticket,connection);
  const text=state.header+chunks.join(''),hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(text))),b=>b.toString(16).padStart(2,'0')).join('');current(ticket,connection);
  // Browser download has a definite boundary: cancellation before this check publishes nothing from this batch.
  const single=state.parts.length===0&&!hasMore,name=single?'KeyTrail-minutes.csv':`${state.name}.part-${String(state.parts.length+1).padStart(5,'0')}.csv`;
  download(name,text,'text/csv;charset=utf-8');state.parts.push({name,rows,bytes:size,sha256:hash});state.complete=!hasMore;
  if(single){message(`已完整导出分钟 CSV：${scopeText(state)}；共 ${state.rows} 行，文件 ${name}。`);notice('所选范围的分钟 CSV 已完整导出。');}
  else message(`CSV ${state.complete?'全部扫描完成，请下载最终完成清单':'导出尚未完成，请继续下载下一片'}：冻结范围 ${scopeText(state)}；已读取 ${state.rows} / ${state.totalRows} 行，已下载 ${state.parts.length} 片。本次每片最多4MiB且含一次列头；取得最终清单并保存全部分片后才构成完整导出。`);
 }catch(e){fail(e,ticket)}finally{if(ticket===run){working=false;controls()}}}
 id('export-csv').addEventListener('click',()=>exportPart(true));id('csv-export-next').addEventListener('click',()=>exportPart(false));id('csv-export-cancel').addEventListener('click',()=>abandon('CSV 导出已取消，内存状态已丢弃；此前下载分片不是完整导出。'));
 id('csv-export-manifest').addEventListener('click',async()=>{if(working||!state?.complete)return;const ticket=++run,connection=state.connection;working=true;controls();try{await verify(ticket,connection);const x=state;download(`${x.name}.manifest.json`,JSON.stringify({format:'KeyTrail-minute-csv-parts-v1',complete:true,start:x.start,end:x.end,source:JSON.parse(x.source),snapshot:x.snapshot,rowCount:x.rows,totalRows:x.totalRows,parts:x.parts},null,2),'application/json');message(`CSV 完整扫描完成，已下载最终清单：${scopeText(x)}；${x.parts.length} 片、共 ${x.rows} 行。请核对每片文件及SHA-256；浏览器无法确认你是否已保存全部下载。`)}catch(e){fail(e,ticket)}finally{if(ticket===run){working=false;controls()}}});
 window.addEventListener('keytrail-disconnect',()=>abandon('连接已断开，CSV 导出已取消；先前分片不能当作完整导出。'));controls();
})();
