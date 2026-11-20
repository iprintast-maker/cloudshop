-- Only iПринт revenue sheets. Keep the complete original workbook privately before changing its layout.
create table if not exists iprint_private.report_layout_backup (
 sheet_id bigint primary key, original_sheet jsonb not null, saved_at timestamptz not null default now()
);
alter table iprint_private.report_layout_backup enable row level security;
revoke all on iprint_private.report_layout_backup from public,anon,authenticated;
insert into iprint_private.report_layout_backup(sheet_id,original_sheet)
 select id,to_jsonb(s) from public.report_sheets s where branch_id is not null and coalesce(data->>'iprint_layout','')<>'2'
 on conflict do nothing;
do $$
declare s record; r record; m jsonb; newrows jsonb; rowdata jsonb; cells jsonb; i integer; dest text; src text;
 headers text[] := array['Дата','День недели','Выручка','Карта','Наличные','Перевод','Счет','Ссылка','QR','Кол-во клиентов','Возврат','Перезаказы','Расходы','Комментарий','Инкассация','Факт в кассе'];
 oldcols text[] := array['A','B','D','G',null,'J','K','I','H','L','M',null,'F','R','O','N'];
begin
 for s in select * from public.report_sheets where branch_id is not null and coalesce(data->>'iprint_layout','')<>'2' for update loop
  newrows:='{}';
  for r in select * from jsonb_each(coalesce(s.data->'rows','{}')) loop
   rowdata:='{}';
   for i in 1..16 loop
    dest:=public.report_col_name(i);src:=oldcols[i];
    if src is not null and r.value ? src then rowdata:=rowdata||jsonb_build_object(dest,(r.value->src)-'f');end if;
   end loop;
   newrows:=newrows||jsonb_build_object(r.key,rowdata);
  end loop;
  for m in select * from jsonb_array_elements(s.months) loop
   cells:='{}';
   for i in 1..16 loop cells:=cells||jsonb_build_object(public.report_col_name(i),jsonb_build_object('s',0,'v',headers[i]));end loop;
   newrows:=jsonb_set(newrows,array[m->>'from'],cells);
   cells:=jsonb_build_object('A',jsonb_build_object('s',1,'v','Итого'));
   foreach dest in array array['C','D','E','F','G','H','I','J','K','L','M','O','P'] loop
    cells:=cells||jsonb_build_object(dest,jsonb_build_object('s',1,'f','SUM('||dest||((m->>'from')::int+1)||':'||dest||((m->>'to')::int-1)||')'));
   end loop;
   newrows:=jsonb_set(newrows,array[m->>'to'],cells);
  end loop;
  update public.report_sheets set data=(s.data-'merges'-'cols')||jsonb_build_object('rows',newrows,'ncols',16,'iprint_layout',2,'merges','[]'::jsonb,'cols',jsonb_build_object('A',12,'B',17,'C',14,'D',14,'E',14,'F',14,'G',14,'H',14,'I',14,'J',18,'K',14,'L',14,'M',14,'N',36,'O',17,'P',18)),updated_at=now() where id=s.id;
  for m in select * from jsonb_array_elements(s.months) loop perform public.report_recalc_total(s.id,(m->>'to')::int);end loop;
 end loop;
 -- There are no longer fully manual daily reports: only the six specified fields are editable.
 update public.report_fills set mode='auto' where sheet_id in(select id from public.report_sheets where data->>'iprint_layout'='2');
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
   insert into public.report_sheets(sort_order,title,branch_id,data,months,staff_visible) values(100+sh.branch_id,branch||' — выручка',sh.branch_id,'{"nrows":0,"ncols":16,"rows":{},"cols":{},"styles":[{"b":1,"bg":"FFFF00"},{"b":1,"bg":"BDD7EE"}],"merges":[],"heights":{}}','[]',false) returning * into sheet;
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
  foreach col in array array['Дата','День недели','Выручка','Карта','Наличные','Перевод','Счет','Ссылка','QR','Кол-во клиентов','Возврат','Перезаказы','Расходы','Комментарий','Инкассация','Факт в кассе'] loop i:=i+1;header:=header||jsonb_build_object(public.report_col_name(i),jsonb_build_object('s',0,'v',col));end loop;
  rows:=rows||jsonb_build_object(start_row::text,header);
  for i in 0..(last_day-first_day) loop
   rows:=rows||jsonb_build_object((start_row+i+1)::text,jsonb_build_object('A',jsonb_build_object('v',first_day+i-date '1899-12-30'),'B',jsonb_build_object('v',(array['Понедельник','Вторник','Среда','Четверг','Пятница','Суббота','Воскресенье'])[extract(isodow from first_day+i)::integer])));
  end loop;
  header:=jsonb_build_object('A',jsonb_build_object('s',1,'v','Итого'));
  foreach col in array array['C','D','E','F','G','H','I','J','K','L','M','O','P'] loop header:=header||jsonb_build_object(col,jsonb_build_object('s',1,'f','SUM('||col||(start_row+1)||':'||col||(end_row-1)||')'));end loop;
  rows:=rows||jsonb_build_object(end_row::text,header);row_no:=start_row+extract(day from d)::integer;
 end if;
 months:=months||jsonb_build_array(jsonb_build_object('m',to_char(d,'YYYY-MM'),'from',greatest(start_row,1),'to',end_row));
 data:=jsonb_set(sheet.data,'{rows}',rows)||jsonb_build_object('ncols',16,'iprint_layout',2);data:=jsonb_set(data,'{nrows}',to_jsonb(greatest(coalesce((sheet.data->>'nrows')::integer,0),end_row)));
 update public.report_sheets set data=report_values.data,months=report_values.months,updated_at=now() where id=sheet.id;
 return jsonb_build_object('sheet_id',sheet.id,'row',row_no,'ready',true);
