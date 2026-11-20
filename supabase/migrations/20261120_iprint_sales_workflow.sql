-- iПринт only: atomic receipt reminder, optimistic sale edits and missing report dates.
create schema if not exists iprint_private;
revoke all on schema iprint_private from public,anon;
grant usage on schema iprint_private to authenticated;
alter table public.sales add column if not exists cash_receipt_issued boolean not null default false,
 add column if not exists cash_receipt_at timestamptz,add column if not exists cash_receipt_by uuid,
 add column if not exists edit_version integer not null default 0;
create table if not exists iprint_private.sale_edits(id bigint generated always as identity primary key,sale_id bigint not null references public.sales(id),actor uuid not null,changed_at timestamptz not null default now(),kind text not null,before_state jsonb not null,after_state jsonb not null);
create index if not exists sale_edits_sale_idx on iprint_private.sale_edits(sale_id,changed_at);
alter table iprint_private.sale_edits enable row level security;
revoke all on iprint_private.sale_edits from public,anon,authenticated;
create policy no_client_access on iprint_private.sale_edits for all to anon,authenticated using(false) with check(false);
create or replace function iprint_private.actor(p_sale_id bigint,p_shift_id bigint) returns public.sales
language plpgsql security definer set search_path='' as $$
declare s public.sales;sh public.sales_shifts;
begin
 if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
 select * into s from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Продажа не найдена';end if;
 if not public.is_admin() then
  select * into sh from public.sales_shifts where id=p_shift_id and status='open';
  if not found or sh.branch_id<>s.branch_id then raise exception 'Откройте смену в филиале этой продажи';end if;
 end if;
 return s;
end $$;
create or replace function iprint_private.snapshot(p_sale_id bigint) returns jsonb language sql security definer set search_path='' as $$
 select jsonb_build_object('sale',to_jsonb(s),'items',coalesce((select jsonb_agg(i order by i.id) from public.sale_items i where sale_id=s.id),'[]'),'payments',coalesce((select jsonb_agg(p order by p.id) from public.sale_payments p where sale_id=s.id),'[]'),'stock',coalesce((select jsonb_agg(sm) from public.stock_moves sm where sale_id=s.id and cancelled_at is null),'[]'),'debts',coalesce((select jsonb_agg(d) from public.customer_debts d where sale_id=s.id),'[]')) from public.sales s where id=p_sale_id
