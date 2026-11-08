begin;
create extension if not exists pgtap with schema extensions;
select plan(144);

-- ---------------------------------------------------------------------------
-- Контекст и хелперы: до смены роли
-- ---------------------------------------------------------------------------
create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;
create function pg_temp.c(text)  returns text  language sql as $$ select v from ctx where k = $1 $$;
create function pg_temp.cu(text) returns uuid  language sql as $$ select v::uuid from ctx where k = $1 $$;
create function pg_temp.cj(text, text) returns uuid language sql as $$ select (v::jsonb ->> $2)::uuid from ctx where k = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

insert into ctx values
  ('ana',    '55555555-5555-5555-5555-555555555555'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444');

-- поездки по 7 000 Kz: João (instant), Teresa (approval), Pedro (instant, unverified)
insert into ctx
select 'trip_i' || case when rn = 1 then '' else rn::text end, id::text
from (select id, row_number() over (order by departure_at) rn from public.trips
      where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') x where rn <= 2;
insert into ctx
select 'trip_a' || case when rn = 1 then '' else rn::text end, id::text
from (select id, row_number() over (order by departure_at) rn from public.trips
      where driver_id = pg_temp.cu('teresa') and price_per_seat_kz = 7000 and status = 'published') x where rn <= 3;
insert into ctx
select 'trip_p' || case when rn = 1 then '' else rn::text end, id::text
from (select id, row_number() over (order by departure_at) rn from public.trips
      where driver_id = pg_temp.cu('pedro') and price_per_seat_kz = 7000 and status = 'published') x where rn <= 3;
-- любые другие поездки для теста лимита
insert into ctx values
  ('trip_x', (select id::text from public.trips where driver_id = pg_temp.cu('joao') and price_per_seat_kz <> 7000 order by departure_at limit 1)),
  ('trip_y', (select id::text from public.trips where driver_id = pg_temp.cu('teresa') and price_per_seat_kz <> 7000 order by departure_at limit 1));

select is((select count(*) from ctx where k like 'trip_%'), 10::bigint, 'seed trips found');

-- ---------------------------------------------------------------------------
-- A. Instant: request_booking -> confirm_payment -> accepted
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r1', public.request_booking(pg_temp.cu('trip_i'), 2, 'Vou com uma mala')::text);
insert into ctx values ('b1', pg_temp.cj('r1', 'booking_id')::text), ('p1', pg_temp.cj('r1', 'payment_id')::text);

select throws_ok($$ select public.request_booking(pg_temp.cu('trip_i'), 1) $$,
  'P0001', 'BOLEIA_BOOKING_DUPLICATE', 'second active booking on same trip is refused');
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_p'), 4) $$,
  'P0001', 'BOLEIA_SEATS_INVALID', '4 seats refused');
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_p'), 0) $$,
  'P0001', 'BOLEIA_SEATS_INVALID', '0 seats refused');
select throws_ok($$ select public.request_booking('00000000-0000-0000-0000-000000000000', 1) $$,
  'P0001', 'BOLEIA_TRIP_NOT_FOUND', 'unknown trip');
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_p'), 1, repeat('x', 301)) $$,
  'P0001', 'BOLEIA_MESSAGE_TOO_LONG', 'message > 300 chars refused');
select throws_ok($$ select public.confirm_payment(pg_temp.cu('p1'), 'ref-1', 'paid', '+244900000005') $$,
  '42501', null, 'confirm_payment is not executable by authenticated');
select throws_ok($$ select public.notify(pg_temp.cu('ana'), 'x', '{}', false) $$,
  '42501', null, 'internal notify() is not executable by authenticated');
select throws_ok($$ select public.ledger_post(gen_random_uuid(), 'x', null, '[]') $$,
  '42501', null, 'internal ledger_post() is not executable by authenticated');

select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_i'), 1) $$,
  'P0001', 'BOLEIA_OWN_TRIP', 'driver cannot book own trip');

