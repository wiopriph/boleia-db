begin;
create extension if not exists pgtap with schema extensions;
select plan(103);

-- ---------------------------------------------------------------------------
-- Контекст и хелперы. Сид-поездки отменяются, сценарии строят свои с выездом D = now() + 100 дней,
-- run_scheduler(as_of) двигает время. RPC внутри используют настоящее now().
-- ---------------------------------------------------------------------------
create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;
create function pg_temp.c(text)  returns text language sql as $$ select v from ctx where k = $1 $$;
create function pg_temp.cu(text) returns uuid language sql as $$ select v::uuid from ctx where k = $1 $$;
create function pg_temp.d(interval) returns timestamptz language sql as $$ select pg_temp.c('D')::timestamptz + $1 $$;
create function pg_temp.t0(interval) returns timestamptz language sql as $$ select now() + $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.mk_trip(k text, driver_k text, o text, dst text, dep timestamptz, mode booking_mode) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.trips (driver_id, vehicle_id, origin_place_id, destination_place_id, origin_detail, destination_detail,
    departure_at, seats_offered, seats_available, price_per_seat_kz, booking_mode, status, published_at)
  select pg_temp.cu(driver_k), (select id from public.vehicles where owner_id = pg_temp.cu(driver_k) limit 1),
         (select id from public.places where slug = o), (select id from public.places where slug = dst), 'Gamek', 'Terminal',
         dep, 3, 3, 7000, mode, 'published', now()
  returning id into v_id;
  insert into ctx values (k, v_id::text);
  return v_id;
end $$;
create function pg_temp.book_paid(k text, trip_k text, passenger_k text, n integer) returns uuid language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.cu(passenger_k));
  r := public.request_booking(pg_temp.cu(trip_k), n);
  perform set_config('role', 'none', true);
  perform public.confirm_payment((r ->> 'payment_id')::uuid, 'ref-' || k, 'paid',
    (select phone from public.profiles where id = pg_temp.cu(passenger_k)));
  insert into ctx values (k, r ->> 'booking_id'), (k || '_pay', r ->> 'payment_id');
  return (r ->> 'booking_id')::uuid;
end $$;
create function pg_temp.book_pending(k text, trip_k text, passenger_k text, n integer) returns uuid language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.cu(passenger_k));
  r := public.request_booking(pg_temp.cu(trip_k), n);
  perform set_config('role', 'none', true);
  insert into ctx values (k, r ->> 'booking_id'), (k || '_pay', r ->> 'payment_id');
  return (r ->> 'booking_id')::uuid;
end $$;
create function pg_temp.run(p_k text, as_of timestamptz) returns jsonb language plpgsql as $$
declare r jsonb := public.run_scheduler(as_of);
begin
  insert into ctx values (p_k, r::text) on conflict (k) do update set v = excluded.v;
  return r;
end $$;
create function pg_temp.notif(user_k text, type text, trip_k text) returns bigint language sql as $$
  select count(*) from public.notifications
  where user_id = pg_temp.cu(user_k) and notifications.type = notif.type and channel = 'inapp'
    and payload ->> 'trip_id' = pg_temp.c(trip_k)
$$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555'),
  ('D',      (now() + interval '100 days')::text);

update public.trips set status = 'cancelled', cancelled_at = now();  -- сид-поездки в сторону

select pg_temp.mk_trip('A', 'joao',   'luanda', 'benguela', pg_temp.d('0'), 'instant');
select pg_temp.mk_trip('B', 'teresa', 'luanda', 'benguela', pg_temp.d('0'), 'approval');
select pg_temp.mk_trip('C', 'teresa', 'luanda', 'lobito',   pg_temp.d('0'), 'approval');
select pg_temp.mk_trip('F', 'pedro',  'luanda', 'benguela', pg_temp.t0('10 hours'), 'instant');
select pg_temp.mk_trip('E', 'joao',   'luanda', 'caxito',   pg_temp.d('0'), 'instant');   -- нет в route_durations -> 480 мин
select pg_temp.mk_trip('G', 'joao',   'luanda', 'benguela', pg_temp.d('0'), 'instant');   -- 420 мин
select pg_temp.mk_trip('H', 'pedro',  'luanda', 'benguela', pg_temp.d('0'), 'instant');
select pg_temp.mk_trip('K', 'joao',   'luanda', 'huambo',   pg_temp.d('0'), 'instant');

