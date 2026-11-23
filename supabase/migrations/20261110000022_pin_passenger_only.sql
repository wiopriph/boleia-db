-- Boleia - PIN посадки в my_bookings видит только пассажир брони, без исключения для админа (ТЗ раздел 4)
--
-- 0021 оставила PIN админу, а админ может быть водителем этой же поездки: тогда view отдавал ему PIN
-- пассажира. Модератору для спора нужен pin_entered_at, а не сам код. План: docs/plans/0021_pin_privacy.md

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
        and b.passenger_id = auth.uid()
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
