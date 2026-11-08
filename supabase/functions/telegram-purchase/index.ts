import { createClient } from "jsr:@supabase/supabase-js@2";
const esc=(s:unknown)=>String(s??"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
const keyboard={keyboard:[[{text:"🛒 Закупка"}]],resize_keyboard:true,is_persistent:true};
Deno.serve(async(req)=>{
if(req.method!=="POST")return new Response("Method not allowed",{status:405});
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
const cfg=await db.rpc("telegram_purchase_config");
if(cfg.error||!cfg.data?.token||!cfg.data?.secret){console.error('telegram_config_error',{code:cfg.error?.code,message:cfg.error?.message,hasToken:!!cfg.data?.token,hasSecret:!!cfg.data?.secret});return new Response("Configuration unavailable",{status:503});}
if(req.headers.get("X-Telegram-Bot-Api-Secret-Token")!==cfg.data.secret)return new Response("Forbidden",{status:403});
let update;try{update=await req.json()}catch{return new Response("Invalid JSON",{status:400})}
const msg=update.message;
if(!msg?.chat?.id||typeof msg.text!=="string")return new Response("ok");
const text=msg.text.trim();
if(!/^(🛒\s*)?закупка$/i.test(text)&&!/^\/(purchase|start)(@\w+)?(?:\s|$)/i.test(text))return new Response("ok");
let registered=false;
if(/^\/start(@\w+)?(?:\s|$)/i.test(text)&&msg.chat.type==="private"&&msg.from?.id===msg.chat.id&&typeof msg.from?.username==="string"){
 const claim=await db.rpc("telegram_claim_recipient",{p_username:msg.from.username,p_chat_id:msg.chat.id,p_user_id:msg.from.id});
 if(claim.error)return new Response("Database unavailable",{status:503});
 registered=claim.data===true;
}
const result=await db.rpc("telegram_purchase_data",{p_chat_id:msg.chat.id});
if(result.error)return new Response("Database unavailable",{status:503});
if(result.data===null)return new Response("ok");
const send=async(body:string)=>{
const response=await fetch("https://api.telegram.org/bot"+cfg.data.token+"/sendMessage",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({chat_id:msg.chat.id,text:body,parse_mode:"HTML",reply_markup:keyboard})});
const value=await response.json();if(!response.ok||!value.ok)throw new Error("Telegram send failed");
};
const rows=result.data as {name:string;branch:string;code:string;urgent:boolean;qty:number|null;unit:string;comment:string}[];
const now=new Date().toLocaleString("ru-RU",{timeZone:"Europe/Moscow"});
const header="🛒 <b>iПринт · Нужно купить · "+rows.length+"</b>\n<i>"+now+" МСК</i>\n";
const field=(v:unknown)=>esc(String(v??"").slice(0,100));
const cards=rows.map((r,i)=>"\n"+(r.urgent?"🔴 СРОЧНО":"▫️ Обычная")+" · "+(i+1)+"\n<b>"+field(r.name)+"</b>\n📍 "+field(r.branch||"Без филиала")+"\n🔖 Код: <code>"+field(r.code||"—")+"</code>"+(r.qty!=null?"\n📦 "+field(r.qty)+" "+field(r.unit):"")+(r.comment?"\n💬 "+field(r.comment):"")+"\n");
try{if(registered)await send("✅ Вы подключены к сводке iПринт. Ежедневный отчёт приходит в 21:00 по Москве. Кнопка «🛒 Закупка» показывает список покупок.");let page=header;for(const card of cards){if(page.length+card.length>3900){await send(page);page="🛒 <b>Закупка · продолжение</b>\n"}page+=card}await send(page+(rows.length?"":"\n✅ Всё куплено. Открытых заявок нет."));return new Response("ok")}catch{return new Response("Telegram unavailable",{status:503})}
});