select is((select count(*) from cron.job where jobname = 'boleia_scheduler'), 1::bigint, 'cron job registered');

-- ---------------------------------------------------------------------------
-- 1. Протухание платежа: expires_at + 5 мин
-- ---------------------------------------------------------------------------
select pg_temp.book_pending('a_A', 'A', 'ana', 1);
select pg_temp.run('r10m', pg_temp.t0('10 minutes'));
select is((select status::text from public.payments where id = pg_temp.cu('a_A_pay')), 'created', 'payment alive at +10m');
select is(pg_temp.c('r10m')::jsonb ->> 'refresh_route_stats', '1', 'route_stats refreshed on first run');
select is(pg_temp.c('r10m')::jsonb ->> 'reconcile', '0', 'reconcile clean');
select pg_temp.run('r21m', pg_temp.t0('21 minutes'));
select is(pg_temp.c('r21m')::jsonb ->> 'expire_payments', '1', 'one payment expired');
select is(pg_temp.c('r21m')::jsonb ->> 'refresh_route_stats', 'skipped', 'hourly job skipped within the hour');
select is(pg_temp.c('r21m')::jsonb ->> 'cleanup', 'skipped', 'daily job skipped');
select is((select (status::text) from public.payments where id = pg_temp.cu('a_A_pay')), 'expired', 'payment expired');
select is((select (status::text, cancel_reason) from public.bookings where id = pg_temp.cu('a_A')), ('payment_failed'::text, 'payment_expired'::text), 'booking payment_failed');
select is((select seats_available from public.trips where id = pg_temp.cu('A')), 3::smallint, 'seat released');
select is((select count(*) from public.notifications where payload ->> 'booking_id' = pg_temp.c('a_A') and type = 'payment_failed' and channel = 'inapp'), 1::bigint, 'passenger notified once');
select pg_temp.run('r21m_again', pg_temp.t0('21 minutes'));
select is(pg_temp.c('r21m_again')::jsonb ->> 'expire_payments', '0', 'idempotent');
select is((select count(*) from public.notifications where payload ->> 'booking_id' = pg_temp.c('a_A') and type = 'payment_failed' and channel = 'inapp'), 1::bigint, 'no duplicate notification');

-- ---------------------------------------------------------------------------
-- 2. Поездка без принятых броней истекает, удержание поздней отмены уходит платформе
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('t_F', 'F', 'teresa', 1);
update public.trips set driver_confirmed_at = now() where id = pg_temp.cu('F');
select pg_temp.as_user(pg_temp.cu('teresa'));
select is((public.cancel_booking(pg_temp.cu('t_F'))) ->> 'held_kz', '4000', 'late cancel: 4000 held');
reset role;
select pg_temp.run('rF', pg_temp.t0('10 hours 1 minute'));
select is((select status::text from public.trips where id = pg_temp.cu('F')), 'expired', 'trip without accepted bookings expired at departure');
select is(public.escrow_balance_kz(pg_temp.cu('t_F')), 0, 'hold forfeited');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('t_F') and memo like 'forfeit:%' and account = 'platform_fee'), 4000, 'forfeit to platform');

-- ---------------------------------------------------------------------------
-- 3. Протухание запросов: 24 ч и departure - 1 ч
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a_B', 'B', 'ana', 1);
select pg_temp.book_paid('a_C', 'C', 'ana', 1);
update public.bookings set requested_at = pg_temp.d('-2 hours') where id = pg_temp.cu('a_C');
select is((select status::text from public.bookings where id = pg_temp.cu('a_B')), 'requested', 'approval booking requested');
insert into ctx values ('teresa_cancels', (select cancels_total::text from public.profiles where id = pg_temp.cu('teresa')));
select pg_temp.run('r23h', pg_temp.t0('23 hours'));
select is((select status::text from public.bookings where id = pg_temp.cu('a_B')), 'requested', 'still requested at 23h');
select pg_temp.run('r24h', pg_temp.t0('24 hours 1 minute'));
select is((select (status::text, cancel_reason, refund_kz) from public.bookings where id = pg_temp.cu('a_B')), ('expired'::text, 'no_response'::text, 8000), 'request expired with full refund');
select is(public.escrow_balance_kz(pg_temp.cu('a_B')), 0, 'escrow refunded');
select is(pg_temp.notif('ana', 'booking_expired', 'B'), 1::bigint, 'passenger notified');
select is((select cancels_total from public.profiles where id = pg_temp.cu('teresa')), pg_temp.c('teresa_cancels')::smallint, 'no sanction for silence');
select is((select status::text from public.bookings where id = pg_temp.cu('a_C')), 'requested', 'C untouched by 24h rule');

