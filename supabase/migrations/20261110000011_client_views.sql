-- Boleia - запросы web-клиента к контракту (ТЗ разделы 4, 6, 7, 12, 15)
--
-- 1. profiles: согласие с правилами и 18+ (раздел 15), ключи terms_accepted / adult_confirmed в upsert_profile.
-- 2. my_bookings: cancel_reason, message и данные пассажира для карточки водителя (раздел 12).
-- 3. reviews_public: отзывы с автором для /perfil/<id>/avaliacoes без обхода RLS profiles.
-- 4. publish_trip: origin/destination только city/town; landmark - в origin_detail (раздел 15, точки посадки).
-- 5. route_stats от route_durations: SEO-страницы стартовых маршрутов существуют до первой поездки.
-- План и решения: docs/plans/0011_client_views.md

-- ---------------------------------------------------------------------------
-- 1. Согласие с правилами и 18+
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column terms_accepted_at  timestamptz,
  add column adult_confirmed_at timestamptz;

create or replace function public.upsert_profile(payload jsonb)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  p  public.profiles := public.current_profile();
  pm jsonb := payload -> 'payout_method';
begin
  if payload ? 'display_name' then
    if char_length(trim(payload ->> 'display_name')) not between 2 and 40 then
      perform public.raise_boleia('NAME_INVALID');
    end if;
  end if;

  if pm is not null and pm <> 'null'::jsonb then
    if not (
      (pm ->> 'type' = 'mcx_express' and (pm ->> 'phone') ~ '^\+244\d{9}$')
      or (pm ->> 'type' = 'iban' and char_length(pm ->> 'iban') = 25 and (pm ->> 'bank') is not null)
    ) then
      perform public.raise_boleia('PAYOUT_METHOD_INVALID');
    end if;
  end if;

  update public.profiles set
    display_name  = coalesce(nullif(trim(payload ->> 'display_name'), ''), display_name),
    avatar_url    = case when payload ? 'avatar_url'   then payload ->> 'avatar_url'              else avatar_url end,
    bio           = case when payload ? 'bio'          then payload ->> 'bio'                     else bio end,
    birth_year    = case when payload ? 'birth_year'   then (payload ->> 'birth_year')::smallint  else birth_year end,
    chat_level    = case when payload ? 'chat_level'   then (payload ->> 'chat_level')::chat_level else chat_level end,
    payout_method = case when payload ? 'payout_method' then pm                                   else payout_method end,
    locale        = coalesce(payload ->> 'locale', locale),
    -- согласие фиксируется один раз, снять его через RPC нельзя
    terms_accepted_at  = case when (payload ->> 'terms_accepted')::boolean  then coalesce(terms_accepted_at, now())  else terms_accepted_at end,
    adult_confirmed_at = case when (payload ->> 'adult_confirmed')::boolean then coalesce(adult_confirmed_at, now()) else adult_confirmed_at end,
    last_seen_at  = now()
  where id = p.id
  returning * into p;

  return p;
end $$;

-- ---------------------------------------------------------------------------
-- 2. my_bookings: причина отказа и пассажир (колонки только добавляются)
-- ---------------------------------------------------------------------------
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
  pp.cancels_total    as passenger_cancels_total
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
-- 3. reviews_public: видимые отзывы с автором
-- ---------------------------------------------------------------------------
create view public.reviews_public as
select
  r.id,
  r.booking_id,
  r.target_id,
  r.author_id,
  a.display_name as author_name,
  a.avatar_url   as author_avatar_url,
  r.direction,
  r.rating,
  r.tags,
  r.comment,
  r.created_at
from public.reviews r
join public.profiles a on a.id = r.author_id
where r.is_visible and a.status::text not in ('banned', 'deleted');
grant select on public.reviews_public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. publish_trip: откуда/куда только city/town
-- ---------------------------------------------------------------------------
create or replace function public.publish_trip(payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v            public.vehicles;
  v_origin     uuid := (payload ->> 'origin_place_id')::uuid;
  v_dest       uuid := (payload ->> 'destination_place_id')::uuid;
  v_dep        timestamptz := (payload ->> 'departure_at')::timestamptz;
  v_seats      smallint := (payload ->> 'seats_offered')::smallint;
  v_price      integer := (payload ->> 'price_per_seat_kz')::integer;
  v_mode       booking_mode := coalesce((payload ->> 'booking_mode')::booking_mode, 'instant');
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
    seats_offered, seats_available, price_per_seat_kz, booking_mode,
    luggage, allows_smoking, allows_pets, max_two_in_back, notes,
    status, published_at
  ) values (
    p.id, v.id, v_origin, v_dest,
    payload ->> 'origin_detail', payload ->> 'destination_detail', v_dep,
    v_seats, v_seats, v_price, v_mode,
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
end $$;

-- ---------------------------------------------------------------------------
-- 5. route_stats: пары из route_durations и из поездок, страницы есть с первого дня
-- ---------------------------------------------------------------------------
drop materialized view public.route_stats;
create materialized view public.route_stats as
with pairs as (
  select origin_place_id, destination_place_id from public.route_durations
  union
  select origin_place_id, destination_place_id from public.trips
  where status in ('published', 'full', 'departed', 'completed')
)
select
  o.slug            as origin_slug,
  o.name            as origin_name,
  d.slug            as destination_slug,
  d.name            as destination_name,
  count(t.id) filter (where t.departure_at > now() - interval '30 days')                       as trips_30d,
  count(t.id) filter (where t.status in ('published', 'full') and t.departure_at > now())     as trips_upcoming,
  min(t.price_per_seat_kz) filter (where t.status in ('published', 'full') and t.departure_at > now()) as min_price_kz,
  min(t.departure_at)      filter (where t.status in ('published', 'full') and t.departure_at > now()) as next_departure_at,
  now()             as refreshed_at,
  rd.minutes,
  rd.price_hint_kz
from pairs pr
join public.places o on o.id = pr.origin_place_id
join public.places d on d.id = pr.destination_place_id
left join public.route_durations rd
  on rd.origin_place_id = pr.origin_place_id and rd.destination_place_id = pr.destination_place_id
left join public.trips t
  on t.origin_place_id = pr.origin_place_id and t.destination_place_id = pr.destination_place_id
 and t.status in ('published', 'full', 'departed', 'completed')
where o.is_active and d.is_active
group by o.slug, o.name, d.slug, d.name, rd.minutes, rd.price_hint_kz;

create unique index route_stats_pk on public.route_stats (origin_slug, destination_slug);
grant select on public.route_stats to anon, authenticated;
