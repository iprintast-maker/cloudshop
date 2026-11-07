set check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select exists(select 1 from public.staff_accounts s where s.user_id = auth.uid() and s.active and s.role = 'admin');
$function$;
CREATE OR REPLACE FUNCTION public.is_staff()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select exists(select 1 from public.staff_accounts s where s.user_id = auth.uid() and s.active);
$function$;
CREATE OR REPLACE FUNCTION public.is_test_branch(p_id bigint)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select is_test from public.sales_branches where id=p_id),false)
$function$;
CREATE OR REPLACE FUNCTION public.kassa_cash_check_enabled()
 RETURNS boolean LANGUAGE sql IMMUTABLE
AS $function$ select false $function$;

CREATE OR REPLACE FUNCTION public.admin_period_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id bigint DEFAULT NULL::bigint, p_bucket text DEFAULT 'day'::text, p_tz text DEFAULT 'Europe/Moscow'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_step interval;
begin
  if not public.is_admin() then raise exception 'Сводка доступна только администратору'; end if;
  if p_bucket not in ('hour','day','week','month') then raise exception 'Некорректная группировка'; end if;
  v_step:=('1 '||p_bucket)::interval;
  with s as (
    select x.*, case when x.created_at>=p_from and x.created_at<p_to then 'cur' else 'prev' end as per
    from public.sales x
    where ((x.created_at>=p_from and x.created_at<p_to) or (x.created_at>=p_prev_from and x.created_at<p_prev_to)) and x.status='completed' and x.payment_status<>'unpaid'
      and (p_branch_id is null or x.branch_id=p_branch_id) and not public.is_test_branch(x.branch_id)
  ), it as (
    select i.*, s.per, coalesce(nullif(c.category,''),'Без категории') as cat
    from public.sale_items i join s on s.id=i.sale_id left join public.sales_catalog c on c.id=i.catalog_id
  ), tot as (
    select per, sum(total) rev, count(*) cnt, sum(discount_amount) disc, sum(loyalty_points_used) pts,
      count(*) filter (where loyalty_customer_id is not null) club
    from s group by per
  ), costs as (select per, sum(coalesce(cost_total,0)) cost, count(*) filter (where cost_price is null) no_cost from it group by per),
  rets as (
    select case when r.created_at>=p_from and r.created_at<p_to then 'cur' else 'prev' end per, sum(r.amount) amt, count(*) cnt
    from public.sales_returns r where ((r.created_at>=p_from and r.created_at<p_to) or (r.created_at>=p_prev_from and r.created_at<p_prev_to)) and (p_branch_id is null or r.branch_id=p_branch_id) and not public.is_test_branch(r.branch_id) group by 1
  ), newc as (
    select case when c.created_at>=p_from and c.created_at<p_to then 'cur' else 'prev' end per, count(*) cnt
    from public.loyalty_customers c where (c.created_at>=p_from and c.created_at<p_to) or (c.created_at>=p_prev_from and c.created_at<p_prev_to) group by 1
  ), sh as (
    select case when x.started_at>=p_from and x.started_at<p_to then 'cur' else 'prev' end per, count(*) cnt
    from public.sales_shifts x where ((x.started_at>=p_from and x.started_at<p_to) or (x.started_at>=p_prev_from and x.started_at<p_prev_to)) and (p_branch_id is null or x.branch_id=p_branch_id) and not public.is_test_branch(x.branch_id) group by 1
  ), per_obj as (
    select p.per, jsonb_build_object('revenue',coalesce(t.rev,0),'count',coalesce(t.cnt,0),'discount',coalesce(t.disc,0),'points',coalesce(t.pts,0),
      'club',coalesce(t.club,0),'cost',coalesce(c.cost,0),'noCostItems',coalesce(c.no_cost,0),'returns',coalesce(r.amt,0),'returnsCount',coalesce(r.cnt,0),
      'newCustomers',coalesce(n.cnt,0),'shifts',coalesce(h.cnt,0)) o
    from (values('cur'),('prev')) p(per)
    left join tot t on t.per=p.per left join costs c on c.per=p.per left join rets r on r.per=p.per
    left join newc n on n.per=p.per left join sh h on h.per=p.per
  ), items as (
    select item_name name, max(cat) cat,
      sum(quantity) filter (where per='cur') qty, sum(line_total) filter (where per='cur') rev, sum(cost_total) filter (where per='cur') cost,
      sum(quantity) filter (where per='prev') pqty, sum(line_total) filter (where per='prev') prev
    from it group by item_name
  ), cats as (
    select cat name, sum(line_total) filter (where per='cur') rev, sum(line_total) filter (where per='prev') prev from it group by cat
  ), br as (
    select coalesce(b.name,'?') name, sum(s.total) filter (where per='cur') rev, count(*) filter (where per='cur') cnt,
      sum(s.total) filter (where per='prev') prev, count(*) filter (where per='prev') pcnt
    from s left join public.sales_branches b on b.id=s.branch_id group by 1
  ), em as (
    select coalesce(pp.name,e.name,'?') name, sum(s.total) filter (where per='cur') rev, count(*) filter (where per='cur') cnt,
      sum(s.total) filter (where per='prev') prev, count(*) filter (where per='prev') pcnt
    from s left join public.sales_employees e on e.id=s.employee_id left join public.sales_people pp on pp.id=e.person_id group by 1
  ), pay as (
    select p.payment_method m, sum(p.amount) filter (where s.per='cur') amt, sum(p.amount) filter (where s.per='prev') prev
    from public.sale_payments p join s on s.id=p.sale_id group by 1
  ), cur_b as (
    select g b from generate_series(date_trunc(p_bucket,p_from at time zone p_tz), (p_to at time zone p_tz)-interval '1 second', v_step) g
  ), prev_b as (
    select g b from generate_series(date_trunc(p_bucket,p_prev_from at time zone p_tz), (p_prev_to at time zone p_tz)-interval '1 second', v_step) g
  ), sb as (
    select per, date_trunc(p_bucket, created_at at time zone p_tz) b, sum(total) rev, count(*) cnt from s group by 1,2
  ), wd as (
    select extract(isodow from created_at at time zone p_tz)::int d, sum(total) rev, count(*) cnt from s where per='cur' group by 1
  ), hr as (
    select extract(hour from created_at at time zone p_tz)::int h, sum(total) rev, count(*) cnt from s where per='cur' group by 1
  ), cash as (
    select x.started_at, b.name branch, x.open_cash, x.open_cash_expected
    from public.sales_shifts x left join public.sales_branches b on b.id=x.branch_id
    where x.started_at>=p_from and x.started_at<p_to and (p_branch_id is null or x.branch_id=p_branch_id) and not public.is_test_branch(x.branch_id)
      and x.open_cash is not null and x.open_cash_expected is not null and x.open_cash<>x.open_cash_expected
  ), tests as (
    select r.product_id, p.name, count(*) cnt, round(avg(r.score*100.0/r.total)) pct
    from public.guide_test_results r left join public.products p on p.id=r.product_id
    where r.created_at>=p_from and r.created_at<p_to group by 1,2
  )
  select jsonb_build_object(
    'cur',(select o from per_obj where per='cur'),
    'prev',(select o from per_obj where per='prev'),
    'items',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'cat',cat,'qty',coalesce(qty,0),'rev',coalesce(rev,0),'cost',coalesce(cost,0),'pqty',coalesce(pqty,0),'prev',coalesce(prev,0)) order by coalesce(rev,0) desc),'[]') from items),
    'cats',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'rev',coalesce(rev,0),'prev',coalesce(prev,0)) order by coalesce(rev,0) desc),'[]') from cats),
    'branches',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'rev',coalesce(rev,0),'cnt',cnt,'prev',coalesce(prev,0),'pcnt',pcnt) order by coalesce(rev,0) desc),'[]') from br),
    'employees',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'rev',coalesce(rev,0),'cnt',cnt,'prev',coalesce(prev,0),'pcnt',pcnt) order by coalesce(rev,0) desc),'[]') from em),
    'payments',(select coalesce(jsonb_agg(jsonb_build_object('method',m,'amt',coalesce(amt,0),'prev',coalesce(prev,0)) order by coalesce(amt,0) desc),'[]') from pay),
    'series',(select coalesce(jsonb_agg(jsonb_build_object('b',to_char(cb.b,'YYYY-MM-DD"T"HH24:MI'),'rev',coalesce(x.rev,0),'cnt',coalesce(x.cnt,0)) order by cb.b),'[]') from cur_b cb left join sb x on x.per='cur' and x.b=cb.b),
    'prevSeries',(select coalesce(jsonb_agg(jsonb_build_object('b',to_char(pb.b,'YYYY-MM-DD"T"HH24:MI'),'rev',coalesce(x.rev,0),'cnt',coalesce(x.cnt,0)) order by pb.b),'[]') from prev_b pb left join sb x on x.per='prev' and x.b=pb.b),
    'weekdays',(select coalesce(jsonb_agg(jsonb_build_object('d',d,'rev',rev,'cnt',cnt) order by d),'[]') from wd),
    'hours',(select coalesce(jsonb_agg(jsonb_build_object('h',h,'rev',rev,'cnt',cnt) order by h),'[]') from hr),
    'cashIssues',(select coalesce(jsonb_agg(jsonb_build_object('at',started_at,'branch',branch,'actual',open_cash,'expected',open_cash_expected) order by started_at),'[]') from cash),
    'tests',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'cnt',cnt,'pct',pct) order by pct),'[]') from tests),
    'pickups',(select jsonb_build_object('count',count(*),'sum',coalesce(sum(total),0),
        'overdue',count(*) filter (where created_at<now()-interval '2 days'),'overdueSum',coalesce(sum(total) filter (where created_at<now()-interval '2 days'),0))
      from public.pickup_orders where status='pending' and (p_branch_id is null or branch_id=p_branch_id) and not public.is_test_branch(branch_id)),
    'debts',(select coalesce(sum(d.amount),0) from public.customer_debts d join public.sales x on x.id=d.sale_id where d.paid_at is null and x.status='completed' and not public.is_test_branch(x.branch_id))
  ) into v;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_branch_id bigint DEFAULT NULL::bigint, p_bucket text DEFAULT 'day'::text, p_tz text DEFAULT 'Europe/Moscow'::text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select public.admin_period_summary(p_from,p_to,p_prev_from,p_from,p_branch_id,p_bucket,p_tz);
