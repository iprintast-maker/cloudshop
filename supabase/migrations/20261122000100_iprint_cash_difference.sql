-- Append columns without shifting or replacing existing fields. Q is automatic unless manually overridden.
create or replace function iprint_private.report_cash_difference() returns trigger language plpgsql security invoker set search_path='' as $$
declare r record;m jsonb;cells jsonb;rows jsonb;cash numeric;actual numeric;diff numeric;total numeric;f text;
begin
 if new.branch_id is null or coalesce(new.data->>'iprint_layout','') not in ('2','3') then return new;end if;
 rows:=coalesce(new.data->'rows','{}');
 for r in select * from jsonb_each(rows) loop
  if coalesce(r.value->'A'->>'v','') !~ '^[0-9]+$' then continue;end if;
  cells:=r.value;
  -- A plain manually supplied value is a persistent override. Clearing it restores the formula.
  if cells->'Q'->'f' is null and cells->'Q'->'v' is not null and jsonb_typeof(cells->'Q'->'v')<>'null' then continue;end if;
  f:='IF(P'||r.key||'="","",E'||r.key||'-P'||r.key||')';
  if jsonb_typeof(cells->'P'->'v')='number' then
   actual:=(cells->'P'->>'v')::numeric;
   cash:=case when jsonb_typeof(cells->'E'->'v')='number' then (cells->'E'->>'v')::numeric else 0 end;
   cells:=jsonb_set(cells,'{Q}',jsonb_build_object('f',f,'v',cash-actual));
  else cells:=jsonb_set(cells,'{Q}',jsonb_build_object('f',f));end if;
  rows:=jsonb_set(rows,array[r.key],cells);
 end loop;
 for m in select * from jsonb_array_elements(coalesce(new.months,'[]')) loop
  cells:=coalesce(rows->(m->>'from'),'{}')||jsonb_build_object('Q',jsonb_build_object('s',0,'v','Расхождения'),'R',jsonb_build_object('s',0,'v','Комментарий'));
  rows:=jsonb_set(rows,array[m->>'from'],cells);
  select coalesce(sum((v->'Q'->>'v')::numeric),0) into total from jsonb_each(rows)t(k,v) where k::int between (m->>'from')::int+1 and (m->>'to')::int-1 and jsonb_typeof(v->'Q'->'v')='number';
  cells:=coalesce(rows->(m->>'to'),'{}')||jsonb_build_object('Q',jsonb_build_object('s',1,'f','SUM(Q'||((m->>'from')::int+1)||':Q'||((m->>'to')::int-1)||')','v',total));
  rows:=jsonb_set(rows,array[m->>'to'],cells);
 end loop;
 new.data:=new.data||jsonb_build_object('rows',rows,'ncols',18,'iprint_layout',3,'cols',coalesce(new.data->'cols','{}')||jsonb_build_object('Q',18,'R',36));
 return new;
end $$;
revoke all on function iprint_private.report_cash_difference() from public,anon,authenticated;
create trigger iprint_cash_difference before insert or update of data,months on public.report_sheets for each row execute function iprint_private.report_cash_difference();
update public.report_sheets set data=data where branch_id is not null and data->>'iprint_layout'='2';
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
   insert into public.report_sheets(sort_order,title,branch_id,data,months,staff_visible) values(100+sh.branch_id,branch||' — выручка',sh.branch_id,'{"nrows":0,"ncols":18,"rows":{},"cols":{},"styles":[{"b":1,"bg":"FFFF00"},{"b":1,"bg":"BDD7EE"}],"merges":[],"heights":{}}','[]',false) returning * into sheet;
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
  foreach col in array array['Дата','День недели','Выручка','Карта','Наличные','Перевод','Счет','Ссылка','QR','Кол-во клиентов','Возврат','Перезаказы','Расходы','Комментарий','Инкассация','Факт в кассе','Расхождения','Комментарий'] loop i:=i+1;header:=header||jsonb_build_object(public.report_col_name(i),jsonb_build_object('s',0,'v',col));end loop;
  rows:=rows||jsonb_build_object(start_row::text,header);
  for i in 0..(last_day-first_day) loop
   rows:=rows||jsonb_build_object((start_row+i+1)::text,jsonb_build_object('A',jsonb_build_object('v',first_day+i-date '1899-12-30'),'B',jsonb_build_object('v',(array['Понедельник','Вторник','Среда','Четверг','Пятница','Суббота','Воскресенье'])[extract(isodow from first_day+i)::integer])));
  end loop;
  header:=jsonb_build_object('A',jsonb_build_object('s',1,'v','Итого'));
  foreach col in array array['C','D','E','F','G','H','I','J','K','L','M','O','P','Q'] loop header:=header||jsonb_build_object(col,jsonb_build_object('s',1,'f','SUM('||col||(start_row+1)||':'||col||(end_row-1)||')'));end loop;
  rows:=rows||jsonb_build_object(end_row::text,header);row_no:=start_row+extract(day from d)::integer;
 end if;
 months:=months||jsonb_build_array(jsonb_build_object('m',to_char(d,'YYYY-MM'),'from',greatest(start_row,1),'to',end_row));
 data:=jsonb_set(sheet.data,'{rows}',rows)||jsonb_build_object('ncols',18,'iprint_layout',3);data:=jsonb_set(data,'{nrows}',to_jsonb(greatest(coalesce((sheet.data->>'nrows')::integer,0),end_row)));
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
      'E', coalesce((select a from pay where m='cash'),0),
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



create or replace function public.report_staff_cols(p_mode text) returns text[] language sql immutable set search_path='' as $$ select case when p_mode in ('auto','manual') then array['L','M','N','O','P','Q','R'] else array[]::text[] end $$;
notify pgrst,'reload schema';
