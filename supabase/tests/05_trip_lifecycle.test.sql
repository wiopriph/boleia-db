begin;
create extension if not exists pgtap with schema extensions;
select plan(128);

-- ---------------------------------------------------------------------------
-- Контекст и хелперы: до смены роли. Cron'а ещё нет, переходы departed/awaiting_confirm
-- делает pg_temp.depart под superuser.
-- ---------------------------------------------------------------------------
create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;
create function pg_temp.c(text)  returns text language sql as $$ select v from ctx where k = $1 $$;
create function pg_temp.cu(text) returns uuid language sql as $$ select v::uuid from ctx where k = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', pg_temp.cu('admin'), 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
-- бронь + оплата от имени пассажира; вызывать как postgres
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
create function pg_temp.book_pending(k text, trip_k text, passenger_k text, n integer) returns uuid language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.cu(passenger_k));
  r := public.request_booking(pg_temp.cu(trip_k), n);
  perform set_config('role', 'none', true);
  insert into ctx values (k, r ->> 'booking_id');
  return (r ->> 'booking_id')::uuid;
end $$;
create function pg_temp.depart(trip_k text, hours_ago numeric) returns void language plpgsql as $$
begin
  update public.trips
  set departure_at = now() - make_interval(mins => (hours_ago * 60)::integer), status = 'departed',
      departed_at = now() - make_interval(mins => (hours_ago * 60)::integer)
  where id = pg_temp.cu(trip_k);
  update public.bookings set status = 'awaiting_confirm' where trip_id = pg_temp.cu(trip_k) and status = 'accepted';
end $$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555');

insert into ctx
select 'j7' || chr(96 + rn::integer), id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') x;
insert into ctx
select 'jx' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz <> 7000 and status = 'published') x where rn <= 2;
insert into ctx
select 'p7' || chr(96 + rn::integer), id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('pedro') and price_per_seat_kz = 7000 and status = 'published') x;
insert into ctx
select 'px' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('pedro') and price_per_seat_kz <> 7000 and status = 'published') x where rn <= 2;
select is((select count(*) from ctx where k ~ '^(j7|jx|p7|px)'), 9::bigint, 'seed trips found');

-- ---------------------------------------------------------------------------
-- A. T1 (João, 7000): Ana + Teresa. PIN, no_show при чужом PIN, confirm_trip(true), settle
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a1', 'j7a', 'ana', 1);
select pg_temp.book_paid('t1', 'j7a', 'teresa', 1);
insert into ctx values ('pin_a1', (select pin_code from public.bookings where id = pg_temp.cu('a1')));

select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.enter_pin(pg_temp.cu('a1'), pg_temp.c('pin_a1')) $$, 'P0001', 'BOLEIA_PIN_WINDOW_CLOSED', 'PIN before departure - 3h refused');
select throws_ok($$ select public.enter_pin(pg_temp.cu('a1'), '12') $$, 'P0001', 'BOLEIA_PIN_INVALID', 'malformed PIN refused');
select throws_ok($$ select public.mark_no_show(pg_temp.cu('a1')) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'no_show before departure refused');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.confirm_trip(pg_temp.cu('a1'), true) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'confirm before departure refused');
select throws_ok($$ select public.enter_pin(pg_temp.cu('a1'), pg_temp.c('pin_a1')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'passenger cannot enter PIN');
reset role;

select pg_temp.depart('j7a', 1);
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.enter_pin(pg_temp.cu('a1'), pg_temp.c('pin_a1')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'other driver cannot enter PIN');
select pg_temp.as_user(pg_temp.cu('joao'));
select is(public.enter_pin(pg_temp.cu('a1'), '0000') - 'pin_entered_at', '{"ok": false, "attempts_left": 4}'::jsonb, 'wrong PIN: ok=false, 4 left');
select is(public.enter_pin(pg_temp.cu('a1'), '0001') ->> 'attempts_left', '3', 'second wrong');
select is(public.enter_pin(pg_temp.cu('a1'), '0002') ->> 'attempts_left', '2', 'third wrong');
select is(public.enter_pin(pg_temp.cu('a1'), '0003') ->> 'attempts_left', '1', 'fourth wrong');
select is(public.enter_pin(pg_temp.cu('a1'), '0004') ->> 'attempts_left', '0', 'fifth wrong');
select throws_ok($$ select public.enter_pin(pg_temp.cu('a1'), pg_temp.c('pin_a1')) $$, 'P0001', 'BOLEIA_RATE_LIMITED', 'blocked after 5 wrong, even correct PIN');
reset role;
select is((select count(*) from public.events where user_id = pg_temp.cu('joao') and name = 'pin_failed'), 5::bigint, 'failed attempts persisted');
update public.events set created_at = created_at - interval '11 minutes' where name = 'pin_failed';  -- прошло 10 минут
select pg_temp.as_user(pg_temp.cu('joao'));
select is(public.enter_pin(pg_temp.cu('a1'), pg_temp.c('pin_a1')) ->> 'ok', 'true', 'correct PIN after cooldown');
select is(public.enter_pin(pg_temp.cu('a1'), pg_temp.c('pin_a1')) ->> 'already', 'true', 'repeated correct PIN is a no-op');
reset role;
select ok((select pin_entered_at is not null from public.bookings where id = pg_temp.cu('a1')), 'pin_entered_at set');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
           where c.booking_id = pg_temp.cu('a1') and m.body like 'Passageiro a bordo%'), 1::bigint, 'system message on boarding');

