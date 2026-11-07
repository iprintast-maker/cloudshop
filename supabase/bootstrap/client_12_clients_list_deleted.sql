create or replace function public.clients_list(p_q text default null) returns table(id bigint,name text,orders bigint,total numeric,last_at timestamptz)
language sql stable security definer set search_path=public as $$
  select c.id,c.name,
    count(s.id) filter (where coalesce(s.status,'completed') not in ('returned','deleted') and s.cancelled_at is null),
    coalesce(sum(s.total) filter (where coalesce(s.status,'completed') not in ('returned','deleted') and s.cancelled_at is null),0),
    max(s.created_at)
  from public.sales_clients c join public.sales s on s.client_id=c.id
  where p_q is null or public.client_name_key(c.name) like '%'||public.client_name_key(p_q)||'%'
  group by c.id,c.name
  order by max(s.created_at) desc nulls last
  limit 500
$$;