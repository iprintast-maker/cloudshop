import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const src=readFileSync('supabase/functions/telegram-purchase/index.ts','utf8').replace(/^import .*$/m,'');
async function check({username='iv_olya',type='private',fromId=77,chatId=77,secret='test-secret',allowed=true}={}){
 const calls=[],sent=[];let handler;
 const context={Response,console,Date,Deno:{env:{get:()=>''},serve:fn=>handler=fn},createClient:()=>({rpc:async(name,args)=>{calls.push({name,args});if(name==='telegram_purchase_config')return {data:{token:'FAKE',secret:'test-secret'}};if(name==='telegram_claim_recipient')return {data:username==='iv_olya'&&allowed};return {data:allowed?[]:null}}}),fetch:async(url,opt)=>{sent.push(JSON.parse(opt.body));return Response.json({ok:true})}};
 vm.runInNewContext(stripTypeScriptTypes(src),context);
 const result=await handler(new Request('https://test.local',{method:'POST',headers:{'X-Telegram-Bot-Api-Secret-Token':secret},body:JSON.stringify({message:{text:'/start',chat:{id:chatId,type},from:{id:fromId,username}}})}));
 return {calls,sent,status:result.status};
}
const yes=await check();assert.equal(yes.status,200);assert.equal(yes.sent.length,2);assert.ok(yes.sent[0].text.includes('21:00'));
const stranger=await check({username:'stranger',allowed:false});assert.equal(stranger.sent.length,0);
for(const args of [{type:'group'},{fromId:88}]){const r=await check(args);assert.equal(r.calls.some(c=>c.name==='telegram_claim_recipient'),false)}
const forged=await check({secret:'wrong'});assert.equal(forged.status,403);assert.equal(forged.sent.length,0);assert.equal(forged.calls.length,1);
console.log('Passed: approved welcome, unknown user blocked, group and mismatched sender cannot claim, forged webhook blocked');