-- Teresa не пришла: у Ana есть PIN
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.mark_no_show(pg_temp.cu('t1')) $$, 'no_show with another PIN on trip');
reset role;
select is((select status::text from public.bookings where id = pg_temp.cu('t1')), 'no_show', 'booking no_show');
select is(public.escrow_balance_kz(pg_temp.cu('t1')), 0, 'no_show: escrow released');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('t1') and account = 'driver_balance'), 7000, 'driver gets price on no_show');
select is((select no_shows from public.profiles where id = pg_temp.cu('teresa')), 1::smallint, 'passenger no_shows +1');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('teresa') and type = 'booking_no_show'), 'passenger notified');
select is((select status::text from public.trips where id = pg_temp.cu('j7a')), 'departed', 'trip still departed: Ana not final yet');

-- Ana доехала
select pg_temp.as_user(pg_temp.cu('teresa'));
select throws_ok($$ select public.confirm_trip(pg_temp.cu('a1'), true) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'stranger cannot confirm');
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('a1'), true) $$, 'passenger confirms');
select throws_ok($$ select public.confirm_trip(pg_temp.cu('a1'), true) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'cannot confirm twice');
reset role;
select is((select (status::text, passenger_confirmed_at is not null, completed_at is not null) from public.bookings where id = pg_temp.cu('a1')),
  ('completed'::text, true, true), 'booking completed');
select is(public.escrow_balance_kz(pg_temp.cu('a1')), 0, 'escrow released');
select is((select balance_kz from public.profiles where id = pg_temp.cu('joao')), 14000, 'driver balance = 2 x 7000');
select is((select sum(amount_kz) from public.ledger_entries where account = 'platform_fee'), 2000::bigint, 'platform fee 2 x 1000');
select is((select trips_ridden from public.profiles where id = pg_temp.cu('ana')), 1, 'trips_ridden +1');
select is((select (status::text, completed_at is not null) from public.trips where id = pg_temp.cu('j7a')), ('completed'::text, true), 'trip completed when all bookings final');
select is((select trips_driven from public.profiles where id = pg_temp.cu('joao')), 15, 'trips_driven +1 (seed 14)');
select is((select count(*) from public.notifications where user_id = pg_temp.cu('joao') and type = 'payout_released'), 2::bigint, 'driver notified per release');
select ok((select scheduled_for > now() + interval '23 hours' from public.notifications
           where user_id = pg_temp.cu('ana') and type = 'review_request' limit 1), 'review_request scheduled +24h');

-- ---------------------------------------------------------------------------
-- B. T2 (João): единственный пассажир без PIN -> disputed -> refund_full
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a2', 'jx1', 'ana', 1);
insert into ctx values ('a2_amount', (select (price_total_kz + fee_kz)::text from public.bookings where id = pg_temp.cu('a2')));
select pg_temp.depart('jx1', 2);
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.mark_no_show(pg_temp.cu('a2')) $$, 'single passenger without PIN -> dispute');
reset role;
select is((select (status::text, driver_confirmed_at is not null) from public.bookings where id = pg_temp.cu('a2')), ('disputed'::text, true), 'disputed by driver');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'dispute_opened'), 'passenger notified of dispute');