-- ---------------------------------------------------------------------------
-- Данные для дня D
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a_E', 'E', 'ana', 1);
select pg_temp.book_pending('t_E', 'E', 'teresa', 1);
update public.payments set expires_at = pg_temp.d('1 hour') where id = pg_temp.cu('t_E_pay');  -- payments-init продлил
select pg_temp.book_paid('a_G', 'G', 'ana', 1);
select pg_temp.book_paid('t_H', 'H', 'teresa', 1);
select public.ensure_conversation(pg_temp.cu('K'), pg_temp.cu('ana'));  -- чат без брони
insert into public.devices (user_id, platform, push_token, last_seen_at) values (pg_temp.cu('ana'), 'android', 'old-token', now() - interval '100 days');
insert into public.events (user_id, name, props, created_at) values (pg_temp.cu('ana'), 'search', '{}', now() - interval '400 days');
insert into public.driver_verifications (user_id, vehicle_id, id_doc_url, status, reviewed_at)
  values (pg_temp.cu('pedro'), (select id from public.vehicles where owner_id = pg_temp.cu('pedro') limit 1), 'https://x/doc.jpg', 'rejected', now() - interval '40 days');

-- ---------------------------------------------------------------------------
-- 4. Напоминания -24 ч и -6 ч, чистка
-- ---------------------------------------------------------------------------
select pg_temp.run('r25h', pg_temp.d('-25 hours'));
select ok((select reminded_24h_at is null from public.trips where id = pg_temp.cu('G')), 'no 24h reminder at -25h');
select is((select count(*) from public.devices where push_token = 'old-token'), 0::bigint, 'cleanup: stale device deleted');
select is((select count(*) from public.events where name = 'search' and created_at < now() - interval '12 months'), 0::bigint, 'cleanup: old events deleted');
select is((select id_doc_url from public.driver_verifications where user_id = pg_temp.cu('pedro')), null, 'cleanup: verification documents wiped after 30 days');
select ok((select closed_at is not null from public.conversations where booking_id = pg_temp.cu('a_B')), 'expired booking chat closed after 24h');

select pg_temp.run('r23hD', pg_temp.d('-23 hours'));
select ok((select reminded_24h_at is not null from public.trips where id = pg_temp.cu('G')), '24h reminder marked');
select is(pg_temp.notif('joao', 'trip_reminder_24h', 'G'), 1::bigint, 'driver reminded');
select is(pg_temp.notif('ana', 'trip_reminder_24h', 'G'), 1::bigint, 'passenger reminded');
select pg_temp.run('r23hD_again', pg_temp.d('-23 hours'));
select is(pg_temp.notif('ana', 'trip_reminder_24h', 'G'), 1::bigint, 'no duplicate reminder');

select pg_temp.as_user(pg_temp.cu('pedro'));
select lives_ok($$ select public.confirm_trip_intent(pg_temp.cu('H')) $$, 'Pedro confirms H');
reset role;
select pg_temp.run('r5h', pg_temp.d('-5 hours'));
select is(pg_temp.notif('ana', 'driver_unconfirmed', 'G'), 1::bigint, 'G passengers told driver is silent');
select is(pg_temp.notif('joao', 'trip_reminder_6h', 'G'), 1::bigint, 'G driver last reminder');
select is(pg_temp.notif('teresa', 'driver_unconfirmed', 'H'), 0::bigint, 'H confirmed: no warning');
select ok((select reminded_6h_at is null from public.trips where id = pg_temp.cu('H')), 'H not marked');

-- ---------------------------------------------------------------------------
-- 5. PIN за 2 ч, поздняя бронь получает PIN на следующем тике
-- ---------------------------------------------------------------------------
select pg_temp.run('r2h', pg_temp.d('-2 hours'));
select ok((select pin_sent_at is not null from public.bookings where id = pg_temp.cu('a_G')), 'pin_sent_at set');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
           where c.booking_id = pg_temp.cu('a_G') and m.sender_id is null
             and m.body like '%' || (select pin_code from public.bookings where id = pg_temp.cu('a_G')) || '%'), 1::bigint, 'PIN posted in chat');