$function$;

CREATE OR REPLACE FUNCTION public.announcement_change_note(p_source text, p_key text, p_name text, p_kind text, p_old numeric DEFAULT NULL::numeric, p_new numeric DEFAULT NULL::numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_opposite text;
begin
  if p_kind in ('edit','price','on','off') and exists(select 1 from announcement_changes where status='pending' and source=p_source and item_key=p_key and kind='new') then
    update announcement_changes set item_name=p_name, new_price=coalesce(p_new,new_price), updated_at=now()
      where status='pending' and source=p_source and item_key=p_key and kind='new';
    if p_kind='off' then
      update announcement_changes set status='skipped', updated_at=now()
        where status='pending' and source=p_source and item_key=p_key and kind='new';
    end if;
    return;
  end if;
  if p_kind in ('on','off') then
    v_opposite := case p_kind when 'on' then 'off' else 'on' end;
    if exists(select 1 from announcement_changes where status='pending' and source=p_source and item_key=p_key and kind=v_opposite) then
      update announcement_changes set status='skipped', updated_at=now()
        where status='pending' and source=p_source and item_key=p_key and kind=v_opposite;
      return;
    end if;
  end if;
  insert into announcement_changes(source,item_key,item_name,kind,old_price,new_price)
    values(p_source,p_key,p_name,p_kind,p_old,p_new)
  on conflict (source,item_key,kind) where status='pending'
    do update set item_name=excluded.item_name, new_price=excluded.new_price, updated_at=now();
  if p_kind='price' then
    update announcement_changes set status='skipped', updated_at=now()
      where status='pending' and source=p_source and item_key=p_key and kind='price' and old_price is not distinct from new_price;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.announcement_mark_read(p_announcement_id bigint, p_shift_id bigint, p_person_id bigint)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
                join public.sales_shifts s on s.id=se.shift_id
                where se.shift_id=p_shift_id and e.person_id=p_person_id and s.status='open') then
    raise exception 'Смена закрыта или сотрудник не участвует в смене'; end if;
  insert into public.announcement_reads(announcement_id,person_id,shift_id) values(p_announcement_id,p_person_id,p_shift_id)
  on conflict(announcement_id,person_id) do nothing;
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.announcement_publish_draft(p_title text, p_body text, p_ids bigint[], p_skip bigint[] DEFAULT '{}'::bigint[])
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id bigint;
begin
  if not public.is_admin() then raise exception 'Только для администратора'; end if;
  if coalesce(trim(p_title),'')='' then raise exception 'Нужен заголовок'; end if;
  insert into announcements(title, body) values(trim(p_title), nullif(trim(p_body),'')) returning id into v_id;
  update announcement_changes set status='published', announcement_id=v_id, updated_at=now()
    where status='pending' and id = any(coalesce(p_ids,'{}'));
  update announcement_changes set status='skipped', updated_at=now()
    where status='pending' and id = any(coalesce(p_skip,'{}'));
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.announcement_track_catalog()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if tg_op='INSERT' then
    if coalesce(new.is_active,true) then
      perform announcement_change_note('catalog', new.id::text, new.name, 'new', null, new.price);
    end if;
    return null;
  end if;
  if new.is_active is distinct from old.is_active then
    perform announcement_change_note('catalog', new.id::text, new.name, case when coalesce(new.is_active,true) then 'on' else 'off' end, null, new.price);
  end if;
  if new.price is distinct from old.price and coalesce(new.is_active,true) then
    perform announcement_change_note('catalog', new.id::text, new.name, 'price', old.price, new.price);
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.announcement_track_products()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if tg_op='INSERT' then
    perform announcement_change_note('guide', new.id::text, new.name, 'new');
  elsif new.name is distinct from old.name or new.description is distinct from old.description
     or new.category is distinct from old.category or new.sku is distinct from old.sku then
    perform announcement_change_note('guide', new.id::text, new.name, 'edit');
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.customer_debts_from_payment()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_customer uuid;
begin
  if new.payment_method<>'bank_account' then return new; end if;
  select loyalty_customer_id into v_customer from public.sales where id=new.sale_id;
  if v_customer is null then return new; end if;
  insert into public.customer_debts(sale_id,customer_id,amount) values(new.sale_id,v_customer,new.amount)
  on conflict(sale_id) do update set amount=public.customer_debts.amount+excluded.amount;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.debts_list(p_include_paid boolean DEFAULT false)
 RETURNS TABLE(debt_id bigint, sale_id bigint, order_number bigint, sale_created_at timestamp with time zone, branch_name text, employee_name text, customer_id uuid, customer_name text, customer_phone text, amount numeric, sale_total numeric, paid_at timestamp with time zone, items text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select d.id, s.id, s.order_number, s.created_at, b.name, e.name, c.id, c.name, c.phone, d.amount, s.total, d.paid_at,
    (select string_agg(i.item_name||' × '||trim(to_char(i.quantity,'FM999999990.###')),', ' order by i.id) from public.sale_items i where i.sale_id=s.id)
  from public.customer_debts d
  join public.sales s on s.id=d.sale_id
  join public.loyalty_customers c on c.id=d.customer_id
  left join public.sales_branches b on b.id=s.branch_id
  left join public.sales_employees e on e.id=s.employee_id
  where s.status='completed' and (p_include_paid or d.paid_at is null)
  order by c.name, s.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.debts_list_v2(p_include_paid boolean DEFAULT false, p_branch_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(debt_id bigint, sale_id bigint, order_number bigint, sale_created_at timestamp with time zone, branch_id bigint, branch_name text, employee_name text, customer_id uuid, customer_name text, customer_phone text, amount numeric, sale_total numeric, paid_at timestamp with time zone, items text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select d.id, s.id, s.order_number, s.created_at, s.branch_id, b.name, e.name, c.id, c.name, c.phone, d.amount, s.total, d.paid_at,
    (select string_agg(i.item_name||' × '||trim(to_char(i.quantity,'FM999999990.###')),', ' order by i.id) from public.sale_items i where i.sale_id=s.id)
  from public.customer_debts d
  join public.sales s on s.id=d.sale_id
  join public.loyalty_customers c on c.id=d.customer_id
  left join public.sales_branches b on b.id=s.branch_id
  left join public.sales_employees e on e.id=s.employee_id
  where s.status='completed' and (p_include_paid or d.paid_at is null)
    and (p_branch_id is null or s.branch_id=p_branch_id)
  order by c.name, s.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.debts_mark_paid(p_debt_ids bigint[])
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_count integer;
begin
  update public.customer_debts set paid_at=now() where id=any(p_debt_ids) and paid_at is null;
  get diagnostics v_count=row_count; return v_count;
end $function$;

CREATE OR REPLACE FUNCTION public.debts_mark_unpaid(p_debt_ids bigint[])
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Вернуть в долг может только администратор'; end if;
  update public.customer_debts set paid_at=null where id=any(p_debt_ids) and paid_at is not null;
  get diagnostics v_count=row_count; return v_count;
end $function$;