create table if not exists public.sales_estimates(
  id bigserial primary key,
  branch_id bigint references public.sales_branches(id),
  shift_id bigint references public.sales_shifts(id),
  employee_id bigint references public.sales_employees(id),
  client_id bigint references public.sales_clients(id),
  client_name text,
  loyalty_customer_id uuid references public.loyalty_customers(id) on delete set null,
  items jsonb not null,
  discount_percent numeric not null default 0,
  comment text,
  total numeric(12,2) not null default 0,
  status text not null default 'open' check (status in ('open','paid','cancelled')),
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  paid_order_number bigint,
  cancelled_at timestamptz
);
alter table public.sales_estimates enable row level security;

create or replace function public.estimate_save(p_shift_id bigint, p_employee_id bigint, p_items jsonb, p_discount_percent numeric default 0, p_comment text default null, p_client_name text default null, p_loyalty_customer_id uuid default null)
returns bigint language plpgsql security definer set search_path=public as $$
declare v_shift record; v_items jsonb:='[]'::jsonb; v_item jsonb; v_cat record; v_qty numeric; v_price numeric; v_gross numeric:=0; v_id bigint; v_total numeric;
begin
  select * into v_shift from public.sales_shifts where id=p_shift_id and status='open';
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_cat from public.sales_catalog where id=(v_item->>'catalog_id')::bigint;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_cat.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_gross:=v_gross+round(v_qty*v_price,2);
    v_items:=v_items||jsonb_build_array(v_item||jsonb_build_object('name',v_cat.name,'unit',v_cat.unit,'line_total',round(v_qty*v_price,2)));
  end loop;
  v_total:=round(v_gross-round(v_gross*coalesce(p_discount_percent,0)/100,2),2);
  insert into public.sales_estimates(branch_id,shift_id,employee_id,client_id,client_name,loyalty_customer_id,items,discount_percent,comment,total)
  values(v_shift.branch_id,p_shift_id,p_employee_id,public.client_get_or_create(p_client_name),nullif(trim(coalesce(p_client_name,'')),''),p_loyalty_customer_id,v_items,coalesce(p_discount_percent,0),nullif(trim(coalesce(p_comment,'')),''),v_total)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.estimates_list(p_status text default 'open') returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'branch_id',e.branch_id,'branch',b.name,'employee',em.name,'client_name',e.client_name,'loyalty_customer_id',e.loyalty_customer_id,
    'items',e.items,'discount_percent',e.discount_percent,'comment',e.comment,'total',e.total,'status',e.status,'created_at',e.created_at,'paid_at',e.paid_at,'paid_order_number',e.paid_order_number) order by e.created_at desc),'[]'::jsonb)
  from public.sales_estimates e left join public.sales_branches b on b.id=e.branch_id left join public.sales_employees em on em.id=e.employee_id
  where e.status=coalesce(p_status,'open') and (e.status='open' or e.created_at>now()-interval '60 days')
$$;

create or replace function public.estimate_mark_paid(p_id bigint, p_order_number bigint) returns void
language plpgsql security definer set search_path=public as $$
begin update public.sales_estimates set status='paid', paid_at=now(), paid_order_number=p_order_number where id=p_id and status='open'; end $$;

create or replace function public.estimate_cancel(p_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin update public.sales_estimates set status='cancelled', cancelled_at=now() where id=p_id and status='open'; end $$;

revoke all on function public.estimate_save(bigint,bigint,jsonb,numeric,text,text,uuid) from public, anon;
revoke all on function public.estimates_list(text) from public, anon;
revoke all on function public.estimate_mark_paid(bigint,bigint) from public, anon;
revoke all on function public.estimate_cancel(bigint) from public, anon;
grant execute on function public.estimate_save(bigint,bigint,jsonb,numeric,text,text,uuid) to authenticated;
grant execute on function public.estimates_list(text) to authenticated;
grant execute on function public.estimate_mark_paid(bigint,bigint) to authenticated;
grant execute on function public.estimate_cancel(bigint) to authenticated;