select is((select payload ->> 'pin' from public.notifications where type = 'pin_ready' and payload ->> 'booking_id' = pg_temp.c('a_G') and channel = 'inapp'),
  (select pin_code::text from public.bookings where id = pg_temp.cu('a_G')), 'pin_ready carries the PIN');
select is((select payload ->> 'driver_phone' from public.notifications where type = 'pin_ready' and payload ->> 'booking_id' = pg_temp.c('a_G') and channel = 'inapp'),
  '+244900000002', 'pin_ready carries driver phone');
select ok(exists (select 1 from public.notifications where type = 'pin_ready' and payload ->> 'booking_id' = pg_temp.c('a_G') and channel = 'sms'), 'pin_ready also by SMS');
select is(pg_temp.notif('joao', 'trip_reminder_2h', 'G'), 1::bigint, 'driver gets passenger list once');
select is((select jsonb_array_length(payload -> 'passengers') from public.notifications where type = 'trip_reminder_2h' and payload ->> 'trip_id' = pg_temp.c('H') and channel = 'inapp'), 1, 'H passenger list has 1');

select pg_temp.book_paid('adm_H', 'H', 'admin', 1);  -- бронь после отметки
select ok((select pin_sent_at is null from public.bookings where id = pg_temp.cu('adm_H')), 'late booking has no PIN yet');
select pg_temp.run('r61m', pg_temp.d('-61 minutes'));
select ok((select pin_sent_at is not null from public.bookings where id = pg_temp.cu('adm_H')), 'late booking gets PIN next tick');
select is(pg_temp.notif('pedro', 'trip_reminder_2h', 'H'), 1::bigint, 'driver list not re-sent');
select is((select status::text from public.bookings where id = pg_temp.cu('a_C')), 'requested', 'C still requested 61 min before');
select pg_temp.run('r59m', pg_temp.d('-59 minutes'));
select is((select status::text from public.bookings where id = pg_temp.cu('a_C')), 'expired', 'C expired at departure - 1h');
select is(public.escrow_balance_kz(pg_temp.cu('a_C')), 0, 'C refunded');

-- ---------------------------------------------------------------------------
-- 6. Выезд
-- ---------------------------------------------------------------------------
select pg_temp.run('rD', pg_temp.d('0'));
select is((select (status::text, departed_at) from public.trips where id = pg_temp.cu('E')), ('departed'::text, pg_temp.d('0')), 'E departed');
select is((select status::text from public.bookings where id = pg_temp.cu('a_E')), 'awaiting_confirm', 'accepted -> awaiting_confirm');
select is((select (status::text, cancel_reason) from public.bookings where id = pg_temp.cu('t_E')), ('payment_failed'::text, 'trip_departed'::text), 'pending -> payment_failed at departure');
select is((select status::text from public.payments where id = pg_temp.cu('t_E_pay')), 'expired', 'its payment expired');
select is((select status::text from public.trips where id = pg_temp.cu('K')), 'expired', 'trip without bookings expired');
select is((select status::text from public.trips where id = pg_temp.cu('H')), 'departed', 'H departed');

-- ---------------------------------------------------------------------------
-- 7. "Вы доехали?" по route_durations (G: 420) и по умолчанию (E: 480)
-- ---------------------------------------------------------------------------
select pg_temp.run('r419', pg_temp.d('419 minutes'));
select ok((select completed_ask_at is null from public.trips where id = pg_temp.cu('G')), 'not asked at 419 min');
select pg_temp.run('r420', pg_temp.d('420 minutes'));
select is(pg_temp.notif('ana', 'trip_completed_ask', 'G'), 1::bigint, 'asked at 420 min (route_durations)');
select ok((select completed_ask_at is null from public.trips where id = pg_temp.cu('E')), 'E not yet (default 480)');
select pg_temp.run('r480', pg_temp.d('480 minutes'));
select is(pg_temp.notif('ana', 'trip_completed_ask', 'E'), 1::bigint, 'E asked at 480 min');

-- ---------------------------------------------------------------------------
-- 8. Водитель не приехал: спор без PIN, 24 ч без ответа водителя
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('a_G'), false) $$, 'Ana disputes G');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('t_H'), false) $$, 'Teresa disputes H');
reset role;
insert into public.messages (conversation_id, sender_id, body)
  select id, pg_temp.cu('pedro'), 'Estive lá às 6h, esperei 30 min.' from public.conversations where booking_id = pg_temp.cu('t_H');
