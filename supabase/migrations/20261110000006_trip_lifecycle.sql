-- Boleia - trip lifecycle (ТЗ разделы 5, 6, 10, 11)
--
-- Тела enter_pin, confirm_trip, mark_no_show, resolve_dispute, confirm_trip_intent, cancel_trip,
-- create_return_trip, update_trip; финализация брони и поездки (complete_booking, settle_trip),
-- которую переиспользует cron 0007. План и решения: docs/plans/0006_trip_lifecycle.md

-- Решение модератора по спору пишется в moderation_actions (ТЗ раздел 6).
alter type public.mod_action add value if not exists 'resolve_dispute';

-- ---------------------------------------------------------------------------
-- notify: отложенная доставка (review_request через 24 ч)
-- ---------------------------------------------------------------------------
drop function public.notify(uuid, text, jsonb, boolean);
create or replace function public.notify(
  p_user_id uuid, p_type text, p_payload jsonb default '{}', p_allow_sms boolean default true,
  p_scheduled_for timestamptz default null
)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, channel, payload, scheduled_for)
  values (p_user_id, p_type, 'inapp', p_payload, p_scheduled_for);
  if exists (select 1 from public.devices where user_id = p_user_id) then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'push', p_payload, p_scheduled_for);
  elsif p_allow_sms then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'sms', p_payload, p_scheduled_for);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Внутренние функции
-- ---------------------------------------------------------------------------
create or replace function public.trip_for_driver(p_trip_id uuid)
returns public.trips language plpgsql security definer set search_path = public as $$
declare
  p public.profiles := public.current_profile();
  t public.trips;
begin
  select * into t from public.trips where id = p_trip_id for update;
  if t.id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
  if t.driver_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  return t;
end $$;

-- Доля водителя в сумме эскроу: цена без комиссии платформы, пропорционально
create or replace function public.driver_share_kz(b public.bookings, p_amount_kz integer)
returns integer language sql immutable as $$
  select (p_amount_kz::bigint * b.price_total_kz / (b.price_total_kz + b.fee_kz))::integer
$$;

-- Поездка закрывается, когда все брони дошли до финала. Удержанные 50 % после поздних отмен
-- пассажиров уходят водителю. trips_driven считается на поездку, не на бронь.
create or replace function public.settle_trip(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  t      public.trips;
  b      public.bookings;
  v_held integer;
begin
  select * into t from public.trips where id = p_trip_id for update;
  if t.status <> 'departed' then return; end if;
  if exists (
    select 1 from public.bookings where trip_id = t.id
      and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm', 'disputed')
  ) then return; end if;

  for b in select * from public.bookings where trip_id = t.id and status = 'cancelled' and cancelled_by = 'passenger' loop
    v_held := public.escrow_balance_kz(b.id);
    if v_held > 0 then
      perform public.ledger_release(b, v_held);
      perform public.notify(t.driver_id, 'payout_released',
        jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'amount_kz', public.driver_share_kz(b, v_held), 'reason', 'late_cancel_hold'), false);
    end if;
  end loop;

  update public.trips set status = 'completed', completed_at = now() where id = t.id;
  if exists (select 1 from public.bookings where trip_id = t.id and status in ('completed', 'no_show')) then
    update public.profiles set trips_driven = trips_driven + 1 where id = t.driver_id;
  end if;
end $$;

