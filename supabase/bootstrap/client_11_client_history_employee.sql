create or replace function public.client_history(p_client_id bigint) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc),'[]'::jsonb) from (
    select jsonb_build_object('id',s.id,'order_number',s.order_number,'created_at',s.created_at,'total',s.total,
      'status',case when s.cancelled_at is not null then 'cancelled' else s.status end,
      'payment_method',s.payment_method,'branch',b.name,'employee',e.name,'comment',s.comment,
      'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.item_name,'qty',i.quantity,'price',i.unit_price,'sum',i.line_total) order by i.id),'[]'::jsonb) from public.sale_items i where i.sale_id=s.id)) x
    from public.sales s left join public.sales_branches b on b.id=s.branch_id left join public.sales_employees e on e.id=s.employee_id
    where s.client_id=p_client_id) t
$$;