insert into ctx values ('joao_cancels', (select cancels_total::text from public.profiles where id = pg_temp.cu('joao')));
select pg_temp.run('r9h', pg_temp.d('9 hours'));
select is(pg_temp.c('r9h')::jsonb ->> 'driver_no_show', '1', 'one trip auto-cancelled');
select is((select (status::text, cancel_reason) from public.trips where id = pg_temp.cu('G')), ('cancelled'::text, 'driver_no_show'::text), 'G cancelled for driver no-show');
select is((select (status::text, cancelled_by::text, cancel_reason, refund_kz) from public.bookings where id = pg_temp.cu('a_G')),
  ('cancelled'::text, 'driver'::text, 'driver_no_show'::text, 8000), 'Ana refunded in full');
select is(public.escrow_balance_kz(pg_temp.cu('a_G')), 0, 'escrow emptied');
select is((select (cancels_total, no_shows) from public.profiles where id = pg_temp.cu('joao')),
  ((pg_temp.c('joao_cancels')::integer + 1)::smallint, 1::smallint), 'driver cancels_total +1, no_shows +1');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'trip_cancelled' and payload ->> 'reason' = 'driver_no_show'), 'passenger told');
select is((select status::text from public.trips where id = pg_temp.cu('H')), 'departed', 'H untouched: driver answered in chat');
select is((select status::text from public.bookings where id = pg_temp.cu('t_H')), 'disputed', 'H dispute waits for moderator');

-- ---------------------------------------------------------------------------
-- 9. Автозавершение: 48 ч с PIN (E), 7 дней без PIN (admin на H)
-- ---------------------------------------------------------------------------
update public.bookings set pin_entered_at = now() where id = pg_temp.cu('a_E');
select pg_temp.run('r47h', pg_temp.d('47 hours'));
select is((select status::text from public.bookings where id = pg_temp.cu('a_E')), 'awaiting_confirm', 'not yet at 47h');
select ok((select closed_at is not null from public.conversations where booking_id = pg_temp.cu('a_G')), 'cancelled booking chat closed after 24h');
select ok((select closed_at is not null from public.conversations where trip_id = pg_temp.cu('K')), 'bookingless chat closed 24h after departure');
select pg_temp.run('r48h', pg_temp.d('48 hours'));
select is((select status::text from public.bookings where id = pg_temp.cu('a_E')), 'completed', 'auto-completed at 48h with PIN');
select is(public.escrow_balance_kz(pg_temp.cu('a_E')), 0, 'released');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.cu('a_E') and account = 'driver_balance'), 7000, 'driver paid');
select is((select status::text from public.trips where id = pg_temp.cu('E')), 'completed', 'E settled');
select is((select trips_driven from public.profiles where id = pg_temp.cu('joao')), 15, 'trips_driven +1');

select pg_temp.run('r6d', pg_temp.d('6 days'));
select is((select status::text from public.bookings where id = pg_temp.cu('adm_H')), 'awaiting_confirm', 'no PIN: not yet at 6 days');
select pg_temp.run('r7d', pg_temp.d('7 days'));
select is((select status::text from public.bookings where id = pg_temp.cu('adm_H')), 'completed', 'auto-completed at 7 days');
select is((select status::text from public.trips where id = pg_temp.cu('H')), 'departed', 'H still open: Teresa disputed');

-- ---------------------------------------------------------------------------
-- 10. Видимость отзыва через 14 дней; закрытие чата через 7 дней после completed
-- ---------------------------------------------------------------------------
update public.bookings set completed_at = pg_temp.d('48 hours') where id = pg_temp.cu('a_E');
insert into public.reviews (booking_id, author_id, target_id, direction, rating)
  values (pg_temp.cu('a_E'), pg_temp.cu('ana'), pg_temp.cu('joao'), 'passenger_to_driver', 5);
select pg_temp.run('r15d', pg_temp.d('15 days'));
select is((select is_visible from public.reviews where booking_id = pg_temp.cu('a_E')), false, 'single review hidden before 14 days');
select ok((select closed_at is not null from public.conversations where booking_id = pg_temp.cu('a_E')), 'completed chat closed after 7 days');
select pg_temp.run('r16d', pg_temp.d('16 days 1 hour'));
select is((select is_visible from public.reviews where booking_id = pg_temp.cu('a_E')), true, 'single review visible after 14 days');

