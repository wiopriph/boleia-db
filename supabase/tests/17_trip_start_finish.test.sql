begin;
create extension if not exists pgtap with schema extensions;
select plan(46);

-- ---------------------------------------------------------------------------
-- Миграция 0025: поездку начинает и завершает водитель. Основной сценарий - в 05 и 06; здесь этапы
-- брони (my_bookings.stage), спор с причиной, исход no_show, страховки cron и закрытые ветки.
-- ---------------------------------------------------------------------------
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
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.ctx_uuid('admin'), 'role', 'authenticated',
    'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.as_owner() returns void language sql as $$ select set_config('role', 'none', true) $$;
create function pg_temp.mk_trip(trip_name text, driver_name text, departs timestamptz, mode public.booking_mode) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.trips (driver_id, vehicle_id, origin_place_id, destination_place_id, origin_detail, destination_detail,
    departure_at, seats_offered, seats_available, price_per_seat_kz, booking_mode, status, published_at)
  select pg_temp.ctx_uuid(driver_name), (select id from public.vehicles where owner_id = pg_temp.ctx_uuid(driver_name) limit 1),
         (select id from public.places where slug = 'luanda'), (select id from public.places where slug = 'benguela'),
         'Gamek', 'Terminal', departs, 4, 4, 7000, mode, 'published', now()
  returning id into v_id;
  insert into ctx values (trip_name, v_id::text);
  return v_id;
end $$;
create function pg_temp.book_paid(booking_name text, trip_name text, passenger_name text) returns uuid language plpgsql as $$
declare response jsonb;
begin
  perform pg_temp.as_user(pg_temp.ctx_uuid(passenger_name));
  response := public.request_booking(pg_temp.ctx_uuid(trip_name), 1);
  perform pg_temp.as_owner();
  perform public.confirm_payment((response ->> 'payment_id')::uuid, 'ref-' || booking_name, 'paid',
    (select phone from public.profiles where id = pg_temp.ctx_uuid(passenger_name)));
  insert into ctx values (booking_name, response ->> 'booking_id');
  return (response ->> 'booking_id')::uuid;
end $$;
create function pg_temp.stage(booking_name text) returns text language sql as $$
  select stage from public.my_bookings where id = pg_temp.ctx_uuid(booking_name)
$$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555');
update public.trips set status = 'cancelled', cancelled_at = now();  -- сид-поездки в сторону

select hasnt_function('public', 'mark_no_show', 'mark_no_show is gone');
select hasnt_function('public', 'driver_arrived', 'driver_arrived is gone');

-- ---------------------------------------------------------------------------
-- 1. Этапы брони: accepted -> boarding -> on_board -> in_trip -> finished -> completed
-- ---------------------------------------------------------------------------
select pg_temp.mk_trip('main', 'joao', now() + interval '3 days', 'instant');
select pg_temp.book_paid('ana_main', 'main', 'ana');
select pg_temp.book_paid('pedro_main', 'main', 'pedro');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select is(pg_temp.stage('ana_main'), 'accepted', 'long before the trip: accepted');
select pg_temp.as_owner();
update public.trips set departure_at = now() + interval '90 minutes' where id = pg_temp.ctx_uuid('main');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select is(pg_temp.stage('ana_main'), 'boarding', 'inside 2h before departure: boarding');
select pg_temp.as_owner();
update public.bookings set pin_entered_at = now() where id = pg_temp.ctx_uuid('ana_main');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select is(pg_temp.stage('ana_main'), 'on_board', 'PIN entered, trip not started: on_board');
select pg_temp.as_user(pg_temp.ctx_uuid('pedro'));
select is(pg_temp.stage('pedro_main'), 'boarding', 'the other passenger is still boarding: PIN is per booking');

-- 2. Пассажиры: один сел, второй нет. Старт после ожидания, затем завершение.
select pg_temp.as_owner();
update public.trips set departure_at = now() - interval '40 minutes' where id = pg_temp.ctx_uuid('main');
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is(public.start_trip(pg_temp.ctx_uuid('main')) - 'started_at', '{"on_board": 1, "not_boarded": 1}'::jsonb, 'start after the wait');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select is(pg_temp.stage('ana_main'), 'in_trip', 'started: in_trip');
select is((select respond_until from public.my_bookings where id = pg_temp.ctx_uuid('ana_main')), null, 'no deadline while the trip is running');
select pg_temp.as_user(pg_temp.ctx_uuid('pedro'));
select is(pg_temp.stage('pedro_main'), 'not_boarded', 'no PIN at start: not_boarded');
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is(public.finish_trip(pg_temp.ctx_uuid('main')) ->> 'asked', '1', 'finish asks only the boarded passenger');
select throws_ok($$ select public.enter_pin(pg_temp.ctx_uuid('pedro_main'), '0000') $$, 'P0001', 'BOLEIA_PIN_WINDOW_CLOSED', 'no PIN after the trip is finished');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select is((select (stage, respond_until = trip_finished_at + interval '24 hours') from public.my_bookings where id = pg_temp.ctx_uuid('ana_main')),
  ('finished'::text, true), 'finished: 24h to rate or contest');
