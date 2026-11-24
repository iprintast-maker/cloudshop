-- Preserve existing field addresses: S is displayed before P by the report UI.
create table if not exists iprint_private.report_cash_total_backup (
 sheet_id bigint primary key, original_sheet jsonb not null, saved_at timestamptz not null default now()
);
alter table iprint_private.report_cash_total_backup enable row level security;
revoke all on iprint_private.report_cash_total_backup from public,anon,authenticated;
insert into iprint_private.report_cash_total_backup(sheet_id,original_sheet)
 select id,to_jsonb(s) from public.report_sheets s where branch_id is not null and data->>'iprint_layout' in ('2','3') on conflict do nothing;
create or replace function iprint_private.report_cash_difference() returns trigger language plpgsql security invoker set search_path='' as $$
declare r record;m jsonb;cells jsonb;rows jsonb;dates jsonb:='{}';prev text;opening numeric;expected numeric;cash numeric;expense numeric;collection numeric;total numeric;f text;col text;
begin
 if new.branch_id is null or coalesce(new.data->>'iprint_layout','') not in ('2','3','4') then return new;end if;
 rows:=coalesce(new.data->'rows','{}');
 for r in select * from jsonb_each(rows) loop
  if coalesce(r.value->'A'->>'v','') ~ '^[0-9]+$' then dates:=dates||jsonb_build_object(r.value->'A'->>'v',r.key);end if;
 end loop;
 for r in select * from jsonb_each(rows) loop
  if coalesce(r.value->'A'->>'v','') !~ '^[0-9]+$' then continue;end if;
  cells:=r.value;prev:=dates->>((cells->'A'->>'v')::int-1)::text;
  opening:=case when prev is null then 0 when jsonb_typeof(rows->prev->'P'->'v')='number' then (rows->prev->'P'->>'v')::numeric else null end;
  cash:=case when jsonb_typeof(cells->'E'->'v')='number' then (cells->'E'->>'v')::numeric else 0 end;
  expense:=case when jsonb_typeof(cells->'M'->'v')='number' then (cells->'M'->>'v')::numeric else 0 end;
  collection:=case when jsonb_typeof(cells->'O'->'v')='number' then (cells->'O'->>'v')::numeric else 0 end;
  expected:=opening+cash-expense-collection;
  f:=case when prev is null then 'E'||r.key||'-M'||r.key||'-O'||r.key else 'IF(P'||prev||'="","",P'||prev||'+E'||r.key||'-M'||r.key||'-O'||r.key||')' end;
  cells:=jsonb_set(cells,'{S}',jsonb_strip_nulls(jsonb_build_object('f',f,'v',expected)));
  f:='IF(P'||r.key||'="","",IF(S'||r.key||'="","",S'||r.key||'-P'||r.key||'))';
  cells:=jsonb_set(cells,'{Q}',jsonb_strip_nulls(jsonb_build_object('f',f,'v',case when jsonb_typeof(cells->'P'->'v')='number' then expected-(cells->'P'->>'v')::numeric else null end)));
  rows:=jsonb_set(rows,array[r.key],cells);
 end loop;
 for m in select * from jsonb_array_elements(coalesce(new.months,'[]')) loop
  cells:=coalesce(rows->(m->>'from'),'{}')||jsonb_build_object('S',jsonb_build_object('s',0,'v','Итого в кассе'),'Q',jsonb_build_object('s',0,'v','Расхождения'),'R',jsonb_build_object('s',0,'v','Комментарий'));
  rows:=jsonb_set(rows,array[m->>'from'],cells);
  -- Cash balances are snapshots, not an additive monthly revenue.
  cells:=coalesce(rows->(m->>'to'),'{}')-'S';
  select coalesce(sum((v->'Q'->>'v')::numeric),0) into total from jsonb_each(rows)t(k,v) where k::int between (m->>'from')::int+1 and (m->>'to')::int-1 and jsonb_typeof(v->'Q'->'v')='number';
  cells:=cells||jsonb_build_object('Q',jsonb_build_object('s',1,'f','SUM(Q'||((m->>'from')::int+1)||':Q'||((m->>'to')::int-1)||')','v',total));
  rows:=jsonb_set(rows,array[m->>'to'],cells);
 end loop;
 new.data:=new.data||jsonb_build_object('rows',rows,'ncols',19,'iprint_layout',4,'cols',coalesce(new.data->'cols','{}')||jsonb_build_object('S',20,'Q',18,'R',36));
 return new;
end $$;
revoke all on function iprint_private.report_cash_difference() from public,anon,authenticated;
create or replace function public.report_staff_cols(p_mode text) returns text[] language sql immutable set search_path='' as $$ select case when p_mode in ('auto','manual') then array['L','M','N','O','P','R'] else array[]::text[] end $$;
update public.report_sheets set data=data where branch_id is not null and data->>'iprint_layout' in ('2','3','4');
notify pgrst,'reload schema';
