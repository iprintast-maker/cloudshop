-- iPrint only. Data archives are downloaded by the administrator, never stored server-side.
create schema iprint_backup;
revoke all on schema iprint_backup from public,anon;
grant usage on schema iprint_backup to authenticated;
create table iprint_backup.tables(schema_name text not null,table_name text not null,primary key(schema_name,table_name));
insert into iprint_backup.tables select schemaname,tablename from pg_tables where (schemaname='public' and tablename not in('site_dev_settings','site_developers','site_updates','telegram_recipient_invites','report_import')) or schemaname='iprint_private';
create table iprint_backup.settings(id boolean primary key default true check(id),enabled boolean not null default true,last_confirmed_at timestamptz,last_confirmed_month text,claim_id uuid,claim_user uuid,claim_at timestamptz);
insert into iprint_backup.settings(id) values(true);
create table iprint_backup.events(id bigint generated always as identity primary key,kind text not null,actor uuid not null,created_at timestamptz not null default now(),details jsonb not null default '{}');
alter table iprint_backup.tables enable row level security;
alter table iprint_backup.settings enable row level security;
alter table iprint_backup.events enable row level security;
create policy no_clients on iprint_backup.tables for all to anon,authenticated using(false) with check(false);
create policy no_clients on iprint_backup.settings for all to anon,authenticated using(false) with check(false);
create policy no_clients on iprint_backup.events for all to anon,authenticated using(false) with check(false);
revoke all on all tables in schema iprint_backup from public,anon,authenticated;

create function iprint_backup.require_admin() returns void language plpgsql stable security definer set search_path='' as $$begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Резервная копия доступна только администратору';end if;
end $$;
create function iprint_backup.shape() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_object_agg(t.schema_name||'.'||t.table_name,
 (select jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'generated',a.attgenerated,'identity',a.attidentity) order by a.attnum)
 from pg_attribute a where a.attrelid=to_regclass(format('%I.%I',t.schema_name,t.table_name)) and a.attnum>0 and not a.attisdropped)),'{}') from iprint_backup.tables t
$$;
create function iprint_backup.state(p_action text default 'status',p_claim uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare s iprint_backup.settings;month text:=to_char(now() at time zone 'Europe/Moscow','YYYY-MM');
begin
 perform iprint_backup.require_admin();select * into s from iprint_backup.settings where id for update;
 if p_action='claim' then
  if not s.enabled or s.last_confirmed_month=month or to_char(s.claim_at at time zone 'Europe/Moscow','YYYY-MM')=month then return jsonb_build_object('claimed',false,'enabled',s.enabled,'last_confirmed_month',s.last_confirmed_month,'month',month,'attempted_month',to_char(s.claim_at at time zone 'Europe/Moscow','YYYY-MM'));end if;
  update iprint_backup.settings set claim_id=gen_random_uuid(),claim_user=auth.uid(),claim_at=now() where id returning * into s;
 elsif p_action='confirm' then
  if p_claim is null or s.claim_id is distinct from p_claim or s.claim_user is distinct from auth.uid() then raise exception 'Подтверждение устарело. Скачайте новую копию';end if;
  update iprint_backup.settings set last_confirmed_at=now(),last_confirmed_month=to_char(s.claim_at at time zone 'Europe/Moscow','YYYY-MM'),claim_at=null,claim_id=null,claim_user=null where id returning * into s;
  insert into iprint_backup.events(kind,actor) values('confirmed',auth.uid());
 elsif p_action in('enable','disable') then update iprint_backup.settings set enabled=p_action='enable' where id returning * into s;
 elsif p_action='manual' then
  update iprint_backup.settings set claim_id=gen_random_uuid(),claim_user=auth.uid(),claim_at=now() where id returning * into s;
 elsif p_action<>'status' then raise exception 'Неизвестная операция';end if;
 return jsonb_build_object('claimed',p_action in('claim','manual'),'claim',case when s.claim_user=auth.uid() then s.claim_id end,'enabled',s.enabled,'month',month,'attempted_month',to_char(s.claim_at at time zone 'Europe/Moscow','YYYY-MM'),'last_confirmed_month',s.last_confirmed_month,'last_confirmed_at',s.last_confirmed_at);
end $$;
create function iprint_backup.export_data() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t record;data jsonb:='{}';rows jsonb;shape jsonb;
begin
 perform iprint_backup.require_admin();
 if exists(select 1 from pg_tables p where ((p.schemaname='public' and p.tablename not in('site_dev_settings','site_developers','site_updates','telegram_recipient_invites','report_import')) or p.schemaname='iprint_private') and not exists(select 1 from iprint_backup.tables b where b.schema_name=p.schemaname and b.table_name=p.tablename)) then raise exception 'В базе появились новые таблицы. Нужно обновить модуль резервной копии';end if;
 for t in select * from iprint_backup.tables order by schema_name,table_name loop
  execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]'') from %I.%I r',t.schema_name,t.table_name) into rows;
  data:=data||jsonb_build_object(t.schema_name||'.'||t.table_name,rows);
 end loop;
 shape:=iprint_backup.shape();
 return jsonb_build_object('format','iprint-data-backup','version',1,'project','cvlwoylsdgvwycntyqxu','created_at',now(),'shape',shape,'data',data,'excluded',jsonb_build_array('Пароли и учётные записи авторизации','Токены и настройки разработчика','Файлы изображений и вложений','История обновлений сайта','Временные приглашения Telegram и импорт отчётов'));
