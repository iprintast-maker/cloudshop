alter table public.sales_catalog add column if not exists unit text not null default 'pcs';
alter table public.sales_catalog add constraint sales_catalog_unit_chk check (unit in ('pcs','m'));