-- ---------------------------------------------------------------------------
-- 11. Сверка ловит расхождение; ошибка шага не ломает остальные
-- ---------------------------------------------------------------------------
select is(pg_temp.c('r16d')::jsonb ->> 'reconcile', '0', 'clean reconcile');
update public.payments set refund_kz = refund_kz + 1 where id = pg_temp.cu('a_B_pay');
delete from public.scheduler_jobs where name = 'reconcile';
select pg_temp.run('r16d2', pg_temp.d('16 days 2 hours'));
select is(pg_temp.c('r16d2')::jsonb ->> 'reconcile', '1', 'one issue found');
select ok(exists (select 1 from public.events where name = 'reconciliation_mismatch' and props -> 'issues' @> '[{"check":"refunds_vs_payments"}]'), 'mismatch event');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('admin') and type = 'reconciliation_alert'), 'admin alerted');
update public.payments set refund_kz = refund_kz - 1 where id = pg_temp.cu('a_B_pay');

drop index public.route_stats_pk;
delete from public.scheduler_jobs where name = 'refresh_route_stats';
select pg_temp.run('r16d3', pg_temp.d('16 days 3 hours'));
select matches(pg_temp.c('r16d3')::jsonb ->> 'refresh_route_stats', '^error:', 'failing step reported');
select is(pg_temp.c('r16d3')::jsonb ->> 'close_chats', '0', 'other steps still ran');
select ok((select last_error is not null from public.scheduler_jobs where name = 'refresh_route_stats'), 'error stored in scheduler_jobs');
select ok(exists (select 1 from public.events where name = 'scheduler_error' and props ->> 'job' = 'refresh_route_stats'), 'error event');

-- ---------------------------------------------------------------------------
-- 12. Тихие часы в notify (22:00-07:00 Luanda)
-- ---------------------------------------------------------------------------
insert into public.devices (user_id, platform, push_token) values (pg_temp.cu('teresa'), 'android', 'tok-teresa');
select public.notify(pg_temp.cu('teresa'), 'trip_reminder_24h', '{"q":1}', false, (timestamp '2026-12-01 23:00') at time zone 'Africa/Luanda');
select is((select scheduled_for from public.notifications where payload ->> 'q' = '1' and channel = 'push'),
  (timestamp '2026-12-02 07:00') at time zone 'Africa/Luanda', 'non-urgent push at 23:00 moves to 07:00 next day');
select is((select scheduled_for from public.notifications where payload ->> 'q' = '1' and channel = 'inapp'),
  (timestamp '2026-12-01 23:00') at time zone 'Africa/Luanda', 'inapp keeps its time');
select public.notify(pg_temp.cu('teresa'), 'trip_reminder_24h', '{"q":2}', false, (timestamp '2026-12-01 06:00') at time zone 'Africa/Luanda');
select is((select scheduled_for from public.notifications where payload ->> 'q' = '2' and channel = 'push'),
  (timestamp '2026-12-01 07:00') at time zone 'Africa/Luanda', 'at 06:00 moves to 07:00 same day');
select public.notify(pg_temp.cu('teresa'), 'payment_failed', '{"q":3}', true, (timestamp '2026-12-01 23:00') at time zone 'Africa/Luanda');
select is((select scheduled_for from public.notifications where payload ->> 'q' = '3' and channel = 'push'),
  (timestamp '2026-12-01 23:00') at time zone 'Africa/Luanda', 'urgent push not delayed');
select public.notify(pg_temp.cu('teresa'), 'trip_reminder_24h', '{"q":4}', false, (timestamp '2026-12-01 12:00') at time zone 'Africa/Luanda');
select is((select scheduled_for from public.notifications where payload ->> 'q' = '4' and channel = 'push'),
  (timestamp '2026-12-01 12:00') at time zone 'Africa/Luanda', 'daytime push not delayed');

-- ---------------------------------------------------------------------------
-- 13. Инварианты и права
-- ---------------------------------------------------------------------------
select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x), 0::bigint, 'every ledger op sums to zero');
select is((select count(*) from public.profiles p where p.balance_kz <> coalesce((select sum(amount_kz) from public.ledger_entries where user_id = p.id and account = 'driver_balance'), 0)),
  0::bigint, 'balance cache consistent');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.run_scheduler() $$, '42501', null, 'authenticated cannot run the scheduler');
select throws_ok($$ select * from public.pending_refunds $$, '42501', null, 'authenticated cannot read pending_refunds');
reset role;
select ok((select count(*) >= 1 from public.pending_refunds), 'pending_refunds lists refunds awaiting the gateway');

select * from finish();
rollback;