end $$;
create function iprint_backup.inspect(p_backup jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t record;key text;rows jsonb;counts jsonb:='[]';n bigint:=0;
begin
 perform iprint_backup.require_admin();
 if exists(select 1 from pg_tables p where ((p.schemaname='public' and p.tablename not in('site_dev_settings','site_developers','site_updates','telegram_recipient_invites','report_import')) or p.schemaname='iprint_private') and not exists(select 1 from iprint_backup.tables b where b.schema_name=p.schemaname and b.table_name=p.tablename)) then raise exception 'В базе появились новые таблицы. Нужно обновить модуль резервной копии';end if;
 if p_backup->>'format' is distinct from 'iprint-data-backup' or p_backup->>'version' is distinct from '1' or p_backup->>'project' is distinct from 'cvlwoylsdgvwycntyqxu' then raise exception 'Это не резервная копия Айпринта';end if;
 if p_backup->'shape' is distinct from iprint_backup.shape() then raise exception 'Структура сайта изменилась после создания копии. Для восстановления этой версии нужна адаптация архива';end if;
 if jsonb_typeof(p_backup->'data') is distinct from 'object' or(select count(*) from jsonb_object_keys(p_backup->'data'))<>(select count(*) from iprint_backup.tables) then raise exception 'В архиве неполный или неизвестный набор таблиц';end if;
 for t in select * from iprint_backup.tables order by schema_name,table_name loop
  key:=t.schema_name||'.'||t.table_name;rows:=p_backup->'data'->key;
  if jsonb_typeof(rows) is distinct from 'array' then raise exception 'Повреждена таблица %',key;end if;
  if exists(select 1 from jsonb_array_elements(rows) r where jsonb_typeof(r)<>'object' or(select count(*) from jsonb_object_keys(r))<>jsonb_array_length(p_backup->'shape'->key) or exists(select 1 from jsonb_array_elements(p_backup->'shape'->key) c where not r ? (c->>'name'))) then raise exception 'Повреждены строки таблицы %',key;end if;
  n:=n+jsonb_array_length(rows);counts:=counts||jsonb_build_array(jsonb_build_object('table',key,'rows',jsonb_array_length(rows)));
 end loop;
 if not exists(select 1 from jsonb_array_elements(p_backup->'data'->'public.staff_accounts') r where r->>'user_id'=auth.uid()::text and r->>'role'='admin' and (r->>'active')::boolean) then raise exception 'В копии нет вашего действующего аккаунта администратора. Обратитесь за восстановлением с сохранением доступа';end if;
 return jsonb_build_object('valid',true,'created_at',p_backup->'created_at','rows',n,'tables',counts,'excluded',p_backup->'excluded');
end $$;
create function iprint_backup.restore(p_backup jsonb,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare preview jsonb;t record;c record;tr record;triggers jsonb;constraints jsonb;cols text;seq text;highest bigint;previous bigint;
begin
 perform iprint_backup.require_admin();
 if p_confirmation is distinct from 'ВОССТАНОВИТЬ' then raise exception 'Для восстановления введите ВОССТАНОВИТЬ';end if;
 preview:=iprint_backup.inspect(p_backup);
 perform pg_advisory_xact_lock(hashtextextended('iprint-backup-restore',0));
 -- Lock the complete business dataset in a deterministic order before any replacement.
 for t in select * from iprint_backup.tables order by schema_name,table_name loop execute format('lock table %I.%I in access exclusive mode',t.schema_name,t.table_name);end loop;
 preview:=iprint_backup.inspect(p_backup);
 if exists(select 1 from pg_constraint fk join iprint_backup.tables p on to_regclass(format('%I.%I',p.schema_name,p.table_name))=fk.confrelid where fk.contype='f' and not exists(select 1 from iprint_backup.tables ch where to_regclass(format('%I.%I',ch.schema_name,ch.table_name))=fk.conrelid)) then raise exception 'На данные ссылается таблица вне архива. Нужна адаптация восстановления';end if;
 select coalesce(jsonb_agg(jsonb_build_object('schema',n.nspname,'table',cl.relname,'name',g.tgname,'enabled',g.tgenabled)),'[]') into triggers from pg_trigger g join pg_class cl on cl.oid=g.tgrelid join pg_namespace n on n.oid=cl.relnamespace join iprint_backup.tables b on b.schema_name=n.nspname and b.table_name=cl.relname where not g.tgisinternal;
 select coalesce(jsonb_agg(jsonb_build_object('schema',n.nspname,'table',cl.relname,'name',f.conname)),'[]') into constraints from pg_constraint f join pg_class cl on cl.oid=f.conrelid join pg_namespace n on n.oid=cl.relnamespace join iprint_backup.tables b on b.schema_name=n.nspname and b.table_name=cl.relname where f.contype='f' and not f.condeferrable;
 -- Keep foreign keys enabled and validate the entire restored graph before finishing.
 for c in select * from jsonb_to_recordset(constraints) as x(schema text,"table" text,name text) loop execute format('alter table %I.%I alter constraint %I deferrable initially immediate',c.schema,c."table",c.name);end loop;
 set constraints all deferred;
 for t in select * from iprint_backup.tables order by schema_name,table_name loop execute format('alter table %I.%I disable trigger user',t.schema_name,t.table_name);end loop;
 for t in select * from iprint_backup.tables order by schema_name,table_name loop execute format('delete from %I.%I',t.schema_name,t.table_name);end loop;
 for t in select * from iprint_backup.tables order by schema_name,table_name loop
  select string_agg(format('%I',a.attname),',' order by a.attnum) into cols from pg_attribute a where a.attrelid=to_regclass(format('%I.%I',t.schema_name,t.table_name)) and a.attnum>0 and not a.attisdropped and a.attgenerated='';
  execute format('insert into %I.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::%I.%I,$1)',t.schema_name,t.table_name,cols,cols,t.schema_name,t.table_name) using p_backup->'data'->(t.schema_name||'.'||t.table_name);
 end loop;
 set constraints all immediate;
 for c in select * from jsonb_to_recordset(constraints) as x(schema text,"table" text,name text) loop execute format('alter table %I.%I alter constraint %I not deferrable initially immediate',c.schema,c."table",c.name);end loop;
 for tr in select * from jsonb_to_recordset(triggers) as x(schema text,"table" text,name text,enabled text) loop
  execute format('alter table %I.%I %s trigger %I',tr.schema,tr."table",case tr.enabled when 'D' then 'disable' when 'A' then 'enable always' when 'R' then 'enable replica' else 'enable' end,tr.name);
 end loop;
 for t in select b.*,a.attname from iprint_backup.tables b join pg_attribute a on a.attrelid=to_regclass(format('%I.%I',b.schema_name,b.table_name)) where a.attnum>0 and not a.attisdropped loop
  seq:=pg_get_serial_sequence(format('%I.%I',t.schema_name,t.table_name),t.attname);
  if seq is not null then
   execute format('select max(%I) from %I.%I',t.attname,t.schema_name,t.table_name) into highest;
   execute format('select last_value from %s',seq::regclass) into previous;
   if highest>previous then perform setval(seq::regclass,highest,true);end if;
  end if;
 end loop;
 insert into iprint_backup.events(kind,actor,details) values('restored',auth.uid(),jsonb_build_object('backup_date',p_backup->'created_at','rows',preview->'rows'));
 return jsonb_build_object('ok',true,'rows',preview->'rows');
end $$;
create function public.iprint_backup_state(p_action text default 'status',p_claim uuid default null) returns jsonb language sql security invoker set search_path='' as $$select iprint_backup.state(p_action,p_claim)$$;
create function public.iprint_backup_export() returns jsonb language sql security invoker set search_path='' as $$select iprint_backup.export_data()$$;
create function public.iprint_backup_inspect(p_backup jsonb) returns jsonb language sql security invoker set search_path='' as $$select iprint_backup.inspect(p_backup)$$;
create function public.iprint_backup_restore(p_backup jsonb,p_confirmation text) returns jsonb language sql security invoker set search_path='' as $$select iprint_backup.restore(p_backup,p_confirmation)$$;
do $$declare f record;begin
 for f in select p.oid::regprocedure sig,n.nspname ns,p.proname name from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='iprint_backup' or(n.nspname='public' and p.proname like 'iprint_backup_%') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.sig);
  if f.ns='public' or f.name in('state','export_data','inspect','restore') then execute format('grant execute on function %s to authenticated',f.sig);end if;
 end loop;
end $$;
notify pgrst,'reload schema';