select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.resolve_dispute(pg_temp.cu('a2'), 'refund_full') $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'non-admin cannot resolve');
select pg_temp.as_admin();
select throws_ok($$ select public.resolve_dispute(pg_temp.cu('a2'), 'whatever') $$, 'P0001', 'BOLEIA_DISPUTE_OUTCOME_INVALID', 'unknown outcome');
select lives_ok($$ select public.resolve_dispute(pg_temp.cu('a2'), 'refund_full') $$, 'admin refunds in full');
select throws_ok($$ select public.resolve_dispute(pg_temp.cu('a2'), 'completed') $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'cannot resolve twice');
reset role;
select is((select (status::text, cancelled_by::text, cancel_reason, refund_kz::text) from public.bookings where id = pg_temp.cu('a2')),
  ('cancelled'::text, 'system'::text, 'dispute_refund'::text, pg_temp.c('a2_amount')), 'refund_full -> cancelled by system');
select is(public.escrow_balance_kz(pg_temp.cu('a2')), 0, 'escrow refunded');
select is((select no_shows from public.profiles where id = pg_temp.cu('joao')), 1::smallint, 'driver no_shows +1');
select is((select (action::text, target_user_id, reason) from public.moderation_actions where admin_id = pg_temp.cu('admin')),
  ('resolve_dispute'::text, pg_temp.cu('ana'), 'refund_full'::text), 'moderation action logged');
select is((select status::text from public.trips where id = pg_temp.cu('jx1')), 'completed', 'trip settled');
select is((select trips_driven from public.profiles where id = pg_temp.cu('joao')), 15, 'trips_driven unchanged: nothing completed');
select is((select count(distinct user_id) from public.notifications where type = 'dispute_resolved'), 2::bigint, 'both sides notified');

-- ---------------------------------------------------------------------------
-- C. T3 (Pedro, 7000): два пассажира без PIN, спор пассажира, refund_partial
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a3', 'p7a', 'ana', 1);
select pg_temp.book_paid('t3', 'p7a', 'teresa', 1);
insert into ctx values ('pin_t3', (select pin_code from public.bookings where id = pg_temp.cu('t3')));
select pg_temp.depart('p7a', 3);
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.mark_no_show(pg_temp.cu('a3')) $$, 'P0001', 'BOLEIA_NO_SHOW_NEEDS_PIN', 'two passengers, no PIN: refused');
select is(public.enter_pin(pg_temp.cu('t3'), pg_temp.c('pin_t3')) ->> 'ok', 'true', 'Teresa boards');
select throws_ok($$ select public.mark_no_show(pg_temp.cu('t3')) $$, 'P0001', 'BOLEIA_NO_SHOW_NEEDS_PIN', 'boarded passenger cannot be no_show');
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('a3'), false) $$, 'passenger disputes');
reset role;
select is((select status::text from public.bookings where id = pg_temp.cu('a3')), 'disputed', 'disputed by passenger');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('pedro') and type = 'dispute_opened'), 'driver notified');
select pg_temp.as_admin();
select throws_ok($$ select public.resolve_dispute(pg_temp.cu('a3'), 'refund_partial', 0) $$, 'P0001', 'BOLEIA_DISPUTE_AMOUNT_INVALID', 'partial 0 refused');
select throws_ok($$ select public.resolve_dispute(pg_temp.cu('a3'), 'refund_partial', 8000) $$, 'P0001', 'BOLEIA_DISPUTE_AMOUNT_INVALID', 'partial = full refused');
select throws_ok($$ select public.resolve_dispute(pg_temp.cu('a3'), 'refund_partial') $$, 'P0001', 'BOLEIA_DISPUTE_AMOUNT_INVALID', 'partial without amount refused');
select lives_ok($$ select public.resolve_dispute(pg_temp.cu('a3'), 'refund_partial', 3000) $$, 'partial refund 3000');
reset role;
select is((select (status::text, refund_kz) from public.bookings where id = pg_temp.cu('a3')), ('completed'::text, 3000), 'partial -> completed with refund_kz');
select is(public.escrow_balance_kz(pg_temp.cu('a3')), 0, 'escrow emptied');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a3') and account = 'refunds'), 3000, 'passenger refunded 3000');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a3') and account = 'driver_balance'), 4375, 'driver 5000 x 7000/8000');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a3') and account = 'platform_fee'), 625, 'platform 5000 x 1000/8000');
select is((select trips_ridden from public.profiles where id = pg_temp.cu('ana')), 2, 'partial counts as ridden');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('t3'), true) $$, 'Teresa confirms');
reset role;
select is((select status::text from public.trips where id = pg_temp.cu('p7a')), 'completed', 'trip settled after last booking');
select is((select trips_driven from public.profiles where id = pg_temp.cu('pedro')), 1, 'Pedro trips_driven +1');
select is((select balance_kz from public.profiles where id = pg_temp.cu('pedro')), 4375 + 7000, 'Pedro balance');

