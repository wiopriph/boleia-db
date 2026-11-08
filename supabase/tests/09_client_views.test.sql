begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

create temp table ctx (k text primary key, v text);
grant all on ctx to anon, authenticated;
create function pg_temp.c(text)  returns text language sql as $$ select v from ctx where k = $1 $$;
create function pg_temp.cu(text) returns uuid language sql as $$ select v::uuid from ctx where k = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;
create function pg_temp.book_paid(k text, trip_k text, passenger_k text, n integer, msg text default null) returns uuid language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.cu(passenger_k));
  r := public.request_booking(pg_temp.cu(trip_k), n, msg);
  perform set_config('role', 'none', true);
  perform public.confirm_payment((r ->> 'payment_id')::uuid, 'ref-' || k, 'paid',
    (select phone from public.profiles where id = pg_temp.cu(passenger_k)));
  insert into ctx values (k, r ->> 'booking_id'), (k || '_pay', r ->> 'payment_id');
  return (r ->> 'booking_id')::uuid;
end $$;

insert into ctx values
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('ana',    '55555555-5555-5555-5555-555555555555');
insert into ctx select 'j' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;

-- ---------------------------------------------------------------------------
-- 1. Согласие с правилами и 18+
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
select is((public.upsert_profile('{"bio":"olá"}')).terms_accepted_at, null, 'no consent yet');
select ok((public.upsert_profile('{"terms_accepted": true, "adult_confirmed": true}')).terms_accepted_at is not null, 'terms accepted');
reset role;
insert into ctx values ('terms_at', (select terms_accepted_at::text from public.profiles where id = pg_temp.cu('ana')));
select ok((select adult_confirmed_at is not null from public.profiles where id = pg_temp.cu('ana')), 'adult confirmed');
select pg_temp.as_user(pg_temp.cu('ana'));
select is((public.upsert_profile('{"terms_accepted": true}')).terms_accepted_at::text, pg_temp.c('terms_at'), 'second accept keeps the first timestamp');
select is((public.upsert_profile('{"terms_accepted": false}')).terms_accepted_at::text, pg_temp.c('terms_at'), 'consent cannot be withdrawn via RPC');
reset role;

-- ---------------------------------------------------------------------------
-- 2. my_bookings: пассажир для водителя, message, cancel_reason
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('t1', 'j1', 'teresa', 1, 'Vou com uma mala grande');
select pg_temp.as_user(pg_temp.cu('joao'));
select is((select (passenger_name, passenger_trips_ridden, passenger_cancels_total, message) from public.my_bookings where id = pg_temp.cu('t1')),
  ('Teresa S.'::text, 0, 0::smallint, 'Vou com uma mala grande'::text), 'driver sees passenger card data and message');
select is((select passenger_rating_avg from public.my_bookings where id = pg_temp.cu('t1')), 4.50::numeric(3,2), 'passenger rating from seed');
select is((select cancel_reason from public.my_bookings where id = pg_temp.cu('t1')), null, 'no cancel reason on an accepted booking');
reset role;

select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r2', public.request_booking(pg_temp.cu('j2'), 1)::text);
reset role;
select public.confirm_payment((pg_temp.c('r2')::jsonb ->> 'payment_id')::uuid, 'ref-r2', 'paid', '+244999999999');
select pg_temp.as_user(pg_temp.cu('ana'));
select is((select (status::text, cancel_reason) from public.my_bookings where id = (pg_temp.c('r2')::jsonb ->> 'booking_id')::uuid),
  ('payment_failed'::text, 'PAYMENT_PHONE_MISMATCH'::text), 'passenger sees why the payment failed');
reset role;

-- ---------------------------------------------------------------------------
-- 3. reviews_public
-- ---------------------------------------------------------------------------
update public.trips set departure_at = now() - interval '2 hours', status = 'departed' where id = pg_temp.cu('j1');
update public.bookings set status = 'awaiting_confirm' where id = pg_temp.cu('t1');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('t1'), true) $$, 'completed');
insert into ctx values ('rev', public.submit_review(pg_temp.cu('t1'), 5, array['pontual'], 'Top')::text);
select pg_temp.as_anon();
select is((select count(*) from public.reviews_public where id = pg_temp.cu('rev')), 0::bigint, 'single review hidden from reviews_public');
reset role;
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.submit_review(pg_temp.cu('t1'), 4) $$, 'driver reviews back');
select pg_temp.as_anon();
select is((select (author_name, target_id, rating, direction::text) from public.reviews_public where id = pg_temp.cu('rev')),
  ('Teresa S.'::text, pg_temp.cu('joao'), 5::smallint, 'passenger_to_driver'::text), 'anon reads the visible review with author name');
select is((select count(*) from public.reviews_public where target_id = pg_temp.cu('joao')), 1::bigint, 'reviews about the driver');
reset role;

-- ---------------------------------------------------------------------------
-- 4. publish_trip: landmark не город
-- ---------------------------------------------------------------------------
create temp table pl (payload jsonb);
grant all on pl to anon, authenticated;
insert into pl select jsonb_build_object(
  'vehicle_id', (select id from public.vehicles where owner_id = pg_temp.cu('joao') limit 1),
  'origin_place_id',      (select id from public.places where slug = 'terminal-macon-gamek'),
  'destination_place_id', (select id from public.places where slug = 'benguela'),
  'departure_at',         (now() + interval '20 days')::text,
  'seats_offered', 2, 'price_per_seat_kz', 7000);
update public.trips set status = 'cancelled', cancelled_at = now() where driver_id = pg_temp.cu('joao') and status = 'published';  -- лимит 5 активных
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.publish_trip((select payload from pl)) $$, 'P0001', 'BOLEIA_PLACE_INVALID', 'landmark as origin refused');
select lives_ok($$ select public.publish_trip((select payload || jsonb_build_object('origin_place_id', (select id from public.places where slug = 'viana'), 'origin_detail', 'Terminal Macon') from pl)) $$,
  'town as origin with the landmark in origin_detail');
reset role;

-- ---------------------------------------------------------------------------
-- 5. route_stats от route_durations
-- ---------------------------------------------------------------------------
refresh materialized view public.route_stats;
select is((select (trips_upcoming, minutes, price_hint_kz) from public.route_stats where origin_slug = 'benguela' and destination_slug = 'lubango'),
  (0::bigint, 330::smallint, 5000), 'route without trips exists with duration and price hint');
select ok((select trips_upcoming > 0 from public.route_stats where origin_slug = 'luanda' and destination_slug = 'benguela'), 'route with trips counts them');
select ok((select count(*) >= 14 from public.route_stats), 'all seed routes present');
select pg_temp.as_anon();
select ok((select count(*) > 0 from public.route_stats), 'anon reads route_stats');
reset role;

select * from finish();
rollback;
