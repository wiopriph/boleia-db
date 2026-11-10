-- Boleia - retry_payment сбрасывает cancel_reason (ТЗ раздел 5, машина состояний брони)
--
-- payment_failed -> pending_payment: причина прошлой неудачи (payment_expired, PAYMENT_PHONE_MISMATCH)
-- оставалась в брони и после успешной оплаты, клиент показывал её рядом с оплаченным статусом.

create or replace function public.retry_payment(booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
  v_payment_id uuid;
  v_expires    timestamptz := now() + interval '15 minutes';
begin
  if p.status = 'restricted' then perform public.raise_boleia('PROFILE_RESTRICTED'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  if b.passenger_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;

  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if b.status = 'pending_payment' then perform public.raise_boleia('PAYMENT_PENDING'); end if;
  if b.status <> 'payment_failed' then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if (select count(*) from public.payments where payments.booking_id = b.id) >= 3 then
    perform public.raise_boleia('PAYMENT_RETRY_LIMIT');
  end if;

  if t.status = 'full' then perform public.raise_boleia('TRIP_FULL'); end if;
  if t.status <> 'published' or t.departure_at <= now() + interval '1 hour' then
    perform public.raise_boleia('TRIP_NOT_BOOKABLE');
  end if;
  if b.seats > t.seats_available then perform public.raise_boleia('TRIP_FULL'); end if;

  update public.bookings set status = 'pending_payment', cancel_reason = null where id = b.id;

  insert into public.payments (booking_id, payer_id, amount_kz, expires_at)
  values (b.id, p.id, b.price_total_kz + b.fee_kz, v_expires)
  returning id into v_payment_id;

  perform public.notify(p.id, 'payment_pending',
    jsonb_build_object('booking_id', b.id, 'payment_id', v_payment_id,
                       'amount_kz', b.price_total_kz + b.fee_kz, 'expires_at', v_expires), false);
  perform public.log_event('payment_retry', jsonb_build_object('booking_id', b.id));

  return jsonb_build_object(
    'booking_id', b.id, 'payment_id', v_payment_id,
    'amount_kz', b.price_total_kz + b.fee_kz, 'price_total_kz', b.price_total_kz, 'fee_kz', b.fee_kz, 'expires_at', v_expires
  );
end $$;
