begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- Новый пользователь без профиля-водителя
insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
values ('99999999-9999-9999-9999-999999999999', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  '+244900000099', now(), '', '{"provider":"phone","providers":["phone"]}', '{"display_name":"Teste T."}', now(), now(), '', '', '', '', '', '', '', '');

select is(
  (select display_name from public.profiles where id = '99999999-9999-9999-9999-999999999999'),
  'Teste T.', 'profile auto-created from auth.users'
);

-- temp-таблицы создаём до смены роли (у authenticated может не быть TEMP)
create temp table t (payload jsonb);
create temp table v (id uuid);
grant all on t, v to authenticated;
insert into t select jsonb_build_object(
  'origin_place_id',      (select id from public.places where slug = 'luanda'),
  'destination_place_id', (select id from public.places where slug = 'benguela'),
  'departure_at',         (now() + interval '2 days')::text,
  'seats_offered',        3,
  'price_per_seat_kz',    7000
);

select set_config('request.jwt.claims', '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
set local role authenticated;

-- 1. нет аватара и payout_method → PROFILE_INCOMPLETE
select throws_ok(
  $$ select public.publish_trip((select payload from t)) $$,
  'P0001', 'BOLEIA_PROFILE_INCOMPLETE', 'publish refused without avatar/payout'
);

-- заполняем профиль через RPC
select lives_ok(
  $$ select public.upsert_profile('{"avatar_url":"https://x/a.png","payout_method":{"type":"mcx_express","phone":"+244900000099"}}') $$,
  'upsert_profile sets avatar and payout method'
);
select throws_ok(
  $$ select public.upsert_profile('{"payout_method":{"type":"mcx_express","phone":"12345"}}') $$,
  'P0001', 'BOLEIA_PAYOUT_METHOD_INVALID', 'invalid payout phone is rejected'
);

-- 2. нет машины → VEHICLE_NOT_FOUND
select throws_ok(
  $$ select public.publish_trip((select payload from t)) $$,
  'P0001', 'BOLEIA_VEHICLE_NOT_FOUND', 'publish refused without vehicle'
);

-- машина
insert into v select public.upsert_vehicle('{"make":"Toyota","model":"Corolla","seats_total":4,"plate":"LD-00-00-ZZ"}');
update t set payload = payload || jsonb_build_object('vehicle_id', (select id from v));

-- 3. слишком рано → DEPARTURE_TOO_SOON
select throws_ok(
  $$ select public.publish_trip((select payload || jsonb_build_object('departure_at', (now() + interval '1 hour')::text) from t)) $$,
  'P0001', 'BOLEIA_DEPARTURE_TOO_SOON', 'publish refused < 2h before departure'
);

-- 4. 5 мест при лимите 4 → SEATS_INVALID
select throws_ok(
  $$ select public.publish_trip((select payload || '{"seats_offered":5}' from t)) $$,
  'P0001', 'BOLEIA_SEATS_INVALID', 'publish refused with 5 seats'
);

-- 5. успех
select lives_ok(
  $$ select public.publish_trip((select payload from t)) $$,
  'publish_trip succeeds with complete profile and vehicle'
);
select is(
  (select count(*) from public.trips_public where driver_id = '99999999-9999-9999-9999-999999999999'),
  1::bigint, 'published trip is visible in trips_public'
);

-- 6. дубль ±2 ч → TRIP_DUPLICATE
select throws_ok(
  $$ select public.publish_trip((select payload from t)) $$,
  'P0001', 'BOLEIA_TRIP_DUPLICATE', 'same time slot is refused'
);

-- 7. лимит 5 активных → DRIVER_LIMIT_REACHED (ещё 4 успешных, 6-я — отказ)
select lives_ok($$
  select public.publish_trip((select payload || jsonb_build_object('departure_at', (now() + (d || ' days')::interval)::text) from t))
  from generate_series(3, 6) as d
$$, '4 more trips published');
select throws_ok(
  $$ select public.publish_trip((select payload || jsonb_build_object('departure_at', (now() + interval '7 days')::text) from t)) $$,
  'P0001', 'BOLEIA_DRIVER_LIMIT_REACHED', '6th active trip is refused'
);

reset role;
select * from finish();
rollback;
