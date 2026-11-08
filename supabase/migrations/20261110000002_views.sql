-- Boleia — views (ТЗ раздел 4 «Представления», раздел 7 «Чтение»)
--
-- trips_public и profiles_public — security definer (по умолчанию для view):
-- это единственная публичная поверхность, в ней намеренно нет телефона, номера машины, баланса.
-- my_* и driver_wallet — security_invoker: RLS базовых таблиц решает, что видит пользователь.

-- ---------------------------------------------------------------------------
-- profiles_public
-- ---------------------------------------------------------------------------
create view public.profiles_public as
select
  p.id,
  p.display_name,
  p.avatar_url,
  p.bio,
  p.birth_year,
  p.chat_level,
  (p.driver_status = 'verified')          as driver_verified,
  p.rating_avg,
  p.rating_count,
  p.trips_driven,
  p.trips_ridden,
  p.cancels_total,
  case
    when p.cancels_total = 0 and (p.trips_driven + p.trips_ridden) > 0 then 'never_cancelled'
    when p.cancels_total > 0 then 'sometimes_cancels'
    else null
  end                                     as cancel_badge,
  p.created_at                            as member_since
from public.profiles p
where p.status <> 'banned';

-- ---------------------------------------------------------------------------
-- trips_public — то, что читают анонимы и поиск
-- ---------------------------------------------------------------------------
create view public.trips_public as
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
  -- маршрут
  o.id        as origin_place_id,
  o.name      as origin_name,
  o.slug      as origin_slug,
  o.province  as origin_province,
  d.id        as destination_place_id,
  d.name      as destination_name,
  d.slug      as destination_slug,
  d.province  as destination_province,
  rd.minutes  as duration_minutes,
  -- водитель (без телефона)
  p.id            as driver_id,
  p.display_name  as driver_name,
  p.avatar_url    as driver_avatar_url,
  p.rating_avg    as driver_rating_avg,
  p.rating_count  as driver_rating_count,
  p.trips_driven  as driver_trips_driven,
  (p.driver_status = 'verified') as driver_verified,
  p.cancels_total as driver_cancels_total,
  p.chat_level    as driver_chat_level,
  -- машина (без номера)
  v.make      as vehicle_make,
  v.model     as vehicle_model,
  v.color     as vehicle_color,
  v.photo_url as vehicle_photo_url,
  v.verified  as vehicle_verified
from public.trips t
join public.places   o  on o.id = t.origin_place_id
join public.places   d  on d.id = t.destination_place_id
join public.profiles p  on p.id = t.driver_id
join public.vehicles v  on v.id = t.vehicle_id
left join public.route_durations rd
  on rd.origin_place_id = t.origin_place_id and rd.destination_place_id = t.destination_place_id
where t.status in ('published', 'full')
  and p.status in ('active', 'restricted');

-- ---------------------------------------------------------------------------
-- my_bookings — брони текущего пользователя (RLS bookings решает, какие)
-- ---------------------------------------------------------------------------
create view public.my_bookings
with (security_invoker = true) as
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
  -- поездка
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
  -- платёж (последний)
  pay.status          as payment_status,
  pay.expires_at      as payment_expires_at,
  -- чат
  c.id                as conversation_id
from public.bookings b
join public.trips    t  on t.id = b.trip_id
join public.places   o  on o.id = t.origin_place_id
join public.places   d  on d.id = t.destination_place_id
join public.profiles dp on dp.id = t.driver_id
left join lateral (
  select status, expires_at from public.payments
  where booking_id = b.id order by created_at desc limit 1
) pay on true
left join public.conversations c on c.trip_id = b.trip_id and c.passenger_id = b.passenger_id;

-- ---------------------------------------------------------------------------
-- my_conversations — список чатов с последним сообщением и непрочитанными
-- ---------------------------------------------------------------------------
create view public.my_conversations
with (security_invoker = true) as
select
  c.id,
  c.trip_id,
  c.booking_id,
  c.passenger_id,
  c.driver_id,
  case when c.passenger_id = auth.uid() then c.driver_id else c.passenger_id end as other_user_id,
  op.display_name as other_user_name,
  op.avatar_url   as other_user_avatar_url,
  c.last_message_at,
  c.closed_at,
  t.departure_at,
  o.name as origin_name,
  d.name as destination_name,
  lm.body        as last_message_body,
  lm.sender_id   as last_message_sender_id,
  (select count(*) from public.messages m
     where m.conversation_id = c.id and m.read_at is null
       and (m.sender_id is distinct from auth.uid())) as unread_count
from public.conversations c
join public.trips  t on t.id = c.trip_id
join public.places o on o.id = t.origin_place_id
join public.places d on d.id = t.destination_place_id
join public.profiles op
  on op.id = case when c.passenger_id = auth.uid() then c.driver_id else c.passenger_id end
left join lateral (
  select body, sender_id from public.messages
  where conversation_id = c.id order by id desc limit 1
) lm on true;

-- ---------------------------------------------------------------------------
-- driver_wallet — баланс, в ожидании, выплаты (только свой)
-- ---------------------------------------------------------------------------
create view public.driver_wallet as
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
    where user_id = p.id and account = 'driver_balance' and amount_kz > 0
  ), 0) as earned_total_kz,
  coalesce((
    select sum(amount_kz) from public.payouts
    where user_id = p.id and status in ('requested', 'processing')
  ), 0) as payouts_pending_kz,
  p.payout_method
from public.profiles p
where p.id = auth.uid();

-- ---------------------------------------------------------------------------
-- route_stats — для SEO-страниц, materialized, refresh раз в час (cron, I1)
-- ---------------------------------------------------------------------------
create materialized view public.route_stats as
select
  o.slug            as origin_slug,
  o.name            as origin_name,
  d.slug            as destination_slug,
  d.name            as destination_name,
  count(*) filter (where t.departure_at > now() - interval '30 days')              as trips_30d,
  count(*) filter (where t.status in ('published', 'full') and t.departure_at > now()) as trips_upcoming,
  min(t.price_per_seat_kz) filter (where t.status in ('published', 'full') and t.departure_at > now()) as min_price_kz,
  min(t.departure_at)      filter (where t.status in ('published', 'full') and t.departure_at > now()) as next_departure_at,
  now() as refreshed_at
from public.trips t
join public.places o on o.id = t.origin_place_id
join public.places d on d.id = t.destination_place_id
where t.status in ('published', 'full', 'departed', 'completed')
group by o.slug, o.name, d.slug, d.name;

create unique index route_stats_pk on public.route_stats (origin_slug, destination_slug);

-- ---------------------------------------------------------------------------
-- Grants: публичные views читают все, остальные — authenticated
-- ---------------------------------------------------------------------------
grant select on public.trips_public, public.profiles_public, public.route_stats to anon, authenticated;
grant select on public.my_bookings, public.my_conversations, public.driver_wallet to authenticated;