-- Поездка не состоялась: удержанные 50 % уходят платформе (ТЗ раздел 5).
create or replace function public.forfeit_trip_holds(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_held integer;
begin
  for b in select * from public.bookings where trip_id = p_trip_id and status = 'cancelled' and cancelled_by = 'passenger' loop
    v_held := public.escrow_balance_kz(b.id);
    if v_held > 0 then perform public.ledger_forfeit(b, v_held); end if;
  end loop;
end $$;

-- Финал брони с деньгами водителю.
create or replace function public.complete_booking(b public.bookings, p_by party)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_amount integer := public.escrow_balance_kz(b.id);
  t        public.trips;
begin
  select * into t from public.trips where id = b.trip_id;

  update public.bookings
  set status = 'completed', completed_at = now(),
      passenger_confirmed_at = case when p_by = 'passenger' then now() else passenger_confirmed_at end,
      driver_confirmed_at    = case when p_by = 'driver'    then now() else driver_confirmed_at end
  where id = b.id;

  if v_amount > 0 then
    perform public.ledger_release(b, v_amount);
    perform public.notify(t.driver_id, 'payout_released',
      jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'amount_kz', public.driver_share_kz(b, v_amount)), false);
  end if;

  update public.profiles set trips_ridden = trips_ridden + 1 where id = b.passenger_id;

  perform public.notify(b.passenger_id, 'review_request', jsonb_build_object('booking_id', b.id), false, now() + interval '24 hours');
  perform public.notify(t.driver_id,    'review_request', jsonb_build_object('booking_id', b.id), false, now() + interval '24 hours');

  perform public.settle_trip(b.trip_id);
end $$;

