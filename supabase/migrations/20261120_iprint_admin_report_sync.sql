-- An administrator opens the report directly, bypassing the staff transfer path.
create or replace function iprint_private.sync_reports(p_shift_id bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare sh record;done integer:=0;manual_count integer:=0;errors jsonb:='[]';
begin
 if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
 if p_shift_id is null and not public.is_admin() then raise sqlstate 'PT403' using message='Общую синхронизацию запускает администратор';end if;
 for sh in select distinct on(s.branch_id,(s.started_at at time zone 'Europe/Moscow')::date) s.id,s.branch_id,(s.started_at at time zone 'Europe/Moscow')::date as work_day
  from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id
  where not b.is_test and not b.is_workshop and ((p_shift_id is not null and s.id=p_shift_id) or(p_shift_id is null and (s.started_at at time zone 'Europe/Moscow')::date>=date_trunc('month',now() at time zone 'Europe/Moscow')::date and s.started_at<=now()))
  order by s.branch_id,(s.started_at at time zone 'Europe/Moscow')::date,s.started_at desc loop
  if exists(select 1 from public.report_fills f where f.branch_id=sh.branch_id and f.day=sh.work_day and f.mode='manual') then manual_count:=manual_count+1;continue;end if;
  begin
   perform iprint_private.report_prepare(sh.id);perform public.report_fill_shift(sh.id,'auto');done:=done+1;
  exception when others then errors:=errors||jsonb_build_array(jsonb_build_object('branch_id',sh.branch_id,'day',sh.work_day,'message',sqlerrm));end;
 end loop;
 return jsonb_build_object('synced',done,'manual_skipped',manual_count,'errors',errors);
end $$;
revoke all on function iprint_private.sync_reports(bigint) from public,anon;
grant execute on function iprint_private.sync_reports(bigint) to authenticated;
create or replace function public.iprint_sync_reports(p_shift_id bigint default null) returns jsonb language sql security invoker set search_path='' as $$select iprint_private.sync_reports(p_shift_id)$$;
revoke all on function public.iprint_sync_reports(bigint) from public,anon;
grant execute on function public.iprint_sync_reports(bigint) to authenticated;
notify pgrst,'reload schema';
