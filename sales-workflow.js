/* iПринт: receipt reminders, direct PDF and transactional sale editing. */
(()=>{
 const $=id=>document.getElementById(id);let healthChecking=false;
 window.iprintWorkflowReady=false;
 const e=(tag,text,props={})=>{const n=document.createElement(tag);if(text!=null)n.textContent=text;for(const[k,v]of Object.entries(props))n.setAttribute(k,v);return n;};
 function button(text,fn){const b=e('button',text,{type:'button',class:'secondary'});b.onclick=fn;return b;}
 const receiptBox=e('label',null,{style:'display:flex;gap:9px;align-items:center;margin:15px 0'}),receipt=e('input',null,{type:'checkbox',id:'saleCashReceipt',disabled:''});receiptBox.append(receipt,e('span','Кассовый чек выдан'));$('saleComment').closest('.field').after(receiptBox);
 receiptBox.hidden=true;receiptBox.title='Только отметка сотрудника о выдаче чека. Касса через сайт не пробивается.';
 async function probe(){if(healthChecking||!(typeof staffAccount!=='undefined'&&staffAccount))return;healthChecking=true;try{const before=window.iprintWorkflowReady,r=await db.rpc('iprint_workflow_info');if(!r.error)window.iprintWorkflowReady=r.data?.version>=1;else if(r.error.code==='PGRST202')window.iprintWorkflowReady=false;receipt.disabled=!window.iprintWorkflowReady;receiptBox.hidden=!window.iprintWorkflowReady;if(before!==window.iprintWorkflowReady&&$('salesMovementModal')?.classList.contains('show'))renderMovement().catch(()=>{});}catch{}finally{healthChecking=false;}}
 setTimeout(probe,1800);setInterval(probe,30000);window.addEventListener('focus',probe);
 const openBase=openSaleV4;openSaleV4=async function(){receipt.checked=false;return openBase.apply(this,arguments)};$('salesBtn').onclick=()=>openSaleV4();
 const originalRpc=db.rpc.bind(db),prepare=new Map();
 db.rpc=async(fn,args,opts)=>{
  if(fn==='sales_create_sale'&&window.iprintWorkflowReady&&!pickupRpcOverride)args={...args,p_cash_receipt_issued:receipt.checked};
  if(window.iprintWorkflowReady&&['report_staff_view','report_branch_month','report_fill_shift'].includes(fn)&&args?.p_shift_id){
   const id=args.p_shift_id;if(!prepare.has(id))prepare.set(id,Promise.resolve(originalRpc('iprint_report_prepare',{p_shift_id:id})).finally(()=>prepare.delete(id)));
   const ready=await prepare.get(id);if(ready.error)return ready;
  }
  return originalRpc(fn,args,opts);
 };
 const oldKq=kqCall;kqCall=function(fn,args){if(['sales_create_sale_v6','sales_create_sale_v7'].includes(fn)&&args&&Object.hasOwn(args,'p_cash_receipt_issued'))return oldKq('iprint_create_sale',{...args,p_client_name:args.p_client_name||null});return oldKq(fn,args);};
 let upsellTimer,notice;
 window.iprintUpsellNotice=(question,name)=>{notice?.remove();clearTimeout(upsellTimer);notice=e('aside',null,{class:'iprint-upsell',role:'status'});notice.append(e('strong','Предложи клиенту: '+name));if(question&&!/предложить.*дополнительный/i.test(question))notice.append(e('span',question));document.body.append(notice);upsellTimer=setTimeout(()=>{notice?.remove();notice=null;},6500);};
 document.addEventListener('wheel',event=>{if(event.target instanceof HTMLInputElement&&event.target.type==='number'&&document.activeElement===event.target)event.preventDefault();},{capture:true,passive:false});
 document.addEventListener('keydown',event=>{if(event.target instanceof HTMLInputElement&&event.target.type==='number'&&['ArrowUp','ArrowDown'].includes(event.key))event.preventDefault();},true);
 window.printSaleReceipt=printSaleReceipt=async id=>{
  try{
   const [sr,ir,pr]=await Promise.all([db.from('sales').select('*,sales_branches(name),sales_employees(name)').eq('id',id).single(),db.from('sale_items').select('*').eq('sale_id',id).order('id'),db.from('sale_payments').select('*').eq('sale_id',id).order('id')]);
   for(const r of[sr,ir,pr])if(r.error)throw r.error;const s=sr.data;
   await EstimatePDF.loadLogo();const blob=EstimatePDF.render({receipt:true,number:s.order_number||s.id,date:new Date(s.created_at).toLocaleString('ru-RU'),branch:s.sales_branches?.name,employee:s.sales_employees?.name,items:ir.data.map(i=>({name:saleItemLabel(i),quantity:Number(i.quantity),price:Number(i.unit_price),unit:salesCatalog.find(c=>Number(c.id)===Number(i.catalog_id))?.unit||'pcs'})),gross:Number(s.gross_total??ir.data.reduce((a,i)=>a+Number(i.line_total),0)),discount:Number(s.discount_amount||0),percent:Number(s.discount_percent||0),points:Number(s.loyalty_points_used||0),total:Number(s.total),comment:s.comment,paymentNote:s.payment_status==='unpaid'?'Не оплачено':s.payment_status==='pending'?'Ожидает оплаты':'',payments:pr.data.map(p=>({name:V4_PAY_LABELS[p.payment_method]||p.payment_method,amount:Number(p.amount)}))});
   const url=URL.createObjectURL(blob),a=e('a',null,{href:url,download:'Товарный чек '+(s.order_number||id)+'.pdf'});document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);
  }catch(error){alert('Не удалось скачать товарный чек: '+error.message);}
 };
 window.iprintSetReceipt=async id=>{if(!window.iprintWorkflowReady){alert('Отметка о кассовом чеке пока недоступна. Обновление подключается.');return;}const r=await db.rpc('iprint_set_cash_receipt',{p_sale_id:id,p_shift_id:salesSession?.shiftId||null,p_issued:true});if(r.error){alert(r.error.message);return;}await renderMovement();};
 let dialog=null;
 window.iprintEditSale=async id=>{
  if(dialog)return;dialog=e('dialog',null,{class:'iprint-edit'});document.body.append(dialog);dialog.append(e('p','Открываю продажу…'));dialog.showModal();
  let loaded,rows=[],saving=false;
  const close=()=>{if(saving)return;dialog?.close();dialog?.remove();dialog=null;};dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
  try{
   if(!window.iprintWorkflowReady){dialog.replaceChildren(e('p','Редактирование пока недоступно. Обновление базы подключается.'),button('Закрыть',close));return;}
   const r=await db.rpc('iprint_get_sale',{p_sale_id:id,p_shift_id:salesSession?.shiftId||null});if(r.error)throw r.error;loaded=r.data;if(loaded.editable){const report=await db.rpc('iprint_report_prepare',{p_shift_id:loaded.sale.shift_id});if(report.error)throw report.error;}rows=loaded.items.map(i=>({...i,quantity:Number(i.quantity),unit_price:Number(i.unit_price)}));await loadSalesSetup();
   dialog.replaceChildren();const head=e('div',null,{class:'iprint-edit-head'});head.append(e('h2','Продажа №'+(loaded.sale.order_number||id)),button('Закрыть',close));dialog.append(head,e('p',new Date(loaded.sale.created_at).toLocaleString('ru-RU')+' · Кассир: '+loaded.employee,{class:'iprint-edit-note'}));
   const status=e('div','',{class:'iprint-edit-status',role:'status'}),list=e('div'),total=e('div','',{class:'iprint-edit-total'});dialog.append(status,list);
   function field(parent,label,element){const wrap=e('div'),id='iprint-field-'+crypto.randomUUID();element.id=id;wrap.append(e('label',label,{for:id}),element);parent.append(wrap);return element;}
   function numeric(value,step='0.01'){const n=e('input',null,{type:'number',min:'0',step,inputmode:'decimal'});n.value=value;return n;}
   function draw(){list.replaceChildren();rows.forEach((item,i)=>{
    const row=e('div',null,{class:'iprint-edit-line'}),catalog=e('select',null,{'aria-label':'Товар '+(i+1)});const choices=[...salesCatalog];if(!choices.some(c=>Number(c.id)===Number(item.catalog_id)))choices.unshift({id:item.catalog_id??'',name:item.item_name||'Товар из продажи'});for(const c of choices)catalog.append(e('option',c.name,{value:c.id??''}));catalog.value=item.catalog_id??'';
    catalog.onchange=()=>{const c=salesCatalog.find(c=>Number(c.id)===Number(catalog.value));if(c){item.catalog_id=c.id;item.item_name=c.name;item.unit_price=v4Price(c,item.quantity);item.variant_material_id=null;draw();}};field(row,'Товар / услуга',catalog);
    const qty=field(row,'Количество',numeric(item.quantity,'0.001'));qty.oninput=()=>{item.quantity=Number(qty.value);recount();};const price=field(row,'Цена, ₽',numeric(item.unit_price));price.oninput=()=>{item.unit_price=Number(price.value);recount();};const sum=e('div',salesMoney(item.quantity*item.unit_price),{class:'iprint-line-sum'});field(row,'Сумма',sum);
    row.append(button('×',()=>{rows.splice(i,1);draw();}));list.append(row);
    const c=salesCatalog.find(c=>Number(c.id)===Number(item.catalog_id));if(c?.variants?.length){const select=e('select',null,{'aria-label':'Вариант товара '+(i+1)});select.append(e('option','Выберите размер / цвет',{value:''}));for(const v of c.variants)select.append(e('option',[v.var_size,v.var_color,v.name].filter(Boolean).join(' · '),{value:v.id}));select.value=item.variant_material_id||'';select.onchange=()=>item.variant_material_id=Number(select.value)||null;row.firstChild.append(select);}
   });recount();}
   const controls=e('div',null,{class:'iprint-edit-grid'}),payment=e('select'),discount=numeric(loaded.sale.discount_percent||0),points=numeric(loaded.sale.loyalty_points_used||0),comment=e('textarea',null,{rows:'3',maxlength:'4000'}),cash=e('input',null,{type:'checkbox'});
   for(const[v,t]of Object.entries({...V4_PAY_LABELS,split:'Раздельная оплата'}))payment.append(e('option',t,{value:v}));payment.value=loaded.sale.payment_method;comment.value=loaded.sale.comment||'';cash.checked=!!loaded.sale.cash_receipt_issued;
   field(controls,'Оплата',payment);field(controls,'Скидка, %',discount);discount.max='100';field(controls,'Списать баллы',points);points.disabled=!loaded.sale.loyalty_customer_id;field(controls,'Кассовый чек выдан',cash);
   const split=e('div',null,{class:'iprint-edit-grid'}),splits={};for(const[v,t]of Object.entries(V4_PAY_LABELS)){const input=field(split,t,numeric(loaded.payments.filter(x=>x.payment_method===v).reduce((a,x)=>a+Number(x.amount),0)));input.oninput=recount;splits[v]=input;}
   payment.onchange=()=>{split.hidden=payment.value!=='split';recount();};split.hidden=payment.value!=='split';discount.oninput=points.oninput=recount;
   dialog.append(button('＋ Добавить позицию',()=>{const c=salesCatalog[0];if(c){rows.push({catalog_id:c.id,item_name:c.name,quantity:1,unit_price:v4Price(c,1)});draw();}}),controls,split,e('label','Комментарий'),comment,total);
   function recount(){const gross=rows.reduce((a,i)=>a+Math.round(i.quantity*i.unit_price*100)/100,0),disc=Math.round(gross*(Number(discount.value)||0))/100,after=Math.round((gross-disc)*100)/100,max=Math.max(0,Math.min(Math.round(after*.3*100)/100,Number(loaded.balance||0)+Number(loaded.sale.loyalty_points_used||0)));points.max=max;total.textContent='Итого: '+salesMoney(after-(Number(points.value)||0));total.title='Максимум баллов клиента: '+salesMoney(max);list.querySelectorAll('.iprint-line-sum').forEach((node,i)=>node.textContent=salesMoney(rows[i].quantity*rows[i].unit_price));}
   const save=button('Сохранить изменения',async()=>{if(saving)return;if(!rows.length){status.textContent='Добавьте хотя бы одну позицию.';return;}saving=true;save.disabled=true;status.textContent='Сохраняю изменения…';try{const r=await db.rpc('iprint_edit_sale',{p_sale_id:id,p_shift_id:salesSession?.shiftId||null,p_expected_version:loaded.sale.edit_version,p_items:rows.map(i=>({id:i.id,catalog_id:i.catalog_id,quantity:i.quantity,unit_price:i.unit_price,variant_material_id:i.variant_material_id})),p_discount_percent:Number(discount.value),p_loyalty_points:Number(points.value),p_payment_method:payment.value,p_payments:Object.entries(splits).filter(([,n])=>Number(n.value)>0).map(([method,n])=>({method,amount:Number(n.value)})),p_comment:comment.value,p_cash_receipt_issued:cash.checked});if(r.error)throw r.error;saving=false;close();await renderMovement();}catch(error){status.textContent=error.message;}finally{saving=false;save.disabled=false;}});
   const actions=e('div',null,{class:'actions'});actions.append(button('Товарный чек PDF',()=>printSaleReceipt(id)),save);dialog.append(actions);if(!loaded.editable){save.disabled=true;status.textContent='Редактируются действующие продажи за сегодня. Эту продажу можно просмотреть и скачать чек.';dialog.querySelectorAll('input,select,textarea').forEach(n=>n.disabled=true);}draw();
  }catch(error){dialog.replaceChildren(e('p','Не удалось открыть продажу: '+error.message),button('Закрыть',close));}
 };
})();
