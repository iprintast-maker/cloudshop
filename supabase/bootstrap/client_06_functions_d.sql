set check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.stock_actor(p_shift_id bigint, p_person_id bigint, OUT is_admin boolean, OUT branch_id bigint, OUT person_name text)
 RETURNS record LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  is_admin:=public.is_admin();
  select s.branch_id, coalesce(pp.name,e.name) into branch_id, person_name
    from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
    join public.sales_shifts s on s.id=se.shift_id left join public.sales_people pp on pp.id=e.person_id
    where se.shift_id=p_shift_id and e.person_id=p_person_id and s.status='open' limit 1;
  if branch_id is null and not is_admin then raise exception 'Откройте смену: складские операции делает сотрудник смены или администратор'; end if;
  if is_admin and person_name is null then person_name:='Администратор'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_archive_material(p_id bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_norms set active=false where material_id in (select id from public.stock_materials where id=p_id or parent_id=p_id);
  update public.stock_materials set archived=true, is_active=false, name=name||' (удалён №'||id||')'
   where (id=p_id or parent_id=p_id) and not archived;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_cancel_operation(p_move_id bigint)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_g uuid; v_n int;
begin
  if not public.is_admin() then raise exception 'Отменить операцию может только администратор'; end if;
  select group_id into v_g from public.stock_moves where id=p_move_id and kind<>'sale' and cancelled_at is null;
  if v_g is null then raise exception 'Операция не найдена (списание по продаже меняется через выполняющий филиал)'; end if;
  update public.stock_moves set cancelled_at=now() where group_id=v_g and cancelled_at is null; get diagnostics v_n=row_count; return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_journal(p_branch_id bigint DEFAULT NULL::bigint, p_material_id bigint DEFAULT NULL::bigint, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_kind text DEFAULT NULL::text, p_limit integer DEFAULT 300)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(x order by x.created_at desc, x.id desc),'[]') from (
    select m.id, m.created_at, m.kind, m.qty, m.counted, m.price_total, m.supplier, m.comment, m.person_name, m.branch_id, m.other_branch_id,
      m.material_id, mt.name material, mt.unit, m.sale_id, s.order_number, s.branch_id sale_branch_id, i.item_name
    from public.stock_moves m join public.stock_materials mt on mt.id=m.material_id
    left join public.sales s on s.id=m.sale_id left join public.sale_items i on i.id=m.sale_item_id
    where m.cancelled_at is null and (p_branch_id is null or m.branch_id=p_branch_id) and (p_material_id is null or m.material_id=p_material_id)
      and (p_from is null or m.created_at>=p_from) and (p_to is null or m.created_at<p_to)
      and (p_kind is null or m.kind=p_kind or (p_kind='transfer' and m.kind in ('transfer_in','transfer_out')))
    order by m.created_at desc, m.id desc limit least(greatest(coalesce(p_limit,300),1),2000)
  ) x;
$function$;