reset role;
select is(pg_temp.c('r1')::jsonb ->> 'amount_kz', '15400', 'amount = 2 x 7000 + fee 1400');
select is(pg_temp.c('r1')::jsonb ->> 'fee_kz', '1400', 'fee snapshot');
select is((select status::text from public.bookings where id = pg_temp.cu('b1')), 'pending_payment', 'booking pending_payment');
select is((select status::text from public.payments where id = pg_temp.cu('p1')), 'created', 'payment created');
select ok((select expires_at > now() + interval '14 minutes' from public.payments where id = pg_temp.cu('p1')), 'expires_at set at request');
select is((select seats_available from public.trips where id = pg_temp.cu('trip_i')), 1::smallint, 'seats reserved at pending_payment');
select is((select array_agg(channel::text order by channel::text) from public.notifications where user_id = pg_temp.cu('ana') and type = 'payment_pending'),
  array['inapp'], 'payment_pending: inapp only, no sms');

select lives_ok($$ select public.confirm_payment(pg_temp.cu('p1'), 'ref-1', 'paid', '244900000005', '{"gw":"ok"}') $$,
  'webhook paid with matching phone');
select is((select status::text from public.bookings where id = pg_temp.cu('b1')), 'accepted', 'instant: paid -> accepted');
select matches((select pin_code from public.bookings where id = pg_temp.cu('b1')), '^\d{4}$', 'PIN generated');
select ok((select requested_at is not null and responded_at is not null from public.bookings where id = pg_temp.cu('b1')), 'timestamps set');
select is((select booking_id from public.conversations where trip_id = pg_temp.cu('trip_i') and passenger_id = pg_temp.cu('ana')),
  pg_temp.cu('b1'), 'conversation created with booking_id');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
           where c.booking_id = pg_temp.cu('b1') and m.sender_id is null), 1::bigint, 'system message posted');
select is((select array_agg(channel::text order by channel::text) from public.notifications where user_id = pg_temp.cu('ana') and type = 'booking_accepted'),
  array['inapp', 'sms'], 'passenger notified: inapp + sms (no device)');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('joao') and type = 'booking_confirmed'), 'driver notified booking_confirmed');
select is((select status::text from public.payments where id = pg_temp.cu('p1')), 'paid', 'payment paid');
select is((select provider_ref from public.payments where id = pg_temp.cu('p1')), 'ref-1', 'provider_ref stored');
select is((select raw_webhook ->> 'gw' from public.payments where id = pg_temp.cu('p1')), 'ok', 'raw webhook stored');
select is((select count(*) from public.ledger_entries where booking_id = pg_temp.cu('b1')), 2::bigint, 'payment op has two rows');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('b1') and account = 'cash_in'), -15400, 'cash_in row');
select is(public.escrow_balance_kz(pg_temp.cu('b1')), 15400, 'escrow holds the paid amount');

-- идемпотентность и валидация вебхука
select lives_ok($$ select public.confirm_payment(pg_temp.cu('p1'), 'ref-1', 'paid', '244900000005') $$, 'repeated webhook is a no-op');
select is((select count(*) from public.ledger_entries where booking_id = pg_temp.cu('b1')), 2::bigint, 'no double posting');
select throws_ok($$ select public.confirm_payment(pg_temp.cu('p1'), 'ref-1', 'bogus', null) $$,
  'P0001', 'BOLEIA_PAYMENT_STATUS_INVALID', 'unknown status refused');
select throws_ok($$ select public.confirm_payment('00000000-0000-0000-0000-000000000000', 'x', 'paid', null) $$,
  'P0001', 'BOLEIA_PAYMENT_NOT_FOUND', 'unknown payment');

