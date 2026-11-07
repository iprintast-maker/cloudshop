// Only update offers are accessible here. Financial and staff tables are never queried.
export function createHandler({clientUrl,clientServiceKey,publisherUrl,publisherKey,allowedOrigins,fetchImpl=fetch,randomUUID=()=>crypto.randomUUID()}){
  const project=new URL(publisherUrl).hostname.split('.')[0];
  const imagePrefix=clientUrl+'/storage/v1/object/public/product-images/';
  const transitions={offered:['withdrawn'],accepted:['installed'],declined:['offered'],withdrawn:['offered'],installed:[]};
  return async function handler(req){
    const origin=req.headers.get('origin');
    const cors={'Access-Control-Allow-Origin':origin&&allowedOrigins.includes(origin)?origin:allowedOrigins[0],'Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Cache-Control':'no-store'};
    const json=(body,status=200)=>Response.json(body,{status,headers:cors});
    if(origin&&!allowedOrigins.includes(origin))return json({error:'Этот сайт не подключён'},403);
    if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
    if(req.method!=='POST')return json({error:'Метод не поддерживается'},405);
    const auth=req.headers.get('Authorization')||'';
    if(!/^Bearer\s+\S+$/i.test(auth))return json({error:'Войдите администратором основного сайта'},401);
    const remote=(url,options={})=>fetchImpl(url,{...options,signal:AbortSignal.timeout(15000)});
    let uploaded=[];
    try{
      // Verify the session at its issuing Auth server; never trust JWT metadata for roles.
      const userResponse=await remote(publisherUrl+'/auth/v1/user',{headers:{apikey:publisherKey,Authorization:auth}});
      if(!userResponse.ok)return json({error:'Сессия основного сайта истекла. Войдите заново.'},401);
      const user=await userResponse.json();
      if(!user.id||typeof user.id!=='string')return json({error:'Не удалось проверить пользователя'},401);
      const accountResponse=await remote(publisherUrl+'/rest/v1/staff_accounts?select=user_id,role,active&user_id=eq.'+encodeURIComponent(user.id),{headers:{apikey:publisherKey,Authorization:auth}});
      if(!accountResponse.ok)return json({error:'Не удалось проверить права на основном сайте'},403);
      const accounts=await accountResponse.json();
      if(!Array.isArray(accounts)||!accounts.some(a=>a.user_id===user.id&&a.active===true&&a.role==='admin'))return json({error:'Предлагать обновления может только активный администратор основного сайта'},403);
      if(Number(req.headers.get('content-length')||0)>6000000)return json({error:'Файлы слишком большие'},413);
      const raw=await req.text();
      if(raw.length>6000000)return json({error:'Файлы слишком большие'},413);
      let b;try{b=JSON.parse(raw)}catch{return json({error:'Неверный запрос'},400)}
      if(!b||typeof b!=='object'||Array.isArray(b))return json({error:'Неверный запрос'},400);
      const dbHeaders={apikey:clientServiceKey,Authorization:'Bearer '+clientServiceKey,'Content-Type':'application/json',Prefer:'return=representation'};
      const root=clientUrl+'/rest/v1/site_updates';
      const scope='publisher_project=eq.'+project;
      const db=async(url,options={})=>{const r=await remote(url,{...options,headers:{...dbHeaders,...options.headers}});if(!r.ok)throw Error('Не удалось сохранить или загрузить предложение');return r.status===204?[]:r.json()};
      if(b.action==='list')return json({updates:await db(root+'?'+scope+'&order=created_at.desc,id.desc&limit=200')});
      if(!['save','set_status'].includes(b.action))return json({error:'Неизвестное действие'},400);
      const id=b.id==null?null:Number(b.id);
      if(id!==null&&(!Number.isSafeInteger(id)||id<=0))return json({error:'Неверный номер предложения'},400);
      let current=null;
      if(id!==null){
        current=(await db(root+'?'+scope+'&id=eq.'+id+'&limit=1'))[0];
        if(!current)return json({error:'Предложение не найдено'},404);
      }
      if(b.action==='set_status'){
        if(!current)return json({error:'Выберите предложение'},400);
        if(!transitions[current.status]?.includes(b.status))return json({error:'Статус уже изменился. Обновите список.'},409);
        const patch={status:b.status};if(b.status==='installed')patch.installed_at=new Date().toISOString();
        if(b.status==='offered'){Object.assign(patch,{decided_at:null,decided_by:null,decided_by_name:null,installed_at:null})}
        const rows=await db(root+'?'+scope+'&id=eq.'+id+'&status=eq.'+current.status,{method:'PATCH',body:JSON.stringify(patch)});
        if(!rows.length)return json({error:'Клиент уже изменил статус. Обновите список.'},409);
        return json({update:rows[0]});
      }
      if(current&&current.status!=='offered')return json({error:'Редактировать можно только предложение, которое ждёт ответа'},409);
      const title=typeof b.title==='string'?b.title.trim():'';
      const description=typeof b.description==='string'?b.description.trim():'';
      const eta=typeof b.eta==='string'?b.eta.trim():'';
      const price=Number(b.price);
      if(!title||title.length>140||description.length>8000||eta.length>120)return json({error:'Проверьте название, описание и срок'},400);
      if(!Number.isFinite(price)||price<0||price>9999999999)return json({error:'Укажите корректную стоимость'},400);
      const files=b.files??[];
      if(!Array.isArray(files)||files.length>3)return json({error:'Можно прикрепить до 3 изображений'},400);
      const decoded=[];let total=0;
      for(const file of files){
        if(!file||!['image/png','image/jpeg','image/webp'].includes(file.mime)||typeof file.base64!=='string'||file.base64.length>2800000)return json({error:'Используйте PNG, JPG или WebP размером до 2 МБ'},400);
        let bytes;try{bytes=Uint8Array.from(atob(file.base64),c=>c.charCodeAt(0))}catch{return json({error:'Не удалось прочитать изображение'},400)}
        const png=bytes[0]===137&&bytes[1]===80&&bytes[2]===78&&bytes[3]===71;
        const jpg=bytes[0]===255&&bytes[1]===216&&bytes[2]===255;
        const webp=String.fromCharCode(...bytes.slice(0,4))==='RIFF'&&String.fromCharCode(...bytes.slice(8,12))==='WEBP';
        if(bytes.length>2097152||!({'image/png':png,'image/jpeg':jpg,'image/webp':webp}[file.mime]))return json({error:'Формат изображения не соответствует файлу'},400);
        total+=bytes.length;decoded.push({bytes,mime:file.mime});
      }
      if(total>4194304)return json({error:'Общий размер изображений — не больше 4 МБ'},400);
      let images=b.remove_images?[]:(current?.images||[]);
      if(decoded.length){
        images=[];
        for(const file of decoded){
          const ext={'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[file.mime];
          const path='updates/'+randomUUID()+'.'+ext;
          const up=await remote(clientUrl+'/storage/v1/object/product-images/'+path,{method:'POST',headers:{apikey:clientServiceKey,Authorization:'Bearer '+clientServiceKey,'Content-Type':file.mime,'x-upsert':'false'},body:file.bytes});
          if(!up.ok)throw Error('Не удалось загрузить изображение');
          uploaded.push(path);images.push(imagePrefix+path);
        }
      }
      const patch={title,description:description||null,price:Math.round(price*100)/100,eta:eta||null,images};
      const rows=await db(current?root+'?'+scope+'&id=eq.'+id+'&status=eq.offered':root,{method:current?'PATCH':'POST',body:JSON.stringify(current?patch:{...patch,publisher_project:project,publisher_user_id:user.id})});
      if(!rows.length)throw Error('Статус изменился во время сохранения. Обновите список.');
      uploaded=[];
      return json({update:rows[0]});
    }catch(e){
      if(uploaded.length){try{await remote(clientUrl+'/storage/v1/object/product-images',{method:'DELETE',headers:{apikey:clientServiceKey,Authorization:'Bearer '+clientServiceKey,'Content-Type':'application/json'},body:JSON.stringify({prefixes:uploaded})})}catch{}}
      return json({error:e?.name==='TimeoutError'?'Сервер не ответил вовремя. Повторите позже.':(e?.message||'Не удалось выполнить действие')},500);
    }
  };
}
