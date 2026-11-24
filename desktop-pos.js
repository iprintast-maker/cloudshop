(()=>{
 if(new URLSearchParams(location.search).get('desktop')!=='1')return;
 document.body.classList.add('desktop-pos');
 const style=document.createElement('link');style.rel='stylesheet';style.href='desktop-pos.css?v=1';document.head.append(style);
 const $=id=>document.getElementById(id),core=CloudshopDesktopDraft;
 const home=document.createElement('section');home.id='desktopHome';home.innerHTML='<div class="desktop-brand">АЙПРИНТ <span>Касса на рабочем столе</span></div><h1>Продажа без лишних окон</h1><p>Распечатали часть заказа — сразу добавьте позиции. Черновик сохранится на этом компьютере.</p><div id="desktopIdentity" role="status"></div><div class="desktop-home-actions"><button id="desktopSale" class="primary">Открыть продажу</button><button id="desktopShift" class="secondary">Выбрать смену</button><button id="desktopAccount" class="secondary">Сменить аккаунт</button></div><div id="desktopDraftNotice" role="status"></div><div id="desktopSaveStatus" role="status"></div>';document.body.append(home);
 let opening=false,restoring=false,pendingSave=false,timer,storageOK=true,lastSummary='',currentUser='',favs=new Set();
 const fields=['saleClientName','cashReceived','saleComment','salePayment','saleDiscountPercent','saleClubQuery','saleClubNewName','saleClubNewPhone','saleClubComment','salePointsToUse'];
 const user=()=>staffAccount?.user_id||null;
 function stored(){const u=user();return u?core.parse(localStorage.getItem(core.key(u)),u):null;}
 function post(){const summary=(saleDraft?.length||0)+' поз. · '+($('saleTotal')?.textContent||'0 ₽')+(storageOK?'':' · черновик не сохранён'),saving=!!$('saveSale')?.disabled;if(summary+':'+saving===lastSummary)return;lastSummary=summary+':'+saving;window.chrome?.webview?.postMessage({type:'desktop-state',summary,saving});}
 function persist(){
  if(opening||restoring)return true;const u=user();if(!u)return true;
  try{
   if(saleDraft?.length&&saleContext?.shiftId){
    const data={version:1,user:u,context:{shiftId:saleContext.shiftId,branchId:saleContext.branchId,branchName:saleContext.branchName,personId:saleContext.personId,employeeId:saleContext.employeeId},orderNo:window.currentSaleOrderNumber,items:saleDraft.map(i=>({...i,label:salesCatalog.find(c=>Number(c.id)===Number(i.catalogId))?.name||'Позиция'})),fields:Object.fromEntries(fields.map(id=>[id,$(id)?.value||''])),cashReceipt:!!$('saleCashReceipt')?.checked,club:!!$('saleClubEnabled')?.checked,usePoints:!!$('saleUsePoints')?.checked,customerId:saleLoyaltyCustomerId,split:typeof v4SplitRows==='undefined'?[]:v4SplitRows,attempted:pendingSave||!!stored()?.attempted,updatedAt:new Date().toISOString()};
    // Pickup payments have a separate server order. Do not turn them into a new sale on restart.
    if(typeof salePickup!=='undefined'&&salePickup)data.pickupId=salePickup.id;
    if(typeof saleEstimate!=='undefined'&&saleEstimate)data.estimateId=saleEstimate.id;
    localStorage.setItem(core.key(u),JSON.stringify(data));$('desktopSaveStatus').textContent='✓ Черновик сохранён на этом компьютере.';
   }else if($('saleModal').classList.contains('show')&&!pendingSave)localStorage.removeItem(core.key(u));
   storageOK=true;post();return true;
  }catch{$('desktopSaveStatus').textContent='Не удалось сохранить черновик. Не закрывайте программу до оформления продажи.';storageOK=false;post();return false;}
 }
 async function wasSold(d){
  if(!d.orderNo)return false;
  const r=await db.from('sales').select('id').eq('branch_id',d.context.branchId).eq('shift_id',d.context.shiftId).eq('order_number',d.orderNo).limit(1);
  if(r.error)throw new Error('Не удалось проверить, был ли заказ уже оформлен. Проверьте интернет — черновик сохранён.');return !!r.data?.length;
 }
 const baseSale=openSaleV4;
 openSaleV4=async function(){
  if(opening)return;opening=true;
  try{
   if(!user()){open('loginModal');return;}
   if(!isAdmin&&salesSession?.shiftId&&Number(salesSession.personId)!==Number(staffAccount?.person_id)){await openSalesWorkspace();return;}
   if(saleDraft?.length){await baseSale.apply(this,arguments);return;}
   let d=stored();
   if(d?.estimateId){$('desktopDraftNotice').textContent='Сохранён черновик существующего предварительного расчёта №'+d.estimateId+'. Откройте этот расчёт на обычном сайте, чтобы продолжить его без дублирования.';return;}
   if(d?.pickupId){$('desktopDraftNotice').textContent='Сохранён черновик оплаты заказа при получении. Откройте этот заказ на обычном сайте; он не будет оформлен повторно.';return;}
   if(d?.attempted&&await wasSold(d)){localStorage.removeItem(core.key(user()));d=null;$('desktopDraftNotice').textContent='Предыдущая продажа уже оформлена. Повторно создавать её не нужно.';}
   if(d&&salesSession?.shiftId&&!core.compatible(d,user(),salesSession)){ $('desktopDraftNotice').textContent='Черновик сохранён для филиала «'+d.context.branchName+'» и другого кассира. Выберите прежний филиал и свой аккаунт. Он не будет перенесён автоматически.';return;}
   const anotherShift=d&&salesSession?.shiftId&&Number(d.context.shiftId)!==Number(salesSession.shiftId);
   if(anotherShift){if(!confirm('Черновик остался от закрытой смены. Перенести его позиции в текущую смену?'))return;if(await wasSold(d)){localStorage.removeItem(core.key(user()));d=null;}else localStorage.removeItem('pendingOrder_'+d.context.branchId);}
   await baseSale.apply(this,arguments);
   if(!$('saleModal').classList.contains('show')||!saleContext?.shiftId)return;
   if(d&&core.compatible(d,user(),saleContext)){
    restoring=true;pendingSave=!!d.attempted;
    saleDraft=d.items.map(({label,...i})=>i);for(const id of fields)if($(id))$(id).value=d.fields?.[id]||'';
    if($('saleCashReceipt'))$('saleCashReceipt').checked=!!d.cashReceipt;
    $('saleClubEnabled').checked=!!d.club;$('saleLoyaltyFields').style.display=d.club?'block':'none';
    // Recheck the customer's current balance rather than restoring an old balance from disk.
    if(d.customerId&&d.fields?.saleClubNewPhone){const r=await db.rpc('loyalty_find_customers',{p_query:clubPhoneValue(d.fields.saleClubNewPhone)});const customer=(r.data||[]).find(c=>String(c.customer_id)===String(d.customerId));if(customer)selectSaleLoyaltyCustomer(customer);else{$('saleUsePoints').checked=false;$('salePointsToUse').value='0';$('saleClubStatus').textContent='Выберите клубную карту заново: баланс не удалось проверить.';}}
    if(d.customerId&&saleLoyaltyCustomerId){$('saleUsePoints').checked=!!d.usePoints;$('salePointsFields').style.display=d.usePoints?'block':'none';}
    v4SplitRows=d.split||[];$('salePayment').onchange?.();renderSaleDraft();
    if(!anotherShift&&d.orderNo){window.currentSaleOrderNumber=d.orderNo;$('saleOrderPreview').textContent='№ '+d.orderNo+' (черновик)';}
    $('saleStatus').textContent='Черновик восстановлен. Проверьте позиции и оплату перед оформлением.';
   }
   if(saleContext?.personId){$('saleEmployeeView').value=String(saleContext.employeeId);$('saleEmployeeView').onchange?.();}
   quick();
  }catch(e){$('desktopDraftNotice').textContent=e.message;}
  finally{restoring=false;opening=false;persist();post();}
 };
 const originalRPC=db.rpc;
 db.rpc=function(name,args,...rest){
  if(name!=='sales_create_sale')return originalRPC.call(this,name,args,...rest);
  const u=user();pendingSave=true;persist();post();
  const target=this;return (async()=>{try{const r=await originalRPC.call(target,name,args,...rest);if(!r.error&&u){localStorage.removeItem(core.key(u));pendingSave=false;}return r;}finally{post();}})();
 };
 const baseRender=renderSaleDraft;renderSaleDraft=function(){const r=baseRender.apply(this,arguments);persist();return r;};
 const baseClose=close;close=function(id){const u=user(),r=baseClose.apply(this,arguments);if(id==='saleModal'&&r!==false&&!saleDraft.length&&u){localStorage.removeItem(core.key(u));pendingSave=false;}return r;};
 const baseCatalog=renderSaleCatalog;
 function quick(){
  const left=$('saleModal').querySelector('.sales-workspace-left');let bar=$('desktopQuick');if(!bar){bar=document.createElement('div');bar.id='desktopQuick';left.prepend(bar);}bar.replaceChildren();
  const list=salesCatalog.filter(c=>favs.has(Number(c.id)));if(!list.length){bar.textContent='Нажмите ☆ у частых позиций — они появятся здесь.';return;}
  for(const c of list){const b=document.createElement('button');b.type='button';b.textContent=c.name;b.className='secondary small';b.onclick=()=>window.addSaleCatalogItem(c.id);bar.append(b);}
 }
 renderSaleCatalog=function(){const r=baseCatalog.apply(this,arguments);for(const card of $('saleCatalogList').querySelectorAll('.sale-catalog-item')){const id=Number(card.getAttribute('onclick')?.match(/addSaleCatalogItem\((\d+)\)/)?.[1]);if(!id)continue;const b=document.createElement('button');b.type='button';b.className='desktop-star';b.textContent=favs.has(id)?'★':'☆';b.setAttribute('aria-label','Избранное: '+card.querySelector('b').textContent);b.setAttribute('aria-pressed',String(favs.has(id)));b.ondblclick=e=>e.stopPropagation();b.onclick=e=>{e.stopPropagation();if(favs.has(id))favs.delete(id);else favs.add(id);localStorage.setItem('iprint.desktop.favs:'+user(),JSON.stringify([...favs]));renderSaleCatalog();};card.append(b);}quick();return r;};
 function tick(){
  if(user()!==currentUser){currentUser=user();try{favs=new Set(JSON.parse(localStorage.getItem('iprint.desktop.favs:'+user())||'[]').map(Number));}catch{favs=new Set();}}
  $('desktopIdentity').textContent=staffAccount?(staffAccount.name+' · '+(salesSession?.branchName||'Смена не выбрана')):'Войдите под своим логином и паролем';
  if(!saleDraft.length){const d=stored();if(d)$('desktopDraftNotice').textContent='Сохранён черновик: '+d.items.length+' поз. · '+(d.context.branchName||'')+'. Нажмите «Открыть продажу» для восстановления.';}
  post();
 }
 $('desktopSale').onclick=()=>openSaleV4();$('salesBtn').onclick=()=>openSaleV4();$('desktopShift').onclick=()=>openSalesWorkspace();$('desktopAccount').onclick=async()=>{if(saleDraft?.length&&!confirm('Черновик сохранится для текущего сотрудника. Выйти из аккаунта?'))return;persist();$('logoutBtn').click();};
 document.addEventListener('input',e=>{if(e.target.closest('#saleModal')){clearTimeout(timer);timer=setTimeout(persist,180);}});
 document.addEventListener('change',e=>{if(e.target.closest('#saleModal'))persist();});
 window.addEventListener('pagehide',persist);window.addEventListener('keydown',e=>{if(e.ctrlKey&&e.key.toLowerCase()==='f'){e.preventDefault();$('saleCatalogSearch')?.focus();}});
 setInterval(tick,1000);
 window.DesktopPOS={openSale:()=>openSaleV4(),beforeExit(){if($('saveSale')?.disabled)return false;return persist();}};tick();
})();