select pg_temp.as_owner();
select is((select count(*) from public.notifications where user_id = pg_temp.ctx_uuid('ana') and type = 'trip_finished' and channel = 'sms'), 1::bigint,
  'trip_finished is urgent: sms, not delayed');

-- ---------------------------------------------------------------------------
-- 3. Спор после завершения: причина из списка, комментарий виден пассажиру и админу
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select throws_ok($$ select public.open_dispute(pg_temp.ctx_uuid('ana_main'), 'was_there', 'Texto suficiente') $$, 'P0001', 'BOLEIA_DISPUTE_REASON_INVALID',
  'not-boarded reason refused for a boarded passenger');
select throws_ok($$ select public.open_dispute(pg_temp.ctx_uuid('ana_main'), 'left_midway', '   ') $$, 'P0001', 'BOLEIA_DISPUTE_DETAILS_REQUIRED', 'empty details refused');
select pg_temp.as_user(pg_temp.ctx_uuid('pedro'));
select throws_ok($$ select public.open_dispute(pg_temp.ctx_uuid('ana_main'), 'left_midway', 'Texto suficiente') $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT',
  'only the passenger of the booking disputes');
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select lives_ok($$ select public.open_dispute(pg_temp.ctx_uuid('ana_main'), 'left_midway', 'Deixou-me no Dondo, a meio do caminho') $$, 'dispute after the finish');
select throws_ok($$ select public.confirm_trip(pg_temp.ctx_uuid('ana_main'), true) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'no approval after a dispute');
select is((select (stage, dispute_reason, dispute_details) from public.my_bookings where id = pg_temp.ctx_uuid('ana_main')),
  ('disputed'::text, 'left_midway'::text, 'Deixou-me no Dondo, a meio do caminho'::text), 'passenger sees his own dispute text');
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is((select (dispute_reason, dispute_details) from public.my_bookings where id = pg_temp.ctx_uuid('ana_main')),
  ('left_midway'::text, null::text), 'driver sees the reason, not the text');
select throws_ok($$ select dispute_details from public.bookings where id = pg_temp.ctx_uuid('ana_main') $$, '42501', null,
  'dispute_details is not readable from the table');
select pg_temp.as_admin();
select is((select dispute_details from public.my_bookings where id = pg_temp.ctx_uuid('ana_main')), 'Deixou-me no Dondo, a meio do caminho', 'admin reads the text');
select throws_ok($$ select public.resolve_dispute(pg_temp.ctx_uuid('ana_main'), 'no_show') $$, 'P0001', 'BOLEIA_DISPUTE_OUTCOME_INVALID',
  'no_show is not an outcome for a boarded passenger');
select lives_ok($$ select public.resolve_dispute(pg_temp.ctx_uuid('ana_main'), 'completed') $$, 'moderator: the trip happened');

-- 4. Спор "поездка началась без вас" и исход no_show
select pg_temp.as_user(pg_temp.ctx_uuid('pedro'));
select lives_ok($$ select public.open_dispute(pg_temp.ctx_uuid('pedro_main'), 'was_there', 'Estava no local desde as 7h30') $$, 'not boarded passenger contests');
select pg_temp.as_admin();
select lives_ok($$ select public.resolve_dispute(pg_temp.ctx_uuid('pedro_main'), 'no_show') $$, 'moderator sides with the driver');
select pg_temp.as_owner();
select is((select (status::text, public.escrow_balance_kz(id)) from public.bookings where id = pg_temp.ctx_uuid('pedro_main')), ('no_show'::text, 0), 'no_show, escrow released');
select is((select amount_kz from public.ledger_entries where booking_id = pg_temp.ctx_uuid('pedro_main') and account = 'driver_balance'), 7000, 'driver paid for the no_show');
select is((select no_shows from public.profiles where id = pg_temp.ctx_uuid('pedro')), 1::smallint, 'passenger no_shows +1');
select is((select status::text from public.trips where id = pg_temp.ctx_uuid('main')), 'completed', 'trip settles when every booking is final');

