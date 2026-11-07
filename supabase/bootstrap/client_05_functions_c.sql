set check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.sales_cancel_pickup(p_pickup_id bigint, p_reason text DEFAULT NULL::text)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  update public.pickup_orders set status='cancelled',cancelled_at=now(),cancel_reason=nullif(trim(coalesce(p_reason,'')),'')
  where id=p_pickup_id and status='pending';
  if not found then raise exception 'Заказ не найден или уже закрыт'; end if;
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_close_shift(p_shift_id bigint)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_closed boolean;
begin
  update public.sales_shifts set status = 'closed', ended_at = coalesce(ended_at, now())
   where id = p_shift_id and status = 'open';
  v_closed := found;
  return v_closed;
end;
$function$;

CREATE OR REPLACE FUNCTION public.sales_close_team_shift(p_shift_id bigint, p_employee_id bigint)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_branch_id bigint; v_shift public.sales_shifts%rowtype;
begin
  select branch_id into v_branch_id from public.sales_shifts where id=p_shift_id;
  if not found then raise exception 'Смена не найдена'; end if;
  perform pg_advisory_xact_lock(v_branch_id);
  select * into v_shift from public.sales_shifts where id=p_shift_id for update;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then
    raise exception 'Кассир не является участником смены';
  end if;
  if v_shift.status<>'open' then return false; end if;
  if exists(select 1 from public.sales_shift_tasks t where t.branch_id=v_branch_id and t.is_active
    and t.task_date=(now() at time zone 'Europe/Moscow')::date
    and not exists(select 1 from public.sales_shift_task_completions c where c.task_id=t.id and c.shift_id=p_shift_id)) then
    raise exception 'Подтвердите выполнение заданий смены';
  end if;
  if public.kassa_cash_check_enabled() and v_shift.close_cash is null then
    raise exception 'Укажите остаток наличных в кассе. Если окна для суммы нет — обновите страницу (Ctrl+F5).';
  end if;
  update public.sales_shifts set status='closed',ended_at=now() where id=p_shift_id;
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_complete_person_task(p_task_id bigint, p_shift_id bigint, p_employee_id bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_person bigint;
begin
  select e.person_id into v_person
  from sales_shift_employees se
  join sales_employees e on e.id = se.employee_id
  join sales_shifts s on s.id = se.shift_id
  where se.shift_id = p_shift_id and se.employee_id = p_employee_id and s.ended_at is null;
  if v_person is null then raise exception 'Смена закрыта или сотрудник не участвует в смене'; end if;
  update sales_person_tasks
     set completed_at = now(), completed_shift_id = p_shift_id, completed_by_employee_id = p_employee_id
   where id = p_task_id and person_id = v_person and completed_at is null and is_active;
  if not found then raise exception 'Задание не найдено или уже выполнено'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_create_sale(p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid DEFAULT NULL::uuid, p_loyalty_points numeric DEFAULT 0, p_loyalty_name text DEFAULT NULL::text, p_loyalty_phone text DEFAULT NULL::text, p_loyalty_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_discount_percent numeric DEFAULT 0, p_payments jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_shift public.sales_shifts%rowtype;
  v_sale_id bigint;
  v_order bigint;
  v_gross numeric(12,2):=0;
  v_discount numeric(12,2):=0;
  v_after_discount numeric(12,2):=0;
  v_total numeric(12,2):=0;
  v_points numeric(12,2):=round(coalesce(p_loyalty_points,0),2);
  v_item jsonb; v_pay jsonb; v_catalog public.sales_catalog%rowtype;
  v_qty numeric(12,3); v_price numeric(12,2); v_line numeric(12,2);
  v_pay_sum numeric(12,2):=0; v_customer_id uuid:=p_loyalty_customer_id;
  v_min bigint;
  v_forced bigint:=nullif(current_setting('polaroid.pickup_order',true),'')::bigint;
begin
  select * into v_shift from public.sales_shifts where id=p_shift_id and (status='open' or current_setting('polaroid.offline_sync',true)='1') for update;
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then raise exception 'Сотрудник не подключён к этой смене'; end if;
  if p_payment_method not in ('cash','card','qr','link','bank_account','transfer','split') then raise exception 'Выберите способ оплаты'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  if coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100 then raise exception 'Скидка должна быть от 0 до 100%%'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_catalog from public.sales_catalog where id=(v_item->>'catalog_id')::bigint and is_active=true;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_catalog.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_line:=round(v_qty*v_price,2); v_gross:=v_gross+v_line;
  end loop;
  v_discount:=round(v_gross*coalesce(p_discount_percent,0)/100,2);
  v_after_discount:=round(v_gross-v_discount,2);
  if v_points<0 or v_points>round(v_after_discount*0.30,2) then raise exception 'Баллами можно оплатить не более 30%% после скидки'; end if;
  if v_points>0 then
    if v_customer_id is null then raise exception 'Выберите клиента клубной карты'; end if;
    perform public.loyalty_redeem(v_customer_id,v_after_discount,v_points,'Списание баллов при продаже');
  end if;
  v_total:=round(v_after_discount-v_points,2);

  if p_payment_method='split' then
    if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)<2 then raise exception 'Для раздельной оплаты добавьте минимум два способа оплаты'; end if;
    for v_pay in select * from jsonb_array_elements(p_payments) loop
      if (v_pay->>'method') not in ('cash','card','qr','link','bank_account','transfer') then raise exception 'Некорректный способ в раздельной оплате'; end if;
      if coalesce((v_pay->>'amount')::numeric,0)<=0 then raise exception 'Сумма каждого способа оплаты должна быть больше 0'; end if;
      v_pay_sum:=v_pay_sum+round((v_pay->>'amount')::numeric,2);
    end loop;
  else
    v_pay_sum:=v_total;
  end if;
  if round(v_pay_sum,2)<>round(v_total,2) then raise exception 'Сумма способов оплаты должна быть ровно %',v_total; end if;

  insert into public.sales_branch_order_counters(branch_id,next_number) values(v_shift.branch_id,1000) on conflict(branch_id) do nothing;
  select next_number into v_min from public.sales_branch_order_counters where branch_id=v_shift.branch_id for update;
  if v_forced is not null and v_forced=p_order_number
     and not exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_forced) then
    v_order:=v_forced;
  else
    select greatest(v_min, coalesce(max(s.order_number)+1,v_min)) into v_min
    from public.sales s where s.branch_id=v_shift.branch_id;
    v_order:=case when p_order_number is null or p_order_number<v_min then v_min else p_order_number end;
    while exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_order)
       or exists(select 1 from public.pickup_orders o where o.branch_id=v_shift.branch_id and o.order_number=v_order and o.status='pending') loop
      v_order:=v_order+1;
    end loop;
  end if;

  if v_customer_id is null and nullif(trim(coalesce(p_loyalty_phone,'')),'') is not null then
    select x.customer_id into v_customer_id from public.loyalty_add_purchase(trim(p_loyalty_name),trim(p_loyalty_phone),v_gross,nullif(trim(coalesce(p_loyalty_comment,'')),'')) x limit 1;
  elsif v_customer_id is not null then
    select x.customer_id into v_customer_id from public.loyalty_customers c cross join lateral public.loyalty_add_purchase(c.name,c.phone,v_gross,nullif(trim(coalesce(p_loyalty_comment,'')),'')) x where c.id=v_customer_id;
  end if;

  insert into public.sales(order_number,shift_id,branch_id,employee_id,payment_method,total,gross_total,discount_percent,discount_amount,loyalty_points_used,loyalty_customer_id,comment,receipt_issued,payment_status,paid_at)
  values(v_order,v_shift.id,v_shift.branch_id,p_employee_id,p_payment_method,v_total,v_gross,coalesce(p_discount_percent,0),v_discount,v_points,v_customer_id,nullif(trim(coalesce(p_comment,'')),''),case when p_payment_method='link' then null else true end,case when p_payment_method='link' then 'pending' else 'paid' end,case when p_payment_method='link' then null else now() end)
  returning id into v_sale_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_catalog from public.sales_catalog where id=(v_item->>'catalog_id')::bigint;
    v_qty:=(v_item->>'quantity')::numeric; v_price:=(v_item->>'unit_price')::numeric; v_line:=round(v_qty*v_price,2);
    insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total,variant_material_id)
    values(v_sale_id,v_catalog.id,v_catalog.item_type,v_catalog.name,v_qty,v_price,v_line,v_catalog.cost_price,round(coalesce(v_catalog.cost_price,0)*v_qty,2),
      (select m.id from public.stock_materials m where m.id=nullif(v_item->>'variant_material_id','')::bigint and (m.variant_catalog_id=v_catalog.id or exists(select 1 from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=v_catalog.id and n.active))));
  end loop;
  if p_payment_method='split' then
    for v_pay in select * from jsonb_array_elements(p_payments) loop
      insert into public.sale_payments(sale_id,payment_method,amount) values(v_sale_id,(v_pay->>'method'),round((v_pay->>'amount')::numeric,2));
    end loop;
  else
    insert into public.sale_payments(sale_id,payment_method,amount) values(v_sale_id,p_payment_method,v_total);
  end if;
  update public.sales_branch_order_counters set next_number=greatest(next_number,v_order+1),updated_at=now() where branch_id=v_shift.branch_id;
  return v_order;
