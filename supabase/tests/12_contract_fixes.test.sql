begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

create temp table ctx (name text primary key, value text);
grant all on ctx to anon, authenticated;
create function pg_temp.ctx_text(text) returns text language sql as $$ select value from ctx where name = $1 $$;
create function pg_temp.ctx_uuid(text) returns uuid language sql as $$ select value::uuid from ctx where name = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', pg_temp.ctx_uuid('admin'), 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.book_paid(booking_name text, trip_name text, passenger_name text, seat_count integer) returns uuid language plpgsql as $$
declare response jsonb;
begin
  perform pg_temp.as_user(pg_temp.ctx_uuid(passenger_name));
  response := public.request_booking(pg_temp.ctx_uuid(trip_name), seat_count);
  perform set_config('role', 'none', true);
  perform public.confirm_payment((response ->> 'payment_id')::uuid, 'ref-' || booking_name, 'paid',
    (select phone from public.profiles where id = pg_temp.ctx_uuid(passenger_name)));
  insert into ctx values (booking_name, response ->> 'booking_id');
  return (response ->> 'booking_id')::uuid;
end $$;
create function pg_temp.depart(trip_name text, minutes_ago integer) returns void language plpgsql as $$
begin
  update public.trips
  set departure_at = now() - make_interval(mins => minutes_ago), departed_at = now() - make_interval(mins => minutes_ago), status = 'departed'
  where id = pg_temp.ctx_uuid(trip_name);
  update public.bookings set status = 'awaiting_confirm' where trip_id = pg_temp.ctx_uuid(trip_name) and status = 'accepted';
end $$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555');
insert into ctx select 'joao_trip_' || position, id::text from (select id, row_number() over (order by departure_at) as position from public.trips
  where driver_id = pg_temp.ctx_uuid('joao') and price_per_seat_kz = 7000 and status = 'published') ranked where position <= 2;
insert into ctx select 'teresa_trip_' || position, id::text from (select id, row_number() over (order by departure_at) as position from public.trips
  where driver_id = pg_temp.ctx_uuid('teresa') and price_per_seat_kz = 7000 and status = 'published') ranked where position <= 1;

-- ---------------------------------------------------------------------------
-- 1. publish_trip: длина notes с кодом BOLEIA
-- ---------------------------------------------------------------------------
update public.trips set status = 'cancelled', cancelled_at = now() where driver_id = pg_temp.ctx_uuid('pedro');
create temp table trip_payload (payload jsonb);
grant all on trip_payload to authenticated;
insert into trip_payload select jsonb_build_object(
  'vehicle_id', (select id from public.vehicles where owner_id = pg_temp.ctx_uuid('pedro') limit 1),
  'origin_place_id', (select id from public.places where slug = 'luanda'), 'destination_place_id', (select id from public.places where slug = 'caxito'),
  'departure_at', (now() + interval '30 days')::text, 'seats_offered', 2, 'price_per_seat_kz', 3000);
select pg_temp.as_user(pg_temp.ctx_uuid('pedro'));
select throws_ok($$ select public.publish_trip((select payload || jsonb_build_object('notes', repeat('x', 501)) from trip_payload)) $$,
  'P0001', 'BOLEIA_MESSAGE_TOO_LONG', 'notes over 500 chars answer with a BOLEIA code');
select lives_ok($$ select public.publish_trip((select payload || jsonb_build_object('notes', repeat('x', 500)) from trip_payload)) $$, 'notes of exactly 500 chars pass');

-- ---------------------------------------------------------------------------
-- 2. upsert_vehicle: места и год с кодами BOLEIA
-- ---------------------------------------------------------------------------
select throws_ok($$ select public.upsert_vehicle('{"make":"Kia","model":"Rio","seats_total":0}') $$, 'P0001', 'BOLEIA_SEATS_INVALID', '0 seats');
select throws_ok($$ select public.upsert_vehicle('{"make":"Kia","model":"Rio","seats_total":9}') $$, 'P0001', 'BOLEIA_SEATS_INVALID', '9 seats');
select throws_ok($$ select public.upsert_vehicle('{"make":"Kia","model":"Rio","seats_total":4,"year":1979}') $$, 'P0001', 'BOLEIA_YEAR_INVALID', 'year 1979');
select throws_ok($$ select public.upsert_vehicle('{"make":"Kia","model":"Rio","seats_total":4,"year":2031}') $$, 'P0001', 'BOLEIA_YEAR_INVALID', 'year 2031');
select throws_ok($$ select public.upsert_vehicle('{"make":"Kia","model":"Rio"}') $$, 'P0001', 'BOLEIA_VEHICLE_INCOMPLETE', 'missing seats still VEHICLE_INCOMPLETE');
insert into ctx values ('new_vehicle', public.upsert_vehicle('{"make":"Kia","model":"Rio","seats_total":8,"year":1980}')::text);
select throws_ok($$ select public.upsert_vehicle(jsonb_build_object('id', pg_temp.ctx_uuid('new_vehicle'), 'year', 1900)) $$, 'P0001', 'BOLEIA_YEAR_INVALID', 'update with a bad year');
select throws_ok($$ select public.upsert_vehicle(jsonb_build_object('id', pg_temp.ctx_uuid('new_vehicle'), 'seats_total', 12)) $$, 'P0001', 'BOLEIA_SEATS_INVALID', 'update with too many seats');
select lives_ok($$ select public.upsert_vehicle(jsonb_build_object('id', pg_temp.ctx_uuid('new_vehicle'), 'year', 2030, 'seats_total', 1)) $$, 'boundary values pass');
reset role;

