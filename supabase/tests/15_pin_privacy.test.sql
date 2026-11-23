begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

-- ---------------------------------------------------------------------------
-- PIN посадки виден только пассажиру (миграция 0021): ни чат, ни views, ни таблица bookings
-- не отдают его водителю.
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
create function pg_temp.as_owner() returns void language sql as $$ select set_config('role', 'none', true) $$;

insert into ctx values
  ('admin', '11111111-1111-1111-1111-111111111111'),
  ('joao',  '22222222-2222-2222-2222-222222222222'),
  ('ana',   '55555555-5555-5555-5555-555555555555');

with created as (
  insert into public.trips (driver_id, vehicle_id, origin_place_id, destination_place_id, origin_detail, destination_detail,
    departure_at, seats_offered, seats_available, price_per_seat_kz, booking_mode, status, published_at)
  select pg_temp.ctx_uuid('joao'), (select id from public.vehicles where owner_id = pg_temp.ctx_uuid('joao') limit 1),
         (select id from public.places where slug = 'luanda'), (select id from public.places where slug = 'benguela'),
         'Gamek', 'Terminal', now() + interval '10 hours', 3, 3, 7000, 'instant', 'published', now()
  returning id
)
insert into ctx select 'trip', id::text from created;

do $$
declare response jsonb;
begin
  perform pg_temp.as_user(pg_temp.ctx_uuid('ana'));
  response := public.request_booking(pg_temp.ctx_uuid('trip'), 1);
  perform pg_temp.as_owner();
  perform public.confirm_payment((response ->> 'payment_id')::uuid, 'ref-pin-privacy', 'paid',
    (select phone from public.profiles where id = pg_temp.ctx_uuid('ana')));
  insert into ctx values ('booking', response ->> 'booking_id');
end $$;
insert into ctx select 'pin', pin_code::text from public.bookings where id = pg_temp.ctx_uuid('booking');

select matches(pg_temp.ctx_text('pin'), '^\d{4}$', 'instant booking has a PIN after payment');

-- 1. Таблица bookings: колонка закрыта грантом
select ok(not has_column_privilege('authenticated', 'public.bookings', 'pin_code', 'select'), 'authenticated has no select on pin_code');
select ok(not has_column_privilege('anon', 'public.bookings', 'pin_code', 'select'), 'anon has no select on pin_code');
select is((select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'bookings' and column_name <> 'pin_code'
             and not has_column_privilege('authenticated', 'public.bookings', column_name, 'select')),
  0::bigint, 'every other bookings column stays readable');

select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select throws_ok($$ select pin_code from public.bookings where id = pg_temp.ctx_uuid('booking') $$,
  '42501', null, 'driver cannot select pin_code from bookings');
select throws_ok($$ select * from public.bookings where id = pg_temp.ctx_uuid('booking') $$,
  '42501', null, 'select * on bookings is rejected');
select is((select status::text from public.bookings where id = pg_temp.ctx_uuid('booking')), 'accepted',
  'driver still reads the other columns of his trip bookings');
select pg_temp.as_owner();

select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select throws_ok($$ select pin_code from public.bookings where id = pg_temp.ctx_uuid('booking') $$,
  '42501', null, 'passenger reads the PIN through my_bookings only');

-- 2. my_bookings до -2 ч: PIN не виден никому
select is((select pin_code from public.my_bookings where id = pg_temp.ctx_uuid('booking')), null, 'passenger: no PIN earlier than 2 h before departure');
select pg_temp.as_owner();

-- 3. Cron за 2 ч до выезда
select is(public.sch_send_pins(now() + interval '8 hours 5 minutes'), 1, 'PIN sent for the booking');
update public.trips set departure_at = now() + interval '1 hour 50 minutes' where id = pg_temp.ctx_uuid('trip');

select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select is((select pin_code::text from public.my_bookings where id = pg_temp.ctx_uuid('booking')), pg_temp.ctx_text('pin'),
  'passenger sees the PIN in my_bookings from 2 h before departure');
select is((select payload ->> 'pin' from public.notifications
           where type = 'pin_ready' and channel = 'inapp' and payload ->> 'booking_id' = pg_temp.ctx_text('booking')),
  pg_temp.ctx_text('pin'), 'passenger gets the PIN in pin_ready');
select pg_temp.as_owner();

select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is((select count(*) from public.my_bookings where id = pg_temp.ctx_uuid('booking')), 1::bigint, 'driver sees the booking in my_bookings');
select is((select pin_code from public.my_bookings where id = pg_temp.ctx_uuid('booking')), null, 'driver: my_bookings hides the PIN');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
           where c.booking_id = pg_temp.ctx_uuid('booking') and m.body like '%' || pg_temp.ctx_text('pin') || '%'),
  0::bigint, 'driver: no chat message carries the PIN');
select is((select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
           where c.booking_id = pg_temp.ctx_uuid('booking') and m.sender_id is null and m.body like 'O PIN de embarque já está disponível%'),
  1::bigint, 'chat says the PIN is ready without the digits');
select ok((select last_message_body not like '%' || pg_temp.ctx_text('pin') || '%' from public.my_conversations
           where booking_id = pg_temp.ctx_uuid('booking')), 'driver: chat list preview has no PIN');
select is((select count(*) from public.notifications where payload ? 'pin'), 0::bigint, 'driver: no notification carries a PIN');
select pg_temp.as_owner();

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.ctx_uuid('admin'), 'role', 'authenticated',
  'app_metadata', json_build_object('role', 'admin'))::text, true);
select set_config('role', 'authenticated', true);
select is((select pin_code::text from public.my_bookings where id = pg_temp.ctx_uuid('booking')), pg_temp.ctx_text('pin'),
  'admin sees the PIN in my_bookings');
select pg_temp.as_owner();

-- 4. Водитель по-прежнему вводит PIN, который назвал пассажир
select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select is(public.enter_pin(pg_temp.ctx_uuid('booking'), pg_temp.ctx_text('pin')) ->> 'ok', 'true', 'driver enters the PIN told by the passenger');
select ok((select pin_entered_at is not null from public.bookings where id = pg_temp.ctx_uuid('booking')), 'pin_entered_at is visible to the driver');
select pg_temp.as_owner();

select * from finish();
rollback;