-- ---------------------------------------------------------------------------
-- B. Несовпадение телефона: деньги пришли, сразу возврат
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r2', public.request_booking(pg_temp.cu('trip_p'), 1)::text);
insert into ctx values ('b2', pg_temp.cj('r2', 'booking_id')::text), ('p2', pg_temp.cj('r2', 'payment_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cu('p2'), 'ref-2', 'paid', '+244999999999') $$, 'paid from another phone');
select is((select status::text from public.bookings where id = pg_temp.cu('b2')), 'payment_failed', 'mismatch -> payment_failed');
select is((select cancel_reason from public.bookings where id = pg_temp.cu('b2')), 'PAYMENT_PHONE_MISMATCH', 'reason recorded');
select is(public.escrow_balance_kz(pg_temp.cu('b2')), 0, 'escrow emptied by refund');
select is((select count(*) from public.ledger_entries where booking_id = pg_temp.cu('b2')), 4::bigint, 'payment + refund rows');
select is((select (status::text, refund_kz, refund_ref) from public.payments where id = pg_temp.cu('p2')),
  ('paid'::text, 8000, null::text), 'payment paid, refund pending for gateway');
select is((select refund_kz from public.bookings where id = pg_temp.cu('b2')), 8000, 'booking refund_kz');
select is((select seats_available from public.trips where id = pg_temp.cu('trip_p')), 3::smallint, 'seat released');
select is((select count(*) from public.events where user_id = pg_temp.cu('ana') and name = 'payment_phone_mismatch'), 1::bigint, 'mismatch counted');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'payment_failed'
                  and payload ->> 'reason' = 'PAYMENT_PHONE_MISMATCH'), 'passenger told why');

-- ---------------------------------------------------------------------------
-- C. failed / expired от шлюза и retry_payment
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r3', public.request_booking(pg_temp.cu('trip_p'), 1)::text);
insert into ctx values ('b3', pg_temp.cj('r3', 'booking_id')::text), ('p3', pg_temp.cj('r3', 'payment_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cu('p3'), 'ref-3', 'failed', null) $$, 'gateway failed');
select is((select status::text from public.bookings where id = pg_temp.cu('b3')), 'payment_failed', 'failed -> payment_failed');
select is((select status::text from public.payments where id = pg_temp.cu('p3')), 'failed', 'payment failed');
select is((select count(*) from public.ledger_entries where booking_id = pg_temp.cu('b3')), 0::bigint, 'no ledger rows for failed payment');

select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r3b', public.retry_payment(pg_temp.cu('b3'))::text);
select throws_ok($$ select public.retry_payment(pg_temp.cu('b3')) $$, 'P0001', 'BOLEIA_PAYMENT_PENDING', 'retry while pending refused');
reset role;
select is((select status::text from public.bookings where id = pg_temp.cu('b3')), 'pending_payment', 'retry -> pending_payment');
select is((select count(*) from public.payments where booking_id = pg_temp.cu('b3')), 2::bigint, 'second payment row');
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r3b', 'payment_id'), 'ref-3b', 'expired', null) $$, 'gateway expired');
select is((select status::text from public.payments where id = pg_temp.cj('r3b', 'payment_id')), 'expired', 'payment expired');

select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r3c', public.retry_payment(pg_temp.cu('b3'))::text);
reset role;
-- payments-init проставил provider_ref, вебхук пришёл с другим
update public.payments set provider_ref = 'init-3c', status = 'pending' where id = pg_temp.cj('r3c', 'payment_id');
select throws_ok($$ select public.confirm_payment(pg_temp.cj('r3c', 'payment_id'), 'other-ref', 'failed', null) $$,
  'P0001', 'BOLEIA_PAYMENT_REF_MISMATCH', 'foreign provider_ref refused');
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r3c', 'payment_id'), 'init-3c', 'failed', null) $$, 'third attempt failed');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.retry_payment(pg_temp.cu('b3')) $$, 'P0001', 'BOLEIA_PAYMENT_RETRY_LIMIT', '4th attempt refused');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.retry_payment(pg_temp.cu('b3')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'retry by someone else refused');

-- ---------------------------------------------------------------------------
-- D. Approval: requested -> declined / accepted
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r4', public.request_booking(pg_temp.cu('trip_a'), 1)::text);
insert into ctx values ('b4', pg_temp.cj('r4', 'booking_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r4', 'payment_id'), 'ref-4', 'paid', '+244900000005') $$, 'approval: paid');
select is((select status::text from public.bookings where id = pg_temp.cu('b4')), 'requested', 'approval: paid -> requested');
select ok((select requested_at is not null and responded_at is null from public.bookings where id = pg_temp.cu('b4')), 'requested_at set, no response yet');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
           where c.booking_id = pg_temp.cu('b4') and m.sender_id is null and m.body like 'Pedido pago%'), 1::bigint, 'system message: request paid');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('teresa') and type = 'booking_requested'
                  and channel = 'sms'), 'driver notified by sms (no device)');
