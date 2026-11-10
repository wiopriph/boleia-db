-- Boleia - исправления по находкам web-клиента (ТЗ разделы 5, 6, 7, 12)
--
-- 1. publish_trip: notes > 500 давали нарушение check без кода BOLEIA -> MESSAGE_TOO_LONG.
-- 2. upsert_vehicle: seats_total вне 1-8 и year вне 1980-2030 -> SEATS_INVALID / YEAR_INVALID.
-- 3. refund_rule: водитель по брони в requested получал rule driver_cancel и counter = true, хотя
--    cancel_booking такую бронь отклоняет без счётчика -> driver_decline, counter = false.
-- 4. driver_wallet.earned_total_kz считал заработком возврат на баланс после неудачной выплаты.
-- 5. mark_no_show и cron "водитель не приехал" засчитывали PIN отменённой брони.
-- 6. my_bookings: passenger_rating_count, чтобы новичка не показывать с рейтингом 0,00.
-- План и решения: docs/plans/0015_contract_fixes.md

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
  if char_length(payload ->> 'notes') > 500 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;

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

CREATE OR REPLACE FUNCTION public.upsert_vehicle(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p    public.profiles := public.current_profile();
  v_id uuid := (payload ->> 'id')::uuid;
  v    public.vehicles;
begin
  if payload ? 'seats_total' and coalesce((payload ->> 'seats_total')::integer, 0) not between 1 and 8 then
    perform public.raise_boleia('SEATS_INVALID');
  end if;
  if (payload ->> 'year') is not null and (payload ->> 'year')::integer not between 1980 and 2030 then
    perform public.raise_boleia('YEAR_INVALID');
  end if;

  if v_id is not null then
    select * into v from public.vehicles where id = v_id and owner_id = p.id;
    if v.id is null then perform public.raise_boleia('VEHICLE_NOT_FOUND'); end if;

    update public.vehicles set
      make        = coalesce(payload ->> 'make', make),
      model       = coalesce(payload ->> 'model', model),
      color       = coalesce(payload ->> 'color', color),
      year        = coalesce((payload ->> 'year')::smallint, year),
      plate       = coalesce(payload ->> 'plate', plate),
      seats_total = coalesce((payload ->> 'seats_total')::smallint, seats_total),
      photo_url   = coalesce(payload ->> 'photo_url', photo_url),
      status      = coalesce((payload ->> 'status')::vehicle_status, status),
      verified    = case when payload ? 'plate' and payload ->> 'plate' is distinct from plate then false else verified end
    where id = v_id;
    return v_id;
  end if;

  if (select count(*) from public.vehicles where owner_id = p.id and status = 'active') >= 3 then
    perform public.raise_boleia('VEHICLE_LIMIT_REACHED');
  end if;
  if payload ->> 'make' is null or payload ->> 'model' is null or (payload ->> 'seats_total') is null then
    perform public.raise_boleia('VEHICLE_INCOMPLETE');
  end if;

  insert into public.vehicles (owner_id, make, model, color, year, plate, seats_total, photo_url)
  values (
    p.id,
    payload ->> 'make', payload ->> 'model', payload ->> 'color',
    (payload ->> 'year')::smallint, payload ->> 'plate',
    (payload ->> 'seats_total')::smallint, payload ->> 'photo_url'
  )
  returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.refund_rule(b bookings, t trips, p_by party)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_paid   integer := b.price_total_kz + b.fee_kz;
  v_fee    integer := 0;
  v_refund integer;
  v_rule   text;
  v_counter boolean := true;
begin
  if p_by = 'driver' then
    v_refund := v_paid;
    -- неотвеченный запрос водитель не отменяет, а отклоняет: cancel_booking делает то же, без счётчика
    if b.status = 'requested' then v_rule := 'driver_decline'; v_counter := false;
    else v_rule := 'driver_cancel'; end if;
  elsif t.driver_confirmed_at is null and now() >= t.departure_at - interval '6 hours' then
    v_refund := v_paid; v_rule := 'driver_unconfirmed'; v_counter := false;
  elsif b.status = 'requested' then
    v_fee := public.gateway_fee_kz(v_paid); v_refund := v_paid - v_fee; v_rule := 'passenger_withdraw';
  elsif now() < t.departure_at - interval '24 hours' then
    v_fee := public.gateway_fee_kz(v_paid); v_refund := v_paid - v_fee; v_rule := 'passenger_early';
  else
    v_refund := (v_paid + 1) / 2; v_rule := 'passenger_late';
  end if;

  return jsonb_build_object(
    'refund_kz', v_refund, 'gateway_fee_kz', v_fee,
    'held_kz', v_paid - v_refund - v_fee, 'rule', v_rule, 'counter', v_counter
  );
end $function$;

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

  -- PIN отменённой до выезда брони не доказывает, что кто-то сел
  if exists (select 1 from public.bookings where trip_id = t.id and id <> b.id and pin_entered_at is not null
             and status in ('awaiting_confirm', 'completed', 'disputed')) then
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
      and not exists (select 1 from public.bookings where trip_id = tr.id
                      and ((pin_entered_at is not null and status in ('awaiting_confirm', 'completed', 'disputed'))
                           or status in ('completed', 'no_show')))
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

-- Заработано = только release по завершённым поездкам; payout_failed возвращает уже учтённое
create or replace view public.driver_wallet as
select
  p.id as user_id,
  p.balance_kz,
  coalesce((
    select sum(b.price_total_kz)
    from public.bookings b join public.trips t on t.id = b.trip_id
    where t.driver_id = p.id and b.status in ('accepted', 'awaiting_confirm')
  ), 0) as pending_kz,
  coalesce((
    select sum(amount_kz) from public.ledger_entries
    where user_id = p.id and account = 'driver_balance' and amount_kz > 0 and memo like 'release:%'
  ), 0) as earned_total_kz,
  coalesce((
    select sum(amount_kz) from public.payouts
    where user_id = p.id and status in ('requested', 'processing')
  ), 0) as payouts_pending_kz,
  p.payout_method
from public.profiles p
where p.id = auth.uid();

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
  pp.no_shows         as passenger_no_shows,
  pp.rating_count     as passenger_rating_count
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
