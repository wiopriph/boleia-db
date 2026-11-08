-- Boleia - время ожидания опоздавших (ТЗ разделы 4, 5, 6, 9)
--
-- Резерв - контракт обеих сторон: пассажир к departure_at, водитель ждёт wait_minutes (30/45/60, выбирает
-- при публикации). До конца ожидания "não apareceu" невозможен (NO_SHOW_TOO_EARLY). Водитель отмечает
-- "Cheguei" (driver_arrived): пассажиры видят, что он на месте, а при споре это его ответ - cron не
-- отменяет поездку автоматически, решает модератор. План и решения: docs/plans/0013_wait_time.md

alter table public.trips
  add column wait_minutes      smallint not null default 30 check (wait_minutes in (30, 45, 60)),
  add column driver_arrived_at timestamptz;

-- publish_trip / update_trip / create_return_trip: ключ wait_minutes (30 | 45 | 60)
CREATE OR REPLACE FUNCTION public.publish_trip(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p            public.profiles := public.current_profile();
  v            public.vehicles;
  v_origin     uuid := (payload ->> 'origin_place_id')::uuid;
  v_dest       uuid := (payload ->> 'destination_place_id')::uuid;
  v_dep        timestamptz := (payload ->> 'departure_at')::timestamptz;
  v_seats      smallint := (payload ->> 'seats_offered')::smallint;
  v_price      integer := (payload ->> 'price_per_seat_kz')::integer;
  v_mode       booking_mode := coalesce((payload ->> 'booking_mode')::booking_mode, 'instant');
  v_wait       smallint := coalesce((payload ->> 'wait_minutes')::smallint, 30);
  v_hint       integer;
  v_id         uuid;
begin
  if p.avatar_url is null or p.payout_method is null or char_length(p.display_name) < 2 then
    perform public.raise_boleia('PROFILE_INCOMPLETE');
  end if;

  select * into v from public.vehicles
  where id = (payload ->> 'vehicle_id')::uuid and owner_id = p.id and status = 'active';
  if v.id is null then perform public.raise_boleia('VEHICLE_NOT_FOUND'); end if;

  if v_origin is null or v_dest is null then perform public.raise_boleia('PLACE_INVALID'); end if;
  if v_origin = v_dest then perform public.raise_boleia('SAME_PLACE'); end if;
  -- landmark (терминал, аэропорт) - это точка посадки в origin_detail, а не город маршрута:
  -- поиск идёт по slug города, и поездка от терминала иначе не найдётся
  if (select count(*) from public.places where id in (v_origin, v_dest) and is_active and kind in ('city', 'town')) <> 2 then
    perform public.raise_boleia('PLACE_INVALID');
  end if;

  if v_dep is null or v_dep < now() + interval '2 hours' then perform public.raise_boleia('DEPARTURE_TOO_SOON'); end if;
  if v_seats is null or v_seats < 1 or v_seats > least(4, v.seats_total) then perform public.raise_boleia('SEATS_INVALID'); end if;
  if v_price is null or v_price not between 500 and 100000 then perform public.raise_boleia('PRICE_INVALID'); end if;
  if v_wait not in (30, 45, 60) then perform public.raise_boleia('WAIT_INVALID'); end if;

  if (select count(*) from public.trips where driver_id = p.id and status in ('published', 'full')) >= 5 then
    perform public.raise_boleia('DRIVER_LIMIT_REACHED');
  end if;

  if exists (
    select 1 from public.trips
    where driver_id = p.id and status in ('published', 'full')
      and departure_at between v_dep - interval '2 hours' and v_dep + interval '2 hours'
  ) then
    perform public.raise_boleia('TRIP_DUPLICATE');
  end if;

  insert into public.trips (
    driver_id, vehicle_id, origin_place_id, destination_place_id,
    origin_detail, destination_detail, departure_at,
    seats_offered, seats_available, price_per_seat_kz, booking_mode, wait_minutes,
    luggage, allows_smoking, allows_pets, max_two_in_back, notes,
    status, published_at
  ) values (
    p.id, v.id, v_origin, v_dest,
    payload ->> 'origin_detail', payload ->> 'destination_detail', v_dep,
    v_seats, v_seats, v_price, v_mode, v_wait,
    coalesce((payload ->> 'luggage')::luggage_size, 'medium'),
    coalesce((payload ->> 'allows_smoking')::boolean, false),
    coalesce((payload ->> 'allows_pets')::boolean, false),
    coalesce((payload ->> 'max_two_in_back')::boolean, false),
    payload ->> 'notes',
    'published', now()
  )
  returning id into v_id;

  select price_hint_kz into v_hint from public.route_durations
  where origin_place_id = v_origin and destination_place_id = v_dest;

  perform public.log_event('trip_published', jsonb_build_object('trip_id', v_id, 'price', v_price));

  return jsonb_build_object('id', v_id, 'price_hint_kz', v_hint);
end $function$;

CREATE OR REPLACE FUNCTION public.update_trip(trip_id uuid, payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t         public.trips := public.trip_for_driver(trip_id);
  v         public.vehicles;
  v_allowed text[] := array['price_per_seat_kz', 'seats_offered', 'notes', 'luggage', 'allows_smoking', 'allows_pets',
                            'max_two_in_back', 'origin_detail', 'destination_detail', 'departure_at', 'booking_mode', 'wait_minutes'];
  v_details text[] := array['price_per_seat_kz', 'seats_offered', 'notes', 'luggage', 'allows_smoking', 'allows_pets',
                            'max_two_in_back', 'origin_detail', 'destination_detail', 'wait_minutes'];
  v_paid    boolean;
  v_any     boolean;
  v_taken   integer;
  v_dep     timestamptz;
begin
  if t.status not in ('published', 'full') then perform public.raise_boleia('TRIP_CLOSED'); end if;
  if exists (select 1 from jsonb_object_keys(coalesce(payload, '{}')) k where k <> all (v_allowed)) then
    perform public.raise_boleia('TRIP_FIELD_LOCKED');
  end if;

  select exists (select 1 from public.bookings where bookings.trip_id = t.id and status in ('requested', 'accepted', 'awaiting_confirm')),
         exists (select 1 from public.bookings where bookings.trip_id = t.id and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm')),
         coalesce((select sum(seats) from public.bookings where bookings.trip_id = t.id
                   and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm')), 0)
  into v_paid, v_any, v_taken;

  if payload ? 'booking_mode' then
    t.booking_mode := (payload ->> 'booking_mode')::booking_mode;
  end if;

  if payload ?| v_details then
    if v_paid then perform public.raise_boleia('TRIP_HAS_BOOKINGS'); end if;
    if payload ? 'price_per_seat_kz' then
      t.price_per_seat_kz := (payload ->> 'price_per_seat_kz')::integer;
      if t.price_per_seat_kz is null or t.price_per_seat_kz not between 500 and 100000 then perform public.raise_boleia('PRICE_INVALID'); end if;
    end if;
    if payload ? 'seats_offered' then
      select * into v from public.vehicles where id = t.vehicle_id;
      t.seats_offered := (payload ->> 'seats_offered')::smallint;
      if t.seats_offered is null or t.seats_offered < greatest(1, v_taken) or t.seats_offered > least(4, v.seats_total) then
        perform public.raise_boleia('SEATS_INVALID');
      end if;
    end if;
    if payload ? 'notes' then
      t.notes := nullif(btrim(payload ->> 'notes'), '');
      if char_length(t.notes) > 500 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;
    end if;
    if payload ? 'wait_minutes' then
      t.wait_minutes := (payload ->> 'wait_minutes')::smallint;
      if t.wait_minutes is null or t.wait_minutes not in (30, 45, 60) then perform public.raise_boleia('WAIT_INVALID'); end if;
    end if;
    if payload ? 'luggage'            then t.luggage            := (payload ->> 'luggage')::luggage_size; end if;
    if payload ? 'allows_smoking'     then t.allows_smoking     := (payload ->> 'allows_smoking')::boolean; end if;
    if payload ? 'allows_pets'        then t.allows_pets        := (payload ->> 'allows_pets')::boolean; end if;
    if payload ? 'max_two_in_back'    then t.max_two_in_back    := (payload ->> 'max_two_in_back')::boolean; end if;
    if payload ? 'origin_detail'      then t.origin_detail      := nullif(btrim(payload ->> 'origin_detail'), ''); end if;
    if payload ? 'destination_detail' then t.destination_detail := nullif(btrim(payload ->> 'destination_detail'), ''); end if;
  end if;

  if payload ? 'departure_at' then
    if v_any then perform public.raise_boleia('TRIP_HAS_BOOKINGS'); end if;
    v_dep := (payload ->> 'departure_at')::timestamptz;
    if v_dep is null or v_dep < now() + interval '2 hours' then perform public.raise_boleia('DEPARTURE_TOO_SOON'); end if;
    if exists (
      select 1 from public.trips where driver_id = t.driver_id and id <> t.id and status in ('published', 'full')
        and trips.departure_at between v_dep - interval '2 hours' and v_dep + interval '2 hours'
    ) then perform public.raise_boleia('TRIP_DUPLICATE'); end if;
    t.departure_at := v_dep;
    t.driver_confirmed_at := null;
  end if;

  t.seats_available := greatest(t.seats_offered - v_taken, 0);
  t.status := case when t.seats_available = 0 then 'full'::trip_status else 'published'::trip_status end;

  update public.trips set
    booking_mode = t.booking_mode, wait_minutes = t.wait_minutes, price_per_seat_kz = t.price_per_seat_kz, seats_offered = t.seats_offered,
    seats_available = t.seats_available, status = t.status, notes = t.notes, luggage = t.luggage,
    allows_smoking = t.allows_smoking, allows_pets = t.allows_pets, max_two_in_back = t.max_two_in_back,
    origin_detail = t.origin_detail, destination_detail = t.destination_detail,
    departure_at = t.departure_at, driver_confirmed_at = t.driver_confirmed_at
  where id = t.id;
  perform public.log_event('trip_updated', jsonb_build_object('trip_id', t.id, 'keys', (select jsonb_agg(k) from jsonb_object_keys(payload) k)));
end $function$;

CREATE OR REPLACE FUNCTION public.create_return_trip(trip_id uuid, departure_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p public.profiles := public.current_profile();
  t public.trips;
  r jsonb;
begin
  select * into t from public.trips where id = create_return_trip.trip_id;
  if t.id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
  if t.driver_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;

  r := public.publish_trip(jsonb_build_object(
    'vehicle_id',           t.vehicle_id,
    'origin_place_id',      t.destination_place_id,
    'destination_place_id', t.origin_place_id,
    'origin_detail',        t.destination_detail,
    'destination_detail',   t.origin_detail,
    'departure_at',         create_return_trip.departure_at,
    'seats_offered',        t.seats_offered,
    'price_per_seat_kz',    t.price_per_seat_kz,
    'booking_mode',         t.booking_mode,
    'luggage',              t.luggage,
    'allows_smoking',       t.allows_smoking,
    'allows_pets',          t.allows_pets,
    'max_two_in_back',      t.max_two_in_back,
    'wait_minutes',         t.wait_minutes,
    'notes',                t.notes
  ));
  return (r ->> 'id')::uuid;
end $function$;

-- mark_no_show: не раньше конца ожидания
CREATE OR REPLACE FUNCTION public.mark_no_show(booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
  v_amount     integer;
  v_conv       uuid;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if t.driver_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status <> 'awaiting_confirm' then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if now() > t.departure_at + interval '48 hours' then perform public.raise_boleia('NO_SHOW_WINDOW_CLOSED'); end if;
  -- контракт ожидания: водитель ждёт опоздавших wait_minutes после departure_at (ТЗ раздел 5)
  if now() < t.departure_at + make_interval(mins => t.wait_minutes) then perform public.raise_boleia('NO_SHOW_TOO_EARLY'); end if;
  if b.pin_entered_at is not null then perform public.raise_boleia('NO_SHOW_NEEDS_PIN'); end if;

  v_conv := public.ensure_conversation(t.id, b.passenger_id, b.id);

  if exists (select 1 from public.bookings where trip_id = t.id and id <> b.id and pin_entered_at is not null) then
    v_amount := public.escrow_balance_kz(b.id);
    update public.bookings set status = 'no_show', driver_confirmed_at = now(), completed_at = now() where id = b.id;
    if v_amount > 0 then
      perform public.ledger_release(b, v_amount);
      perform public.notify(t.driver_id, 'payout_released',
        jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'amount_kz', public.driver_share_kz(b, v_amount), 'reason', 'no_show'), false);
    end if;
    update public.profiles set no_shows = no_shows + 1 where id = b.passenger_id;
    perform public.system_message(v_conv, 'O condutor indicou que o passageiro não apareceu. Reserva fechada sem reembolso.');
    perform public.notify(b.passenger_id, 'booking_no_show', jsonb_build_object('booking_id', b.id, 'trip_id', t.id), true);
    perform public.log_event('no_show', jsonb_build_object('booking_id', b.id));
    perform public.settle_trip(t.id);
  elsif not exists (
    select 1 from public.bookings where trip_id = t.id and id <> b.id
      and status in ('accepted', 'awaiting_confirm', 'completed', 'no_show', 'disputed')
  ) then
    -- единственный пассажир без PIN: решает модератор
    update public.bookings set status = 'disputed', driver_confirmed_at = now() where id = b.id;
    perform public.system_message(v_conv, 'O condutor indicou que o passageiro não apareceu. A moderação vai analisar.');
    perform public.notify(b.passenger_id, 'dispute_opened', jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'by', 'driver'), true);
    perform public.log_event('dispute_opened', jsonb_build_object('booking_id', b.id, 'by', 'driver'));
  else
    perform public.raise_boleia('NO_SHOW_NEEDS_PIN');
  end if;
end $function$;

-- cron: отметка водителя считается ответом на спор
CREATE OR REPLACE FUNCTION public.sch_driver_no_show(as_of timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.trips; b public.bookings; v_amount integer; n integer := 0;
begin
  for t in
    select tr.* from public.trips tr
    where tr.status = 'departed'
      and tr.driver_arrived_at is null  -- отметка "Cheguei" = ответ водителя, спор ждёт модератора
      and not exists (select 1 from public.bookings where trip_id = tr.id and (pin_entered_at is not null or status in ('completed', 'no_show')))
      and exists (select 1 from public.bookings d where d.trip_id = tr.id and d.status = 'disputed'
                  and d.passenger_confirmed_at is not null and d.passenger_confirmed_at + interval '24 hours' <= as_of)
      and not exists (
        select 1 from public.messages m
        join public.conversations c on c.id = m.conversation_id
        join public.bookings d on d.id = c.booking_id
        where d.trip_id = tr.id and d.status = 'disputed' and m.sender_id = tr.driver_id and m.created_at >= d.passenger_confirmed_at
      )
  loop
    select * into t from public.trips where id = t.id for update;
    if t.status <> 'departed' then continue; end if;

    for b in select * from public.bookings where trip_id = t.id and status in ('awaiting_confirm', 'disputed') for update loop
      v_amount := public.escrow_balance_kz(b.id);
      update public.bookings set status = 'cancelled', cancelled_at = as_of, cancelled_by = 'driver', cancel_reason = 'driver_no_show' where id = b.id;
      if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
      perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
        'O condutor não compareceu. Reembolso total em 1 a 3 dias úteis.');
      perform public.notify(b.passenger_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'reason', 'driver_no_show', 'refund_kz', v_amount), true);
    end loop;

    update public.trips set status = 'cancelled', cancelled_at = as_of, cancel_reason = 'driver_no_show' where id = t.id;
    perform public.forfeit_trip_holds(t.id);
    update public.profiles set cancels_total = cancels_total + 1, no_shows = no_shows + 1 where id = t.driver_id;
    perform public.notify(t.driver_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'reason', 'driver_no_show'), true);
    n := n + 1;
  end loop;
  return n;
end $function$;

-- pin_ready: до какого времени ждёт водитель
CREATE OR REPLACE FUNCTION public.sch_send_pins(as_of timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_first boolean; n integer := 0;
begin
  for r in
    select b.id as booking_id, b.passenger_id, b.pin_code, t.id as trip_id, t.driver_id, t.departure_at, t.wait_minutes
    from public.bookings b join public.trips t on t.id = b.trip_id
    where b.status in ('accepted', 'awaiting_confirm') and b.pin_sent_at is null and b.pin_code is not null
      and t.status in ('published', 'full', 'departed') and t.departure_at <= as_of + interval '2 hours'
    order by t.id, b.created_at
  loop
    v_first := not exists (select 1 from public.bookings where trip_id = r.trip_id and pin_sent_at is not null);

    perform public.system_message(public.ensure_conversation(r.trip_id, r.passenger_id, r.booking_id),
      'O seu PIN de embarque: ' || r.pin_code || '. Diga-o ao condutor ao entrar no carro.');
    perform public.notify(r.passenger_id, 'pin_ready', jsonb_build_object(
      'booking_id', r.booking_id, 'trip_id', r.trip_id, 'pin', r.pin_code, 'departure_at', r.departure_at,
      'wait_until', r.departure_at + make_interval(mins => r.wait_minutes),
      'driver_phone', (select phone from public.profiles where id = r.driver_id)), true);
    update public.bookings set pin_sent_at = as_of where id = r.booking_id;

    if v_first then
      perform public.notify(r.driver_id, 'trip_reminder_2h', jsonb_build_object(
        'trip_id', r.trip_id, 'departure_at', r.departure_at,
        'passengers', (select jsonb_agg(jsonb_build_object('booking_id', b2.id, 'name', p2.display_name, 'phone', p2.phone, 'seats', b2.seats))
                       from public.bookings b2 join public.profiles p2 on p2.id = b2.passenger_id
                       where b2.trip_id = r.trip_id and b2.status in ('accepted', 'awaiting_confirm'))), true);
    end if;
    n := n + 1;
  end loop;
  return n;
end $function$;

-- notify: driver_arrived срочное, тихие часы не задерживают
CREATE OR REPLACE FUNCTION public.notify(p_user_id uuid, p_type text, p_payload jsonb DEFAULT '{}'::jsonb, p_allow_sms boolean DEFAULT true, p_scheduled_for timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_at    timestamptz := coalesce(p_scheduled_for, now());
  v_local timestamp   := v_at at time zone 'Africa/Luanda';
  v_deliver_at timestamptz := p_scheduled_for;
  v_urgent boolean := p_type like 'payment\_%' or p_type like 'booking\_%' or p_type like 'dispute\_%'
                   or p_type in ('trip_cancelled', 'refund_done', 'pin_ready', 'trip_reminder_2h', 'reconciliation_alert', 'driver_arrived');
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
end $function$;

-- ---------------------------------------------------------------------------
-- Views: wait_minutes и driver_arrived_at наружу (колонки добавляются в конец)
-- ---------------------------------------------------------------------------
create or replace view public.trips_public as
select
  t.id,
  t.status,
  t.departure_at,
  t.seats_offered,
  t.seats_available,
  t.price_per_seat_kz,
  t.currency,
  t.booking_mode,
  t.luggage,
  t.allows_smoking,
  t.allows_pets,
  t.max_two_in_back,
  t.notes,
  t.origin_detail,
  t.destination_detail,
  t.published_at,
  o.id        as origin_place_id,
  o.name      as origin_name,
  o.slug      as origin_slug,
  o.province  as origin_province,
  d.id        as destination_place_id,
  d.name      as destination_name,
  d.slug      as destination_slug,
  d.province  as destination_province,
  rd.minutes  as duration_minutes,
  p.id            as driver_id,
  p.display_name  as driver_name,
  p.avatar_url    as driver_avatar_url,
  p.rating_avg    as driver_rating_avg,
  p.rating_count  as driver_rating_count,
  p.trips_driven  as driver_trips_driven,
  (p.driver_status = 'verified') as driver_verified,
  p.cancels_total as driver_cancels_total,
  p.chat_level    as driver_chat_level,
  v.make      as vehicle_make,
  v.model     as vehicle_model,
  v.color     as vehicle_color,
  v.photo_url as vehicle_photo_url,
  v.verified  as vehicle_verified,
  t.wait_minutes
from public.trips t
join public.places   o  on o.id = t.origin_place_id
join public.places   d  on d.id = t.destination_place_id
join public.profiles p  on p.id = t.driver_id
join public.vehicles v  on v.id = t.vehicle_id
left join public.route_durations rd
  on rd.origin_place_id = t.origin_place_id and rd.destination_place_id = t.destination_place_id
where t.status in ('published', 'full')
  and p.status in ('active', 'restricted');

create or replace view public.my_bookings as
select
  b.id,
  b.trip_id,
  b.passenger_id,
  b.seats,
  b.price_total_kz,
  b.fee_kz,
  b.price_total_kz + b.fee_kz as paid_total_kz,
  b.status,
  case when b.status in ('accepted', 'awaiting_confirm')
        and now() >= t.departure_at - interval '2 hours'
       then b.pin_code else null end as pin_code,
  b.pin_entered_at,
  b.requested_at,
  b.responded_at,
  b.cancelled_at,
  b.cancelled_by,
  b.refund_kz,
  b.passenger_confirmed_at,
  b.completed_at,
  b.created_at,
  t.departure_at,
  t.status            as trip_status,
  t.booking_mode,
  t.origin_detail,
  t.destination_detail,
  o.name              as origin_name,
  o.slug              as origin_slug,
  d.name              as destination_name,
  d.slug              as destination_slug,
  t.driver_id,
  dp.display_name     as driver_name,
  dp.avatar_url       as driver_avatar_url,
  pay.status          as payment_status,
  pay.expires_at      as payment_expires_at,
  c.id                as conversation_id,
  v.make              as vehicle_make,
  v.model             as vehicle_model,
  v.color             as vehicle_color,
  v.photo_url         as vehicle_photo_url,
  right(v.plate, 3)   as vehicle_plate_suffix,
  b.cancel_reason,
  b.message,
  pp.display_name     as passenger_name,
  pp.avatar_url       as passenger_avatar_url,
  pp.rating_avg       as passenger_rating_avg,
  pp.trips_ridden     as passenger_trips_ridden,
  pp.cancels_total    as passenger_cancels_total,
  t.wait_minutes,
  t.departure_at + make_interval(mins => t.wait_minutes) as wait_until,
  t.driver_arrived_at,
  pp.no_shows         as passenger_no_shows
from public.bookings b
join public.trips    t  on t.id = b.trip_id
join public.places   o  on o.id = t.origin_place_id
join public.places   d  on d.id = t.destination_place_id
join public.profiles dp on dp.id = t.driver_id
join public.profiles pp on pp.id = b.passenger_id
join public.vehicles v  on v.id = t.vehicle_id
left join lateral (
  select status, expires_at from public.payments
  where booking_id = b.id order by created_at desc limit 1
) pay on true
left join public.conversations c on c.trip_id = b.trip_id and c.passenger_id = b.passenger_id
where b.passenger_id = auth.uid() or t.driver_id = auth.uid() or public.is_admin();

-- ---------------------------------------------------------------------------
-- driver_arrived - водитель на месте встречи
-- ---------------------------------------------------------------------------
create or replace function public.driver_arrived(trip_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t       public.trips := public.trip_for_driver(trip_id);
  b       public.bookings;
  v_until timestamptz;
begin
  if t.status not in ('published', 'full', 'departed') then perform public.raise_boleia('TRIP_CLOSED'); end if;
  v_until := t.departure_at + make_interval(mins => t.wait_minutes);
  if now() < t.departure_at - interval '3 hours' or now() > v_until then perform public.raise_boleia('ARRIVAL_WINDOW_CLOSED'); end if;
  if t.driver_arrived_at is not null then
    return jsonb_build_object('driver_arrived_at', t.driver_arrived_at, 'wait_until', v_until, 'already', true);
  end if;

  update public.trips set driver_arrived_at = now() where id = t.id;
  for b in select * from public.bookings where bookings.trip_id = t.id and status in ('accepted', 'awaiting_confirm') loop
    perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
      'O condutor chegou ao ponto de encontro. Espera até ' || to_char(v_until at time zone 'Africa/Luanda', 'HH24:MI') || '.');
    perform public.notify(b.passenger_id, 'driver_arrived',
      jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'wait_until', v_until), true);
  end loop;
  perform public.log_event('driver_arrived', jsonb_build_object('trip_id', t.id));
  return jsonb_build_object('driver_arrived_at', now(), 'wait_until', v_until);
end $$;

revoke all on function public.driver_arrived(uuid) from public, anon, authenticated;
grant execute on function public.driver_arrived(uuid) to authenticated;