select is(public.escrow_balance_kz(pg_temp.cu('b4')), 8000, 'escrow holds 8000');

select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.respond_booking(pg_temp.cu('b4'), true) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'passenger cannot respond');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.respond_booking(pg_temp.cu('b4'), false, 'Carro cheio') $$, 'driver declines');
select throws_ok($$ select public.respond_booking(pg_temp.cu('b4'), true) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'cannot respond twice');
reset role;
select is((select (status::text, cancel_reason, refund_kz) from public.bookings where id = pg_temp.cu('b4')),
  ('declined'::text, 'Carro cheio'::text, 8000), 'declined with full refund');
select is(public.escrow_balance_kz(pg_temp.cu('b4')), 0, 'escrow emptied');
select is((select refund_kz from public.payments where id = pg_temp.cj('r4', 'payment_id')), 8000, 'payment refund pending');
select is((select cancels_total from public.profiles where id = pg_temp.cu('teresa')), 0::smallint, 'decline is not a cancel');
select is((select seats_available from public.trips where id = pg_temp.cu('trip_a')), 3::smallint, 'seat released after decline');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'booking_declined'), 'passenger notified');

select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r5', public.request_booking(pg_temp.cu('trip_a'), 1)::text);
insert into ctx values ('b5', pg_temp.cj('r5', 'booking_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r5', 'payment_id'), 'ref-5', 'paid', '+244900000005') $$, 'approval: paid again');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.respond_booking(pg_temp.cu('b5'), true) $$, 'driver accepts');
reset role;
select is((select status::text from public.bookings where id = pg_temp.cu('b5')), 'accepted', 'requested -> accepted');
select matches((select pin_code from public.bookings where id = pg_temp.cu('b5')), '^\d{4}$', 'PIN generated on accept');

-- ---------------------------------------------------------------------------
-- E. Отмены по таблице раздела 5
-- ---------------------------------------------------------------------------
-- пассажир, > 24 ч
select pg_temp.as_user(pg_temp.cu('ana'));
select is(public.cancel_quote(pg_temp.cu('b5')) - 'counter',
  '{"refund_kz": 8000, "gateway_fee_kz": 0, "held_kz": 0, "rule": "passenger_early"}'::jsonb, 'quote: early cancel = 100% minus gateway fee (0)');
insert into ctx values ('c5', public.cancel_booking(pg_temp.cu('b5'), 'Mudei de planos')::text);
reset role;
select is(pg_temp.c('c5')::jsonb ->> 'refund_kz', '8000', 'early cancel refund');
select is((select (status::text, cancelled_by::text, cancel_reason, refund_kz) from public.bookings where id = pg_temp.cu('b5')),
  ('cancelled'::text, 'passenger'::text, 'Mudei de planos'::text, 8000), 'cancelled by passenger');
select is(public.escrow_balance_kz(pg_temp.cu('b5')), 0, 'escrow emptied');
select is((select cancels_total from public.profiles where id = pg_temp.cu('ana')), 1::smallint, 'passenger cancels_total +1');
select is((select array_agg(channel::text order by channel::text) from public.notifications where user_id = pg_temp.cu('teresa') and type = 'booking_cancelled_by_passenger'),
  array['inapp'], 'driver notified in-app only');
select is((select seats_available from public.trips where id = pg_temp.cu('trip_a')), 3::smallint, 'seat released');

