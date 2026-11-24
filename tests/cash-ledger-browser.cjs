const {chromium}=require('playwright'),fs=require('fs'),assert=require('node:assert/strict');
(async()=>{
 const html=fs.readFileSync('index.html','utf8');
 const section=html.split('// ===== Общий отчет =====')[1].split('// ---------- Открытие ----------')[0];
 const staff=html.slice(html.indexOf('let grStaffChain='),html.indexOf('// Кнопки на итоге смены.'));
 const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 const page=await browser.newPage();await page.setContent('<div id="grBody"></div><div id="grWrap"></div>');
 await page.addScriptTag({path:'formula.js'});
 await page.addScriptTag({content:`var isAdmin=true;var $=id=>document.getElementById(id);var esc=s=>String(s);${section}
 const sheet={title:'Выручка',data:{ncols:19,styles:[],rows:{'1':{A:{v:'Дата'},P:{v:'Факт в кассе'},Q:{v:'Расхождения'},R:{v:'Комментарий'},S:{v:'Итого в кассе'}},'2':{A:{v:46054},P:{v:3200},S:{v:3300},Q:{v:100}}}}};
 gr.sheets=[sheet];$('grWrap').innerHTML=grTableHTML(sheet,1,2,grCan,2);window.canActual=grCan('P2');window.canTotal=grCan('S2');window.canDifference=grCan('Q2');
 var grMsg=()=>{},grPaint=()=>{},grParseInput=t=>({v:Number(t)});
 ${staff}
 gr.staff={sheet,row:2,cols:['P'],past:[]};gr.shiftId=1;var calls=[];
 var db={rpc:async(fn)=>{calls.push(fn);return fn==='report_staff_view'?{data:{data:{rows:{'2':{P:{v:3400}},'3':{S:{v:3500},Q:{v:50}}}}}}:{data:{'2':{P:{v:3400}}}}}};
 window.update=async()=>{grStaffSet('P2','3400');await grStaffChain;return {calls,rows:sheet.data.rows}};
 `});
 const headers=await page.locator('thead th').allTextContents();assert.ok(headers.indexOf('S')<headers.indexOf('P'));assert.ok(headers.indexOf('P')<headers.indexOf('Q'));
 assert.equal(await page.evaluate(()=>canActual),true);assert.equal(await page.evaluate(()=>canTotal),false);assert.equal(await page.evaluate(()=>canDifference),false);
 const updated=await page.evaluate(()=>update());assert.equal(updated.rows['3'].S.v,3500);assert.deepEqual(updated.calls,['report_staff_set','report_staff_view']);
 await browser.close();console.log('PASS cash report UI: total beside actual, computed columns read-only, manual actual, next-day live refresh.');
})().catch(e=>{console.error(e);process.exit(1)});