$$;
create or replace function iprint_private.set_receipt(p_sale_id bigint,p_shift_id bigint,p_issued boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.sales;before jsonb;
begin
 s:=iprint_private.actor(p_sale_id,p_shift_id);before:=iprint_private.snapshot(s.id);
 if s.cash_receipt_issued is distinct from coalesce(p_issued,false) then
  update public.sales set cash_receipt_issued=coalesce(p_issued,false),cash_receipt_at=case when p_issued then now() end,cash_receipt_by=case when p_issued then auth.uid() end,edit_version=edit_version+1 where id=s.id;
  insert into iprint_private.sale_edits(sale_id,actor,kind,before_state,after_state) values(s.id,auth.uid(),'receipt',before,iprint_private.snapshot(s.id));
 end if;return '{"ok":true}';
end $$;
create or replace function iprint_private.get_sale(p_sale_id bigint,p_shift_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.sales;
begin
 s:=iprint_private.actor(p_sale_id,p_shift_id);
 return iprint_private.snapshot(s.id)||jsonb_build_object('employee',(select name from public.sales_employees where id=s.employee_id),'balance',coalesce((select balance from public.loyalty_get_customer(s.loyalty_customer_id)),0),'editable',s.status='completed' and (s.created_at at time zone 'Europe/Moscow')::date=(now() at time zone 'Europe/Moscow')::date);
end $$;
create or replace function iprint_private.edit_sale(p_sale_id bigint,p_shift_id bigint,p_expected_version integer,p_items jsonb,p_discount_percent numeric,p_loyalty_points numeric,p_payment_method text,p_payments jsonb,p_comment text,p_cash_receipt_issued boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
<<edit_values>>
declare s public.sales;before jsonb;it jsonb;pay jsonb;c public.sales_catalog;old_it public.sale_items;new_id bigint;gross numeric:=0;discount numeric;after_discount numeric;points numeric:=round(coalesce(p_loyalty_points,0),2);total numeric;pay_sum numeric:=0;qty numeric;price numeric;balance numeric;old_debt public.customer_debts;due numeric:=0;route bigint;v_variant bigint;earned_delta numeric;available timestamptz;report_shift bigint;
begin
 s:=iprint_private.actor(p_sale_id,p_shift_id);
 if s.status<>'completed' or (s.created_at at time zone 'Europe/Moscow')::date<>(now() at time zone 'Europe/Moscow')::date then raise exception 'Редактируются только действующие продажи за сегодня';end if;
 if s.edit_version is distinct from p_expected_version then raise sqlstate 'PT409' using message='Продажа уже изменена другим сотрудником. Откройте её заново';end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Добавьте от 1 до 500 позиций';end if;
 if p_discount_percent is null or p_discount_percent not between 0 and 100 then raise exception 'Скидка должна быть от 0 до 100%%';end if;
 if length(coalesce(p_comment,''))>4000 then raise exception 'Комментарий — не более 4000 символов';end if;
 if p_payment_method not in('cash','card','qr','link','bank_account','transfer','split') or p_payment_method is null then raise exception 'Выберите способ оплаты';end if;
 before:=iprint_private.snapshot(s.id);
 for it in select * from jsonb_array_elements(p_items) loop
  select * into old_it from public.sale_items where id=(it->>'id')::bigint and sale_id=s.id;
  select * into c from public.sales_catalog where id=(it->>'catalog_id')::bigint;
  if c.id is null and (old_it.id is null or old_it.catalog_id is not null) then raise exception 'Товар не найден';end if;
  if c.id is not null and not c.is_active and not exists(select 1 from public.sale_items where sale_id=s.id and catalog_id=c.id) then raise exception 'Товар снят с продажи: %',c.name;end if;
  qty:=(it->>'quantity')::numeric;price:=(it->>'unit_price')::numeric;
  if qty is null or qty<=0 or qty>99999999 or qty<>round(qty,3) or price is null or price<0 or price>99999999 or price<>round(price,2) then raise exception 'Проверьте количество и цену';end if;
  if coalesce(c.unit,'pcs')='pcs' and qty<>trunc(qty) then raise exception 'Количество штучного товара должно быть целым';end if;
  v_variant:=nullif(it->>'variant_material_id','')::bigint;
  if v_variant is not null and not exists(select 1 from public.stock_materials m where m.id=v_variant and (m.variant_catalog_id=c.id or exists(select 1 from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=c.id and n.active))) then raise exception 'Вариант не относится к выбранному товару';end if;
  if v_variant is null and exists(select 1 from public.stock_materials where variant_catalog_id=c.id and not archived) then raise exception 'Выберите размер и цвет товара';end if;
  gross:=gross+round(qty*price,2);
 end loop;
 discount:=round(gross*p_discount_percent/100,2);after_discount:=gross-discount;
 if points<0 or points>round(after_discount*.3,2) then raise exception 'Баллами можно списать не более 30%% после скидки';end if;
 if s.loyalty_customer_id is null and points<>0 then raise exception 'К продаже не привязана клубная карта';end if;
 if s.loyalty_customer_id is not null then
  perform 1 from public.loyalty_customers where id=s.loyalty_customer_id for update;
  select coalesce(sum(t.points),0) into balance from public.loyalty_transactions t where t.customer_id=s.loyalty_customer_id and available_at<=now();
  if points>balance+s.loyalty_points_used then raise exception 'Недостаточно баллов клиента';end if;
 end if;
 total:=round(after_discount-points,2);
 if p_payment_method='split' then
  if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)<2 then raise exception 'Укажите минимум два способа оплаты';end if;
  for pay in select * from jsonb_array_elements(p_payments) loop
   if pay->>'method' not in('cash','card','qr','link','bank_account','transfer') or pay->>'method' is null or (pay->>'amount')::numeric<=0 or (pay->>'amount')::numeric<>round((pay->>'amount')::numeric,2) then raise exception 'Проверьте раздельную оплату';end if;
   pay_sum:=pay_sum+(pay->>'amount')::numeric;if pay->>'method'='bank_account' then due:=due+(pay->>'amount')::numeric;end if;
  end loop;
  if pay_sum<>total then raise exception 'Сумма способов оплаты не равна итогу продажи';end if;
 else p_payments:=jsonb_build_array(jsonb_build_object('method',p_payment_method,'amount',total));if p_payment_method='bank_account' then due:=total;end if;end if;
 select * into old_debt from public.customer_debts where sale_id=s.id for update;
 if old_debt.paid_at is not null and due<>old_debt.amount then raise exception 'Долг этой продажи уже погашен. Сумму оплаты по расчётному счёту нужно корректировать отдельно';end if;
 -- Save item history and cancel its old stock usage, retaining the ledger itself.
 update public.stock_moves set cancelled_at=coalesce(cancelled_at,now()),sale_item_id=null where sale_id=s.id and sale_item_id is not null;
 delete from public.sale_items where sale_id=s.id;
 update public.sales set gross_total=gross,discount_percent=p_discount_percent,discount_amount=discount,loyalty_points_used=points,total=edit_values.total,payment_method=p_payment_method,comment=nullif(trim(p_comment),''),
  cash_receipt_issued=coalesce(p_cash_receipt_issued,false),cash_receipt_at=case when p_cash_receipt_issued then coalesce(cash_receipt_at,now()) end,cash_receipt_by=case when p_cash_receipt_issued then coalesce(cash_receipt_by,auth.uid()) end,
  receipt_issued=case when p_payment_method='link' then case when s.payment_method='link' then s.receipt_issued end else true end,
  payment_status=case when p_payment_method='link' then case when s.payment_method='link' then s.payment_status else 'pending' end else 'paid' end,
  paid_at=case when p_payment_method='link' then case when s.payment_method='link' then s.paid_at end else coalesce(s.paid_at,now()) end,edit_version=edit_version+1 where id=s.id;
 for it in select * from jsonb_array_elements(p_items) loop
  select * into c from public.sales_catalog where id=(it->>'catalog_id')::bigint;
  select * into old_it from jsonb_populate_recordset(null::public.sale_items,before->'items') where id=(it->>'id')::bigint;
  qty:=(it->>'quantity')::numeric;price:=(it->>'unit_price')::numeric;
  insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total,variant_material_id)
  values(s.id,c.id,coalesce(c.item_type,old_it.item_type),coalesce(c.name,old_it.item_name),qty,price,round(qty*price,2),case when c.id is not distinct from old_it.catalog_id then old_it.cost_price else c.cost_price end,
   round(coalesce(case when c.id is not distinct from old_it.catalog_id then old_it.cost_price else c.cost_price end,0)*qty,2),nullif(it->>'variant_material_id','')::bigint) returning id into new_id;
  perform public.stock_redo_item(new_id);
  if old_it.catalog_id is not distinct from c.id then
   select x.branch_id into route from jsonb_populate_recordset(null::public.stock_moves,before->'stock') x join public.stock_materials m on m.id=x.material_id where x.sale_item_id=old_it.id and not m.in_workshop and m.store_branch_id is null order by x.id limit 1;
   if route is not null then update public.stock_moves sm set branch_id=route from public.stock_materials m where sm.sale_item_id=new_id and sm.cancelled_at is null and m.id=sm.material_id and not m.in_workshop and m.store_branch_id is null;end if;
  end if;
 end loop;
 perform public.stock_sale_extra(s.id);
 -- Rebuild the payment split and its debt together, never leaving a partially edited sale.
 delete from public.customer_debts where sale_id=s.id;delete from public.sale_payments where sale_id=s.id;
 for pay in select * from jsonb_array_elements(p_payments) loop
  insert into public.sale_payments(sale_id,payment_method,amount) values(s.id,pay->>'method',(pay->>'amount')::numeric);
 end loop;
 if old_debt.paid_at is not null then update public.customer_debts set paid_at=old_debt.paid_at where sale_id=s.id;end if;
 if s.loyalty_customer_id is not null then
  if s.loyalty_points_used<>points then insert into public.loyalty_transactions(customer_id,transaction_type,order_amount,points,comment,available_at) values(s.loyalty_customer_id,'adjustment',after_discount,s.loyalty_points_used-points,'Изменение списания в продаже №'||s.order_number,now());end if;
  earned_delta:=round(gross*.05,2)-round(coalesce(s.gross_total,s.total+s.loyalty_points_used)*.05,2);
  if earned_delta<>0 then
   select min(t.available_at) into available from public.loyalty_transactions t where t.customer_id=s.loyalty_customer_id and t.transaction_type='purchase' and t.created_at between s.created_at-interval '1 minute' and s.created_at+interval '1 minute' and t.order_amount=s.gross_total;
   insert into public.loyalty_transactions(customer_id,transaction_type,order_amount,points,comment,available_at) values(s.loyalty_customer_id,'adjustment',gross,earned_delta,'Корректировка начисления в продаже №'||s.order_number,coalesce(available,now()+interval '24 hours'));
  end if;
 end if;
 -- Already transferred automatic reports must follow the corrected figures. Manual cells stay untouched.
 select rf.shift_id into report_shift from public.report_fills rf where rf.branch_id=s.branch_id and rf.day=(select (started_at at time zone 'Europe/Moscow')::date from public.sales_shifts where id=s.shift_id) and rf.mode='auto' order by rf.updated_at desc limit 1;
 if report_shift is not null then perform public.report_fill_shift(report_shift,'auto');end if;
 insert into iprint_private.sale_edits(sale_id,actor,kind,before_state,after_state) values(s.id,auth.uid(),'edit',before,iprint_private.snapshot(s.id));
 return jsonb_build_object('ok',true,'version',s.edit_version+1);
end $$;
create or replace function iprint_private.report_prepare(p_shift_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
<<report_values>>
declare sh public.sales_shifts;sheet public.report_sheets;branch text;d date;first_day date;last_day date;serial integer;rows jsonb;months jsonb;month jsonb;header jsonb;row_no integer;start_row integer;end_row integer;i integer;col text;data jsonb;
begin
 if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
 select * into sh from public.sales_shifts where id=p_shift_id;
 if not found then raise exception 'Смена не найдена';end if;
 if public.is_test_branch(sh.branch_id) then raise exception 'Тестовый филиал не переносится в отчёт';end if;
 perform pg_advisory_xact_lock(hashtext('iprint-report:'||sh.branch_id::text));
 select name into branch from public.sales_branches where id=sh.branch_id;
 select * into sheet from public.report_sheets where branch_id=sh.branch_id order by sort_order,id limit 1 for update;
 if not found then
  -- A generic unassigned revenue sheet is reusable only when there is exactly one real branch.
  if (select count(*) from public.sales_branches where is_active and not is_test and not is_workshop)=1 then
   select * into sheet from public.report_sheets where branch_id is null and title ~* '^выручка$' order by id limit 1 for update;
   if found then update public.report_sheets set branch_id=sh.branch_id where id=sheet.id;end if;
  end if;
  if sheet.id is null then
   insert into public.report_sheets(sort_order,title,branch_id,data,months,staff_visible) values(100+sh.branch_id,branch||' — выручка',sh.branch_id,'{"nrows":0,"ncols":19,"rows":{},"cols":{},"styles":[{"b":1,"bg":"FFFF00"},{"b":1,"bg":"BDD7EE"}],"merges":[],"heights":{}}','[]',false) returning * into sheet;
  end if;
 end if;
 d:=(sh.started_at at time zone 'Europe/Moscow')::date;serial:=d-date '1899-12-30';rows:=coalesce(sheet.data->'rows','{}');months:=coalesce(sheet.months,'[]');
 select min(k::integer) into row_no from jsonb_each(rows) item(k,v) where v->'A'->>'v'=serial::text;
 select m into month from jsonb_array_elements(months) m where m->>'m'=to_char(d,'YYYY-MM') limit 1;
 if row_no is not null and month is not null then return jsonb_build_object('sheet_id',sheet.id,'row',row_no,'ready',true);end if;
 first_day:=date_trunc('month',d)::date;last_day:=(first_day+interval '1 month - 1 day')::date;
 if row_no is not null then
  -- Repair month metadata without touching an existing day's cells.
  select min(k::integer)-1,max(k::integer)+1 into start_row,end_row from jsonb_each(rows) item(k,v) where case when v->'A'->>'v' ~ '^[0-9]+$' then (v->'A'->>'v')::integer end between first_day-date '1899-12-30' and last_day-date '1899-12-30';
 else
  if month is not null then raise exception 'В месяце отчёта отсутствует строка даты. Нужна проверка существующего листа, данные не изменены';end if;
  select coalesce(max(k::integer),-1)+2 into start_row from jsonb_each(rows) item(k,v);end_row:=start_row+(last_day-first_day)+2;
  header:='{}';i:=0;
  foreach col in array array['Дата','День недели','Смена','Выручка','Курьер','Расходы','Карта','QR','Ссылка','Перевод','Р/с','Чеков','Возвраты','Наличные в кассе','Инкассация','Прочие расходы','Ретушь','Комментарий','Зарплата'] loop i:=i+1;header:=header||jsonb_build_object(public.report_col_name(i),jsonb_build_object('s',0,'v',col));end loop;
  rows:=rows||jsonb_build_object(start_row::text,header);
  for i in 0..(last_day-first_day) loop
   rows:=rows||jsonb_build_object((start_row+i+1)::text,jsonb_build_object('A',jsonb_build_object('v',first_day+i-date '1899-12-30'),'B',jsonb_build_object('v',(array['Понедельник','Вторник','Среда','Четверг','Пятница','Суббота','Воскресенье'])[extract(isodow from first_day+i)::integer])));
  end loop;
  header:=jsonb_build_object('A',jsonb_build_object('s',1,'v','Итого'));
  foreach col in array array['D','E','F','G','H','I','J','K','L','M','N','O','P','Q','S'] loop header:=header||jsonb_build_object(col,jsonb_build_object('s',1,'f','SUM('||col||(start_row+1)||':'||col||(end_row-1)||')'));end loop;
  rows:=rows||jsonb_build_object(end_row::text,header);row_no:=start_row+extract(day from d)::integer;
 end if;
 months:=months||jsonb_build_array(jsonb_build_object('m',to_char(d,'YYYY-MM'),'from',greatest(start_row,1),'to',end_row));
 data:=jsonb_set(sheet.data,'{rows}',rows);data:=jsonb_set(data,'{nrows}',to_jsonb(greatest(coalesce((sheet.data->>'nrows')::integer,0),end_row)));
 update public.report_sheets set data=report_values.data,months=report_values.months,updated_at=now() where id=sheet.id;
 return jsonb_build_object('sheet_id',sheet.id,'row',row_no,'ready',true);
end $$;
create or replace function iprint_private.create_sale(p_client_uid uuid,p_offline_at timestamptz,p_shift_id bigint,p_employee_id bigint,p_payment_method text,p_comment text,p_items jsonb,p_loyalty_customer_id uuid default null,p_loyalty_points numeric default 0,p_loyalty_name text default null,p_loyalty_phone text default null,p_loyalty_comment text default null,p_order_number bigint default null,p_discount_percent numeric default 0,p_payments jsonb default '[]',p_client_name text default null,p_cash_receipt_issued boolean default false) returns bigint language plpgsql security definer set search_path='' as $$
declare n bigint;ex boolean;
begin
 if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
 perform pg_advisory_xact_lock(hashtext('sale:'||p_client_uid::text));select exists(select 1 from public.sales where client_uid=p_client_uid) into ex;
 n:=public.sales_create_sale_v7(p_client_name,p_client_uid,p_offline_at,p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_order_number,p_discount_percent,p_payments);
 if not ex then update public.sales set cash_receipt_issued=coalesce(p_cash_receipt_issued,false),cash_receipt_at=case when p_cash_receipt_issued then now() end,cash_receipt_by=case when p_cash_receipt_issued then auth.uid() end where client_uid=p_client_uid;end if;
 return n;
end $$;
create or replace function iprint_private.pay_pickup(p_pickup_id bigint,p_shift_id bigint,p_employee_id bigint,p_payment_method text,p_comment text,p_items jsonb,p_loyalty_customer_id uuid default null,p_loyalty_points numeric default 0,p_loyalty_name text default null,p_loyalty_phone text default null,p_loyalty_comment text default null,p_discount_percent numeric default 0,p_payments jsonb default '[]',p_cash_receipt_issued boolean default false) returns bigint language plpgsql security definer set search_path='' as $$
declare n bigint;
begin
 if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
 n:=public.sales_pay_pickup(p_pickup_id,p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_discount_percent,p_payments);
 update public.sales set cash_receipt_issued=coalesce(p_cash_receipt_issued,false),cash_receipt_at=case when p_cash_receipt_issued then now() end,cash_receipt_by=case when p_cash_receipt_issued then auth.uid() end where id=(select sale_id from public.pickup_orders where id=p_pickup_id);
 return n;
end $$;
create or replace function public.iprint_workflow_info() returns jsonb language sql security invoker set search_path='' as $$select case when public.is_staff() then '{"version":1}'::jsonb else null end$$;
create or replace function public.iprint_set_cash_receipt(p_sale_id bigint,p_shift_id bigint,p_issued boolean) returns jsonb language sql security invoker set search_path='' as $$select iprint_private.set_receipt(p_sale_id,p_shift_id,p_issued)$$;
create or replace function public.iprint_get_sale(p_sale_id bigint,p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$select iprint_private.get_sale(p_sale_id,p_shift_id)$$;
create or replace function public.iprint_edit_sale(p_sale_id bigint,p_shift_id bigint,p_expected_version integer,p_items jsonb,p_discount_percent numeric,p_loyalty_points numeric,p_payment_method text,p_payments jsonb,p_comment text,p_cash_receipt_issued boolean) returns jsonb language sql security invoker set search_path='' as $$select iprint_private.edit_sale(p_sale_id,p_shift_id,p_expected_version,p_items,p_discount_percent,p_loyalty_points,p_payment_method,p_payments,p_comment,p_cash_receipt_issued)$$;
create or replace function public.iprint_report_prepare(p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$select iprint_private.report_prepare(p_shift_id)$$;
create or replace function public.iprint_create_sale(p_client_uid uuid,p_offline_at timestamptz,p_shift_id bigint,p_employee_id bigint,p_payment_method text,p_comment text,p_items jsonb,p_loyalty_customer_id uuid default null,p_loyalty_points numeric default 0,p_loyalty_name text default null,p_loyalty_phone text default null,p_loyalty_comment text default null,p_order_number bigint default null,p_discount_percent numeric default 0,p_payments jsonb default '[]',p_client_name text default null,p_cash_receipt_issued boolean default false) returns bigint language sql security invoker set search_path='' as $$select iprint_private.create_sale(p_client_uid,p_offline_at,p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_order_number,p_discount_percent,p_payments,p_client_name,p_cash_receipt_issued)$$;
create or replace function public.iprint_pay_pickup(p_pickup_id bigint,p_shift_id bigint,p_employee_id bigint,p_payment_method text,p_comment text,p_items jsonb,p_loyalty_customer_id uuid default null,p_loyalty_points numeric default 0,p_loyalty_name text default null,p_loyalty_phone text default null,p_loyalty_comment text default null,p_discount_percent numeric default 0,p_payments jsonb default '[]',p_cash_receipt_issued boolean default false) returns bigint language sql security invoker set search_path='' as $$select iprint_private.pay_pickup(p_pickup_id,p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_discount_percent,p_payments,p_cash_receipt_issued)$$;
revoke all on all functions in schema iprint_private from public,anon,authenticated;
do $$declare f record;begin
 for f in select p.oid::regprocedure sig,n.nspname ns,p.proname name from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='public' and p.proname like 'iprint_%') or(n.nspname='iprint_private' and p.proname in('set_receipt','get_sale','edit_sale','report_prepare','create_sale','pay_pickup')) loop
  execute format('revoke all on function %s from public,anon',f.sig);execute format('grant execute on function %s to authenticated',f.sig);
 end loop;
end $$;
notify pgrst,'reload schema';
