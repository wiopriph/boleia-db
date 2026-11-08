begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

create temp table ctx (k text primary key, v text);
grant all on ctx to anon, authenticated;
create function pg_temp.c(text)  returns text language sql as $$ select v from ctx where k = $1 $$;
create function pg_temp.cu(text) returns uuid language sql as $$ select v::uuid from ctx where k = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.book_paid(k text, trip_k text, passenger_k text, n integer) returns uuid language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.cu(passenger_k));
  r := public.request_booking(pg_temp.cu(trip_k), n);
  perform set_config('role', 'none', true);
  perform public.confirm_payment((r ->> 'payment_id')::uuid, 'ref-' || k, 'paid',
    (select phone from public.profiles where id = pg_temp.cu(passenger_k)));
  insert into ctx values (k, r ->> 'booking_id');
  return (r ->> 'booking_id')::uuid;
end $$;

insert into ctx values
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555');
insert into ctx select 'j' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;
insert into ctx select 'p' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('pedro') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;

-- ---------------------------------------------------------------------------
-- 1. wait_minutes в публикации, правке и обратной поездке
-- ---------------------------------------------------------------------------
select is((select wait_minutes from public.trips where id = pg_temp.cu('j1')), 30::smallint, 'seed trips default to 30 min');
select is((select wait_minutes from public.trips_public where id = pg_temp.cu('j1')), 30::smallint, 'trips_public exposes wait_minutes');
update public.trips set status = 'cancelled', cancelled_at = now() where driver_id = pg_temp.cu('pedro') and status = 'published' and id not in (pg_temp.cu('p1'), pg_temp.cu('p2'));
create temp table pl (payload jsonb);
grant all on pl to authenticated;
insert into pl select jsonb_build_object(
  'vehicle_id', (select id from public.vehicles where owner_id = pg_temp.cu('pedro') limit 1),
  'origin_place_id', (select id from public.places where slug = 'luanda'), 'destination_place_id', (select id from public.places where slug = 'caxito'),
  'departure_at', (now() + interval '30 days')::text, 'seats_offered', 2, 'price_per_seat_kz', 3000);
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.publish_trip((select payload || '{"wait_minutes": 20}' from pl)) $$, 'P0001', 'BOLEIA_WAIT_INVALID', '20 minutes refused');
insert into ctx values ('np', (public.publish_trip((select payload || '{"wait_minutes": 45}' from pl)) ->> 'id'));
select lives_ok($$ select public.update_trip(pg_temp.cu('np'), '{"wait_minutes": 60}') $$, 'update wait to 60');
select throws_ok($$ select public.update_trip(pg_temp.cu('np'), '{"wait_minutes": 15}') $$, 'P0001', 'BOLEIA_WAIT_INVALID', '15 minutes refused on update');
insert into ctx values ('rt', public.create_return_trip(pg_temp.cu('np'), now() + interval '31 days')::text);
reset role;
select is((select wait_minutes from public.trips where id = pg_temp.cu('np')), 60::smallint, 'published with 45, updated to 60');
select is((select wait_minutes from public.trips where id = pg_temp.cu('rt')), 60::smallint, 'return trip copies wait_minutes');
select pg_temp.book_paid('a_np', 'np', 'ana', 1);
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.update_trip(pg_temp.cu('np'), '{"wait_minutes": 30}') $$, 'P0001', 'BOLEIA_TRIP_HAS_BOOKINGS', 'wait is part of the contract: locked after a paid booking');
reset role;

-- ---------------------------------------------------------------------------
-- 2. my_bookings: wait_until, driver_arrived_at, passenger_no_shows
-- ---------------------------------------------------------------------------
insert into ctx values ('np_until', (select (departure_at + interval '60 minutes')::text from public.trips where id = pg_temp.cu('np')));
select pg_temp.as_user(pg_temp.cu('ana'));
select is((select (wait_minutes, wait_until, driver_arrived_at) from public.my_bookings where id = pg_temp.cu('a_np')),
  (60::smallint, pg_temp.c('np_until')::timestamptz, null::timestamptz), 'booking shows how long the driver waits');
select pg_temp.as_user(pg_temp.cu('pedro'));
select is((select passenger_no_shows from public.my_bookings where id = pg_temp.cu('a_np')), 0::smallint, 'driver sees passenger no_shows');
reset role;

