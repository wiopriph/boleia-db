-- Boleia - уведомления несут маршрут и роль получателя; открытый чат гасит свои уведомления (ТЗ раздел 9)
--
-- Клиенту для ленты нужны маршрут, дата и то, кем получатель приходится поездке: одно и то же уведомление
-- (спор, отмена) уходит и водителю, и пассажиру, а ведёт на разные экраны. Контекст дописывает notify(),
-- поэтому его получают все типы, старые и будущие. План: docs/plans/0024_notification_context.md

-- Контекст поездки для получателя: по trip_id, а без него по booking_id. Ключи самого payload сильнее.
create or replace function public.notification_context(p_user_id uuid, p_payload jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_booking_id uuid;
  v_trip_id    uuid;
  v_context    jsonb;
begin
  -- payload пишут RPC, но текст в id не должен ронять операцию, которая шлёт уведомление
  begin
    v_booking_id := nullif(p_payload ->> 'booking_id', '')::uuid;
    v_trip_id    := nullif(p_payload ->> 'trip_id', '')::uuid;
  exception when invalid_text_representation then
    return p_payload;
  end;

  if v_trip_id is null and v_booking_id is not null then
    select trip_id into v_trip_id from public.bookings where id = v_booking_id;
  end if;
  if v_trip_id is null then
    return p_payload;
  end if;

  select jsonb_strip_nulls(jsonb_build_object(
    'trip_id', t.id,
    'origin_name', o.name,
    'destination_name', d.name,
    'departure_at', t.departure_at,
    'role', case
      when t.driver_id = p_user_id then 'driver'
      when exists (
        select 1 from public.bookings b
        where b.trip_id = t.id and b.passenger_id = p_user_id and (v_booking_id is null or b.id = v_booking_id)
      ) then 'passenger'
    end
  ))
  into v_context
  from public.trips t
  join public.places o on o.id = t.origin_place_id
  join public.places d on d.id = t.destination_place_id
  where t.id = v_trip_id;

  return coalesce(v_context, '{}'::jsonb) || p_payload;
end $$;

revoke all on function public.notification_context(uuid, jsonb) from public, anon, authenticated;

create or replace function public.notify(p_user_id uuid, p_type text, p_payload jsonb default '{}'::jsonb, p_allow_sms boolean default true, p_scheduled_for timestamp with time zone default null::timestamp with time zone)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_at    timestamptz := coalesce(p_scheduled_for, now());
  v_local timestamp   := v_at at time zone 'Africa/Luanda';
  v_deliver_at timestamptz := p_scheduled_for;
  v_urgent boolean := p_type like 'payment\_%' or p_type like 'booking\_%' or p_type like 'dispute\_%'
                   or p_type in ('trip_cancelled', 'refund_done', 'pin_ready', 'trip_reminder_2h', 'reconciliation_alert', 'driver_arrived');
  v_payload jsonb := public.notification_context(p_user_id, p_payload);
begin
  if not v_urgent and (v_local::time >= '22:00' or v_local::time < '07:00') then
    v_deliver_at := (date_trunc('day', v_local) + case when v_local::time >= '22:00' then interval '1 day' else interval '0' end
                     + interval '7 hours') at time zone 'Africa/Luanda';
  end if;

  insert into public.notifications (user_id, type, channel, payload, scheduled_for, status, sent_at)
  values (p_user_id, p_type, 'inapp', v_payload, p_scheduled_for, 'sent', now());
  if exists (select 1 from public.devices where user_id = p_user_id) then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'push', v_payload, v_deliver_at);
  elsif p_allow_sms then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'sms', v_payload, v_deliver_at);
  end if;
end $$;

-- mark_read: прочитанный чат гасит и свои уведомления new_message в ленте (только inapp: push и sms в очереди)
create or replace function public.mark_read(conversation_id uuid, up_to_message_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  p         public.profiles := public.current_profile();
  v_conv_id uuid := conversation_id;
  c         public.conversations;
begin
  select * into c from public.conversations where id = v_conv_id;
  if c.id is null or p.id not in (c.passenger_id, c.driver_id) then perform public.raise_boleia('NOT_PARTICIPANT'); end if;

  update public.messages set read_at = now()
  where messages.conversation_id = c.id and id <= up_to_message_id and read_at is null and sender_id is distinct from p.id;

  update public.conversations
  set passenger_seen_at = case when p.id = passenger_id then now() else passenger_seen_at end,
      driver_seen_at    = case when p.id = driver_id    then now() else driver_seen_at end
  where id = c.id;

  update public.notifications set read_at = now(), status = 'read'
  where user_id = p.id and type = 'new_message' and channel = 'inapp' and read_at is null
    and payload ->> 'conversation_id' = c.id::text;
end $$;