-- ---------------------------------------------------------------------------
-- D. T4 (Pedro): окна после 48 ч / 24 ч; подтверждение всё ещё возможно
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a4', 'p7b', 'ana', 1);
insert into ctx values ('pin_a4', (select pin_code from public.bookings where id = pg_temp.cu('a4')));
select pg_temp.depart('p7b', 49);
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.mark_no_show(pg_temp.cu('a4')) $$, 'P0001', 'BOLEIA_NO_SHOW_WINDOW_CLOSED', 'no_show after 48h refused');
select throws_ok($$ select public.enter_pin(pg_temp.cu('a4'), pg_temp.c('pin_a4')) $$, 'P0001', 'BOLEIA_PIN_WINDOW_CLOSED', 'PIN after 24h refused');
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('a4'), true) $$, 'late confirm still works');
reset role;

-- ---------------------------------------------------------------------------
-- E. T5 (João, 7000): удержанные 50 % уходят водителю при completed
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a5', 'j7b', 'ana', 1);
select pg_temp.book_paid('t5', 'j7b', 'teresa', 1);
update public.trips set departure_at = now() + interval '10 hours', driver_confirmed_at = now() where id = pg_temp.cu('j7b');
select pg_temp.as_user(pg_temp.cu('ana'));
select is((public.cancel_booking(pg_temp.cu('a5'))) ->> 'held_kz', '4000', 'late cancel holds 4000');
reset role;
select is(public.escrow_balance_kz(pg_temp.cu('a5')), 4000, 'hold in escrow');
select pg_temp.depart('j7b', 1);
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('t5'), true) $$, 'Teresa confirms');
reset role;
select is(public.escrow_balance_kz(pg_temp.cu('a5')), 0, 'hold released on settle');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a5') and account = 'driver_balance'), 3500, 'driver gets 3500 of hold');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a5') and account = 'platform_fee'), 500, 'platform gets 500 of hold');
select is((select status::text from public.trips where id = pg_temp.cu('j7b')), 'completed', 'trip completed');

-- ---------------------------------------------------------------------------
-- F. T6 (Pedro, 7000): cancel_trip с каскадом; T7 пустая поездка
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a6', 'p7c', 'ana', 1);
update public.trips set departure_at = now() + interval '10 hours', driver_confirmed_at = now() where id = pg_temp.cu('p7c');
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.cancel_booking(pg_temp.cu('a6')) $$, 'Ana cancels late (hold 4000)');
reset role;
update public.trips set departure_at = now() + interval '3 days' where id = pg_temp.cu('p7c');
select pg_temp.book_pending('a6b', 'p7c', 'ana', 1);
select pg_temp.book_paid('t6', 'p7c', 'teresa', 2);
insert into ctx values ('pedro_cancels', (select cancels_total::text from public.profiles where id = pg_temp.cu('pedro')));