end; $function$;

CREATE OR REPLACE FUNCTION public.sales_create_sale_v6(p_client_uid uuid, p_offline_at timestamp with time zone, p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid DEFAULT NULL::uuid, p_loyalty_points numeric DEFAULT 0, p_loyalty_name text DEFAULT NULL::text, p_loyalty_phone text DEFAULT NULL::text, p_loyalty_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_discount_percent numeric DEFAULT 0, p_payments jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_existing bigint; v_order bigint;
  v_at timestamptz:=case when p_offline_at is null then null else least(greatest(p_offline_at,now()-interval '14 days'),now()) end;
begin
  if p_client_uid is null then raise exception 'Нет идентификатора продажи'; end if;
  perform pg_advisory_xact_lock(hashtext('sale:'||p_client_uid::text));
  select order_number into v_existing from public.sales where client_uid=p_client_uid;
  if found then return v_existing; end if;
  if v_at is not null then perform set_config('polaroid.offline_sync','1',true); end if;
  v_order:=public.sales_create_sale(p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,
    p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_order_number,p_discount_percent,p_payments);
  perform set_config('polaroid.offline_sync','',true);
  update public.sales s set client_uid=p_client_uid,
    offline_at=v_at,
    created_at=coalesce(v_at,s.created_at),
    paid_at=case when s.paid_at is not null and v_at is not null then v_at else s.paid_at end
  where s.id=(select x.id from public.sales x join public.sales_shifts sh on sh.branch_id=x.branch_id
              where sh.id=p_shift_id and x.order_number=v_order order by x.id desc limit 1);
  return v_order;
end; $function$;

CREATE OR REPLACE FUNCTION public.sales_ensure_employee(p_person_id bigint, p_branch_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_person public.sales_people%rowtype; v_employee public.sales_employees%rowtype;
begin
  perform pg_advisory_xact_lock(p_branch_id);
  if not exists(select 1 from public.sales_branches where id=p_branch_id and is_active) then
    raise exception 'Филиал не найден или отключён';
  end if;
  select * into v_person from public.sales_people where id=p_person_id and is_active;
  if not found then raise exception 'Сотрудник не найден или отключён'; end if;
  select * into v_employee from public.sales_employees where person_id=p_person_id and branch_id=p_branch_id for update;
  if not found then
    insert into public.sales_employees(person_id,branch_id,name,is_active)
    values(p_person_id,p_branch_id,v_person.name,true) returning * into v_employee;
  elsif not v_employee.is_active then
    update public.sales_employees set is_active=true where id=v_employee.id returning * into v_employee;
  end if;
  return to_jsonb(v_employee);
end $function$;

CREATE OR REPLACE FUNCTION public.sales_get_shift_context(p_shift_id bigint)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
select jsonb_build_object(
  'shiftId',s.id,'branchId',s.branch_id,'branchName',b.name,'status',s.status,'startedAt',s.started_at,
  'participants',coalesce((select jsonb_agg(jsonb_build_object(
    'employeeId',e.id,'personId',e.person_id,'name',coalesce(person.name,e.name),'isLead',p.is_lead,
    'isActive',coalesce(person.is_active,false) and e.is_active) order by e.id)
    from public.sales_shift_employees p join public.sales_employees e on e.id=p.employee_id
    left join public.sales_people person on person.id=e.person_id where p.shift_id=s.id),'[]'::jsonb))
from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id where s.id=p_shift_id;
$function$;

CREATE OR REPLACE FUNCTION public.sales_hold_pickup(p_shift_id bigint, p_employee_id bigint, p_items jsonb, p_discount_percent numeric DEFAULT 0, p_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_customer_id uuid DEFAULT NULL::uuid, p_client_name text DEFAULT NULL::text, p_client_phone text DEFAULT NULL::text)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_shift public.sales_shifts%rowtype; v_item jsonb; v_cat public.sales_catalog%rowtype;
  v_qty numeric(12,3); v_price numeric(12,2); v_line numeric(12,2); v_gross numeric(12,2):=0; v_total numeric(12,2);
  v_items jsonb:='[]'::jsonb; v_min bigint; v_order bigint;
begin
  select * into v_shift from public.sales_shifts where id=p_shift_id and status='open' for update;
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then raise exception 'Сотрудник не подключён к этой смене'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  if coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100 then raise exception 'Скидка должна быть от 0 до 100%%'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_cat from public.sales_catalog where id=(v_item->>'catalog_id')::bigint and is_active=true;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_cat.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_line:=round(v_qty*v_price,2); v_gross:=v_gross+v_line;
    v_items:=v_items||jsonb_build_array(jsonb_build_object('catalog_id',v_cat.id,'name',v_cat.name,'item_type',v_cat.item_type,'quantity',v_qty,'unit_price',v_price,'line_total',v_line,'variant_material_id',v_item->'variant_material_id'));
  end loop;
  v_total:=round(v_gross-round(v_gross*coalesce(p_discount_percent,0)/100,2),2);
  insert into public.sales_branch_order_counters(branch_id,next_number) values(v_shift.branch_id,1000) on conflict(branch_id) do nothing;
  select next_number into v_min from public.sales_branch_order_counters where branch_id=v_shift.branch_id for update;
  select greatest(v_min, coalesce(max(s.order_number)+1,v_min)) into v_min from public.sales s where s.branch_id=v_shift.branch_id;
  v_order:=case when p_order_number is null or p_order_number<v_min then v_min else p_order_number end;
  while exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_order)
     or exists(select 1 from public.pickup_orders o where o.branch_id=v_shift.branch_id and o.order_number=v_order and o.status='pending') loop
    v_order:=v_order+1;
  end loop;
  update public.sales_branch_order_counters set next_number=greatest(next_number,v_order+1),updated_at=now() where branch_id=v_shift.branch_id;
  insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,discount_percent,total,customer_id,client_name,client_phone,comment)
  values(v_shift.branch_id,v_shift.id,p_employee_id,v_order,v_items,v_gross,coalesce(p_discount_percent,0),v_total,p_customer_id,
    nullif(trim(coalesce(p_client_name,'')),''),nullif(trim(coalesce(p_client_phone,'')),''),nullif(trim(coalesce(p_comment,'')),''));
  return v_order;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_hold_pickup_v2(p_shift_id bigint, p_employee_id bigint, p_items jsonb, p_discount_percent numeric DEFAULT 0, p_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_customer_id uuid DEFAULT NULL::uuid, p_client_name text DEFAULT NULL::text, p_client_phone text DEFAULT NULL::text, p_client_order_ref text DEFAULT NULL::text)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_order bigint;
