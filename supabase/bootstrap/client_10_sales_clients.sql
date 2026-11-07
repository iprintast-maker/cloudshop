create table if not exists public.sales_clients(
  id bigserial primary key,
  name text not null,
  name_key text not null unique,
  created_at timestamptz not null default now()
);
alter table public.sales_clients enable row level security;
alter table public.sales add column if not exists client_id bigint references public.sales_clients(id);
create index if not exists sales_client_id_idx on public.sales(client_id);

create or replace function public.client_name_key(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(replace(lower(trim(coalesce(p,''))),'ё','е'),'\s+',' ','g'),'')
$$;

create or replace function public.client_get_or_create(p_name text) returns bigint
language plpgsql security definer set search_path=public as $$
declare v_key text:=public.client_name_key(p_name); v_id bigint;
begin
  if v_key is null then return null; end if;
  select id into v_id from public.sales_clients where name_key=v_key;
  if found then return v_id; end if;
  insert into public.sales_clients(name,name_key) values(regexp_replace(trim(p_name),'\s+',' ','g'),v_key)
    on conflict(name_key) do update set name_key=excluded.name_key returning id into v_id;
  return v_id;
end $$;

-- Продажа с клубной картой без имени клиента → клиент берётся из карты
create or replace function public.sales_client_from_card() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.client_id is null and new.loyalty_customer_id is not null then
    new.client_id:=public.client_get_or_create((select name from public.loyalty_customers where id=new.loyalty_customer_id));
  end if;
  return new;
end $$;
create or replace trigger sales_client_from_card before insert or update of loyalty_customer_id on public.sales
  for each row execute function public.sales_client_from_card();

create or replace function public.sales_create_sale_v7(p_client_name text, p_client_uid uuid, p_offline_at timestamptz, p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid default null, p_loyalty_points numeric default 0, p_loyalty_name text default null, p_loyalty_phone text default null, p_loyalty_comment text default null, p_order_number bigint default null, p_discount_percent numeric default 0, p_payments jsonb default '[]'::jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare v_order bigint; v_client bigint;
begin
  v_order:=public.sales_create_sale_v6(p_client_uid,p_offline_at,p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_order_number,p_discount_percent,p_payments);
  v_client:=public.client_get_or_create(p_client_name);
  if v_client is not null then update public.sales set client_id=v_client where client_uid=p_client_uid; end if;
  return v_order;
end $$;

-- Для оплаты заказа «при получении»: привязать клиента к уже созданной продаже смены
create or replace function public.sales_attach_client(p_shift_id bigint, p_order_number bigint, p_name text) returns boolean
language plpgsql security definer set search_path=public as $$
declare v_client bigint:=public.client_get_or_create(p_name);
begin
  if v_client is null then return false; end if;
  update public.sales set client_id=v_client where shift_id=p_shift_id and order_number=p_order_number;
  return found;
end $$;

create or replace function public.clients_list(p_q text default null) returns table(id bigint,name text,orders bigint,total numeric,last_at timestamptz)
language sql stable security definer set search_path=public as $$
  select c.id,c.name,
    count(s.id) filter (where s.status is distinct from 'returned' and s.cancelled_at is null),
    coalesce(sum(s.total) filter (where s.status is distinct from 'returned' and s.cancelled_at is null),0),
    max(s.created_at)
  from public.sales_clients c left join public.sales s on s.client_id=c.id
  where p_q is null or public.client_name_key(c.name) like '%'||public.client_name_key(p_q)||'%'
  group by c.id,c.name
  having count(s.id)>0
  order by max(s.created_at) desc nulls last
  limit 500
$$;

create or replace function public.client_history(p_client_id bigint) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc),'[]'::jsonb) from (
    select jsonb_build_object('id',s.id,'order_number',s.order_number,'created_at',s.created_at,'total',s.total,
      'status',case when s.cancelled_at is not null then 'cancelled' else s.status end,
      'payment_method',s.payment_method,'branch',b.name,'employee',p.name,'comment',s.comment,
      'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.item_name,'qty',i.quantity,'price',i.unit_price,'sum',i.line_total) order by i.id),'[]'::jsonb) from public.sale_items i where i.sale_id=s.id)) x
    from public.sales s left join public.sales_branches b on b.id=s.branch_id left join public.sales_people p on p.id=s.employee_id
    where s.client_id=p_client_id) t
$$;

create or replace function public.clients_rename(p_client_id bigint, p_name text) returns bigint
language plpgsql security definer set search_path=public as $$
declare v_key text:=public.client_name_key(p_name); v_other bigint;
begin
  if not public.is_admin() then raise exception 'Изменять клиентов может только администратор'; end if;
  if v_key is null then raise exception 'Пустое имя'; end if;
  select id into v_other from public.sales_clients where name_key=v_key and id<>p_client_id;
  if found then
    update public.sales set client_id=v_other where client_id=p_client_id;
    update public.sales_clients set name_key='merged:'||id, name=name||' (объединён)' where id=p_client_id;
    return v_other;
  end if;
  update public.sales_clients set name=regexp_replace(trim(p_name),'\s+',' ','g'), name_key=v_key where id=p_client_id;
  return p_client_id;
end $$;

create or replace function public.sales_detach_client(p_sale_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Только администратор'; end if;
  update public.sales set client_id=null where id=p_sale_id;
end $$;

revoke all on function public.sales_create_sale_v7(text,uuid,timestamptz,bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb) from public, anon;
revoke all on function public.sales_attach_client(bigint,bigint,text) from public, anon;
revoke all on function public.clients_list(text) from public, anon;
revoke all on function public.client_history(bigint) from public, anon;
revoke all on function public.clients_rename(bigint,text) from public, anon;
revoke all on function public.sales_detach_client(bigint) from public, anon;
revoke all on function public.client_get_or_create(text) from public, anon, authenticated;
grant execute on function public.sales_create_sale_v7(text,uuid,timestamptz,bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb) to authenticated;
grant execute on function public.sales_attach_client(bigint,bigint,text) to authenticated;
grant execute on function public.clients_list(text) to authenticated;
grant execute on function public.client_history(bigint) to authenticated;
grant execute on function public.clients_rename(bigint,text) to authenticated;
grant execute on function public.sales_detach_client(bigint) to authenticated;

-- Уже существующие продажи по клубным картам
update public.sales s set client_id=public.client_get_or_create(l.name) from public.loyalty_customers l where l.id=s.loyalty_customer_id and s.client_id is null;