select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.cancel_trip(pg_temp.cu('p7c')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'other driver cannot cancel trip');
select pg_temp.as_user(pg_temp.cu('pedro'));
select lives_ok($$ select public.cancel_trip(pg_temp.cu('p7c'), 'Avaria no carro') $$, 'driver cancels trip');
select throws_ok($$ select public.cancel_trip(pg_temp.cu('p7c')) $$, 'P0001', 'BOLEIA_TOO_LATE_TO_CANCEL', 'cannot cancel twice');
select throws_ok($$ select public.confirm_trip_intent(pg_temp.cu('p7c')) $$, 'P0001', 'BOLEIA_TRIP_CLOSED', 'no intent on cancelled trip');
reset role;
select is((select (status::text, cancel_reason) from public.trips where id = pg_temp.cu('p7c')), ('cancelled'::text, 'Avaria no carro'::text), 'trip cancelled');
select is((select status::text from public.bookings where id = pg_temp.cu('a6b')), 'payment_failed', 'pending booking -> payment_failed');
select is((select (status::text, cancelled_by::text, refund_kz) from public.bookings where id = pg_temp.cu('t6')), ('cancelled'::text, 'driver'::text, 15400), 'paid booking refunded in full');
select is(public.escrow_balance_kz(pg_temp.cu('t6')), 0, 'Teresa escrow refunded');
select is(public.escrow_balance_kz(pg_temp.cu('a6')), 0, 'Ana hold forfeited');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a6') and memo like 'forfeit:%' and account = 'platform_fee'), 4000, 'forfeit to platform');
select is((select cancels_total from public.profiles where id = pg_temp.cu('pedro')), (pg_temp.c('pedro_cancels')::integer + 1)::smallint, 'driver cancels_total +1');
select is((select array_agg(channel::text order by channel::text) from public.notifications where user_id = pg_temp.cu('teresa') and type = 'trip_cancelled'),
  array['inapp', 'sms'], 'passenger notified inapp + sms');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'trip_cancelled' and (payload ->> 'refund_kz') = '0'), 'pending passenger notified too');

select pg_temp.as_user(pg_temp.cu('pedro'));
select lives_ok($$ select public.cancel_trip(pg_temp.cu('px1')) $$, 'empty trip cancelled');
reset role;
select is((select status::text from public.trips where id = pg_temp.cu('px1')), 'cancelled', 'empty trip status');
select is((select cancels_total from public.profiles where id = pg_temp.cu('pedro')), (pg_temp.c('pedro_cancels')::integer + 1)::smallint, 'empty cancel does not count');

-- ---------------------------------------------------------------------------
-- G. confirm_trip_intent и cancel_quote
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a8', 'jx2', 'ana', 1);
update public.trips set departure_at = now() + interval '5 hours' where id = pg_temp.cu('jx2');
select pg_temp.as_user(pg_temp.cu('ana'));
select is(public.cancel_quote(pg_temp.cu('a8')) ->> 'rule', 'driver_unconfirmed', 'free cancel while driver silent');
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.confirm_trip_intent(pg_temp.cu('jx2')) $$, 'driver confirms intent');
select pg_temp.as_user(pg_temp.cu('ana'));
select is(public.cancel_quote(pg_temp.cu('a8')) ->> 'rule', 'passenger_late', 'after intent: late cancel rule');
reset role;
select ok((select driver_confirmed_at is not null from public.trips where id = pg_temp.cu('jx2')), 'driver_confirmed_at set');

-- ---------------------------------------------------------------------------
-- H. create_return_trip
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('teresa'));
select throws_ok($$ select public.create_return_trip(pg_temp.cu('jx2'), now() + interval '30 days') $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'not my trip');
select pg_temp.as_user(pg_temp.cu('joao'));
insert into ctx values ('ret', public.create_return_trip(pg_temp.cu('jx2'), now() + interval '30 days')::text);
select throws_ok($$ select public.create_return_trip(pg_temp.cu('jx2'), now() + interval '30 days') $$, 'P0001', 'BOLEIA_TRIP_DUPLICATE', 'same slot twice');
reset role;
select is(
  (select (origin_place_id, destination_place_id, origin_detail, destination_detail, price_per_seat_kz, seats_offered, booking_mode::text, vehicle_id)
   from public.trips where id = pg_temp.cu('ret')),
  (select (destination_place_id, origin_place_id, destination_detail, origin_detail, price_per_seat_kz, seats_offered, booking_mode::text, vehicle_id)
   from public.trips where id = pg_temp.cu('jx2')),
  'return trip mirrors the original');
select is((select status::text from public.trips where id = pg_temp.cu('ret')), 'published', 'return trip published');

