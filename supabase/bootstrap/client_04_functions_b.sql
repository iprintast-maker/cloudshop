set check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.loyalty_add_purchase(p_name text, p_phone text, p_amount numeric, p_comment text DEFAULT NULL::text)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text, points_added numeric, available_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_customer public.loyalty_customers%rowtype;
  v_points numeric(12,2);
  v_available timestamptz;
  v_order_count bigint;
  v_rule public.loyalty_gift_rules%rowtype;
begin
  if nullif(trim(p_name),'') is null then raise exception 'Введите имя клиента'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Введите номер клиента'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Сумма покупки должна быть больше 0'; end if;
  v_points := round(p_amount * 0.05, 2);
  v_available := now() + interval '24 hours';
  if length(regexp_replace(trim(p_phone),'[^0-9]','','g')) < 4 then
    raise exception 'Номер клиента должен содержать минимум 4 цифры';
  end if;
  insert into public.loyalty_customers(name, phone, comment)
  values(trim(p_name), regexp_replace(trim(p_phone),'[^0-9]','','g'), nullif(trim(coalesce(p_comment,'')),''))
  on conflict(phone) do update
    set name = excluded.name,
        comment = case when excluded.comment is not null then excluded.comment else public.loyalty_customers.comment end,
        updated_at = now()
  returning * into v_customer;
  insert into public.loyalty_transactions(customer_id, transaction_type, order_amount, points, comment, available_at)
  values(v_customer.id, 'purchase', p_amount, v_points, nullif(trim(coalesce(p_comment,'')),''), v_available);
  select count(*) into v_order_count from public.loyalty_transactions t
  where t.customer_id = v_customer.id and t.transaction_type = 'purchase';
  for v_rule in select * from public.loyalty_gift_rules where order_count = v_order_count loop
    if not exists (select 1 from public.loyalty_transactions t where t.customer_id = v_customer.id and t.transaction_type = 'gift' and t.gift_rule_id = v_rule.id) then
      insert into public.loyalty_transactions(customer_id, transaction_type, order_amount, points, comment, available_at, gift_rule_id)
      values(v_customer.id, 'gift', 0, 0, 'Подарок за ' || v_rule.order_count || ' заказов: ' || v_rule.gift_name, now(), v_rule.id);
    end if;
  end loop;
  return query select v_customer.id, v_customer.name, v_customer.phone, v_points, v_available;
end;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_admin_adjust_points(p_customer_id uuid, p_points numeric, p_comment text DEFAULT NULL::text)
 RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_balance numeric; v_new numeric;
