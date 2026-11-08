import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html=fs.readFileSync('index.html','utf8');
const code=html.slice(html.indexOf('let staffAccount=null;'),html.indexOf('window.editProduct=async'));
function setup(){
 const nodes=new Map(),classes=new Set();
 const node=id=>{if(!nodes.has(id))nodes.set(id,{style:{},textContent:'',classList:{toggle(){}}});return nodes.get(id)};
 const env={console,isAdmin:false,STAFF_LOGIN_REQUIRED:true,$:node,document:{body:{classList:{add:x=>classes.add(x),toggle:(x,on)=>on?classes.add(x):classes.delete(x)}}},open(){},close(){},render(){},setTimeout:()=>1,clearTimeout(){},userResult:{data:{user:{id:'a'}}},accountResult:{data:{user_id:'a',active:true,role:'admin',name:'Admin'}}};
 env.db={auth:{getUser:async()=>env.userResult},from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>env.accountResult})})})};
 vm.createContext(env);vm.runInContext(code,env);return {env,classes,nodes,run:()=>env.refreshAuth()};
}
const t=setup();await t.run();assert.equal(t.env.isAdmin,true);
t.env.userResult={data:{user:null},error:{name:'AuthRetryableFetchError',status:0}};await t.run();assert.equal(t.classes.has('staff-locked'),false);assert.equal(t.env.isAdmin,true);
t.env.userResult={data:{user:{id:'a'}}};t.env.accountResult={error:{message:'fetch failed'},status:0};await t.run();assert.equal(t.classes.has('staff-locked'),false);
t.env.accountResult={data:{user_id:'a',active:false,role:'admin'}};await t.run();assert.equal(t.env.isAdmin,false);assert.equal(t.classes.has('staff-locked'),true);
const b=setup();b.env.userResult={data:{user:null},error:{status:0}};await b.run();assert.equal(b.classes.has('staff-locked'),true);assert.equal(b.env.isAdmin,false);
const c=setup();await c.run();await c.env.refreshAuth(true);assert.equal(c.env.isAdmin,false);assert.equal(c.classes.has('staff-locked'),true);
const d=setup();await d.run();d.env.userResult={data:{user:null},error:{status:401}};await d.run();assert.equal(d.env.isAdmin,false);assert.equal(d.classes.has('staff-locked'),true);
console.log('Passed: successful verification, network errors in auth/staff query, disabled staff, cold offline start, sign-out, rejected token');

const race=setup();let finish;race.env.db.auth.getUser=()=>new Promise(resolve=>finish=resolve);const pending=race.run();await race.env.refreshAuth(true);finish({data:{user:{id:'a'}}});await pending;assert.equal(race.env.isAdmin,false);assert.equal(race.classes.has('staff-locked'),true);
console.log('Passed: late auth response cannot reopen a signed-out session');
