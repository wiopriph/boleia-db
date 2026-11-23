-- Boleia - PIN посадки виден только пассажиру (ТЗ разделы 4, 6, 9, 10)
--
-- PIN доказывает, что пассажир сел: от него зависят споры, no_show и срок автозавершения. Водитель
-- читал его четырьмя путями: системное сообщение в общем чате, превью в my_conversations,
-- my_bookings.pin_code и колонка bookings.pin_code напрямую (в том числе через realtime).
-- План: docs/plans/0021_pin_privacy.md

-- 1. Колонка pin_code закрыта от клиентов; новые колонки bookings нужно добавлять в этот grant.
--    Realtime отдаёт только колонки, на которые у роли есть select. anon сохраняет прежнее поведение:
--    запрос проходит, RLS не отдаёт строк.
revoke select on public.bookings from anon, authenticated;
grant select (
  id, trip_id, passenger_id, seats, price_total_kz, fee_kz, message, status, pin_entered_at, requested_at,
  responded_at, cancelled_at, cancelled_by, cancel_reason, refund_kz, passenger_confirmed_at,
  driver_confirmed_at, completed_at, created_at, updated_at, pin_sent_at
) on public.bookings to anon, authenticated;

-- 2. my_bookings: pin_code только пассажиру брони и админу (колонки и порядок прежние)
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
        and (b.passenger_id = auth.uid() or public.is_admin())
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

-- 3. sch_send_pins: в чат уходит только факт, что PIN готов; сам PIN остаётся в pin_ready и my_bookings
create or replace function public.sch_send_pins(as_of timestamp with time zone)
returns integer language plpgsql security definer set search_path = public as $$
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
      'O PIN de embarque já está disponível para o passageiro, na página da reserva. O passageiro diz o PIN ao condutor ao entrar no carro.');
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
end $$;

-- 4. Уже отправленные сообщения с PIN: цифры убираются
update public.messages
set body = 'O PIN de embarque já está disponível para o passageiro, na página da reserva. O passageiro diz o PIN ao condutor ao entrar no carro.'
where sender_id is null and body ~ '^O seu PIN de embarque: \d{4}\.';