CREATE OR REPLACE FUNCTION public.stock_operation(p_shift_id bigint, p_person_id bigint, p_kind text, p_branch_id bigint, p_items jsonb, p_to_branch_id bigint DEFAULT NULL::bigint, p_supplier text DEFAULT NULL::text, p_comment text DEFAULT NULL::text)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare a record; it jsonb; v_m bigint; v_q numeric; v_bal numeric; v_g uuid:=gen_random_uuid(); v_n int:=0;
begin
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if p_kind not in ('receipt','transfer','writeoff','inventory') then raise exception 'Неизвестная операция'; end if;
  if p_branch_id is null or not exists(select 1 from public.sales_branches where id=p_branch_id) then raise exception 'Выберите филиал'; end if;
  if p_kind='transfer' then
    if p_to_branch_id is null or p_to_branch_id=p_branch_id or not exists(select 1 from public.sales_branches where id=p_to_branch_id) then raise exception 'Выберите, в какой филиал передаёте'; end if;
    if not a.is_admin and a.branch_id not in (p_branch_id,p_to_branch_id) and coalesce(public.stock_workshop_id(),0) not in (p_branch_id,p_to_branch_id) then raise exception 'Перемещение должно быть с вашего филиала или на ваш филиал'; end if;
  elsif not a.is_admin and a.branch_id<>p_branch_id and p_branch_id<>coalesce(public.stock_workshop_id(),0) then raise exception 'Сотрудник смены работает только со складом своего филиала';
  end if;
  if p_kind='writeoff' and nullif(trim(coalesce(p_comment,'')),'') is null then raise exception 'Укажите причину списания'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items,'[]')) loop
    v_m:=(it->>'material_id')::bigint; v_q:=nullif(it->>'qty','')::numeric;
    if v_m is null or v_q is null then continue; end if;
    if not exists(select 1 from public.stock_materials where id=v_m) then raise exception 'Материал не найден'; end if;
    if p_kind='inventory' then
      if v_q<0 then raise exception 'Количество не может быть отрицательным'; end if;
      perform pg_advisory_xact_lock(hashtext('stock:'||v_m||':'||p_branch_id));
      select coalesce(sum(qty),0) into v_bal from public.stock_moves where material_id=v_m and branch_id=p_branch_id and cancelled_at is null;
      insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,counted,comment,person_id,person_name,shift_id)
        values(v_m,p_branch_id,v_q-v_bal,'inventory',v_g,v_q,p_comment,p_person_id,a.person_name,p_shift_id);
    else
      if v_q<=0 then raise exception 'Количество должно быть больше нуля'; end if;
      if p_kind='receipt' then
        insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,price_total,supplier,comment,person_id,person_name,shift_id)
          values(v_m,p_branch_id,v_q,'receipt',v_g,nullif(it->>'price_total','')::numeric,nullif(trim(coalesce(p_supplier,'')),''),p_comment,p_person_id,a.person_name,p_shift_id);
      elsif p_kind='writeoff' then
        insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,comment,person_id,person_name,shift_id)
          values(v_m,p_branch_id,-v_q,'writeoff',v_g,p_comment,p_person_id,a.person_name,p_shift_id);
      else
        insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,other_branch_id,comment,person_id,person_name,shift_id)
          values(v_m,p_branch_id,-v_q,'transfer_out',v_g,p_to_branch_id,p_comment,p_person_id,a.person_name,p_shift_id),
                (v_m,p_to_branch_id,v_q,'transfer_in',v_g,p_branch_id,p_comment,p_person_id,a.person_name,p_shift_id);
      end if;
    end if;
    v_n:=v_n+1;
  end loop;
  if v_n=0 then raise exception 'Добавьте хотя бы один материал с количеством'; end if;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_orders(p_branch_id bigint DEFAULT NULL::bigint, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_order_number bigint DEFAULT NULL::bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(o order by o.created_at desc),'[]') from (
    select s.id, s.order_number, s.created_at, s.branch_id, s.total, s.comment,
      (select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'name',i.item_name,'quantity',i.quantity,
          'moves',(select coalesce(jsonb_agg(jsonb_build_object('b',m.branch_id,'material',mt.name,'unit',mt.unit,'qty',-m.qty)),'[]')
                   from public.stock_moves m join public.stock_materials mt on mt.id=m.material_id where m.sale_item_id=i.id and m.kind='sale' and m.cancelled_at is null)) order by i.id),'[]')
       from public.sale_items i where i.sale_id=s.id) items
    from public.sales s
    where s.status<>'deleted' and (p_branch_id is null or s.branch_id=p_branch_id)
      and (p_order_number is null or s.order_number=p_order_number)
      and (p_order_number is not null or ((p_from is null or s.created_at>=p_from) and (p_to is null or s.created_at<p_to)))
    order by s.created_at desc limit 300
  ) o;
$function$;

CREATE OR REPLACE FUNCTION public.stock_purchase_week()
 RETURNS date LANGUAGE sql STABLE
AS $function$ select date_trunc('week',(now() at time zone 'Europe/Moscow'))::date $function$;