-- ---------------------------------------------------------------------------
-- 3. driver_arrived: окно, уведомления, идемпотентность
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.driver_arrived(pg_temp.cu('np')) $$, 'P0001', 'BOLEIA_ARRIVAL_WINDOW_CLOSED', 'too early: 30 days before');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.driver_arrived(pg_temp.cu('np')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'passenger cannot mark arrival');
reset role;
update public.trips set departure_at = now() + interval '1 hour' where id = pg_temp.cu('np');
select pg_temp.as_user(pg_temp.cu('pedro'));
select is(public.driver_arrived(pg_temp.cu('np')) ->> 'already', null, 'arrival marked');
select is(public.driver_arrived(pg_temp.cu('np')) ->> 'already', 'true', 'second call is a no-op');
reset role;
select ok((select driver_arrived_at is not null from public.trips where id = pg_temp.cu('np')), 'driver_arrived_at set');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'driver_arrived' and (payload ->> 'wait_until')::timestamptz = (select departure_at + interval '60 minutes' from public.trips where id = pg_temp.cu('np'))),
  'passenger told the driver is there and until when he waits');
select is((select count(*) from public.notifications where user_id = pg_temp.cu('ana') and type = 'driver_arrived' and channel = 'sms'), 1::bigint, 'driver_arrived is urgent: sms, not delayed');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id where c.booking_id = pg_temp.cu('a_np') and m.body like 'O condutor chegou%'), 1::bigint, 'system message in chat');
update public.trips set departure_at = now() - interval '2 hours', status = 'departed', departed_at = now() - interval '2 hours', driver_arrived_at = null where id = pg_temp.cu('p1');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.driver_arrived(pg_temp.cu('p1')) $$, 'P0001', 'BOLEIA_ARRIVAL_WINDOW_CLOSED', 'too late: after departure + wait');
reset role;

-- ---------------------------------------------------------------------------
-- 4. mark_no_show не раньше конца ожидания
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a_j1', 'j1', 'ana', 1);
select pg_temp.book_paid('t_j1', 'j1', 'teresa', 1);
update public.trips set departure_at = now() - interval '10 minutes', status = 'departed', departed_at = now() - interval '10 minutes' where id = pg_temp.cu('j1');
update public.bookings set status = 'awaiting_confirm' where trip_id = pg_temp.cu('j1') and status = 'accepted';
update public.bookings set pin_entered_at = now() where id = pg_temp.cu('a_j1');  -- Ana села
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.mark_no_show(pg_temp.cu('t_j1')) $$, 'P0001', 'BOLEIA_NO_SHOW_TOO_EARLY', '10 minutes after departure: still waiting (30)');
reset role;
update public.trips set departure_at = now() - interval '31 minutes', departed_at = now() - interval '31 minutes' where id = pg_temp.cu('j1');
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.mark_no_show(pg_temp.cu('t_j1')) $$, 'after the wait: no_show allowed');
reset role;
select is((select status::text from public.bookings where id = pg_temp.cu('t_j1')), 'no_show', 'latecomer marked no_show');

-- ---------------------------------------------------------------------------
-- 5. pin_ready несёт wait_until; спор с отметкой "Cheguei" ждёт модератора
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('t_j2', 'j2', 'teresa', 1);
update public.trips set departure_at = now() + interval '1 hour' where id = pg_temp.cu('j2');
select public.sch_send_pins(now());
select is((select (payload ->> 'wait_until')::timestamptz from public.notifications where type = 'pin_ready' and payload ->> 'booking_id' = pg_temp.c('t_j2') and channel = 'inapp'),
  (select departure_at + interval '30 minutes' from public.trips where id = pg_temp.cu('j2')), 'pin_ready says until when the driver waits');

select pg_temp.book_paid('a_p2', 'p2', 'ana', 1);
update public.trips set departure_at = now() - interval '3 hours', status = 'departed', departed_at = now() - interval '3 hours', driver_arrived_at = now() - interval '3 hours' where id = pg_temp.cu('p2');
update public.bookings set status = 'disputed', passenger_confirmed_at = now() - interval '2 hours' where id = pg_temp.cu('a_p2');
select is((public.run_scheduler(now() + interval '2 days') ->> 'driver_no_show')::int, 0, 'driver who checked in is not auto-cancelled: moderator decides');
select is((select status::text from public.trips where id = pg_temp.cu('p2')), 'departed', 'trip untouched');
update public.trips set driver_arrived_at = null where id = pg_temp.cu('p2');
select is((public.run_scheduler(now() + interval '2 days') ->> 'driver_no_show')::int, 1, 'without check-in the no-show cascade runs');

select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x), 0::bigint, 'ledger balanced');

select * from finish();
rollback;
