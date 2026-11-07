-- Применить после деплоя функции telegram-purchase (--no-verify-jwt).
-- Существующий токен бота берётся из Vault; не копируйте его в исходный код.
begin;
do $$
begin
  if not exists(select 1 from vault.secrets where name='telegram_purchase_webhook_secret') then
    perform vault.create_secret(replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),'telegram_purchase_webhook_secret');
  end if;
end $$;

create or replace function public.telegram_purchase_config() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('token',(select decrypted_secret from vault.decrypted_secrets where name='telegram_bot_token'),
    'secret',(select decrypted_secret from vault.decrypted_secrets where name='telegram_purchase_webhook_secret'));
$$;
revoke all on function public.telegram_purchase_config() from public,anon,authenticated;
grant execute on function public.telegram_purchase_config() to service_role;

-- Сначала getWebhookInfo: если у бота уже есть обработчик, подключите к нему команду,
-- не заменяйте существующий webhook. Регистрацию ниже выполнять после этой проверки.
commit;

