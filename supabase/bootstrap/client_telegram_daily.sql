create extension if not exists pg_cron;
-- Ежедневная сводка в Telegram для владельца (21:00 по Москве). Применено в Supabase 2026-10-12.
-- pg_cron «daily-report» → daily_report_send() → daily_report_text() → Telegram sendMessage через pg_net.
-- Ключ бота лежит в Vault (секрет telegram_bot_token), получатели — в report_recipients (только для сервера, RLS без политик).

create table if not exists public.report_recipients(
  chat_id bigint primary key,
  name text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.report_recipients enable row level security;

create or replace function public.rep_money(x numeric) returns text
language sql immutable as $fn$
  select replace(to_char(round(coalesce(x,0)),'FM999,999,999,990'),',',' ')||' ₽'
$fn$;

create or replace function public.rep_esc(x text) returns text
language sql immutable as $fn$
  select replace(replace(replace(x,'&','&amp;'),'<','&lt;'),'>','&gt;')
$fn$;

create or replace function public.rep_pct(cur numeric, prev numeric) returns text
language sql immutable as $fn$
  select case when coalesce(prev,0)=0 then '' else
    ' ('||case when cur>=prev then '+' else '−' end||abs(round((cur-prev)*100/prev))||'%)' end
$fn$;

create or replace function public.rep_person(p_employee_id bigint) returns text
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(pp.name,e.name,'?') from public.sales_employees e left join public.sales_people pp on pp.id=e.person_id where e.id=p_employee_id
$fn$;

create or replace function public.daily_report_text(p_day date default null) returns text
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  tz constant text:='Europe/Moscow';
  d date:=coalesce(p_day,(now() at time zone tz)::date);
  t0 timestamptz:=d::timestamp at time zone tz;
  t1 timestamptz:=(d+1)::timestamp at time zone tz;
  p0 timestamptz:=(d-7)::timestamp at time zone tz;
  p1 timestamptz:=(d-6)::timestamp at time zone tz;
  months text[]:=array['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря'];
  wd text[]:=array['пн','вт','ср','чт','пт','сб','вс'];
  pm jsonb:='{"cash":"наличные","card":"карта","qr":"QR","transfer":"перевод","link":"ссылка","bank_account":"р/с"}';
  r record; out text; prob text:=''; nprob int:=0;
  rev numeric; cnt int; prev numeric; rets numeric; retc int; line text; exp_cash numeric;
begin
  out:='📊 <b>iПринт · Сводка за '||extract(day from d)||' '||months[extract(month from d)::int]||' ('||wd[extract(isodow from d)::int]||')</b>'||E'\n';

  -- Итог за день
  select coalesce(sum(total),0), count(*) into rev, cnt from public.sales
   where created_at>=t0 and created_at<t1 and status='completed' and payment_status<>'unpaid' and not public.is_test_branch(branch_id);
  select coalesce(sum(total),0) into prev from public.sales
   where created_at>=p0 and created_at<p1 and status='completed' and payment_status<>'unpaid' and not public.is_test_branch(branch_id);
  select coalesce(sum(amount),0), count(*) into rets, retc from public.sales_returns
   where created_at>=t0 and created_at<t1 and not public.is_test_branch(branch_id);
  out:=out||E'\n💰 Выручка: <b>'||rep_money(rev)||'</b>'||rep_pct(rev,prev)
    ||case when prev>0 then E'\n<i>прошлый '||wd[extract(isodow from d)::int]||': '||rep_money(prev)||'</i>' else '' end
    ||E'\n🧾 Чеков: '||cnt||case when cnt>0 then ' · средний '||rep_money(rev/cnt) else '' end;
  select string_agg(coalesce(pm->>m,m)||' '||rep_money(a),' · ' order by a desc) into line from (
    select p.payment_method m, sum(p.amount) a from public.sale_payments p join public.sales s on s.id=p.sale_id
     where s.created_at>=t0 and s.created_at<t1 and s.status='completed' and s.payment_status<>'unpaid' and not public.is_test_branch(s.branch_id)
     group by 1) x;
  if line is not null then out:=out||E'\n💳 '||line; end if;
  if retc>0 then out:=out||E'\n↩️ Возвраты: '||retc||' на '||rep_money(rets); end if;

  -- По филиалам
  out:=out||E'\n\n🏪 <b>По филиалам</b>';
  for r in
    select b.id, b.name,
      (select coalesce(sum(total),0) from public.sales s where s.branch_id=b.id and s.created_at>=t0 and s.created_at<t1 and s.status='completed' and s.payment_status<>'unpaid') rev,
      (select count(*) from public.sales s where s.branch_id=b.id and s.created_at>=t0 and s.created_at<t1 and s.status='completed' and s.payment_status<>'unpaid') cnt,
      (select coalesce(sum(total),0) from public.sales s where s.branch_id=b.id and s.created_at>=p0 and s.created_at<p1 and s.status='completed' and s.payment_status<>'unpaid') prev,
      (select string_agg(distinct rep_person(se.employee_id),', ') from public.sales_shift_employees se join public.sales_shifts sh on sh.id=se.shift_id
        where sh.branch_id=b.id and sh.started_at>=t0 and sh.started_at<t1) who
    from public.sales_branches b
    where b.is_active and not b.is_test and not b.is_workshop
    order by 3 desc
  loop
    out:=out||E'\n• '||rep_esc(r.name)||': <b>'||rep_money(r.rev)||'</b>'||rep_pct(r.rev,r.prev)||', чеков '||r.cnt
      ||E'\n   '||case when r.who is null then 'смены не было' else 'работали: '||rep_esc(r.who) end;
  end loop;

  -- Наличные: закрытие смены не сошлось с расчётом
  for r in
    select sh.*, b.name bname,
      coalesce((select sum(p.amount) from public.sale_payments p join public.sales x on x.id=p.sale_id
                 where x.shift_id=sh.id and x.status='completed' and p.payment_method='cash'),0) cash_sales,
      coalesce((select sum(rt.amount) from public.sales_returns rt join public.sales x on x.id=rt.sale_id
                 where rt.shift_id=sh.id and x.shift_id<>sh.id and x.payment_method='cash'),0) cash_rets
    from public.sales_shifts sh join public.sales_branches b on b.id=sh.branch_id
    where sh.started_at>=t0 and sh.started_at<t1 and not b.is_test
    order by b.name
  loop
    if r.open_cash is null then
      nprob:=nprob+1; prob:=prob||E'\n💵 '||rep_esc(r.bname)||': на открытии смены не указали наличные в кассе';
    elsif r.open_cash_expected is not null and abs(r.open_cash-r.open_cash_expected)>=1 then
      nprob:=nprob+1; prob:=prob||E'\n💵 '||rep_esc(r.bname)||': утром в кассе '||rep_money(r.open_cash)||', а вечером оставили '||rep_money(r.open_cash_expected)
        ||' → <b>'||case when r.open_cash>r.open_cash_expected then '+' else '−' end||rep_money(abs(r.open_cash-r.open_cash_expected))||'</b>'
        ||coalesce(' (открыл(а) '||rep_esc(rep_person(r.open_cash_employee_id))||')','');
    end if;
    if r.close_cash is not null and r.open_cash is not null then
      exp_cash:=r.open_cash+r.cash_sales-r.cash_rets;
      if abs(r.close_cash-exp_cash)>=1 then
        nprob:=nprob+1; prob:=prob||E'\n💵 '||rep_esc(r.bname)||': при закрытии в кассе '||rep_money(r.close_cash)||', а по продажам должно быть '||rep_money(exp_cash)
          ||' → <b>'||case when r.close_cash>exp_cash then 'лишние +' else 'не хватает −' end||rep_money(abs(r.close_cash-exp_cash))||'</b>'
          ||coalesce(' (закрыл(а) '||rep_esc(rep_person(r.close_cash_employee_id))||')','')
          ||E'\n   <i>утром '||rep_money(r.open_cash)||' + наличные продажи '||rep_money(r.cash_sales)
          ||case when r.cash_rets>0 then ' − возвраты '||rep_money(r.cash_rets) else '' end||'</i>';
      end if;
    end if;
  end loop;

  -- Незакрытые смены
  for r in
    select sh.*, b.name bname from public.sales_shifts sh join public.sales_branches b on b.id=sh.branch_id
    where sh.status='open' and not b.is_test and sh.started_at<t1 order by sh.started_at
  loop
    nprob:=nprob+1; prob:=prob||E'\n🕒 '||rep_esc(r.bname)||': смена не закрыта (открыта '||to_char(r.started_at at time zone tz,'DD.MM HH24:MI')
      ||coalesce(', '||rep_esc(rep_person(r.employee_id)),'')||')';
  end loop;

  -- Возвраты
  for r in
    select rt.*, b.name bname, x.order_number, x.created_at sale_at from public.sales_returns rt join public.sales_branches b on b.id=rt.branch_id
      left join public.sales x on x.id=rt.sale_id
    where rt.created_at>=t0 and rt.created_at<t1 and not b.is_test order by rt.created_at
  loop
    nprob:=nprob+1; prob:=prob||E'\n↩️ '||rep_esc(r.bname)||': возврат '||rep_money(r.amount)||coalesce(', чек №'||r.order_number,'')
      ||case when r.sale_at<t0 then ' от '||to_char(r.sale_at at time zone tz,'DD.MM') else '' end
      ||coalesce(' ('||rep_esc(rep_person(r.employee_id))||')','')||coalesce(' — '||rep_esc(left(nullif(btrim(r.comment),''),80)),'');
  end loop;

  -- Удалённые чеки
  for r in
    select x.*, b.name bname from public.sales x join public.sales_branches b on b.id=x.branch_id
    where x.status='deleted' and coalesce(x.cancelled_at,x.created_at)>=t0 and coalesce(x.cancelled_at,x.created_at)<t1 and not b.is_test order by x.created_at
  loop
    nprob:=nprob+1; prob:=prob||E'\n🗑 '||rep_esc(r.bname)||': удалён чек'||coalesce(' №'||r.order_number,'')||' на '||rep_money(r.total)
      ||coalesce(' ('||rep_esc(rep_person(r.employee_id))||')','')||coalesce(' — '||rep_esc(left(nullif(btrim(r.comment),''),80)),'');
  end loop;

  -- Большие скидки (от 15% или от 500 ₽)
  for r in
    select x.*, b.name bname from public.sales x join public.sales_branches b on b.id=x.branch_id
    where x.created_at>=t0 and x.created_at<t1 and x.status='completed' and not b.is_test
      and (coalesce(x.discount_percent,0)>=15 or coalesce(x.discount_amount,0)>=500) order by x.discount_amount desc nulls last
  loop
    nprob:=nprob+1; prob:=prob||E'\n🏷 '||rep_esc(r.bname)||': скидка '||coalesce(round(r.discount_percent)||'% ','')||'(−'||rep_money(r.discount_amount)||')'
      ||coalesce(', чек №'||r.order_number,'')||' на '||rep_money(r.total)||coalesce(' ('||rep_esc(rep_person(r.employee_id))||')','');
  end loop;

  -- Общий отчет заполнен вручную (кнопка «Заполнить отчет вручную» после смены, см. report_fill.sql)
  select string_agg(distinct rep_esc(b.name),', ') into line from public.report_fills f join public.sales_branches b on b.id=f.branch_id
   where f.day=d and f.mode='manual';
  if line is not null then nprob:=nprob+1; prob:=prob||E'\n✍️ Общий отчет заполнен вручную: '||line; end if;

  -- В долг за день
  select count(*), coalesce(sum(cd.amount),0) into cnt, rev from public.customer_debts cd join public.sales x on x.id=cd.sale_id
   where cd.created_at>=t0 and cd.created_at<t1 and x.status='completed' and not public.is_test_branch(x.branch_id);
  if cnt>0 then nprob:=nprob+1; prob:=prob||E'\n📝 Отдали в долг: '||cnt||' на '||rep_money(rev); end if;

  -- «При получении» дольше 2 дней
  select count(*), coalesce(sum(total),0) into cnt, rev from public.pickup_orders
   where status='pending' and created_at<now()-interval '2 days' and not public.is_test_branch(branch_id);
  if cnt>0 then nprob:=nprob+1; prob:=prob||E'\n⏳ Не оплачены «при получении» больше 2 дней: '||cnt||' на '||rep_money(rev); end if;

  out:=out||E'\n\n'||case when nprob=0 then '✅ <b>Всё сошлось</b>, замечаний нет.' else '⚠️ <b>Что не сошлось ('||nprob||')</b>'||prob end;
  return out;
end $fn$;

create or replace function public.daily_report_send(p_day date default null) returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare v_token text; v_text text; v_n int:=0; r record;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name='telegram_bot_token';
  if v_token is null then raise exception 'Нет ключа Telegram-бота'; end if;
  v_text:=public.daily_report_text(p_day);
  if length(v_text)>4000 then v_text:=left(v_text,3990)||E'\n…'; end if;
  for r in select chat_id from public.report_recipients where active loop
    perform net.http_post(
      url:='https://api.telegram.org/bot'||v_token||'/sendMessage',
      headers:='{"Content-Type":"application/json"}'::jsonb,
      body:=jsonb_build_object('chat_id',r.chat_id,'text',v_text,'parse_mode','HTML','disable_web_page_preview',true),
      timeout_milliseconds:=30000);
    v_n:=v_n+1;
  end loop;
  return v_n;
end $fn$;

revoke execute on function public.daily_report_text(date) from public, anon, authenticated;
revoke execute on function public.daily_report_send(date) from public, anon, authenticated;
revoke execute on function public.rep_person(bigint) from public, anon, authenticated;

select cron.schedule('daily-report','0 18 * * *','select public.daily_report_send()');


grant execute on function public.daily_report_text(date),public.daily_report_send(date) to service_role;

DO $$ DECLARE f record; BEGIN FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('rep_money','rep_esc','rep_pct','rep_person') LOOP EXECUTE format('ALTER FUNCTION %s SET search_path=public,pg_temp',f.sig); END LOOP; END $$;