CREATE OR REPLACE FUNCTION public.stock_purchase_calc()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  with mb as (
    select m.id material_id, m.name, m.unit, m.purchase_code, m.min_qty, m.pack_qty, m.pack_price, b.id branch_id
    from public.stock_materials m cross join public.sales_branches b
    where m.is_active and not m.no_track and cardinality(m.var_sizes)+cardinality(m.var_colors)=0 and ((not m.in_workshop and b.is_active is not false and not b.is_test and not b.is_workshop and (m.store_branch_id is null or m.store_branch_id=b.id)) or (m.in_workshop and b.is_workshop))
  ), x as (
    select mb.*, u.*,
      coalesce((select sum(qty) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null),0) balance,
      (select min(created_at) from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null) first_at
    from mb cross join lateral (
      select coalesce(-sum(qty),0) used,
        coalesce(-sum(qty) filter (where created_at>=now()-interval '7 days'),0) w0,
        coalesce(-sum(qty) filter (where created_at>=now()-interval '14 days' and created_at<now()-interval '7 days'),0) w1,
        coalesce(-sum(qty) filter (where created_at>=now()-interval '21 days' and created_at<now()-interval '14 days'),0) w2,
        coalesce(-sum(qty) filter (where created_at<now()-interval '21 days'),0) w3
      from public.stock_moves s where s.material_id=mb.material_id and s.branch_id=mb.branch_id and s.cancelled_at is null
        and s.kind in ('sale','writeoff') and s.created_at>=now()-interval '28 days') u
  ), d as (
    select x.*, greatest(extract(epoch from now()-greatest(first_at,now()-interval '28 days'))/86400,0) days from x
  ), y as (
    select d2.*, case
      when first_at is null then 0
      when n>=3 then case when mx>2*(sm-mx)/(n-1) and sm>mx then (sm-mx)/(n-1) else sm/n end
      else greatest(used,0)*7/greatest(days,1) end week_use
    from (select d1.*, (select sum(greatest(v,0)) from unnest((array[w0,w1,w2,w3])[1:n::int]) v) sm,
                 (select max(greatest(v,0)) from unnest((array[w0,w1,w2,w3])[1:n::int]) v) mx
          from (select d.*, least(4,ceil(days/7)) n from d) d1) d2
  ), z as (
    select y.*, (first_at is not null and balance<=0 and (used>0 or min_qty>0)) urgent,
      case when first_at is null then 0 else
        greatest(week_use + case when min_qty>0 then min_qty else coalesce(pack_qty,0) end - greatest(balance,0), 0) end raw
    from y
  ), w as (
    select z.*, case when urgent then greatest(raw,coalesce(pack_qty,1)) else raw end req from z
  ), v as (
    select w.*, case when pack_qty>0 then ceil(round(req/pack_qty,6)) end packs,
      case when pack_qty>0 then ceil(round(req/pack_qty,6))*pack_qty else ceil(round(req,6)) end need
    from w
  )
  select coalesce(jsonb_agg(r order by (r->>'urgent')::boolean desc, r->>'name'),'[]') from (
    select jsonb_build_object('material_id',material_id,'name',name,'unit',unit,'code',purchase_code,'min_qty',min_qty,
      'pack_qty',pack_qty,'pack_price',pack_price,'total',sum(need),'packs',sum(packs),
      'sum',case when pack_price>0 then coalesce(sum(packs),sum(need))*pack_price end,
      'urgent',bool_or(urgent),
      'branches',jsonb_agg(jsonb_build_object('b',branch_id,'balance',balance,'week_use',round(week_use::numeric,2),'need',need,'packs',packs,'urgent',urgent) order by branch_id)) r
    from v group by material_id,name,unit,purchase_code,min_qty,pack_qty,pack_price having sum(need)>0
  ) q;
$function$;

CREATE OR REPLACE FUNCTION public.stock_purchase_build()
 RETURNS date LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_w date:=public.stock_purchase_week();