begin
  if p_customer_id is null and nullif(trim(coalesce(p_client_name,'')),'') is null and nullif(trim(coalesce(p_client_phone,'')),'') is null then
    raise exception 'Укажите контакт клиента: Telegram, Max или телефон';
  end if;
  v_order:=public.sales_hold_pickup(p_shift_id,p_employee_id,p_items,p_discount_percent,p_comment,p_order_number,p_customer_id,p_client_name,p_client_phone);
  update public.pickup_orders set client_order_ref=nullif(trim(coalesce(p_client_order_ref,'')),'')
  where id=(select max(id) from public.pickup_orders where order_number=v_order and status='pending' and shift_id=p_shift_id);
  return v_order;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_mark_link_payment(p_sale_id bigint, p_paid boolean)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if p_paid then
    update public.sales set payment_status='paid', paid_at=now()
    where id=p_sale_id and payment_method='link' and status='completed';
  else
    update public.sales set payment_status='unpaid', cancelled_at=now(), status='returned'
    where id=p_sale_id and payment_method='link' and status='completed';
  end if;
  return found;
end;
$function$;

CREATE OR REPLACE FUNCTION public.sales_next_order_number(p_branch_id bigint)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_next bigint;
begin
  insert into public.sales_branch_order_counters(branch_id,next_number)
  values(p_branch_id,1000) on conflict(branch_id) do nothing;
  select next_number into v_next from public.sales_branch_order_counters where branch_id=p_branch_id;
  return v_next;
