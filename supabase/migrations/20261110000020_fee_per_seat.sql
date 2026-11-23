-- Boleia - комиссия считается за место, а не за бронь (ТЗ раздел 10)
--
-- Было: max(10% x price_total_kz, 1000) один раз на бронь. Стало: max(10% x цена места, 1000) за каждое
-- место: 2 x 7000 = 14000 + 2000, а не 14000 + 1400. План: docs/plans/0020_fee_per_seat.md

drop function public.calc_fee_kz(integer);

create function public.calc_fee_kz(price_per_seat_kz integer, seats integer)
returns integer language sql immutable as $$
  select seats * greatest((price_per_seat_kz * 10 + 50) / 100, 1000)
$$;

revoke all on function public.calc_fee_kz(integer, integer) from public, anon, authenticated;

create or replace function public.request_booking(trip_id uuid, seats integer, message text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_trip_id    uuid := trip_id;
  v_seats      integer := seats;
  v_msg        text := nullif(btrim(message), '');
  t            public.trips;
  v_total      integer;
  v_fee        integer;
  v_booking_id uuid;
  v_payment_id uuid;
  v_expires    timestamptz := now() + interval '15 minutes';
begin
  if p.status = 'restricted' then perform public.raise_boleia('PROFILE_RESTRICTED'); end if;

  select * into t from public.trips where id = v_trip_id for update;
  if t.id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
  if t.status = 'full' then perform public.raise_boleia('TRIP_FULL'); end if;
  if t.status <> 'published' or t.departure_at <= now() + interval '1 hour' then
    perform public.raise_boleia('TRIP_NOT_BOOKABLE');
  end if;
  if v_seats is null or v_seats not between 1 and 3 then perform public.raise_boleia('SEATS_INVALID'); end if;
  if v_msg is not null and char_length(v_msg) > 300 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;

  if exists (
    select 1 from public.bookings
    where bookings.trip_id = v_trip_id and passenger_id = p.id
      and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm')
  ) then perform public.raise_boleia('BOOKING_DUPLICATE'); end if;

  if (select count(*) from public.bookings
      where passenger_id = p.id and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm')) >= 3 then
    perform public.raise_boleia('BOOKING_LIMIT_REACHED');
  end if;

  if v_seats > t.seats_available then perform public.raise_boleia('TRIP_FULL'); end if;

  v_total := v_seats * t.price_per_seat_kz;
  v_fee   := public.calc_fee_kz(t.price_per_seat_kz, v_seats);

  insert into public.bookings (trip_id, passenger_id, seats, price_total_kz, fee_kz, message)
  values (t.id, p.id, v_seats, v_total, v_fee, v_msg)
  returning id into v_booking_id;

  insert into public.payments (booking_id, payer_id, amount_kz, expires_at)
  values (v_booking_id, p.id, v_total + v_fee, v_expires)
  returning id into v_payment_id;

  perform public.notify(p.id, 'payment_pending',
    jsonb_build_object('booking_id', v_booking_id, 'payment_id', v_payment_id,
                       'amount_kz', v_total + v_fee, 'expires_at', v_expires), false);
  perform public.log_event('booking_requested', jsonb_build_object('trip_id', t.id, 'seats', v_seats, 'amount_kz', v_total + v_fee));

  return jsonb_build_object(
    'booking_id', v_booking_id, 'payment_id', v_payment_id,
    'amount_kz', v_total + v_fee, 'price_total_kz', v_total, 'fee_kz', v_fee, 'expires_at', v_expires
  );
end $$;