-- ---------------------------------------------------------------------------
-- 5. Ранний старт закрывает неотвеченный запрос; закрытые ветки старта
-- ---------------------------------------------------------------------------
select pg_temp.mk_trip('approval', 'teresa', now() + interval '2 hours', 'approval');
select pg_temp.book_paid('ana_approval', 'approval', 'ana');
select pg_temp.book_paid('pedro_approval', 'approval', 'pedro');
select pg_temp.as_user(pg_temp.ctx_uuid('teresa'));
select lives_ok($$ select public.respond_booking(pg_temp.ctx_uuid('ana_approval'), true) $$, 'driver accepts one request');
select pg_temp.as_owner();
update public.bookings set pin_entered_at = now() where id = pg_temp.ctx_uuid('ana_approval');
select pg_temp.as_user(pg_temp.ctx_uuid('teresa'));
select lives_ok($$ select public.start_trip(pg_temp.ctx_uuid('approval')) $$, 'everyone accepted is on board: early start');
select pg_temp.as_owner();
select is((select (status::text, cancel_reason, public.escrow_balance_kz(id)) from public.bookings where id = pg_temp.ctx_uuid('pedro_approval')),
  ('expired'::text, 'no_response'::text, 0), 'unanswered request expires with a refund at the start');

select pg_temp.mk_trip('empty', 'joao', now() - interval '2 hours', 'instant');
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select throws_ok($$ select public.start_trip(pg_temp.ctx_uuid('empty')) $$, 'P0001', 'BOLEIA_TRIP_NO_PASSENGERS', 'nothing to start without bookings');
select throws_ok($$ select public.start_trip(pg_temp.ctx_uuid('approval')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'another driver cannot start');
select pg_temp.as_owner();

-- ---------------------------------------------------------------------------
-- 6. Страховки: забытое завершение; поездка без старта с жалобой "не приехал"
-- ---------------------------------------------------------------------------
select is(public.sch_auto_close(now() + interval '23 hours'), 0, 'started trip: no auto finish before 24h');
select is(public.sch_auto_close(now() + interval '25 hours'), 1, 'started and forgotten: finished by the system');
select is((select (finished_at is not null, closed_by_system) from public.trips where id = pg_temp.ctx_uuid('approval')), (true, true), 'finished by the system');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.ctx_uuid('teresa') and type = 'trip_auto_closed' and payload ->> 'step' = 'finish'),
  'driver told the system finished the trip');
select is(public.sch_autocomplete(now() + interval '50 hours'), 1, 'silent passenger: completed 24h after the system finish');
select is((select status::text from public.bookings where id = pg_temp.ctx_uuid('ana_approval')), 'completed', 'booking completed, money released');

select pg_temp.mk_trip('ghost', 'pedro', now() + interval '3 days', 'instant');
select pg_temp.book_paid('ana_ghost', 'ghost', 'ana');
update public.trips set departure_at = now() - interval '25 hours', status = 'departed', departed_at = now() - interval '25 hours' where id = pg_temp.ctx_uuid('ghost');
update public.bookings set status = 'awaiting_confirm' where id = pg_temp.ctx_uuid('ana_ghost');
insert into public.reports (reporter_id, target_user_id, trip_id, booking_id, reason, details)
values (pg_temp.ctx_uuid('ana'), pg_temp.ctx_uuid('pedro'), pg_temp.ctx_uuid('ghost'), pg_temp.ctx_uuid('ana_ghost'), 'no_show', 'O condutor não apareceu');
insert into ctx values ('pedro_counters', (select cancels_total || ',' || no_shows from public.profiles where id = pg_temp.ctx_uuid('pedro')));
select is(public.sch_auto_close(now()), 1, 'never started: cancelled after 24h');
select is((select (status::text, cancel_reason, refund_kz) from public.bookings where id = pg_temp.ctx_uuid('ana_ghost')),
  ('cancelled'::text, 'trip_not_started'::text, 8000), 'passenger refunded in full');
select is((select cancels_total || ',' || no_shows from public.profiles where id = pg_temp.ctx_uuid('pedro')),
  (split_part(pg_temp.ctx_text('pedro_counters'), ',', 1)::integer + 1) || ',' || (split_part(pg_temp.ctx_text('pedro_counters'), ',', 2)::integer + 1),
  'a passenger report "did not show up" adds a no_show to the driver');

select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) unbalanced), 0::bigint, 'ledger balanced');

select * from finish();
rollback;