-- пассажир, < 24 ч: 50 %, остаток в эскроу
update public.trips set departure_at = now() + interval '10 hours', driver_confirmed_at = now() where id = pg_temp.cu('trip_i');
select pg_temp.as_user(pg_temp.cu('ana'));
select is(public.cancel_quote(pg_temp.cu('b1')) - 'counter',
  '{"refund_kz": 7700, "gateway_fee_kz": 0, "held_kz": 7700, "rule": "passenger_late"}'::jsonb, 'quote: late cancel = 50%');
insert into ctx values ('c1', public.cancel_booking(pg_temp.cu('b1'))::text);
reset role;
select is(pg_temp.c('c1')::jsonb - 'status', '{"refund_kz": 7700, "held_kz": 7700, "rule": "passenger_late"}'::jsonb, 'late cancel result');
select is(public.escrow_balance_kz(pg_temp.cu('b1')), 7700, 'half stays in escrow');
select is((select refund_kz from public.bookings where id = pg_temp.cu('b1')), 7700, 'booking refund_kz = half');
select is((select refund_kz from public.payments where id = pg_temp.cu('p1')), 7700, 'payment refund_kz = half');
select is((select cancels_total from public.profiles where id = pg_temp.cu('ana')), 2::smallint, 'passenger cancels_total +1');
select is((select (status::text, seats_available) from public.trips where id = pg_temp.cu('trip_i')), ('published'::text, 3::smallint), 'trip back to published, seats released');

-- бесплатная отмена: водитель не подтвердил к -6 ч
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r6', public.request_booking(pg_temp.cu('trip_i2'), 1)::text);
insert into ctx values ('b6', pg_temp.cj('r6', 'booking_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r6', 'payment_id'), 'ref-6', 'paid', '+244900000005') $$, 'paid');
update public.trips set departure_at = now() + interval '5 hours' where id = pg_temp.cu('trip_i2');
select pg_temp.as_user(pg_temp.cu('ana'));
select is(public.cancel_quote(pg_temp.cu('b6')) ->> 'rule', 'driver_unconfirmed', 'quote: driver did not confirm');
insert into ctx values ('c6', public.cancel_booking(pg_temp.cu('b6'))::text);
reset role;
select is(pg_temp.c('c6')::jsonb ->> 'refund_kz', '8000', 'free cancel: 100%');
select is((select cancels_total from public.profiles where id = pg_temp.cu('ana')), 2::smallint, 'free cancel does not count');

-- водитель на неотвеченный запрос = отказ, без санкции
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r7', public.request_booking(pg_temp.cu('trip_a2'), 2)::text);
insert into ctx values ('b7', pg_temp.cj('r7', 'booking_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r7', 'payment_id'), 'ref-7', 'paid', '+244900000005') $$, 'paid');
select pg_temp.as_user(pg_temp.cu('teresa'));
insert into ctx values ('c7', public.cancel_booking(pg_temp.cu('b7'), 'Avaria')::text);
reset role;
select is(pg_temp.c('c7')::jsonb ->> 'rule', 'driver_decline', 'driver cancel on requested = decline');
select is((select (status::text, refund_kz) from public.bookings where id = pg_temp.cu('b7')), ('declined'::text, 15400), 'declined, full refund');
select is((select cancels_total from public.profiles where id = pg_temp.cu('teresa')), 0::smallint, 'no sanction for decline');

