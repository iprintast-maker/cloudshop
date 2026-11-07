create or replace function public.pickup_update_items(p_pickup_id bigint, p_items jsonb, p_discount_percent numeric default 0, p_comment text default null)
returns bigint language plpgsql security definer set search_path=public as $$
declare v_o public.pickup_orders%rowtype; v_item jsonb; v_cat public.sales_catalog%rowtype; v_qty numeric(12,3); v_price numeric(12,2); v_line numeric(12,2); v_gross numeric(12,2):=0; v_items jsonb:='[]'::jsonb;
begin
  select * into v_o from public.pickup_orders where id=p_pickup_id and status='pending' for update;
  if not found then raise exception 'Заказ не найден или уже закрыт'; end if;
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
  update public.pickup_orders set items=v_items,gross_total=v_gross,discount_percent=coalesce(p_discount_percent,0),
    total=round(v_gross-round(v_gross*coalesce(p_discount_percent,0)/100,2),2),comment=nullif(trim(coalesce(p_comment,'')),'')
  where id=p_pickup_id;
  return v_o.order_number;
end $$;

create or replace function public.estimate_update(p_id bigint, p_items jsonb, p_discount_percent numeric default 0, p_comment text default null, p_client_name text default null)
returns bigint language plpgsql security definer set search_path=public as $$
declare v_items jsonb:='[]'::jsonb; v_item jsonb; v_cat record; v_qty numeric; v_price numeric; v_gross numeric:=0;
begin
  perform 1 from public.sales_estimates where id=p_id and status='open' for update;
  if not found then raise exception 'Расчёт не найден или уже закрыт'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_cat from public.sales_catalog where id=(v_item->>'catalog_id')::bigint;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_cat.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_gross:=v_gross+round(v_qty*v_price,2);
    v_items:=v_items||jsonb_build_array(v_item||jsonb_build_object('name',v_cat.name,'unit',v_cat.unit,'line_total',round(v_qty*v_price,2)));
  end loop;
  update public.sales_estimates set items=v_items,discount_percent=coalesce(p_discount_percent,0),comment=nullif(trim(coalesce(p_comment,'')),''),
    total=round(v_gross-round(v_gross*coalesce(p_discount_percent,0)/100,2),2),
    client_name=coalesce(nullif(trim(coalesce(p_client_name,'')),''),client_name),
    client_id=coalesce(public.client_get_or_create(p_client_name),client_id)
  where id=p_id;
  return p_id;
end $$;

revoke all on function public.pickup_update_items(bigint,jsonb,numeric,text) from public, anon;
revoke all on function public.estimate_update(bigint,jsonb,numeric,text,text) from public, anon;
grant execute on function public.pickup_update_items(bigint,jsonb,numeric,text) to authenticated;
grant execute on function public.estimate_update(bigint,jsonb,numeric,text,text) to authenticated;