end $$;
CREATE OR REPLACE FUNCTION iprint_private.report_fill_shift(p_shift_id bigint, p_mode text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare c record; d record; v_shifts bigint[]; v_names text; v_vals jsonb;
begin
  if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника'; end if;
  if p_mode not in ('auto','manual') then raise exception 'Неизвестный способ заполнения'; end if;
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no)
    values (p_shift_id,c.branch_id,c.day,'auto',d.sheet_id,d.row_no)
    on conflict (shift_id) do update set mode=excluded.mode, sheet_id=excluded.sheet_id, row_no=excluded.row_no, updated_at=now();
  if true then
    select array_agg(id) into v_shifts from public.sales_shifts
     where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=c.day;
    select string_agg(nm,'/' order by first_at) into v_names from (
      select coalesce(nullif(btrim(p.name),''),e.name) nm, min(se.created_at) first_at
        from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
        left join public.sales_people p on p.id=e.person_id
       where se.shift_id=any(v_shifts) group by 1) x;
    with v as (select id,total from public.sales where shift_id=any(v_shifts) and status='completed' and payment_status<>'unpaid'),
         pay as (select p.payment_method m, sum(p.amount) a from public.sale_payments p join v on v.id=p.sale_id group by 1)
    select jsonb_build_object(
      'C', (select coalesce(sum(total),0) from v),
      'D', coalesce((select a from pay where m='card'),0),
      'F', coalesce((select a from pay where m='transfer'),0),
      'G', coalesce((select a from pay where m='bank_account'),0),
      'H', coalesce((select a from pay where m='link'),0),
      'I', coalesce((select a from pay where m='qr'),0),
      'J', (select count(*) from v),
      'K', (select coalesce(sum(amount),0) from public.sales_returns where shift_id=any(v_shifts))) into v_vals;
    perform public.report_put_row(d.sheet_id, d.row_no, v_vals);
    perform public.report_recalc_total(d.sheet_id, d.m_to);
  end if;
  return public.report_staff_view(p_shift_id);
end $function$;


revoke all on function iprint_private.report_fill_shift(bigint,text) from public,anon;
grant execute on function iprint_private.report_fill_shift(bigint,text) to authenticated;
create or replace function public.report_fill_shift(p_shift_id bigint,p_mode text) returns jsonb language sql security invoker set search_path='' as $$ select iprint_private.report_fill_shift(p_shift_id,p_mode) $$;
revoke all on function public.report_fill_shift(bigint,text) from public,anon;
grant execute on function public.report_fill_shift(bigint,text) to authenticated;
create or replace function public.report_staff_cols(p_mode text) returns text[] language sql immutable set search_path='' as $$ select case when p_mode in ('auto','manual') then array['E','L','M','N','O','P'] else array[]::text[] end $$;
notify pgrst,'reload schema';