-- водитель на принятую бронь: 100 %, счётчик +1
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r8', public.request_booking(pg_temp.cu('trip_a3'), 1)::text);
insert into ctx values ('b8', pg_temp.cj('r8', 'booking_id')::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r8', 'payment_id'), 'ref-8', 'paid', '+244900000005') $$, 'paid');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.respond_booking(pg_temp.cu('b8'), true) $$, 'accepted');
select is(public.cancel_quote(pg_temp.cu('b8')) ->> 'rule', 'driver_cancel', 'quote for driver');
insert into ctx values ('c8', public.cancel_booking(pg_temp.cu('b8'), 'Avaria')::text);
reset role;
select is((select (status::text, cancelled_by::text, refund_kz) from public.bookings where id = pg_temp.cu('b8')),
  ('cancelled'::text, 'driver'::text, 8000), 'cancelled by driver, full refund');
select is((select cancels_total from public.profiles where id = pg_temp.cu('teresa')), 1::smallint, 'driver cancels_total +1');
select is((select array_agg(channel::text order by channel::text) from public.notifications where user_id = pg_temp.cu('ana') and type = 'booking_cancelled_by_driver'),
  array['inapp', 'sms'], 'passenger notified inapp + sms');

-- ошибки отмены
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.cancel_booking(pg_temp.cu('b8')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'stranger cannot cancel');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.cancel_booking(pg_temp.cu('b8')) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'cannot cancel twice');
insert into ctx values ('r9', public.request_booking(pg_temp.cu('trip_p'), 1)::text);
insert into ctx values ('b9', pg_temp.cj('r9', 'booking_id')::text);
select throws_ok($$ select public.cancel_booking(pg_temp.cu('b9')) $$, 'P0001', 'BOLEIA_PAYMENT_PENDING', 'cannot cancel while payment pending');
select throws_ok($$ select public.cancel_quote(pg_temp.cu('b9')) $$, 'P0001', 'BOLEIA_PAYMENT_PENDING', 'no quote while payment pending');
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r9', 'payment_id'), 'ref-9', 'paid', '+244900000005') $$, 'paid');
update public.trips set status = 'departed', departed_at = now() where id = pg_temp.cu('trip_p');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.cancel_booking(pg_temp.cu('b9')) $$, 'P0001', 'BOLEIA_TOO_LATE_TO_CANCEL', 'no cancel after departure');
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_p'), 1) $$, 'P0001', 'BOLEIA_TRIP_NOT_BOOKABLE', 'departed trip not bookable');

-- ---------------------------------------------------------------------------
-- F. Поздняя оплата: бронь уже payment_failed, деньги возвращаются
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('r10', public.request_booking(pg_temp.cu('trip_p2'), 1)::text);
insert into ctx values ('b10', pg_temp.cj('r10', 'booking_id')::text);
reset role;
update public.bookings set status = 'payment_failed' where id = pg_temp.cu('b10');  -- так сделает cron
select lives_ok($$ select public.confirm_payment(pg_temp.cj('r10', 'payment_id'), 'ref-10', 'paid', '+244900000005') $$, 'late paid webhook');
select is((select status::text from public.bookings where id = pg_temp.cu('b10')), 'payment_failed', 'booking untouched');
select is(public.escrow_balance_kz(pg_temp.cu('b10')), 0, 'late payment fully refunded');
select is((select refund_kz from public.payments where id = pg_temp.cj('r10', 'payment_id')), 8000, 'refund pending for gateway');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'refund_done'), 'passenger told about refund');

-- ---------------------------------------------------------------------------
-- G. Лимиты: TRIP_NOT_BOOKABLE, TRIP_FULL, BOOKING_LIMIT_REACHED
-- ---------------------------------------------------------------------------
update public.trips set departure_at = now() + interval '50 minutes' where id = pg_temp.cu('trip_p2');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_p2'), 1) $$, 'P0001', 'BOLEIA_TRIP_NOT_BOOKABLE', 'less than 1h before departure');
insert into ctx values ('r11', public.request_booking(pg_temp.cu('trip_p3'), 3)::text);
reset role;
select is((select status::text from public.trips where id = pg_temp.cu('trip_p3')), 'full', 'trip full after 3 seats reserved');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_p3'), 1) $$, 'P0001', 'BOLEIA_TRIP_FULL', 'full trip refused');
-- Ana: активны b9 (accepted) и r11 (pending); третья проходит, четвёртая нет
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.request_booking(pg_temp.cu('trip_x'), 1) $$, 'third active booking allowed');
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_y'), 1) $$, 'P0001', 'BOLEIA_BOOKING_LIMIT_REACHED', 'fourth active booking refused');