end; $function$;

CREATE OR REPLACE FUNCTION public.sales_open_or_join_shift(p_branch_id bigint, p_employee_id bigint)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_shift_id bigint; v_emp_id bigint;
begin
  perform pg_advisory_xact_lock(p_branch_id);
  select id into v_shift_id from public.sales_shifts where branch_id=p_branch_id and status='open' order by started_at limit 1 for update;
  if v_shift_id is null then
    insert into public.sales_shifts(branch_id,employee_id) values(p_branch_id,p_employee_id) returning id into v_shift_id;
  end if;
  insert into public.sales_shift_employees(shift_id,employee_id,is_lead)
  values(v_shift_id,p_employee_id,false) on conflict(shift_id,employee_id) do nothing;
  return v_shift_id;
end; $function$;

CREATE OR REPLACE FUNCTION public.sales_open_team_shift(p_branch_id bigint, p_person_ids bigint[], p_lead_person_id bigint DEFAULT NULL::bigint, p_expected_shift_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_shift_id bigint; v_person_id bigint; v_employee_id bigint; v_lead_id bigint; v_count integer;
begin
  perform pg_advisory_xact_lock(p_branch_id);
  if not exists(select 1 from public.sales_branches where id=p_branch_id and is_active) then
    raise exception 'Филиал не найден или отключён';
  end if;
  if coalesce(cardinality(p_person_ids),0)=0 or array_position(p_person_ids,null) is not null then
    raise exception 'Выберите хотя бы одного сотрудника';
  end if;
  select id into v_shift_id from public.sales_shifts where branch_id=p_branch_id and status='open' for update;
  if p_expected_shift_id is not null and v_shift_id is distinct from p_expected_shift_id then
    raise exception 'Смена уже закрыта или изменилась. Откройте рабочее место заново.';
  end if;
  for v_person_id in select distinct unnest(p_person_ids) order by 1 loop
    select p.employee_id into v_employee_id from public.sales_shift_employees p
      join public.sales_employees e on e.id=p.employee_id
      where p.shift_id=v_shift_id and e.person_id=v_person_id;
    if v_employee_id is null then
      v_employee_id:=(public.sales_ensure_employee(v_person_id,p_branch_id)->>'id')::bigint;
    end if;
    if v_shift_id is null then
      insert into public.sales_shifts(branch_id,employee_id) values(p_branch_id,v_employee_id) returning id into v_shift_id;
    end if;
    insert into public.sales_shift_employees(shift_id,employee_id,is_lead)
      values(v_shift_id,v_employee_id,false) on conflict(shift_id,employee_id) do nothing;
  end loop;
  select count(*) into v_count from public.sales_shift_employees where shift_id=v_shift_id;
  if v_count=1 then
    select employee_id into v_lead_id from public.sales_shift_employees where shift_id=v_shift_id;
  elsif p_lead_person_id is not null then
    select p.employee_id into v_lead_id from public.sales_shift_employees p
      join public.sales_employees e on e.id=p.employee_id
      where p.shift_id=v_shift_id and e.person_id=p_lead_person_id;
    if v_lead_id is null then raise exception 'Главный по ретуши должен быть участником смены'; end if;
  end if;
  if v_lead_id is not null then
    update public.sales_shift_employees set is_lead=false where shift_id=v_shift_id and is_lead;
    update public.sales_shift_employees set is_lead=true where shift_id=v_shift_id and employee_id=v_lead_id;
  end if;
  return public.sales_get_shift_context(v_shift_id);
end $function$;

CREATE OR REPLACE FUNCTION public.sales_pay_pickup(p_pickup_id bigint, p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid DEFAULT NULL::uuid, p_loyalty_points numeric DEFAULT 0, p_loyalty_name text DEFAULT NULL::text, p_loyalty_phone text DEFAULT NULL::text, p_loyalty_comment text DEFAULT NULL::text, p_discount_percent numeric DEFAULT 0, p_payments jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_o public.pickup_orders%rowtype; v_order bigint; v_branch bigint; v_sale bigint;
begin
  select * into v_o from public.pickup_orders where id=p_pickup_id for update;
  if not found or v_o.status<>'pending' then raise exception 'Заказ уже оплачен или отменён'; end if;
  select branch_id into v_branch from public.sales_shifts where id=p_shift_id;
  perform set_config('polaroid.pickup_order',case when v_branch=v_o.branch_id then v_o.order_number::text else '' end,true);
  v_order:=public.sales_create_sale(p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,
    p_loyalty_name,p_loyalty_phone,p_loyalty_comment,case when v_branch=v_o.branch_id then v_o.order_number else null end,p_discount_percent,p_payments);
  perform set_config('polaroid.pickup_order','',true);
  select id into v_sale from public.sales where branch_id=v_branch and order_number=v_order order by id desc limit 1;
  update public.pickup_orders set status='paid',paid_at=now(),paid_shift_id=p_shift_id,sale_id=v_sale where id=p_pickup_id;
  return v_order;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_return_sale(p_sale_id bigint, p_shift_id bigint, p_comment text)
 RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_sale public.sales%rowtype; v_shift public.sales_shifts%rowtype;
begin
  select * into v_shift from public.sales_shifts where id=p_shift_id and status='open';
  if not found then raise exception 'Смена не найдена или закрыта'; end if;
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Продажа не найдена'; end if;
  if v_sale.status='returned' then raise exception 'Эта продажа уже возвращена'; end if;
  update public.sales set status='returned', returned_at=now() where id=v_sale.id;
  insert into public.sales_returns(sale_id,shift_id,branch_id,employee_id,amount,comment)
  values(v_sale.id,v_shift.id,v_shift.branch_id,v_shift.employee_id,v_sale.total,nullif(trim(coalesce(p_comment,'')),''));
  return v_sale.total;
end;
$function$;

CREATE OR REPLACE FUNCTION public.sales_set_close_cash(p_shift_id bigint, p_employee_id bigint, p_amount numeric)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if p_amount is null or p_amount<0 then raise exception 'Укажите остаток наличных в кассе'; end if;
  if not exists(select 1 from public.sales_shift_employees se join public.sales_shifts s on s.id=se.shift_id
                where se.shift_id=p_shift_id and se.employee_id=p_employee_id and s.status='open') then
    raise exception 'Смена закрыта или сотрудник не участвует в смене'; end if;
  update public.sales_shifts set close_cash=round(p_amount,2),close_cash_employee_id=p_employee_id where id=p_shift_id;
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_set_open_cash(p_shift_id bigint, p_employee_id bigint, p_amount numeric)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_expected numeric(12,2); v_branch bigint;
begin
  if p_amount is null or p_amount<0 then raise exception 'Укажите сумму наличных в кассе'; end if;
  select branch_id into v_branch from public.sales_shifts where id=p_shift_id and status='open';
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then raise exception 'Сотрудник не участвует в смене'; end if;
  select close_cash into v_expected from public.sales_shifts where branch_id=v_branch and id<>p_shift_id and status='closed' and close_cash is not null order by ended_at desc nulls last limit 1;
  update public.sales_shifts set open_cash=round(p_amount,2),open_cash_expected=v_expected,open_cash_at=now(),open_cash_employee_id=p_employee_id where id=p_shift_id;
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.sales_shift_cash_info(p_shift_id bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select jsonb_build_object('shiftId',s.id,'openCash',s.open_cash,'openCashExpected',s.open_cash_expected,'closeCash',s.close_cash,
    'cashSales',(select coalesce(sum(p.amount),0) from public.sale_payments p join public.sales x on x.id=p.sale_id
                 where x.shift_id=s.id and x.status='completed' and p.payment_method='cash'),
    'prev',(select jsonb_build_object('shiftId',v.id,'closeCash',v.close_cash,'endedAt',v.ended_at,
              'closedBy',(select coalesce(pp.name,e.name) from public.sales_employees e left join public.sales_people pp on pp.id=e.person_id where e.id=v.close_cash_employee_id))
            from public.sales_shifts v where v.branch_id=s.branch_id and v.id<>s.id and v.status='closed' and v.close_cash is not null
            order by v.ended_at desc nulls last limit 1))
  from public.sales_shifts s where s.id=p_shift_id;
$function$;

CREATE OR REPLACE FUNCTION public.sales_shift_set_no_pay(p_shift_id bigint, p_no_pay boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  update public.sales_shifts set no_pay=coalesce(p_no_pay,false) where id=p_shift_id and status='open';
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.staff_request_guard()
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
declare r text := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', current_user);
begin
  if r in ('service_role', 'supabase_admin', 'postgres') then return; end if;
  if r = 'authenticated' and public.is_staff() then return; end if;
  raise sqlstate 'PT401' using message = 'Требуется вход сотрудника';
end $function$;