begin
  insert into public.stock_purchase_lists(week_start,created_at,rows) values(v_w,now(),public.stock_purchase_calc())
  on conflict (week_start) do update set created_at=excluded.created_at, rows=excluded.rows;
  return v_w;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_purchase_get(p_week date DEFAULT NULL::date, p_rebuild boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_w date:=coalesce(p_week,public.stock_purchase_week()); r record;
begin
  if p_rebuild then
    if not public.is_admin() then raise exception 'Пересчитать может только администратор'; end if;
    v_w:=public.stock_purchase_build();
  elsif v_w=public.stock_purchase_week() and not exists(select 1 from public.stock_purchase_lists where week_start=v_w) then
    perform public.stock_purchase_build();
  end if;
  select * into r from public.stock_purchase_lists where week_start=v_w;
  return jsonb_build_object('week',v_w,'created_at',r.created_at,'rows',coalesce(r.rows,'[]'::jsonb),
    'weeks',(select coalesce(jsonb_agg(week_start order by week_start desc),'[]') from (select week_start from public.stock_purchase_lists order by week_start desc limit 30) w));
end $function$;

CREATE OR REPLACE FUNCTION public.stock_purchase_hide_set(p_material_id bigint, p_hidden boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Закупку отмечает администратор'; end if;
  insert into public.stock_purchase_hide(material_id,hidden,at) values(p_material_id,coalesce(p_hidden,true),now())
  on conflict (material_id) do update set hidden=excluded.hidden, at=excluded.at;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_purchase_live()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  with c as (select x from jsonb_array_elements(public.stock_purchase_calc()) x),
  h as (select material_id from public.stock_purchase_hide where hidden)
  select jsonb_build_object('at',now(),
    'rows',(select coalesce(jsonb_agg(x),'[]') from c where (x->>'material_id')::bigint not in (select material_id from h)),
    'hidden',(select coalesce(jsonb_agg(x),'[]') from c where (x->>'material_id')::bigint in (select material_id from h)),
    'requests',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'branch_id',r.branch_id,'person_name',r.person_name,'catalog_id',r.catalog_id,
        'material_id',r.material_id,'name',r.name,'qty',r.qty,'comment',r.comment,'status',r.status,'created_at',r.created_at,
        'unit',m.unit,'code',m.purchase_code) order by r.created_at),'[]')
      from public.stock_requests r left join public.stock_materials m on m.id=r.material_id where r.status in ('open','unavailable')));
$function$;

CREATE OR REPLACE FUNCTION public.stock_workshop_id()
 RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select id from public.sales_branches where is_workshop order by id limit 1
$function$;

