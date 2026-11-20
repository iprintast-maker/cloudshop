const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{parseHTML}=require('linkedom');
const html=fs.readFileSync('index.html','utf8');
const names=['Анна','Виталина','Даша'],people=names.map((name,i)=>({personId:i+1,employeeId:101+i,name,isActive:true,isLead:i===0}));
const context={shiftId:10,branchId:1,branchName:'Айпринт',status:'open',startedAt:new Date().toISOString(),participants:people};
function workspace(account){
 const {window,document}=parseHTML('<html><body><select id="saleEmployeeView"></select><p id="saleSessionInfo"></p><p id="saleStatus"></p><select id="salesEmployeeSelect"><option value="1">Анна</option><option value="2">Виталина</option><option value="3">Даша</option></select><select id="salesAdditionalEmployee"><option value="2">Виталина</option></select><input type="checkbox" id="salesAddEmployee"></body></html>');
 const c={window,document,console,staffAccount:account,salesSession:{...context,employeeId:101,personId:1,employeeName:'Анна'},saleContext:null,workspaceShift:context,$:id=>document.getElementById(id),esc:s=>s,persistSalesSession(){},updateSalesSessionUI(){},db:{rpc:async()=>({data:structuredClone(context)})}};
 vm.createContext(c);vm.runInContext(fs.readFileSync('cashier-identity.js','utf8'),c);c.IprintCashier=window.IprintCashier;
 const validate=html.slice(html.indexOf('async function validateSalesSession() {'),html.indexOf('function renderSaleCashiers() {'));
 const render=html.slice(html.indexOf('function renderSaleCashiers() {'),html.indexOf("$('saleEmployeeView').onchange=renderSaleCashiers;"));
 const selected=html.slice(html.indexOf('function selectedWorkspacePeople() {'),html.indexOf('function renderSalesWorkspaceOptions() {'));
 vm.runInContext(validate+render+selected,c);return c;
}
(async()=>{
 const pcs=people.map((p,i)=>workspace({user_id:'user-'+i,person_id:p.personId,name:p.name}));
 for(let i=0;i<pcs.length;i++){const pc=pcs[i];assert.equal(await pc.validateSalesSession(),true);assert.equal(pc.salesSession.employeeName,names[i]);assert.equal(pc.salesSession.shiftId,10);pc.saleContext={...pc.salesSession};pc.renderSaleCashiers();assert.equal(pc.$('saleEmployeeView').children.length,1);assert.equal(pc.$('saleEmployeeView').children[0].textContent,names[i]);assert.equal(pc.$('saleEmployeeView').disabled,true);assert.equal(pc.IprintCashier.bound(pc.staffAccount,pc.saleContext),true);pc.renderSaleCashiers();assert.equal(pc.saleContext.employeeName,names[i]);}
 assert.equal(pcs[0].salesSession.employeeName,'Анна','other PCs must not mutate Anna');assert.equal(pcs[1].salesSession.employeeName,'Виталина');
 const pc=pcs[0];pc.staffAccount={user_id:'user-1',person_id:2,name:'Виталина'};assert.equal(pc.IprintCashier.bound(pc.staffAccount,pc.saleContext),false,'old draft must not save under another account');assert.equal(await pc.validateSalesSession(),true);assert.equal(pc.salesSession.employeeName,'Виталина');
 pc.staffAccount={user_id:'unlinked',person_id:null};await assert.rejects(()=>pc.validateSalesSession(),/не привязан/);
 pc.staffAccount={user_id:'new',person_id:4};assert.equal(await pc.validateSalesSession(),false,'not-yet-joined employee cannot inherit the opener');assert.equal(pc.salesSession,null);
 assert.equal(pcs[2].IprintCashier.participant({user_id:'dash',person_id:3},{participants:[{...people[2],isActive:false}]}),null);
 // Existing people remain in the shared shift when a third employee joins.
 const join=pcs[2];join.$('salesEmployeeSelect').value='3';assert.deepEqual(Array.from(join.selectedWorkspacePeople()).sort(),[1,2,3]);
 assert.ok(html.includes(".select('user_id,login,name,role,active,person_id')"),'identity must be fetched with the staff session');
 assert.ok(html.includes('IprintCashier.bound(staffAccount,salesSession)'),'offline fallback checks the account identity');
 assert.ok(html.includes("const ids=selectedWorkspacePeople();"),'lead choices retain all participants');
 assert.ok(html.includes("iprint:account-changed"));
 console.log('PASS cashier identity: three PCs / one shift, repeat sales, identity switch, unlinked/inactive/not-joined accounts, preserved participants and offline guard.');
})().catch(e=>{console.error(e);process.exit(1)});
