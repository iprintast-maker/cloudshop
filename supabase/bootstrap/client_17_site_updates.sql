create table if not exists public.site_developers(user_id uuid primary key references auth.users(id));
alter table public.site_developers enable row level security;


create or replace function public.is_developer() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.site_developers d where d.user_id=auth.uid())
$$;

create table if not exists public.site_updates(
  id bigserial primary key,
  title text not null,
  description text,
  images jsonb not null default '[]'::jsonb,
  price numeric(12,2) not null default 0,
  eta text,
  status text not null default 'offered' check (status in ('offered','accepted','declined','installed','withdrawn')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid,
  decided_by_name text,
  installed_at timestamptz
);
alter table public.site_updates enable row level security;

create table if not exists public.site_dev_settings(id int primary key default 1 check (id=1), tg_bot_token text, tg_chat_id text);
alter table public.site_dev_settings enable row level security;
insert into public.site_dev_settings(id) values(1) on conflict do nothing;

create or replace function public.site_updates_list() returns setof public.site_updates
language plpgsql stable security definer set search_path=public as $$
begin
  if not (public.is_admin() or public.is_developer()) then return; end if;
  return query select * from public.site_updates where public.is_developer() or status<>'withdrawn' order by created_at desc;
end $$;

create or replace function public.site_update_save(p_id bigint, p_title text, p_description text, p_images jsonb, p_price numeric, p_eta text) returns bigint
language plpgsql security definer set search_path=public as $$
declare v_id bigint;
begin
  if not public.is_developer() then raise exception 'Только для разработчика'; end if;
  if nullif(trim(coalesce(p_title,'')),'') is null then raise exception 'Укажите название обновления'; end if;
  if coalesce(p_price,0)<0 then raise exception 'Цена не может быть меньше 0'; end if;
  if p_id is null then
    insert into public.site_updates(title,description,images,price,eta) values(trim(p_title),nullif(trim(coalesce(p_description,'')),''),coalesce(p_images,'[]'::jsonb),coalesce(p_price,0),nullif(trim(coalesce(p_eta,'')),'')) returning id into v_id;
  else
    update public.site_updates set title=trim(p_title),description=nullif(trim(coalesce(p_description,'')),''),images=coalesce(p_images,'[]'::jsonb),price=coalesce(p_price,0),eta=nullif(trim(coalesce(p_eta,'')),'')
      where id=p_id and status='offered' returning id into v_id;
    if v_id is null then raise exception 'Менять можно только обновление, по которому клиент ещё не ответил'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.site_update_set_status(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_developer() then raise exception 'Только для разработчика'; end if;
  if p_status='installed' then update public.site_updates set status='installed',installed_at=now() where id=p_id and status='accepted';
  elsif p_status='withdrawn' then update public.site_updates set status='withdrawn' where id=p_id and status='offered';
  elsif p_status='offered' then update public.site_updates set status='offered',decided_at=null,decided_by=null,decided_by_name=null where id=p_id and status in ('declined','withdrawn');
  else raise exception 'Неизвестный статус'; end if;
  if not found then raise exception 'Нельзя поменять статус этого обновления'; end if;
end $$;

create or replace function public.site_update_decide(p_id bigint, p_accept boolean) returns void
language plpgsql security definer set search_path=public as $$
declare v public.site_updates%rowtype; s public.site_dev_settings%rowtype; who text;
begin
  if not public.is_admin() then raise exception 'Ответить может только администратор'; end if;
  select name into who from public.staff_accounts where user_id=auth.uid();
  update public.site_updates set status=case when p_accept then 'accepted' else 'declined' end, decided_at=now(), decided_by=auth.uid(), decided_by_name=who
    where id=p_id and status='offered' returning * into v;
  if v.id is null then raise exception 'Это обновление уже не ждёт ответа'; end if;
  select * into s from public.site_dev_settings where id=1;
  if s.tg_bot_token is not null and s.tg_chat_id is not null then
    perform net.http_post(url:='https://api.telegram.org/bot'||s.tg_bot_token||'/sendMessage',
      body:=jsonb_build_object('chat_id',s.tg_chat_id,'text',case when p_accept then '✅ Клиент согласился на обновление' else '❌ Клиент отказался от обновления' end||E'\n«'||v.title||'» — '||case when v.price>0 then v.price::text||' ₽' else 'бесплатно' end||E'\nОтветил(а): '||coalesce(who,'—')),
      headers:='{"Content-Type":"application/json"}'::jsonb);
  end if;
end $$;

revoke all on function public.site_updates_list() from public, anon;
revoke all on function public.site_update_save(bigint,text,text,jsonb,numeric,text) from public, anon;
revoke all on function public.site_update_set_status(bigint,text) from public, anon;
revoke all on function public.site_update_decide(bigint,boolean) from public, anon;
revoke all on function public.is_developer() from public, anon;
grant execute on function public.site_updates_list() to authenticated;
grant execute on function public.site_update_save(bigint,text,text,jsonb,numeric,text) to authenticated;
grant execute on function public.site_update_set_status(bigint,text) to authenticated;
grant execute on function public.site_update_decide(bigint,boolean) to authenticated;
grant execute on function public.is_developer() to authenticated;