begin
  if not public.is_admin() then raise exception 'Требуется вход администратора'; end if;
  if p_points is null then raise exception 'Укажите изменение баллов'; end if;
  perform 1 from public.loyalty_customers where id=p_customer_id for update;
  if not found then raise exception 'Клиент не найден'; end if;
  select coalesce(sum(t.points),0) into v_balance from public.loyalty_transactions t
  where t.customer_id=p_customer_id and t.available_at <= now();
  v_new := v_balance + p_points;
  if v_new < 0 then raise exception 'Баланс не может быть отрицательным'; end if;
  insert into public.loyalty_transactions(customer_id, transaction_type, order_amount, points, comment, available_at)
  values(p_customer_id, 'adjustment', 0, p_points, nullif(trim(coalesce(p_comment,'')),''), now());
  return v_new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_admin_update_customer(p_customer_id uuid, p_name text, p_phone text, p_comment text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Требуется вход администратора'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Имя клиента не может быть пустым'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Номер клиента не может быть пустым'; end if;
  update public.loyalty_customers
  set name=trim(p_name), phone=regexp_replace(trim(p_phone),'[^0-9]','','g'), comment=nullif(trim(coalesce(p_comment,'')),''), updated_at=now()
  where id=p_customer_id;
  if not found then raise exception 'Клиент не найден'; end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_find_customers(p_query text)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text, balance numeric, order_count bigint, customer_comment text, pending_points numeric)
 LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select c.id, c.name, c.phone,
    coalesce(sum(case when t.available_at <= now() then t.points else 0 end),0)::numeric as balance,
    count(t.id) filter (where t.transaction_type='purchase')::bigint as order_count,
    c.comment,
    coalesce(sum(case when t.available_at > now() then t.points else 0 end),0)::numeric as pending_points
  from public.loyalty_customers c
  left join public.loyalty_transactions t on t.customer_id=c.id
  where length(regexp_replace(coalesce(p_query,''),'[^0-9]','','g')) >= 4 and c.phone like '%' || right(regexp_replace(coalesce(p_query,''),'[^0-9]','','g'),4)
  group by c.id
  order by c.name;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_get_customer(p_customer_id uuid)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text, balance numeric, order_count bigint, customer_comment text, pending_points numeric)
 LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select c.id, c.name, c.phone,
    coalesce(sum(case when t.available_at <= now() then t.points else 0 end),0)::numeric,
    count(t.id) filter (where t.transaction_type='purchase')::bigint,
    c.comment,
    coalesce(sum(case when t.available_at > now() then t.points else 0 end),0)::numeric
  from public.loyalty_customers c
  left join public.loyalty_transactions t on t.customer_id=c.id
  where c.id=p_customer_id
  group by c.id;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_get_history(p_customer_id uuid)
 RETURNS TABLE(customer_name text, customer_phone text, transaction_id bigint, transaction_type text, order_amount numeric, points numeric, comment text, available_at timestamp with time zone, created_at timestamp with time zone, created_by_employee text)
 LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
    SELECT c.name, c.phone, t.id,
        CASE t.transaction_type
            WHEN 'purchase' THEN 'Покупка / начисление 5%'
            WHEN 'redeem' THEN 'Списание баллов'
            WHEN 'adjustment' THEN 'Корректировка баллов'
            WHEN 'gift' THEN '🎁 Подарок'
            ELSE t.transaction_type
        END,
        t.order_amount, t.points, t.comment, t.available_at, t.created_at,
        COALESCE(sp.name, 'Не указан')
    FROM public.loyalty_transactions t
    JOIN public.loyalty_customers c ON c.id = t.customer_id
    LEFT JOIN public.sales_people sp ON sp.id = c.created_by_employee_id
    WHERE t.customer_id = p_customer_id
    ORDER BY t.created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_redeem(p_customer_id uuid, p_order_amount numeric, p_points numeric, p_comment text DEFAULT NULL::text)
 RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_balance numeric; v_limit numeric;
begin
  if p_order_amount is null or p_order_amount <= 0 then raise exception 'Сумма заказа должна быть больше 0'; end if;
  if p_points is null or p_points <= 0 then raise exception 'Количество баллов должно быть больше 0'; end if;
  v_limit := round(p_order_amount * 0.30, 2);
  if p_points > v_limit then raise exception 'Можно списать не более % баллов', v_limit; end if;
  perform 1 from public.loyalty_customers where id=p_customer_id for update;
  if not found then raise exception 'Клиент не найден'; end if;
  select coalesce(sum(t.points),0) into v_balance from public.loyalty_transactions t
  where t.customer_id=p_customer_id and t.available_at <= now();
  if p_points > v_balance then raise exception 'Недостаточно доступных баллов. Доступно: %', v_balance; end if;
  insert into public.loyalty_transactions(customer_id, transaction_type, order_amount, points, comment, available_at)
  values(p_customer_id, 'redeem', p_order_amount, -p_points, nullif(trim(coalesce(p_comment,'')),''), now());
  return v_balance - p_points;
end;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_register_customer(p_name text, p_phone text, p_comment text DEFAULT NULL::text)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_customer public.loyalty_customers%rowtype;
begin
  if nullif(trim(p_name),'') is null then raise exception 'Введите имя клиента'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Введите номер клиента'; end if;
  if length(regexp_replace(trim(p_phone),'[^0-9]','','g')) < 4 then raise exception 'Номер клиента должен содержать минимум 4 цифры'; end if;
  insert into public.loyalty_customers(name,phone,comment)
  values(trim(p_name),regexp_replace(trim(p_phone),'[^0-9]','','g'),nullif(trim(coalesce(p_comment,'')),''))
  on conflict(phone) do update set name=excluded.name, comment=coalesce(excluded.comment,public.loyalty_customers.comment), updated_at=now()
  returning * into v_customer;
  return query select v_customer.id,v_customer.name,v_customer.phone;
end;
$function$;