-- 5 неверных PIN за 10 минут -> блок (ТЗ раздел 6). Попытки хранятся в events.
create or replace function public.pin_attempts_blocked(p_driver_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select count(*) >= 5 from public.events
  where user_id = p_driver_id and name = 'pin_failed' and created_at > now() - interval '10 minutes'
$$;

-- ---------------------------------------------------------------------------
-- enter_pin - водитель. Возвращает {ok, attempts_left}: неверный PIN не бросает ошибку,
-- иначе откатилась бы запись о попытке и лимит 5 за 10 минут не работал бы.
-- ---------------------------------------------------------------------------
drop function public.enter_pin(uuid, text);
create or replace function public.enter_pin(booking_id uuid, pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  v_pin        text := btrim(pin);
  b            public.bookings;
  t            public.trips;
  v_failed     integer;
begin
  if v_pin !~ '^\d{4}$' then perform public.raise_boleia('PIN_INVALID'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if t.driver_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status not in ('accepted', 'awaiting_confirm') then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if now() < t.departure_at - interval '3 hours' or now() > t.departure_at + interval '24 hours' then
    perform public.raise_boleia('PIN_WINDOW_CLOSED');
  end if;
  if b.pin_entered_at is not null then
    return jsonb_build_object('ok', true, 'pin_entered_at', b.pin_entered_at, 'already', true);
  end if;
  if public.pin_attempts_blocked(p.id) then perform public.raise_boleia('RATE_LIMITED'); end if;

  if b.pin_code is null or b.pin_code <> v_pin then
    insert into public.events (user_id, name, props) values (p.id, 'pin_failed', jsonb_build_object('booking_id', b.id));
    select count(*) into v_failed from public.events
    where user_id = p.id and name = 'pin_failed' and created_at > now() - interval '10 minutes';
    return jsonb_build_object('ok', false, 'attempts_left', greatest(5 - v_failed, 0));
  end if;

  update public.bookings set pin_entered_at = now() where id = b.id;
  perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id), 'Passageiro a bordo. PIN confirmado.');
  perform public.log_event('pin_entered', jsonb_build_object('booking_id', b.id));
  return jsonb_build_object('ok', true, 'pin_entered_at', now());
end $$;

-- ---------------------------------------------------------------------------
-- confirm_trip - пассажир: "Вы доехали?"
-- ---------------------------------------------------------------------------
create or replace function public.confirm_trip(booking_id uuid, happened boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if b.passenger_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status <> 'awaiting_confirm' then perform public.raise_boleia('BOOKING_CLOSED'); end if;

  if happened then
    perform public.complete_booking(b, 'passenger');
    perform public.log_event('trip_confirmed', jsonb_build_object('booking_id', b.id));
  else
    update public.bookings set status = 'disputed', passenger_confirmed_at = now() where id = b.id;
    perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
      'O passageiro indicou que a viagem não aconteceu. A moderação vai analisar o chat e o PIN.');
    perform public.notify(t.driver_id, 'dispute_opened', jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'by', 'passenger'), true);
    perform public.log_event('dispute_opened', jsonb_build_object('booking_id', b.id, 'by', 'passenger'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- mark_no_show - водитель: только при PIN другого пассажира (ТЗ раздел 6)
-- ---------------------------------------------------------------------------
create or replace function public.mark_no_show(booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------------
-- resolve_dispute - admin
-- ---------------------------------------------------------------------------
create or replace function public.resolve_dispute(booking_id uuid, outcome text, amount_kz integer default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles;
  v_booking_id uuid := booking_id;
  v_amount     integer := amount_kz;
  b            public.bookings;
  t            public.trips;
  v_escrow     integer;
begin
  if not public.is_admin() then perform public.raise_boleia('NOT_ADMIN'); end if;
  p := public.current_profile();
  if outcome not in ('completed', 'refund_full', 'refund_partial') then perform public.raise_boleia('DISPUTE_OUTCOME_INVALID'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;
  if b.status <> 'disputed' then perform public.raise_boleia('BOOKING_CLOSED'); end if;

  v_escrow := public.escrow_balance_kz(b.id);

  if outcome = 'completed' then
    perform public.complete_booking(b, 'driver');

  elsif outcome = 'refund_full' then
    perform public.ledger_refund(b, v_escrow, 0);
    update public.bookings
    set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system', cancel_reason = 'dispute_refund'
    where id = b.id;
    update public.profiles set no_shows = no_shows + 1 where id = t.driver_id;
    perform public.notify(b.passenger_id, 'refund_done', jsonb_build_object('booking_id', b.id, 'refund_kz', v_escrow, 'reason', 'dispute'), true);
    perform public.settle_trip(t.id);

  else
    if v_amount is null or v_amount < 1 or v_amount >= v_escrow then perform public.raise_boleia('DISPUTE_AMOUNT_INVALID'); end if;
    perform public.ledger_refund(b, v_amount, 0);
    perform public.ledger_release(b, v_escrow - v_amount);
    update public.bookings set status = 'completed', completed_at = now(), driver_confirmed_at = now() where id = b.id;
    update public.profiles set trips_ridden = trips_ridden + 1 where id = b.passenger_id;
    perform public.notify(b.passenger_id, 'refund_done', jsonb_build_object('booking_id', b.id, 'refund_kz', v_amount, 'reason', 'dispute'), true);
    perform public.notify(t.driver_id, 'payout_released',
      jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'amount_kz', public.driver_share_kz(b, v_escrow - v_amount), 'reason', 'dispute'), false);
    perform public.settle_trip(t.id);
  end if;

  insert into public.moderation_actions (admin_id, target_user_id, action, reason)
  values (p.id, b.passenger_id, 'resolve_dispute', outcome || coalesce(':' || v_amount, ''));
  perform public.notify(t.driver_id,    'dispute_resolved', jsonb_build_object('booking_id', b.id, 'outcome', outcome), true);
  perform public.notify(b.passenger_id, 'dispute_resolved', jsonb_build_object('booking_id', b.id, 'outcome', outcome), true);
end $$;

-- ---------------------------------------------------------------------------
-- confirm_trip_intent - водитель: ответ на напоминание за 24 ч
-- ---------------------------------------------------------------------------
create or replace function public.confirm_trip_intent(trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips := public.trip_for_driver(trip_id);
begin
  if t.status not in ('published', 'full') then perform public.raise_boleia('TRIP_CLOSED'); end if;
  update public.trips set driver_confirmed_at = now() where id = t.id;
end $$;

-- ---------------------------------------------------------------------------
-- cancel_trip - водитель: каскад по броням, полный возврат, cancels_total +1
-- ---------------------------------------------------------------------------
create or replace function public.cancel_trip(trip_id uuid, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  t        public.trips := public.trip_for_driver(trip_id);
  v_reason text := nullif(btrim(reason), '');
  b        public.bookings;
  v_amount integer;
  v_paid   integer := 0;
begin
  if t.status not in ('draft', 'published', 'full') then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;

  for b in select * from public.bookings where bookings.trip_id = t.id
           and status in ('pending_payment', 'requested', 'accepted') for update loop
    if b.status = 'pending_payment' then
      update public.bookings set status = 'payment_failed', cancel_reason = 'trip_cancelled' where id = b.id;
      perform public.notify(b.passenger_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'refund_kz', 0), true);
    else
      v_amount := public.escrow_balance_kz(b.id);
      update public.bookings
      set status = 'cancelled', cancelled_at = now(), cancelled_by = 'driver', cancel_reason = v_reason
      where id = b.id;
      if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
      v_paid := v_paid + 1;
      perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
        'Viagem cancelada pelo condutor. O reembolso total chega em 1 a 3 dias úteis.');
      perform public.notify(b.passenger_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'refund_kz', v_amount), true);
    end if;
  end loop;

  update public.trips set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason where id = t.id;
  perform public.forfeit_trip_holds(t.id);

  if v_paid > 0 then
    update public.profiles set cancels_total = cancels_total + 1 where id = t.driver_id;
  end if;
  perform public.log_event('trip_cancelled', jsonb_build_object('trip_id', t.id, 'paid_bookings', v_paid));
end $$;

-- ---------------------------------------------------------------------------
-- create_return_trip - копия с перестановкой городов через publish_trip
-- ---------------------------------------------------------------------------
create or replace function public.create_return_trip(trip_id uuid, departure_at timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
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
    'notes',                t.notes
  ));
  return (r ->> 'id')::uuid;
end $$;

-- ---------------------------------------------------------------------------
-- update_trip - водитель: что можно менять и когда (ТЗ раздел 6)
-- ---------------------------------------------------------------------------
create or replace function public.update_trip(trip_id uuid, payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  t         public.trips := public.trip_for_driver(trip_id);
  v         public.vehicles;
  v_allowed text[] := array['price_per_seat_kz', 'seats_offered', 'notes', 'luggage', 'allows_smoking', 'allows_pets',
                            'max_two_in_back', 'origin_detail', 'destination_detail', 'departure_at', 'booking_mode'];
  v_details text[] := array['price_per_seat_kz', 'seats_offered', 'notes', 'luggage', 'allows_smoking', 'allows_pets',
                            'max_two_in_back', 'origin_detail', 'destination_detail'];
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
    booking_mode = t.booking_mode, price_per_seat_kz = t.price_per_seat_kz, seats_offered = t.seats_offered,
    seats_available = t.seats_available, status = t.status, notes = t.notes, luggage = t.luggage,
    allows_smoking = t.allows_smoking, allows_pets = t.allows_pets, max_two_in_back = t.max_two_in_back,
    origin_detail = t.origin_detail, destination_detail = t.destination_detail,
    departure_at = t.departure_at, driver_confirmed_at = t.driver_confirmed_at
  where id = t.id;
  perform public.log_event('trip_updated', jsonb_build_object('trip_id', t.id, 'keys', (select jsonb_agg(k) from jsonb_object_keys(payload) k)));
end $$;

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------
revoke all on function
  public.notify(uuid, text, jsonb, boolean, timestamptz),
  public.trip_for_driver(uuid),
  public.driver_share_kz(public.bookings, integer),
  public.settle_trip(uuid),
  public.forfeit_trip_holds(uuid),
  public.complete_booking(public.bookings, party),
  public.pin_attempts_blocked(uuid),
  public.enter_pin(uuid, text)
from public, anon, authenticated;

grant execute on function public.enter_pin(uuid, text) to authenticated;
