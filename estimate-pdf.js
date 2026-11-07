// Browser-only PDF export. Canvas preserves Cyrillic without external fonts or services.
(()=>{
  const money=n=>new Intl.NumberFormat('ru-RU',{style:'currency',currency:'RUB'}).format(n);
  let logo=null,logoPromise;
  function loadLogo(){
    if(!logoPromise)logoPromise=new Promise((resolve,reject)=>{const img=new Image();img.onload=()=>{logo=img;resolve(img)};img.onerror=()=>{logoPromise=null;reject(new Error('Не удалось загрузить логотип. Обновите страницу и повторите скачивание.'))};img.src=new URL('assets/logo.png',document.baseURI).href});
    return logoPromise;
  }
  function pdfFromPages(pages){
    const enc=new TextEncoder(),chunks=[],offsets=[0];let size=0;
    const put=s=>{const b=typeof s==='string'?enc.encode(s):s;chunks.push(b);size+=b.length};
    const obj=(id,body)=>{offsets[id]=size;put(`${id} 0 obj\n`);body();put('\nendobj\n')};
    put('%PDF-1.4\n');
    obj(1,()=>put('<< /Type /Catalog /Pages 2 0 R >>'));
    obj(2,()=>put(`<< /Type /Pages /Count ${pages.length} /Kids [${pages.map((_,i)=>`${3+i*3} 0 R`).join(' ')}] >>`));
    pages.forEach((canvas,i)=>{
      const id=3+i*3,raw=atob(canvas.toDataURL('image/jpeg',.94).split(',')[1]);
      const jpg=Uint8Array.from(raw,c=>c.charCodeAt(0));
      obj(id,()=>put(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 594] /Resources << /XObject << /Receipt ${id+1} 0 R >> >> /Contents ${id+2} 0 R >>`));
      obj(id+1,()=>{put(`<< /Type /XObject /Subtype /Image /Width ${canvas.width} /Height ${canvas.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpg.length} >>\nstream\n`);put(jpg);put('\nendstream')});
      const content='q 420 0 0 594 0 0 cm /Receipt Do Q';
      obj(id+2,()=>put(`<< /Length ${enc.encode(content).length} >>\nstream\n${content}\nendstream`));
    });
    const xref=size;put(`xref\n0 ${offsets.length}\n0000000000 65535 f \n`);
    offsets.slice(1).forEach(n=>put(`${String(n).padStart(10,'0')} 00000 n \n`));
    put(`trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`);
    return new Blob(chunks,{type:'application/pdf'});
  }
  function render(data){
    const pages=[];let ctx,y;
    function text(s,x,yy,size=14,color='#172033',align='left',bold=false){ctx.font=`${bold?'700':'400'} ${size}px Arial`;ctx.fillStyle=color;ctx.textAlign=align;ctx.fillText(String(s),x,yy)}
    function line(){ctx.strokeStyle='#dce2eb';ctx.beginPath();ctx.moveTo(36,y);ctx.lineTo(524,y);ctx.stroke();y+=18}
    function page(){
      const c=document.createElement('canvas');c.width=1120;c.height=1584;ctx=c.getContext('2d');ctx.scale(2,2);ctx.fillStyle='#fff';ctx.fillRect(0,0,560,792);pages.push(c);
      ctx.fillStyle='#172033';ctx.fillRect(0,0,560,10);
      if(logo)ctx.drawImage(logo,36,22,56,56);
      text('iПринт',logo?108:36,55,25,'#172033','left',true);
      text('ПРЕДВАРИТЕЛЬНЫЙ РАСЧЁТ',36,84,13,'#53647e');
      text(data.date,524,55,12,'#53647e','right');
      text('Оплата не произведена',36,110,12,'#53647e');y=134;
    }
    function room(h){if(y+h>724){page();text('Продолжение расчёта',36,y,12,'#53647e');y+=26}}
    function wrapped(s,width,size=14,bold=false){
      ctx.font=`${bold?'700':'400'} ${size}px Arial`;const out=[];let row='';
      for(const word of String(s).split(/(\n|[^\S\n]+)/)){
        if(word==='\n'){out.push(row.trimEnd());row='';continue}
        if(ctx.measureText(row+word).width>width&&row){out.push(row.trimEnd());row=''}
        if(!row&&!word.trim())continue;
        for(const ch of word){if(ctx.measureText(row+ch).width>width&&row){out.push(row.trimEnd());row=''}row+=ch}
      }
      if(row)out.push(row.trimEnd());return out;
    }
    function paragraph(s,size=13,color='#53647e'){for(const row of wrapped(s,488,size)){room(22);text(row,36,y,size,color);y+=20}}
    page();
    if(data.number)paragraph('Расчёт № '+data.number);
    if(data.client)paragraph('Клиент: '+data.client,14,'#172033');
    if(data.branch)paragraph('Филиал: '+data.branch);
    if(data.employee)paragraph('Подготовил(а): '+data.employee);
    y+=8;line();
    data.items.forEach((item,i)=>{
      room(62);text(String(i+1).padStart(2,'0'),36,y,12,'#8793a6');
      for(const row of wrapped(item.name,454,14,true)){room(22);text(row,70,y,14,'#172033','left',true);y+=21}
      room(42);text(`${new Intl.NumberFormat('ru-RU',{maximumFractionDigits:3}).format(item.quantity)} ${item.unit==='m'?'м':'шт.'} × ${money(item.price)}`,70,y,12,'#53647e');
      text(money(item.quantity*item.price),524,y,14,'#172033','right',true);y+=23;line();
    });
    room(136);
    text('Сумма',36,y,14);text(money(data.gross),524,y,14,'#172033','right');y+=26;
    if(data.discount>0){text(`Скидка ${data.percent}%`,36,y,14);text('-'+money(data.discount),524,y,14,'#172033','right');y+=30}
    ctx.fillStyle='#eef3ff';ctx.fillRect(36,y-7,488,58);text('ИТОГО',52,y+28,18,'#172033','left',true);text(money(data.total),508,y+28,25,'#172033','right',true);y+=79;
    if(data.comment){paragraph('Комментарий',13,'#172033');paragraph(data.comment);y+=10}
    room(46);paragraph('Предварительная стоимость заказа.');paragraph('Не является кассовым чеком.');
    pages.forEach((c,i)=>{ctx=c.getContext('2d');text(`${i+1} / ${pages.length}`,524,765,11,'#8793a6','right')});
    return pdfFromPages(pages);
  }
  window.EstimatePDF={render,loadLogo};
  const payment=document.getElementById('salePayment');
  payment.insertAdjacentHTML('afterend','<button type="button" id="downloadEstimatePdf" class="secondary" style="display:none;margin-top:10px">↓ Скачать расчёт PDF</button>');
  const button=document.getElementById('downloadEstimatePdf');
  const sync=()=>{button.style.display=payment.value==='estimate'?'inline-block':'none'};
  payment.addEventListener('change',sync);
  new MutationObserver(sync).observe(document.getElementById('saleModal'),{attributes:true,attributeFilter:['class']});sync();
  button.onclick=async()=>{
    if(button.disabled)return;
    try{
      if(!saleDraft.length)throw new Error('Добавьте хотя бы одну позицию в расчёт.');
      const items=saleDraft.map(x=>{
        const c=salesCatalog.find(c=>Number(c.id)===Number(x.catalogId));
        const variant=c?.variants?.find(v=>Number(v.id)===Number(x.variantId));
        if(c?.variants?.length&&!variant)throw new Error('Выберите размер и цвет: «'+c.name+'».');
        const quantity=Number(x.quantity),price=Number(x.unitPrice);
        if(!Number.isFinite(quantity)||quantity<=0||!Number.isFinite(price)||price<0)throw new Error('Проверьте количество и цены.');
        return {name:(c?.name||'Товар')+(variant?' - '+variant.label:''),quantity,price,unit:c?.unit};
      });
      if(salePointsUsed()>0)throw new Error('В предварительном расчёте баллы списать нельзя.');
      const gross=items.reduce((s,x)=>s+x.quantity*x.price,0),percent=Math.min(100,Math.max(0,Number(document.getElementById('saleDiscountPercent').value)||0));
      const discount=Math.round(gross*percent)/100,total=Math.round((gross-discount)*100)/100,now=new Date();
      const employee=document.getElementById('saleEmployeeView');
      button.disabled=true;button.textContent='Готовлю PDF…';
      await loadLogo();
      const blob=render({items,gross,percent,discount,total,date:now.toLocaleString('ru-RU'),number:window.saleEstimate?.id,client:document.getElementById('saleClientName')?.value.trim(),branch:document.getElementById('saleBranchView').value,employee:employee.value?employee.selectedOptions[0]?.textContent:'',comment:document.getElementById('saleComment').value.trim()});
      const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`Расчёт-${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}-${now.getTime()}.pdf`;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);
      document.getElementById('saleStatus').textContent='PDF расчёта скачан. Его можно отправить клиенту.';
    }catch(e){document.getElementById('saleStatus').textContent=e.message||'Не удалось скачать расчёт.'}
    finally{button.disabled=false;button.textContent='↓ Скачать расчёт PDF'}
  };
})();