CREATE OR REPLACE FUNCTION public.loyalty_register_customer(p_name text, p_phone text, p_comment text DEFAULT NULL::text, p_created_by_employee_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(customer_id uuid, customer_name text, customer_phone text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_customer public.loyalty_customers%rowtype;
BEGIN
  IF nullif(trim(p_name),'') IS NULL THEN RAISE EXCEPTION 'Введите имя клиента'; END IF;
  IF nullif(trim(p_phone),'') IS NULL THEN RAISE EXCEPTION 'Введите номер клиента'; END IF;
  IF length(regexp_replace(trim(p_phone),'[^0-9]','','g')) < 4 THEN RAISE EXCEPTION 'Номер клиента должен содержать минимум 4 цифры'; END IF;
  INSERT INTO public.loyalty_customers(name, phone, comment, created_by_employee_id)
  VALUES(trim(p_name), regexp_replace(trim(p_phone),'[^0-9]','','g'), nullif(trim(coalesce(p_comment,'')),''), p_created_by_employee_id)
  ON CONFLICT(phone) DO UPDATE SET
    name = excluded.name,
    comment = coalesce(excluded.comment, public.loyalty_customers.comment),
    created_by_employee_id = coalesce(excluded.created_by_employee_id, public.loyalty_customers.created_by_employee_id)
  RETURNING * INTO v_customer;
  RETURN QUERY SELECT v_customer.id, v_customer.name, v_customer.phone;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pickup_list(p_branch_id bigint DEFAULT NULL::bigint, p_include_closed boolean DEFAULT false)
 RETURNS TABLE(id bigint, branch_id bigint, branch_name text, order_number bigint, items jsonb, gross_total numeric, discount_percent numeric, total numeric, customer_id uuid, customer_name text, customer_phone text, client_name text, client_phone text, comment text, employee_name text, status text, created_at timestamp with time zone, paid_at timestamp with time zone, cancelled_at timestamp with time zone, cancel_reason text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select o.id,o.branch_id,b.name,o.order_number,o.items,o.gross_total,o.discount_percent,o.total,o.customer_id,c.name,c.phone,
    o.client_name,o.client_phone,o.comment,coalesce(p.name,e.name),o.status,o.created_at,o.paid_at,o.cancelled_at,o.cancel_reason
  from public.pickup_orders o
  left join public.sales_branches b on b.id=o.branch_id
  left join public.loyalty_customers c on c.id=o.customer_id
  left join public.sales_employees e on e.id=o.employee_id
  left join public.sales_people p on p.id=e.person_id
  where (p_branch_id is null or o.branch_id=p_branch_id)
    and (o.status='pending' or (p_include_closed and coalesce(o.paid_at,o.cancelled_at)>now()-interval '30 days'))
  order by o.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.pickup_list_v2(p_branch_id bigint DEFAULT NULL::bigint, p_include_closed boolean DEFAULT false)
 RETURNS TABLE(id bigint, branch_id bigint, branch_name text, order_number bigint, items jsonb, gross_total numeric, discount_percent numeric, total numeric, customer_id uuid, customer_name text, customer_phone text, client_name text, client_phone text, comment text, employee_name text, status text, created_at timestamp with time zone, paid_at timestamp with time zone, cancelled_at timestamp with time zone, cancel_reason text, client_order_ref text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select l.*, o.client_order_ref from public.pickup_list(p_branch_id,p_include_closed) l join public.pickup_orders o on o.id=l.id order by l.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.rep_esc(x text) RETURNS text LANGUAGE sql IMMUTABLE
AS $function$ select replace(replace(replace(x,'&','&amp;'),'<','&lt;'),'>','&gt;') $function$;
CREATE OR REPLACE FUNCTION public.rep_money(x numeric) RETURNS text LANGUAGE sql IMMUTABLE
AS $function$ select replace(to_char(round(coalesce(x,0)),'FM999,999,999,990'),',',' ')||' ₽' $function$;
CREATE OR REPLACE FUNCTION public.rep_pct(cur numeric, prev numeric) RETURNS text LANGUAGE sql IMMUTABLE
AS $function$
  select case when coalesce(prev,0)=0 then '' else
    ' ('||case when cur>=prev then '+' else '−' end||abs(round((cur-prev)*100/prev))||'%)' end
$function$;
CREATE OR REPLACE FUNCTION public.rep_person(p_employee_id bigint) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(pp.name,e.name,'?') from public.sales_employees e left join public.sales_people pp on pp.id=e.person_id where e.id=p_employee_id
$function$;

CREATE OR REPLACE FUNCTION public.report_admin_set_cells(p_sheet_id bigint, p_cells jsonb, p_months jsonb DEFAULT NULL::jsonb)
 RETURNS timestamp with time zone LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare v_data jsonb; r text; cols jsonb; k text; cell jsonb; v_row jsonb; v_now timestamptz:=now();
begin
  select data into v_data from public.report_sheets where id=p_sheet_id for update;
  if not found then raise exception 'Лист не найден'; end if;
  for r,cols in select * from jsonb_each(p_cells) loop
    v_row:=coalesce(v_data->'rows'->r,'{}'::jsonb);
    for k,cell in select * from jsonb_each(cols) loop
      if cell is null or jsonb_typeof(cell)='null' then v_row:=v_row-k; else v_row:=v_row||jsonb_build_object(k,cell); end if;
    end loop;
    v_data:=jsonb_set(v_data,array['rows',r],v_row,true);
  end loop;
  update public.report_sheets set data=v_data, months=coalesce(p_months,months), updated_at=v_now where id=p_sheet_id;
  return v_now;
end $function$;

CREATE OR REPLACE FUNCTION public.report_branch_month(p_shift_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_branch bigint; v_sheet public.report_sheets; v_month jsonb; v_rows jsonb; v_key text;
begin
  select branch_id into v_branch from public.sales_shifts where id=p_shift_id and status='open';
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  select * into v_sheet from public.report_sheets where branch_id=v_branch order by sort_order limit 1;
  if not found then return null; end if;
  v_key:=to_char(now() at time zone 'Europe/Moscow','YYYY-MM');
  select m into v_month from jsonb_array_elements(v_sheet.months) m where m->>'m'=v_key limit 1;
  if v_month is null then
    select m into v_month from jsonb_array_elements(v_sheet.months) m where m->>'m'<=v_key order by m->>'m' desc limit 1;
  end if;
  if v_month is null then return null; end if;
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into v_rows
    from jsonb_each(v_sheet.data->'rows') as r(k,v)
    where k::int between (v_month->>'from')::int and (v_month->>'to')::int;
  return jsonb_build_object('title',v_sheet.title,'month',v_month->>'m','from',(v_month->>'from')::int,'to',(v_month->>'to')::int,
    'data',jsonb_build_object('ncols',v_sheet.data->'ncols','cols',v_sheet.data->'cols','styles',v_sheet.data->'styles',
      'merges',v_sheet.data->'merges','heights',v_sheet.data->'heights','rows',v_rows),
    'updated_at',v_sheet.updated_at);
end $function$;

CREATE OR REPLACE FUNCTION public.report_col_name(n integer) RETURNS text LANGUAGE plpgsql IMMUTABLE
AS $function$
declare s text:=''; m int;
begin while n>0 loop m:=(n-1)%26; s:=chr(65+m)||s; n:=(n-m-1)/26; end loop; return s; end $function$;

CREATE OR REPLACE FUNCTION public.report_col_num(s text) RETURNS integer LANGUAGE sql IMMUTABLE SET search_path TO 'public'
AS $function$
  select sum((ascii(substr(s,i,1))-64)*power(26,length(s)-i))::int from generate_series(1,length(s)) i
$function$;

CREATE OR REPLACE FUNCTION public.report_day_row(p_branch_id bigint, p_day date, OUT sheet_id bigint, OUT row_no integer, OUT m_from integer, OUT m_to integer)
 RETURNS record LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_sheet public.report_sheets; v_month jsonb; v_serial int:=p_day-date '1899-12-30';
begin
  select * into v_sheet from public.report_sheets s where s.branch_id=p_branch_id order by s.sort_order limit 1;
  if not found then raise exception 'Для этого филиала нет листа в общем отчете'; end if;
  select m into v_month from jsonb_array_elements(v_sheet.months) m where m->>'m'=to_char(p_day,'YYYY-MM') limit 1;
  if v_month is null then raise exception 'В общем отчете нет месяца %', to_char(p_day,'MM.YYYY'); end if;
  sheet_id:=v_sheet.id; m_from:=(v_month->>'from')::int; m_to:=(v_month->>'to')::int;
  select k::int into row_no from jsonb_each(v_sheet.data->'rows') as r(k,v)
   where k::int between m_from and m_to and v->'A'->>'v'=v_serial::text limit 1;
  if row_no is null then raise exception 'В общем отчете нет строки на %', to_char(p_day,'DD.MM.YYYY'); end if;
end $function$;

CREATE OR REPLACE FUNCTION public.report_fill_shift(p_shift_id bigint, p_mode text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare c record; d record; v_shifts bigint[]; v_names text; v_vals jsonb;
begin
  if p_mode not in ('auto','manual') then raise exception 'Неизвестный способ заполнения'; end if;
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no)
    values (p_shift_id,c.branch_id,c.day,p_mode,d.sheet_id,d.row_no)
    on conflict (shift_id) do update set mode=excluded.mode, sheet_id=excluded.sheet_id, row_no=excluded.row_no, updated_at=now();
  if p_mode='auto' then
    select array_agg(id) into v_shifts from public.sales_shifts
     where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=c.day;
    select string_agg(nm,'/' order by first_at) into v_names from (
      select coalesce(nullif(btrim(p.name),''),e.name) nm, min(se.created_at) first_at
        from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
        left join public.sales_people p on p.id=e.person_id
       where se.shift_id=any(v_shifts) group by 1) x;
    with v as (select id,total from public.sales where shift_id=any(v_shifts) and status='completed' and payment_status<>'unpaid'),
         pay as (select p.payment_method m, sum(p.amount) a from public.sale_payments p join v on v.id=p.sale_id group by 1)
    select jsonb_build_object(
      'C', v_names,
      'D', (select coalesce(sum(total),0) from v),
      'G', coalesce((select a from pay where m='card'),0),
      'H', coalesce((select a from pay where m='qr'),0),
      'I', coalesce((select a from pay where m='link'),0),
      'J', coalesce((select a from pay where m='transfer'),0),
      'K', coalesce((select a from pay where m='bank_account'),0),
      'L', (select count(*) from v),
      'M', (select coalesce(sum(amount),0) from public.sales_returns where shift_id=any(v_shifts)),
      'Q', (select coalesce(sum(i.quantity),0) from public.sale_items i join v on v.id=i.sale_id
             where i.item_type='service' and i.item_name ilike '%ретуш%')) into v_vals;
    perform public.report_put_row(d.sheet_id, d.row_no, v_vals);
    perform public.report_recalc_total(d.sheet_id, d.m_to);
  end if;
  return public.report_staff_view(p_shift_id);
end $function$;

CREATE OR REPLACE FUNCTION public.report_import_apply()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r record; j jsonb; v_rows jsonb; v_id bigint; v_out jsonb:='[]'::jsonb; v_cells int;
begin
  for r in select sheet_no, string_agg(body,'' order by part) txt from public.report_import group by sheet_no order by sheet_no loop
    j:=r.txt::jsonb;
    with allc as (
      select public.report_col_name(e.i::int)||rw.key addr, jsonb_build_object('v',e.val) cell
        from jsonb_each(j->'rows') rw, jsonb_array_elements(rw.value) with ordinality e(val,i) where e.val<>'null'::jsonb
      union all
      select f.key, jsonb_strip_nulls(jsonb_build_object('f',f.value->0,'v',f.value->1)) from jsonb_each(j->'fm') f
      union all
      select public.report_col_name(c)||rr, jsonb_build_object('s',st.key::int)
        from jsonb_each(j->'st') st, jsonb_array_elements_text(st.value) a,
             lateral (select regexp_match(a,'^([A-Z]+)([0-9]+)(?::([A-Z]+)([0-9]+))?$') m) p,
             generate_series(public.report_col_num(p.m[1]), public.report_col_num(coalesce(p.m[3],p.m[1]))) c,
             generate_series(p.m[2]::int, coalesce(p.m[4],p.m[2])::int) rr),
    merged as (
      select x.addr, jsonb_object_agg(kv.key,kv.value) cell from allc x, jsonb_each(x.cell) kv group by x.addr),
    byrow as (
      select substring(addr from '[0-9]+$') rn, jsonb_object_agg(substring(addr from '^[A-Z]+'), cell) rowobj from merged group by 1)
    select coalesce(jsonb_object_agg(rn,rowobj),'{}'::jsonb), (select count(*) from merged) into v_rows, v_cells from byrow;
    select id into v_id from public.report_sheets where lower(trim(title))=lower(trim(j->>'t')) limit 1;
    if v_id is null then
      insert into public.report_sheets(sort_order,title,branch_id,data,months)
      values ((j->>'o')::int, j->>'t', nullif(j->>'b','')::bigint, (j->'meta')||jsonb_build_object('rows',v_rows), coalesce(j->'months','[]'::jsonb))
      returning id into v_id;
    else
      update public.report_sheets set sort_order=(j->>'o')::int, branch_id=nullif(j->>'b','')::bigint,
        data=(j->'meta')||jsonb_build_object('rows',v_rows), months=coalesce(j->'months','[]'::jsonb), updated_at=now() where id=v_id;
    end if;
    v_out:=v_out||jsonb_build_object('title',j->>'t','cells',v_cells);
  end loop;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION public.report_past_rows(p_sheet_id bigint, p_from integer, p_day_row integer)
 RETURNS integer[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(k::int order by k::int),array[]::int[]) from public.report_sheets s, jsonb_each(s.data->'rows') as r(k,v)
   where s.id=p_sheet_id and k::int>=p_from and k::int<p_day_row and jsonb_typeof(v->'A'->'v')='number'
$function$;

CREATE OR REPLACE FUNCTION public.report_put_row(p_sheet_id bigint, p_row integer, p_vals jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_row jsonb; v_cell jsonb; k text; val jsonb;
begin
  select coalesce(data->'rows'->(p_row::text),'{}'::jsonb) into v_row from public.report_sheets where id=p_sheet_id for update;
  for k,val in select * from jsonb_each(p_vals) loop
    v_cell:=coalesce(v_row->k,'{}'::jsonb)-'v'-'f';
    if val is not null and jsonb_typeof(val)<>'null' then v_cell:=v_cell||jsonb_build_object('v',val); end if;
    if v_cell='{}'::jsonb then v_row:=v_row-k; else v_row:=v_row||jsonb_build_object(k,v_cell); end if;
  end loop;
  update public.report_sheets set data=jsonb_set(data,array['rows',p_row::text],v_row,true), updated_at=now() where id=p_sheet_id;
end $function$;

CREATE OR REPLACE FUNCTION public.report_recalc_total(p_sheet_id bigint, p_row integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_data jsonb; k text; c jsonb; m text[]; s numeric; vals jsonb:='{}'::jsonb;
begin
  select data into v_data from public.report_sheets where id=p_sheet_id;
  for k,c in select * from jsonb_each(coalesce(v_data->'rows'->(p_row::text),'{}'::jsonb)) loop
    m:=regexp_match(coalesce(c->>'f',''),'^SUM\(([A-Z]+)(\d+):([A-Z]+)(\d+)\)$');
    if m is null or m[1]<>k or m[3]<>k then continue; end if;
    select coalesce(sum((v->k->>'v')::numeric),0) into s from jsonb_each(v_data->'rows') as r(rk,v)
     where rk::int between m[2]::int and m[4]::int and jsonb_typeof(v->k->'v')='number';
    vals:=vals||jsonb_build_object(k,s);
  end loop;
  if vals='{}'::jsonb then return; end if;
  update public.report_sheets set data=jsonb_set(data,array['rows',p_row::text],
    (select jsonb_object_agg(kk, case when vals ? kk then vv||jsonb_build_object('v',vals->kk) else vv end)
       from jsonb_each(data->'rows'->(p_row::text)) as x(kk,vv)),true)
   where id=p_sheet_id;
end $function$;

CREATE OR REPLACE FUNCTION public.report_shift_ctx(p_shift_id bigint, OUT branch_id bigint, OUT day date)
 RETURNS record LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  select sh.branch_id, (sh.started_at at time zone 'Europe/Moscow')::date into branch_id, day
    from public.sales_shifts sh where sh.id=p_shift_id;
  if not found then raise exception 'Смена не найдена'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.report_staff_cols(p_mode text) RETURNS text[] LANGUAGE sql IMMUTABLE
AS $function$
  select case p_mode when 'auto' then array['E','F','N','O','P','R','S']
                     when 'manual' then array['C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S']
                     else array[]::text[] end
$function$;

CREATE OR REPLACE FUNCTION public.report_staff_set(p_shift_id bigint, p_col text, p_value jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare c record; d record; v_mode text; v_data jsonb;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  select * into d from public.report_day_row(c.branch_id, c.day);
  select mode into v_mode from public.report_fills where shift_id=p_shift_id;
  if v_mode is null then
    select mode into v_mode from public.report_fills where branch_id=c.branch_id and day=c.day order by updated_at desc limit 1;
  end if;
  if v_mode is null then raise exception 'Сначала нажмите «Перенести в общий отчет» или «Заполнить отчет вручную»'; end if;
  if not (p_col = any(public.report_staff_cols(v_mode))) then raise exception 'Эту клетку заполняет касса'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>500 then raise exception 'Слишком длинный текст'; end if;
  perform public.report_put_row(d.sheet_id, d.row_no, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  update public.report_fills set updated_at=now() where shift_id=p_shift_id;
  select data into v_data from public.report_sheets where id=d.sheet_id;
  return jsonb_build_object(d.row_no::text, v_data->'rows'->(d.row_no::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $function$;

CREATE OR REPLACE FUNCTION public.report_staff_set_past(p_shift_id bigint, p_row integer, p_col text, p_value jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare c record; d record; v_data jsonb; v_day date; v_shift bigint;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  if not (p_row = any(public.report_past_rows(d.sheet_id,d.m_from,d.row_no))) then raise exception 'Эту строку менять нельзя'; end if;
  if not (p_col = any(public.report_staff_cols('manual'))) then raise exception 'Эту клетку менять нельзя'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>500 then raise exception 'Слишком длинный текст'; end if;
  perform public.report_put_row(d.sheet_id, p_row, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  select data into v_data from public.report_sheets where id=d.sheet_id;
  v_day:=date '1899-12-30'+(v_data->'rows'->(p_row::text)->'A'->>'v')::numeric::int;
  if not exists(select 1 from public.report_fills where branch_id=c.branch_id and day=v_day) then
    select id into v_shift from public.sales_shifts where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=v_day order by started_at limit 1;
    if v_shift is not null then
      insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no) values (v_shift,c.branch_id,v_day,'manual',d.sheet_id,p_row) on conflict (shift_id) do nothing;
    end if;
  else
    update public.report_fills set updated_at=now() where branch_id=c.branch_id and day=v_day;
  end if;
  return jsonb_build_object(p_row::text, v_data->'rows'->(p_row::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $function$;

CREATE OR REPLACE FUNCTION public.report_staff_sheets()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'data',data) order by sort_order,id),'[]'::jsonb)
  from public.report_sheets where staff_visible and branch_id is null;
$function$;

CREATE OR REPLACE FUNCTION public.report_staff_view(p_shift_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare c record; d record; v_sheet public.report_sheets; v_rows jsonb; v_mode text;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  select * into d from public.report_day_row(c.branch_id, c.day);
  select * into v_sheet from public.report_sheets where id=d.sheet_id;
  select mode into v_mode from public.report_fills where shift_id=p_shift_id;
  if v_mode is null then
    select mode into v_mode from public.report_fills where branch_id=c.branch_id and day=c.day order by updated_at desc limit 1;
  end if;
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into v_rows from jsonb_each(v_sheet.data->'rows') as r(k,v)
   where k::int between d.m_from and d.m_to;
  return jsonb_build_object('title',v_sheet.title,'month',to_char(c.day,'YYYY-MM'),'from',d.m_from,'to',d.m_to,'row',d.row_no,
    'mode',v_mode,'cols',to_jsonb(public.report_staff_cols(v_mode)),
    'past',to_jsonb(public.report_past_rows(d.sheet_id,d.m_from,d.row_no)),'past_cols',to_jsonb(public.report_staff_cols('manual')),
    'data',jsonb_build_object('ncols',v_sheet.data->'ncols','cols',v_sheet.data->'cols','styles',v_sheet.data->'styles',
      'merges',v_sheet.data->'merges','heights',v_sheet.data->'heights','rows',v_rows),
    'updated_at',v_sheet.updated_at);
end $function$;