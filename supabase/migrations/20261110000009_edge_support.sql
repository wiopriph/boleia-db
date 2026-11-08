-- Boleia - edge support (ТЗ разделы 6, 8, 9, 10)
--
-- Сервисные RPC для Edge Functions (они не пишут в таблицы напрямую), Auth hooks как
-- Postgres-функции, вызовы Edge из pg_cron через pg_net с ключом в Vault, мгновенная доставка
-- уведомлений триггером. План и решения: docs/plans/0009_edge_functions.md

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- notify: inapp доставлен в момент записи, доставлять нечего
-- ---------------------------------------------------------------------------
create or replace function public.notify(
  p_user_id uuid, p_type text, p_payload jsonb default '{}', p_allow_sms boolean default true,
  p_scheduled_for timestamptz default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_at    timestamptz := coalesce(p_scheduled_for, now());
  v_local timestamp   := v_at at time zone 'Africa/Luanda';
  v_deliver_at timestamptz := p_scheduled_for;
  v_urgent boolean := p_type like 'payment\_%' or p_type like 'booking\_%' or p_type like 'dispute\_%'
                   or p_type in ('trip_cancelled', 'refund_done', 'pin_ready', 'trip_reminder_2h', 'reconciliation_alert');
begin
  if not v_urgent and (v_local::time >= '22:00' or v_local::time < '07:00') then
    v_deliver_at := (date_trunc('day', v_local) + case when v_local::time >= '22:00' then interval '1 day' else interval '0' end
                     + interval '7 hours') at time zone 'Africa/Luanda';
  end if;

  insert into public.notifications (user_id, type, channel, payload, scheduled_for, status, sent_at)
  values (p_user_id, p_type, 'inapp', p_payload, p_scheduled_for, 'sent', now());
  if exists (select 1 from public.devices where user_id = p_user_id) then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'push', p_payload, v_deliver_at);
  elsif p_allow_sms then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'sms', p_payload, v_deliver_at);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- handle_new_user: GoTrue хранит телефон без "+", в profiles он в E.164 (ТЗ раздел 4)
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, phone, display_name, phone_verified_at)
  values (
    new.id,
    case when new.phone is null or new.phone like '+%' then new.phone else '+' || new.phone end,
    coalesce(new.raw_user_meta_data ->> 'display_name', ''),
    new.phone_confirmed_at
  )
  on conflict (id) do nothing;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Сервисные RPC (service_role)
-- ---------------------------------------------------------------------------

