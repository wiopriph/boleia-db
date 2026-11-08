begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

-- ---------------------------------------------------------------------------
-- anon: видит trips_public и places, не видит profiles/bookings/payments
-- ---------------------------------------------------------------------------
set local role anon;

select ok((select count(*) from public.trips_public) > 0, 'anon reads trips_public');
select ok((select count(*) from public.places) > 0,       'anon reads places');
select is((select count(*) from public.profiles), 0::bigint, 'anon sees no profiles rows');
select is((select count(*) from public.bookings), 0::bigint, 'anon sees no bookings rows');
select throws_ok(
  $$ select count(*) from public.payments $$,
  '42501', null, 'anon has no select on payments'
);
select throws_ok(
  $$ insert into public.trips (driver_id, vehicle_id, origin_place_id, destination_place_id, departure_at, seats_offered, seats_available, price_per_seat_kz)
     values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), now(), 1, 1, 1000) $$,
  '42501', null, 'anon cannot insert trips'
);

reset role;

-- ---------------------------------------------------------------------------
-- authenticated (João, водитель из seed): свой профиль видит, чужой — нет, в trips напрямую не пишет
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
set local role authenticated;

select is((select count(*) from public.profiles), 1::bigint, 'authenticated sees only own profile');
select throws_ok(
  $$ insert into public.bookings (trip_id, passenger_id, seats, price_total_kz, fee_kz)
     values (gen_random_uuid(), auth.uid(), 1, 7000, 1000) $$,
  '42501', null, 'authenticated cannot insert bookings directly'
);
select throws_ok(
  $$ update public.profiles set balance_kz = 1000000 where id = auth.uid() $$,
  '42501', null, 'authenticated cannot update balance_kz (column grant)'
);
select lives_ok(
  $$ update public.profiles set bio = 'olá' where id = auth.uid() $$,
  'authenticated can update own bio'
);

reset role;
select * from finish();
rollback;
