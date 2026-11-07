import assert from 'node:assert/strict';
import {createHandler} from '../supabase/functions/client-updates/handler.ts';
const publisher='https://publisher.supabase.co',client='https://client.supabase.co',origin='https://owner.example';
const uuid='11111111-1111-4111-8111-111111111111';
function harness(options={}){
  const calls=[];let current={id:1,status:options.status||'offered',publisher_project:'publisher',images:[]};
  const fetchImpl=async(url,opts={})=>{
    calls.push({url,...opts});
    if(url===publisher+'/auth/v1/user')return Response.json(options.invalid?{error:'Invalid token'}:{id:uuid,user_metadata:{role:'admin'}},{status:options.invalid?401:200});
    if(url.startsWith(publisher+'/rest/v1/staff_accounts'))return Response.json([{user_id:uuid,role:options.role||'admin',active:options.active!==false}]);
    if(url.startsWith(client+'/storage/'))return Response.json({ok:true});
    if(url.startsWith(client+'/rest/v1/site_updates')){
      if(opts.method==='POST'||opts.method==='PATCH'){
        if(options.conflict)return Response.json([]);
        if(options.dbFailure)return Response.json({error:'fail'},{status:500});
        return Response.json([{...current,...JSON.parse(opts.body)}]);
      }
      return Response.json(options.missing?[]:[current]);
    }
    throw Error('Unexpected URL '+url);
  };
  const handler=createHandler({clientUrl:client,clientServiceKey:'server-secret',publisherUrl:publisher,publisherKey:'public-publisher-key',allowedOrigins:[origin],fetchImpl,randomUUID:()=>uuid});
  const request=(body,headers={})=>handler(new Request('https://client/functions/v1/client-updates',{method:'POST',headers:{Authorization:'Bearer test-session',origin,'Content-Type':'application/json',...headers},body:JSON.stringify(body)}));
  return {calls,request,handler};
}
let count=0;
async function check(name,fn){await fn();count++;console.log('PASS',name)}
await check('Reject missing bearer before contacting any server',async()=>{const h=harness();assert.equal((await h.request({action:'list'},{Authorization:''})).status,401);assert.equal(h.calls.length,0)});
await check('Reject other origins before contacting any server',async()=>{const h=harness();assert.equal((await h.request({action:'list'},{origin:'https://untrusted.example'})).status,403);assert.equal(h.calls.length,0)});
await check('Verify session at issuer, not JWT metadata',async()=>{const h=harness({invalid:true});assert.equal((await h.request({action:'list'})).status,401);assert.equal(h.calls.length,1)});
await check('Reject ordinary employee even with admin user_metadata',async()=>{const h=harness({role:'staff'});assert.equal((await h.request({action:'list'})).status,403);assert.ok(!h.calls.some(c=>c.url.startsWith(client)))});
await check('Reject disabled administrator',async()=>{const h=harness({active:false});assert.equal((await h.request({action:'list'})).status,403)});
await check('Only access this publisher offers and never leak client service key upstream',async()=>{const h=harness();assert.equal((await h.request({action:'list'})).status,200);assert.ok(h.calls.at(-1).url.includes('publisher_project=eq.publisher'));for(const c of h.calls.filter(c=>c.url.startsWith(publisher)))assert.ok(!JSON.stringify(c).includes('server-secret'))});
await check('Create offer with server-assigned publisher identity',async()=>{const h=harness();const r=await h.request({action:'save',title:'Новое обновление',price:123.45,description:'Описание',publisher_project:'attacker',publisher_user_id:'attacker'});assert.equal(r.status,200);const body=(await r.json()).update;assert.equal(body.publisher_project,'publisher');assert.equal(body.publisher_user_id,uuid);assert.equal(body.price,123.45)});
await check('Reject editing accepted offer',async()=>{const h=harness({status:'accepted'});assert.equal((await h.request({action:'save',id:1,title:'Changed',price:0})).status,409)});
await check('Reject installation before customer consent',async()=>{const h=harness();assert.equal((await h.request({action:'set_status',id:1,status:'installed'})).status,409)});
await check('Allow marking accepted offer installed',async()=>{const h=harness({status:'accepted'});const r=await h.request({action:'set_status',id:1,status:'installed'});assert.equal(r.status,200);assert.ok((await r.json()).update.installed_at)});
await check('Handle concurrent customer decision without overwriting it',async()=>{const h=harness({conflict:true});assert.equal((await h.request({action:'set_status',id:1,status:'withdrawn'})).status,409)});
await check('Reject negative prices',async()=>{const h=harness();assert.equal((await h.request({action:'save',title:'Offer',price:-1})).status,400)});
await check('Reject images with disguised content',async()=>{const h=harness();assert.equal((await h.request({action:'save',title:'Offer',price:0,files:[{mime:'image/png',base64:btoa('<script>bad</script>')}]})).status,400);assert.ok(!h.calls.some(c=>c.url.includes('/storage/')))});
await check('Clean up only newly uploaded files after failed insert',async()=>{const h=harness({dbFailure:true});const bytes=String.fromCharCode(137,80,78,71,13,10,26,10);assert.equal((await h.request({action:'save',title:'Offer',price:0,files:[{mime:'image/png',base64:btoa(bytes)}]})).status,500);const cleanup=h.calls.find(c=>c.method==='DELETE');assert.deepEqual(JSON.parse(cleanup.body),{prefixes:['updates/'+uuid+'.png']})});
console.log(count+' security and workflow checks passed');