CREATE OR REPLACE FUNCTION public.stock_redo_item(p_item_id bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare it record; v_branch bigint;
begin
  select branch_id into v_branch from public.stock_moves where sale_item_id=p_item_id and kind='sale' and cancelled_at is null and branch_id<>coalesce(public.stock_workshop_id(),0) and material_id not in (select id from public.stock_materials where store_branch_id is not null) order by id limit 1;
  update public.stock_moves set cancelled_at=now() where sale_item_id=p_item_id and kind='sale' and cancelled_at is null;
  select i.*, s.branch_id sale_branch, s.status sale_status, s.created_at sale_at into it
    from public.sale_items i join public.sales s on s.id=i.sale_id where i.id=p_item_id;
  if not found or it.sale_status='deleted' or it.catalog_id is null or public.is_test_branch(coalesce(v_branch,it.sale_branch)) or public.is_test_branch(it.sale_branch) then return; end if;
  insert into public.stock_moves(material_id,branch_id,qty,kind,sale_id,sale_item_id,created_at)
  select n.material_id, case when m.in_workshop then public.stock_workshop_id() when m.store_branch_id is not null then m.store_branch_id else coalesce(v_branch,it.sale_branch) end, -(case when n.per_line then n.qty else n.qty*it.quantity end), 'sale', it.sale_id, it.id, coalesce(it.sale_at,now())
  from public.stock_norms n join public.stock_materials m on m.id=n.material_id where n.catalog_id=it.catalog_id and n.active and not m.no_track and cardinality(m.var_sizes)+cardinality(m.var_colors)=0 and coalesce(it.quantity,0)<>0;
  insert into public.stock_moves(material_id,branch_id,qty,kind,sale_id,sale_item_id,created_at)
  select m.id, case when m.in_workshop then public.stock_workshop_id() when m.store_branch_id is not null then m.store_branch_id else coalesce(v_branch,it.sale_branch) end, -it.quantity*coalesce((select n.qty from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=it.catalog_id and n.active limit 1),1), 'sale', it.sale_id, it.id, coalesce(it.sale_at,now())
  from public.stock_materials m where m.id=it.variant_material_id and coalesce(it.quantity,0)<>0;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_request_add(p_shift_id bigint, p_person_id bigint, p_branch_id bigint, p_name text, p_qty numeric, p_catalog_id bigint DEFAULT NULL::bigint, p_material_id bigint DEFAULT NULL::bigint, p_comment text DEFAULT NULL::text)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare a record; v_b bigint:=p_branch_id; v_id bigint;
begin
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Напишите, что нужно купить'; end if;
  if not a.is_admin then
    if v_b is null or (v_b<>a.branch_id and v_b is distinct from public.stock_workshop_id()) then v_b:=a.branch_id; end if;
  end if;
  insert into public.stock_requests(branch_id,person_name,catalog_id,material_id,name,qty,comment)
  values(v_b,a.person_name,p_catalog_id,p_material_id,trim(p_name),nullif(p_qty,0),nullif(trim(coalesce(p_comment,'')),''))
  returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_request_set(p_id bigint, p_status text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Закупку отмечает администратор'; end if;
  if p_status not in ('open','bought','unavailable') then raise exception 'Неизвестный статус'; end if;
  update public.stock_requests set status=p_status, closed_at=case when p_status='open' then null else now() end where id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_sale_extra(p_sale_id bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare s record;
begin
  select * into s from public.sales where id=p_sale_id;
  if not found or s.status is not distinct from 'dele'||'ted' or public.is_test_branch(s.branch_id) then return; end if;
  insert into public.stock_moves(material_id,branch_id,qty,kind,sale_id,created_at)
  select m.id, case when m.in_workshop then public.stock_workshop_id() when m.store_branch_id is not null then m.store_branch_id else s.branch_id end, -m.per_sale_qty, 'sale', s.id, coalesce(s.created_at,now())
  from public.stock_materials m
  where m.is_active and not m.no_track and m.per_sale_qty>0
    and not exists(select 1 from public.stock_moves x where x.sale_id=s.id and x.sale_item_id is null and x.material_id=m.id and x.kind='sale' and x.cancelled_at is null);
end $function$;

CREATE OR REPLACE FUNCTION public.stock_save_material(p_id bigint, p_name text, p_unit text, p_min_qty numeric, p_comment text, p_is_active boolean, p_norms jsonb)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id bigint;
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Укажите название материала'; end if;
  if p_id is null then
    insert into public.stock_materials(name,unit,min_qty,comment,is_active)
      values(trim(p_name),coalesce(nullif(trim(p_unit),''),'шт'),coalesce(p_min_qty,0),nullif(trim(coalesce(p_comment,'')),''),coalesce(p_is_active,true)) returning id into v_id;
  else
    update public.stock_materials set name=trim(p_name),unit=coalesce(nullif(trim(p_unit),''),'шт'),min_qty=coalesce(p_min_qty,0),
      comment=nullif(trim(coalesce(p_comment,'')),''),is_active=coalesce(p_is_active,true) where id=p_id returning id into v_id;
    if v_id is null then raise exception 'Материал не найден'; end if;
  end if;
  if p_norms is not null then
    update public.stock_norms set active=false where material_id=v_id and active;
    insert into public.stock_norms(catalog_id,material_id,qty,active,per_line)
      select distinct on ((x->>'catalog_id')::bigint) (x->>'catalog_id')::bigint, v_id, (x->>'qty')::numeric, true, coalesce((x->>'per_line')::boolean,false)
      from jsonb_array_elements(p_norms) x where nullif(x->>'qty','')::numeric>0
    on conflict (catalog_id,material_id) do update set qty=excluded.qty, active=true, per_line=excluded.per_line;
  end if;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_in_workshop(p_id bigint, p_on boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set in_workshop=coalesce(p_on,false) where id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_material_extra(p_id bigint, p_pack_qty numeric, p_pack_price numeric, p_per_sale_qty numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set pack_qty=nullif(greatest(coalesce(p_pack_qty,0),0),0), pack_price=nullif(greatest(coalesce(p_pack_price,0),0),0),
    per_sale_qty=greatest(coalesce(p_per_sale_qty,0),0) where id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_no_track(p_id bigint, p_on boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set no_track=coalesce(p_on,false) where id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_producer(p_shift_id bigint, p_person_id bigint, p_branch_id bigint, p_sale_id bigint DEFAULT NULL::bigint, p_sale_item_id bigint DEFAULT NULL::bigint)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare a record; v_n int;
begin
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if not exists(select 1 from public.sales_branches where id=p_branch_id) then raise exception 'Выберите филиал'; end if;
  if p_sale_item_id is null and p_sale_id is null then raise exception 'Не указан заказ'; end if;
  update public.stock_moves set branch_id=p_branch_id, person_id=p_person_id, person_name=a.person_name
   where kind='sale' and cancelled_at is null and branch_id<>coalesce(public.stock_workshop_id(),0) and ((p_sale_item_id is not null and sale_item_id=p_sale_item_id) or (p_sale_item_id is null and sale_id=p_sale_id));
  get diagnostics v_n=row_count; return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_producer_by_number(p_shift_id bigint, p_person_id bigint, p_sale_branch_id bigint, p_order_number bigint, p_branch_id bigint)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_sale bigint;
begin
  select id into v_sale from public.sales where branch_id=p_sale_branch_id and order_number=p_order_number and status<>'deleted' order by id desc limit 1;
  if v_sale is null then return -1; end if;
  return public.stock_set_producer(p_shift_id,p_person_id,p_branch_id,v_sale,null);
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_purchase_code(p_id bigint, p_code text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set purchase_code=nullif(trim(coalesce(p_code,'')),'') where id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_store_branch(p_id bigint, p_branch_id bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set store_branch_id=p_branch_id, in_workshop=case when p_branch_id is not null then false else in_workshop end
   where id=p_id or parent_id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_variant(p_id bigint, p_catalog_id bigint)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  update public.stock_materials set variant_catalog_id=p_catalog_id where id=p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_set_variants(p_id bigint, p_sizes text[], p_colors text[])
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare p record; v_s text[]; v_c text[]; s text; c text; v_name text; v_child bigint; v_keep bigint[]:='{}';
begin
  if not public.is_admin() then raise exception 'Материалы настраивает администратор'; end if;
  select coalesce(array_agg(x order by o),'{}') into v_s from (select distinct on (trim(x)) trim(x) x, o from unnest(coalesce(p_sizes,'{}')) with ordinality u(x,o) where trim(x)<>'' order by trim(x),o) q;
  select coalesce(array_agg(x order by o),'{}') into v_c from (select distinct on (trim(x)) trim(x) x, o from unnest(coalesce(p_colors,'{}')) with ordinality u(x,o) where trim(x)<>'' order by trim(x),o) q;
  update public.stock_materials set var_sizes=v_s, var_colors=v_c, variant_catalog_id=case when cardinality(v_s)+cardinality(v_c)>0 then null else variant_catalog_id end where id=p_id;
  select * into p from public.stock_materials where id=p_id;
  if cardinality(v_s)+cardinality(v_c)>0 then
    foreach c in array (case when cardinality(v_c)>0 then v_c else array[null::text] end) loop
      foreach s in array (case when cardinality(v_s)>0 then v_s else array[null::text] end) loop
        v_name:=trim(p.name||coalesce(' '||c,'')||coalesce(' '||s,''));
        select id into v_child from public.stock_materials where parent_id=p_id and var_size is not distinct from s and var_color is not distinct from c order by id limit 1;
        if v_child is null then
          select id into v_child from public.stock_materials where name=v_name and id<>p_id and (parent_id is null or parent_id=p_id) order by id limit 1;
        end if;
        if v_child is null then
          insert into public.stock_materials(name,unit,min_qty,is_active) values(v_name,p.unit,p.min_qty,true) returning id into v_child;
        end if;
        update public.stock_materials set parent_id=p_id, var_size=s, var_color=c, name=v_name, unit=p.unit, min_qty=p.min_qty, is_active=p.is_active,
          in_workshop=p.in_workshop, store_branch_id=p.store_branch_id, no_track=p.no_track, pack_qty=p.pack_qty, pack_price=p.pack_price, purchase_code=p.purchase_code,
          variant_catalog_id=null, var_sizes='{}', var_colors='{}'
        where id=v_child;
        v_keep:=v_keep||v_child;
      end loop;
    end loop;
  end if;
  update public.stock_materials set is_active=false where parent_id=p_id and not (id=any(v_keep));
end $function$;

CREATE OR REPLACE FUNCTION public.stock_state(p_days integer DEFAULT 30)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select jsonb_build_object('workshop',(select jsonb_build_object('id',id,'name',name) from public.sales_branches where is_workshop order by id limit 1),
    'materials',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'unit',m.unit,'min_qty',m.min_qty,'comment',m.comment,'purchase_code',m.purchase_code,'in_workshop',m.in_workshop,'store_branch_id',m.store_branch_id,'archived',m.archived,'pack_qty',m.pack_qty,'pack_price',m.pack_price,'per_sale_qty',m.per_sale_qty,'is_active',m.is_active,'no_track',m.no_track,'parent_id',m.parent_id,'var_size',m.var_size,'var_color',m.var_color,'var_sizes',m.var_sizes,'var_colors',m.var_colors,'variant_catalog_id',m.variant_catalog_id,
        'norms',(select coalesce(jsonb_agg(jsonb_build_object('catalog_id',n.catalog_id,'qty',n.qty,'per_line',n.per_line,'name',c.name) order by c.name),'[]')
                 from public.stock_norms n join public.sales_catalog c on c.id=n.catalog_id where n.material_id=m.id and n.active)) order by m.name),'[]') from public.stock_materials m),
    'balances',(select coalesce(jsonb_agg(jsonb_build_object('m',material_id,'b',branch_id,'q',q)),'[]')
                from (select material_id,branch_id,sum(qty) q from public.stock_moves where cancelled_at is null group by 1,2) x),
    'usage',(select coalesce(jsonb_agg(jsonb_build_object('m',material_id,'b',branch_id,'q',q)),'[]')
             from (select material_id,branch_id,-sum(qty) q from public.stock_moves where cancelled_at is null and kind in ('sale','writeoff') and created_at>=now()-make_interval(days=>greatest(p_days,1)) group by 1,2) x)
  );
$function$;

CREATE OR REPLACE FUNCTION public.stock_trg_sale()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r record;
begin
  begin
    if new.status='deleted' and old.status is distinct from 'deleted' then
      update public.stock_moves set cancelled_at=now() where sale_id=new.id and kind='sale' and cancelled_at is null;
    elsif old.status='deleted' and new.status<>'deleted' then
      for r in select id from public.sale_items where sale_id=new.id loop perform public.stock_redo_item(r.id); end loop; perform public.stock_sale_extra(new.id);
    elsif new.created_at is distinct from old.created_at then
      update public.stock_moves set created_at=new.created_at where sale_id=new.id and kind='sale' and cancelled_at is null;
    end if;
  exception when others then raise warning 'stock: %', sqlerrm; end;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.stock_trg_sale_item()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.stock_redo_item(new.id); perform public.stock_sale_extra(new.sale_id);
  exception when others then raise warning 'stock: %', sqlerrm; end;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.submit_test_attempt(p_test_id bigint, p_trainee_name text, p_score_percent numeric, p_extra_training_hours numeric, p_answers jsonb)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare v_id bigint;
begin
  if not public.is_staff() then raise exception 'Нет доступа: войдите в аккаунт сотрудника'; end if;
  if coalesce(trim(p_trainee_name),'') = '' then raise exception 'Введите ФИО'; end if;
  insert into public.test_attempts(test_id, trainee_name, score_percent, extra_training_hours)
  values (p_test_id, trim(p_trainee_name), p_score_percent, p_extra_training_hours)
  returning id into v_id;
  insert into public.test_answers(attempt_id, question_id, trainee_answer, is_correct)
  select v_id, (x->>'question_id')::bigint, x->>'trainee_answer', (x->>'is_correct')::boolean
  from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) x;
  return v_id;
end;
$function$;