-- ---------------------------------------------------------------------------
-- H. restricted: три несовпадения телефона
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('joao'));
insert into ctx values ('m1', public.request_booking(pg_temp.cu('trip_y'), 1)::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('m1', 'payment_id'), 'ref-m1', 'paid', '+244911111111') $$, 'mismatch 1');
select pg_temp.as_user(pg_temp.cu('joao'));
insert into ctx values ('m2', public.request_booking(pg_temp.cu('trip_y'), 1)::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('m2', 'payment_id'), 'ref-m2', 'paid', '+244911111111') $$, 'mismatch 2');
select is((select status::text from public.profiles where id = pg_temp.cu('joao')), 'active', 'still active after 2 mismatches');
select pg_temp.as_user(pg_temp.cu('joao'));
insert into ctx values ('m3', public.request_booking(pg_temp.cu('trip_y'), 1)::text);
reset role;
select lives_ok($$ select public.confirm_payment(pg_temp.cj('m3', 'payment_id'), 'ref-m3', 'paid', '+244911111111') $$, 'mismatch 3');
select is((select status::text from public.profiles where id = pg_temp.cu('joao')), 'restricted', 'restricted after 3 mismatches');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.request_booking(pg_temp.cu('trip_y'), 1) $$, 'P0001', 'BOLEIA_PROFILE_RESTRICTED', 'restricted cannot book');
select throws_ok($$ select public.retry_payment(pg_temp.cj('m3', 'booking_id')) $$, 'P0001', 'BOLEIA_PROFILE_RESTRICTED', 'restricted cannot retry');
select lives_ok($$ select public.upsert_profile('{"bio":"ainda cá"}') $$, 'restricted: other RPCs still work');
reset role;

-- ---------------------------------------------------------------------------
-- I. Ledger: инварианты и хелперы для 0006
-- ---------------------------------------------------------------------------
select throws_ok($$ select public.ledger_post(gen_random_uuid(), 'test', null,
  '[{"account":"platform_fee","amount_kz":5},{"account":"refunds","amount_kz":-4}]') $$,
  'P0001', 'BOLEIA_LEDGER_UNBALANCED', 'unbalanced op refused');
select throws_ok($$ select public.ledger_post(gen_random_uuid(), 'test', null, '[{"account":"platform_fee","amount_kz":0}]') $$,
  'P0001', 'BOLEIA_LEDGER_UNBALANCED', 'single-row op refused');
select throws_ok($$ select public.ledger_refund(b, 1, 0) from public.bookings b where id = pg_temp.cu('b5') $$,
  'P0001', 'BOLEIA_LEDGER_UNBALANCED', 'refund above escrow refused');
select throws_ok($$ update public.ledger_entries set amount_kz = 0 where booking_id = pg_temp.cu('b1') $$,
  'P0001', 'BOLEIA_LEDGER_IMMUTABLE', 'ledger is insert-only');

-- release удержанной половины b1: 7700 -> водитель 7000, платформа 700
select lives_ok($$ select public.ledger_release(b, 7700) from public.bookings b where id = pg_temp.cu('b1') $$, 'release held half');
select is(public.escrow_balance_kz(pg_temp.cu('b1')), 0, 'escrow emptied by release');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('b1') and account = 'driver_balance'), 7000, 'driver gets price share');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('b1') and account = 'platform_fee'), 700, 'platform gets fee share');
select is((select balance_kz from public.profiles where id = pg_temp.cu('joao')), 7000, 'balance_kz cache synced through guard');
select lives_ok($$ select public.ledger_forfeit(b, 8000) from public.bookings b where id = pg_temp.cu('b9') $$, 'forfeit');
select is(public.escrow_balance_kz(pg_temp.cu('b9')), 0, 'escrow emptied by forfeit');

select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x),
  0::bigint, 'every ledger op sums to zero');
select is((select sum(amount_kz) from public.ledger_entries where account = 'cash_in'),
  -(select sum(amount_kz) from public.payments where status = 'paid'), 'cash_in equals paid payments');
select is((select coalesce(sum(amount_kz), 0) from public.ledger_entries where account = 'passenger_escrow'),
  (select coalesce(sum(public.escrow_balance_kz(id)), 0) from public.bookings), 'escrow total consistent');

select * from finish();
rollback;