-- ---------------------------------------------------------------------------
-- I. update_trip
-- ---------------------------------------------------------------------------
insert into ctx values ('px2_dep', (select departure_at::text from public.trips where id = pg_temp.cu('px2')));
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"vehicle_id":"00000000-0000-0000-0000-000000000000"}') $$, 'P0001', 'BOLEIA_TRIP_FIELD_LOCKED', 'vehicle is locked');
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"seats_offered":0}') $$, 'P0001', 'BOLEIA_SEATS_INVALID', 'seats 0');
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"price_per_seat_kz":100}') $$, 'P0001', 'BOLEIA_PRICE_INVALID', 'price 100');
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), jsonb_build_object('departure_at', now() + interval '1 hour')) $$, 'P0001', 'BOLEIA_DEPARTURE_TOO_SOON', 'departure too soon');
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), jsonb_build_object('departure_at', (select departure_at from public.trips where driver_id = pg_temp.cu('pedro') and status = 'published' and id <> pg_temp.cu('px2') limit 1))) $$,
  'P0001', 'BOLEIA_TRIP_DUPLICATE', 'departure clashes with own trip');
select lives_ok($$ select public.update_trip(pg_temp.cu('px2'), jsonb_build_object(
  'price_per_seat_kz', 9000, 'seats_offered', 2, 'notes', 'Sem paragens', 'booking_mode', 'approval',
  'departure_at', now() + interval '40 days')) $$, 'update without bookings');
reset role;
select is((select (price_per_seat_kz, seats_offered, seats_available, notes, booking_mode::text, driver_confirmed_at) from public.trips where id = pg_temp.cu('px2')),
  (9000, 2::smallint, 2::smallint, 'Sem paragens'::text, 'approval'::text, null::timestamptz), 'fields updated, seats recomputed');
select ok((select departure_at > now() + interval '39 days' from public.trips where id = pg_temp.cu('px2')), 'departure moved');

select pg_temp.book_pending('a9', 'px2', 'ana', 1);
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), jsonb_build_object('departure_at', now() + interval '41 days')) $$, 'P0001', 'BOLEIA_TRIP_HAS_BOOKINGS', 'departure locked by pending booking');
select lives_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"price_per_seat_kz":9500}') $$, 'price still editable while only pending');
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"seats_offered":0}') $$, 'P0001', 'BOLEIA_SEATS_INVALID', 'seats below taken');
select lives_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"seats_offered":1}') $$, 'seats down to taken');
reset role;
select is((select (seats_offered, seats_available, status::text) from public.trips where id = pg_temp.cu('px2')), (1::smallint, 0::smallint, 'full'::text), 'trip full after shrinking seats');
select lives_ok($$ select public.confirm_payment((select id from public.payments where booking_id = pg_temp.cu('a9')), 'ref-a9', 'paid', '+244900000005') $$, 'Ana pays');
select is((select status::text from public.bookings where id = pg_temp.cu('a9')), 'requested', 'approval mode applied to new booking');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"price_per_seat_kz":9900}') $$, 'P0001', 'BOLEIA_TRIP_HAS_BOOKINGS', 'price locked by paid booking');
select lives_ok($$ select public.update_trip(pg_temp.cu('px2'), '{"booking_mode":"instant"}') $$, 'booking_mode always editable');
select throws_ok($$ select public.update_trip(pg_temp.cu('p7c'), '{"notes":"x"}') $$, 'P0001', 'BOLEIA_TRIP_CLOSED', 'cancelled trip not editable');
reset role;

-- ---------------------------------------------------------------------------
-- J. Инварианты
-- ---------------------------------------------------------------------------
select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x), 0::bigint, 'every ledger op sums to zero');
select is((select count(*) from public.profiles p where p.balance_kz <> coalesce((select sum(amount_kz) from public.ledger_entries where user_id = p.id and account = 'driver_balance'), 0)),
  0::bigint, 'balance_kz cache matches ledger for everyone');
select is((select count(*) from public.bookings b join public.trips t on t.id = b.trip_id
           where b.status in ('completed', 'no_show', 'declined', 'payment_failed') and public.escrow_balance_kz(b.id) <> 0), 0::bigint,
  'no escrow left on final bookings');
select is((select count(*) from public.bookings b join public.trips t on t.id = b.trip_id
           where b.status = 'cancelled' and t.status in ('completed', 'cancelled') and public.escrow_balance_kz(b.id) <> 0), 0::bigint,
  'no holds left on closed trips');

select * from finish();
rollback;