-- payments-init создал транзакцию в шлюзе: created -> pending. Идемпотентна по provider_ref.
create or replace function public.payment_initiated(payment_id uuid, provider_ref text, raw jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_payment_id uuid := payment_id;
  v_ref        text := nullif(btrim(provider_ref), '');
  pay          public.payments;
  b            public.bookings;
begin
  if v_ref is null then perform public.raise_boleia('PAYMENT_REF_MISMATCH'); end if;
  select * into pay from public.payments where id = v_payment_id for update;
  if pay.id is null then perform public.raise_boleia('PAYMENT_NOT_FOUND'); end if;

  if pay.provider_ref = v_ref and pay.status <> 'created' then
    return jsonb_build_object('payment_id', pay.id, 'status', pay.status, 'expires_at', pay.expires_at, 'already', true);
  end if;
  if pay.status <> 'created' then perform public.raise_boleia('PAYMENT_STATUS_INVALID'); end if;

  select * into b from public.bookings where id = pay.booking_id;
  if b.status <> 'pending_payment' then perform public.raise_boleia('BOOKING_CLOSED'); end if;

  update public.payments
  set status = 'pending', provider_ref = v_ref, raw_request = coalesce(raw, '{}'), expires_at = now() + interval '15 minutes'
  where id = pay.id
  returning * into pay;
  return jsonb_build_object('payment_id', pay.id, 'status', pay.status, 'expires_at', pay.expires_at);
end $$;

-- payments-refund сходил в шлюз. После трёх неудач - ручная очередь (ТЗ раздел 6, cron).
create or replace function public.payment_refund_result(payment_id uuid, ok boolean, refund_ref text default null, raw jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_payment_id uuid := payment_id;
  v_ref        text := nullif(btrim(refund_ref), '');
  pay          public.payments;
begin
  select * into pay from public.payments where id = v_payment_id for update;
  if pay.id is null then perform public.raise_boleia('PAYMENT_NOT_FOUND'); end if;
  if pay.refund_kz <= 0 then perform public.raise_boleia('PAYMENT_STATUS_INVALID'); end if;
  if pay.refund_ref is not null then
    return jsonb_build_object('payment_id', pay.id, 'status', pay.status, 'already', true);
  end if;

  if ok then
    if v_ref is null then perform public.raise_boleia('PAYMENT_REF_MISMATCH'); end if;
    update public.payments
    set refund_ref = v_ref, refunded_at = now(),
        status = case when refund_kz >= amount_kz then 'refunded'::payment_status else 'partially_refunded'::payment_status end,
        raw_webhook = coalesce(raw_webhook, '{}') || jsonb_build_object('refund', coalesce(raw, '{}'))
    where id = pay.id
    returning * into pay;
    perform public.notify(pay.payer_id, 'refund_done',
      jsonb_build_object('payment_id', pay.id, 'booking_id', pay.booking_id, 'refund_kz', pay.refund_kz, 'refund_ref', v_ref), true);
  else
    update public.payments
    set refund_attempts = refund_attempts + 1, refund_failed_at = now(),
        raw_webhook = coalesce(raw_webhook, '{}') || jsonb_build_object('refund_error', coalesce(raw, '{}'))
    where id = pay.id
    returning * into pay;
    if pay.refund_attempts >= 3 then
      perform public.notify_admins('refund_manual',
        jsonb_build_object('payment_id', pay.id, 'booking_id', pay.booking_id, 'refund_kz', pay.refund_kz, 'payer_id', pay.payer_id));
    end if;
  end if;
  return jsonb_build_object('payment_id', pay.id, 'status', pay.status, 'refund_attempts', pay.refund_attempts);
end $$;

-- notify отправил push/SMS. Неудача: до 3 попыток через 5 минут (ТЗ раздел 6, Edge notify).
create or replace function public.notification_delivered(id uuid, ok boolean, error text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_id       uuid := id;
  v_error    text := left(error, 500);
  n          public.notifications;
  v_attempts integer;
begin
  select * into n from public.notifications where notifications.id = v_id for update;
  if n.id is null or n.status <> 'queued' then return; end if;

  if ok then
    update public.notifications set status = 'sent', sent_at = now(), error = null where notifications.id = n.id;
    return;
  end if;

  v_attempts := coalesce((n.payload ->> 'attempts')::integer, 0) + 1;
  if v_attempts >= 3 then
    update public.notifications
    set status = 'failed', error = v_error, payload = payload || jsonb_build_object('attempts', v_attempts)
    where notifications.id = n.id;
  else
    update public.notifications
    set error = v_error, payload = payload || jsonb_build_object('attempts', v_attempts), scheduled_for = now() + interval '5 minutes'
    where notifications.id = n.id;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Auth hooks (ТЗ раздел 8): admin в JWT, запрет регистрации забаненных номеров
-- ---------------------------------------------------------------------------
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_claims jsonb := coalesce(event -> 'claims', '{}');
  v_meta   jsonb := coalesce(v_claims -> 'app_metadata', '{}');
  v_admin  boolean;
begin
  select is_admin into v_admin from public.profiles where id = (event ->> 'user_id')::uuid;
  if coalesce(v_admin, false) then
    v_meta := v_meta || '{"role": "admin"}';
  elsif v_meta ->> 'role' = 'admin' then
    v_meta := v_meta - 'role';
  end if;
  return jsonb_build_object('claims', jsonb_set(v_claims, '{app_metadata}', v_meta));
end $$;

create or replace function public.before_user_created_hook(event jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_phone text := event -> 'user' ->> 'phone';
begin
  if v_phone is not null and exists (select 1 from public.banned_phones bp where public.same_phone(bp.phone, v_phone)) then
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', 'Este número não pode registar-se.'));
  end if;
  return '{}'::jsonb;
end $$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb), public.before_user_created_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb), public.before_user_created_hook(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Вызов Edge из базы: pg_net + секреты edge_url / edge_key в Vault. Без секретов - тишина (dev, тесты).
-- ---------------------------------------------------------------------------
create or replace function public.edge_call(p_path text, p_body jsonb default '{}')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_url text; v_key text; v_id bigint;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'edge_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_key';
  if v_url is null or v_key is null then return null; end if;

  select net.http_post(
    url := rtrim(v_url, '/') || '/functions/v1/' || p_path,
    body := coalesce(p_body, '{}'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    timeout_milliseconds := 8000
  ) into v_id;
  return v_id;
end $$;

-- Мгновенная доставка: push/sms без отложенного времени уходят в notify сразу после commit
create or replace function public.notifications_dispatch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.edge_call('notify', jsonb_build_object('id', new.id));
  return null;
end $$;
create trigger notifications_dispatch after insert on public.notifications
  for each row when (new.channel in ('push', 'sms') and new.scheduled_for is null and new.status = 'queued')
  execute function public.notifications_dispatch();

-- ---------------------------------------------------------------------------
-- Права и расписание
-- ---------------------------------------------------------------------------
revoke all on function
  public.notify(uuid, text, jsonb, boolean, timestamptz),
  public.payment_initiated(uuid, text, jsonb),
  public.payment_refund_result(uuid, boolean, text, jsonb),
  public.notification_delivered(uuid, boolean, text),
  public.edge_call(text, jsonb),
  public.notifications_dispatch()
from public, anon, authenticated;
grant execute on function
  public.payment_initiated(uuid, text, jsonb),
  public.payment_refund_result(uuid, boolean, text, jsonb),
  public.notification_delivered(uuid, boolean, text)
to service_role;

select cron.unschedule(jobid) from cron.job where jobname in ('boleia_payments_status', 'boleia_payments_refund', 'boleia_notify_sweep');
select cron.schedule('boleia_payments_status', '* * * * *',   $$select public.edge_call('payments-status?sweep=1')$$);
select cron.schedule('boleia_payments_refund', '*/5 * * * *', $$select public.edge_call('payments-refund')$$);
select cron.schedule('boleia_notify_sweep',    '* * * * *',   $$select public.edge_call('notify?sweep=1')$$);