-- ---------------------------------------------------------------------------
-- 3. cancel_quote водителя по запросу совпадает с cancel_booking
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('requested_booking', 'teresa_trip_1', 'ana', 1);
insert into ctx values ('teresa_cancels', (select cancels_total::text from public.profiles where id = pg_temp.ctx_uuid('teresa')));
select pg_temp.as_user(pg_temp.ctx_uuid('teresa'));
select is(public.cancel_quote(pg_temp.ctx_uuid('requested_booking')),
  '{"refund_kz": 8000, "gateway_fee_kz": 0, "held_kz": 0, "rule": "driver_decline", "counter": false}'::jsonb,
  'driver quote on a requested booking: decline, no counter');
select is(public.cancel_booking(pg_temp.ctx_uuid('requested_booking'), 'Cheio') ->> 'rule', 'driver_decline', 'cancel_booking answers with the same rule');
reset role;
select is((select cancels_total from public.profiles where id = pg_temp.ctx_uuid('teresa')), pg_temp.ctx_text('teresa_cancels')::smallint, 'counter untouched, as quoted');
select pg_temp.book_paid('accepted_booking', 'teresa_trip_1', 'ana', 1);
select pg_temp.as_user(pg_temp.ctx_uuid('teresa'));
select lives_ok($$ select public.respond_booking(pg_temp.ctx_uuid('accepted_booking'), true) $$, 'driver accepts');
select is(public.cancel_quote(pg_temp.ctx_uuid('accepted_booking')) - 'refund_kz' - 'gateway_fee_kz' - 'held_kz',
  '{"rule": "driver_cancel", "counter": true}'::jsonb, 'driver quote on an accepted booking: cancel with counter');
reset role;

-- ---------------------------------------------------------------------------
-- 4. my_bookings.passenger_rating_count
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('teresa_on_joao', 'joao_trip_1', 'teresa', 1);
select pg_temp.book_paid('ana_on_joao', 'joao_trip_1', 'ana', 1);
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is((select (passenger_rating_avg, passenger_rating_count) from public.my_bookings where id = pg_temp.ctx_uuid('teresa_on_joao')),
  (4.50::numeric(3,2), 5), 'rated passenger: average with count');
select is((select (passenger_rating_avg, passenger_rating_count) from public.my_bookings where id = pg_temp.ctx_uuid('ana_on_joao')),
  (0.00::numeric(3,2), 0), 'new passenger: count 0 tells the client to hide 0,00');
reset role;

-- ---------------------------------------------------------------------------
-- 5. driver_wallet.earned_total_kz не растёт от неудачной выплаты
-- ---------------------------------------------------------------------------
select pg_temp.depart('joao_trip_1', 120);
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select lives_ok($$ select public.confirm_trip(pg_temp.ctx_uuid('ana_on_joao'), true) $$, 'Ana confirms');
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is((select (balance_kz, earned_total_kz) from public.driver_wallet), (7000, 7000::bigint), 'earned after one completed booking');
insert into ctx values ('payout', public.request_payout(5000)::text);
select pg_temp.as_admin();
select lives_ok($$ select public.mark_payout(pg_temp.ctx_uuid('payout'), 'failed', 'IBAN inválido') $$, 'payout failed, money back on balance');
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is((select (balance_kz, earned_total_kz) from public.driver_wallet), (7000, 7000::bigint), 'failed payout returns the balance but is not new income');
reset role;

-- ---------------------------------------------------------------------------
-- 6. PIN отменённой брони не считается ни в mark_no_show, ни в cron
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('cancelled_with_pin', 'joao_trip_2', 'ana', 1);
update public.bookings set pin_entered_at = now() where id = pg_temp.ctx_uuid('cancelled_with_pin');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select lives_ok($$ select public.cancel_booking(pg_temp.ctx_uuid('cancelled_with_pin')) $$, 'booking with an entered PIN is cancelled before departure');
reset role;
select pg_temp.book_paid('late_teresa', 'joao_trip_2', 'teresa', 1);
select pg_temp.book_paid('late_admin', 'joao_trip_2', 'admin', 1);
select pg_temp.depart('joao_trip_2', 61);
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select throws_ok($$ select public.mark_no_show(pg_temp.ctx_uuid('late_teresa')) $$, 'P0001', 'BOLEIA_NO_SHOW_NEEDS_PIN',
  'the PIN of a cancelled booking does not prove anyone boarded');
select pg_temp.as_user(pg_temp.ctx_uuid('teresa'));
select lives_ok($$ select public.confirm_trip(pg_temp.ctx_uuid('late_teresa'), false) $$, 'passenger disputes');
reset role;
update public.bookings set passenger_confirmed_at = now() - interval '25 hours' where id = pg_temp.ctx_uuid('late_teresa');
select is(public.sch_driver_no_show(now()), 1, 'cron driver-no-show is not blocked by the cancelled PIN');
select is((select (status::text, cancel_reason) from public.trips where id = pg_temp.ctx_uuid('joao_trip_2')), ('cancelled'::text, 'driver_no_show'::text), 'trip auto-cancelled');

select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) unbalanced), 0::bigint, 'ledger balanced');

select * from finish();
rollback;
