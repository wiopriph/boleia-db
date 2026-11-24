begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

-- ---------------------------------------------------------------------------
-- Миграция 0024: notify() дописывает маршрут, дату и роль получателя; mark_read гасит уведомления чата.
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
-- payload последнего in-app уведомления этого типа у пользователя
create function pg_temp.last_payload(user_name text, notification_type text) returns jsonb language sql as $$
  select payload from public.notifications
  where user_id = pg_temp.ctx_uuid(user_name) and type = notification_type and channel = 'inapp'
  order by created_at desc, id desc limit 1
$$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('ana',    '55555555-5555-5555-5555-555555555555');

with created as (
  insert into public.trips (driver_id, vehicle_id, origin_place_id, destination_place_id, origin_detail, destination_detail,
    departure_at, seats_offered, seats_available, price_per_seat_kz, booking_mode, status, published_at)
  select pg_temp.ctx_uuid('joao'), (select id from public.vehicles where owner_id = pg_temp.ctx_uuid('joao') limit 1),
         (select id from public.places where slug = 'luanda'), (select id from public.places where slug = 'benguela'),
         'Gamek', 'Terminal', now() + interval '3 days', 3, 3, 7000, 'instant', 'published', now()
  returning id, departure_at
)
insert into ctx select 'trip', id::text from created;

do $$
declare response jsonb;
begin
  perform pg_temp.as_user(pg_temp.ctx_uuid('ana'));
  response := public.request_booking(pg_temp.ctx_uuid('trip'), 2);
  perform pg_temp.as_owner();
  perform public.confirm_payment((response ->> 'payment_id')::uuid, 'ref-notification-context', 'paid',
    (select phone from public.profiles where id = pg_temp.ctx_uuid('ana')));
  insert into ctx values ('booking', response ->> 'booking_id');
end $$;

-- 1. Уведомления брони: маршрут, дата и роль у обеих сторон
select is(pg_temp.last_payload('joao', 'booking_confirmed') ->> 'role', 'driver', 'driver notification says role driver');
select is(pg_temp.last_payload('joao', 'booking_confirmed') ->> 'origin_name', 'Luanda', 'driver notification carries the origin');
select is(pg_temp.last_payload('joao', 'booking_confirmed') ->> 'destination_name', 'Benguela', 'driver notification carries the destination');
select is((pg_temp.last_payload('joao', 'booking_confirmed') ->> 'departure_at')::timestamptz,
  (select departure_at from public.trips where id = pg_temp.ctx_uuid('trip')), 'driver notification carries the departure time');
select is(pg_temp.last_payload('joao', 'booking_confirmed') ->> 'passenger_name',
  (select display_name from public.profiles where id = pg_temp.ctx_uuid('ana')), 'own payload keys are kept');
select is(pg_temp.last_payload('ana', 'booking_accepted') ->> 'role', 'passenger', 'passenger notification says role passenger');
select is(pg_temp.last_payload('ana', 'booking_accepted') ->> 'destination_name', 'Benguela', 'passenger notification carries the route');

-- 2. Только booking_id в payload: trip_id и роль находятся по брони
select public.notify(pg_temp.ctx_uuid('ana'),  'dispute_resolved', jsonb_build_object('booking_id', pg_temp.ctx_uuid('booking'), 'outcome', 'completed'), false);
select public.notify(pg_temp.ctx_uuid('joao'), 'dispute_resolved', jsonb_build_object('booking_id', pg_temp.ctx_uuid('booking'), 'outcome', 'completed'), false);
select is(pg_temp.last_payload('ana', 'dispute_resolved') ->> 'trip_id', pg_temp.ctx_text('trip'), 'trip_id resolved from booking_id');
select is(pg_temp.last_payload('ana', 'dispute_resolved') ->> 'role', 'passenger', 'two-sided type: passenger');
select is(pg_temp.last_payload('joao', 'dispute_resolved') ->> 'role', 'driver', 'two-sided type: driver');

-- 3. Получатель не участник поездки (админ): маршрут есть, роли нет
select public.notify(pg_temp.ctx_uuid('admin'), 'refund_manual', jsonb_build_object('booking_id', pg_temp.ctx_uuid('booking'), 'refund_kz', 8000), false);
select is(pg_temp.last_payload('admin', 'refund_manual') ->> 'origin_name', 'Luanda', 'outsider still gets the route');
select ok(not (pg_temp.last_payload('admin', 'refund_manual') ? 'role'), 'outsider has no role');
-- другой пассажир этой поездки не получает роль по чужой брони
select public.notify(pg_temp.ctx_uuid('teresa'), 'booking_accepted', jsonb_build_object('booking_id', pg_temp.ctx_uuid('booking')), false);
select ok(not (pg_temp.last_payload('teresa', 'booking_accepted') ? 'role'), 'no role for a booking that is not yours');

-- 4. Без поездки payload не меняется; свои ключи сильнее контекста; мусор в id не роняет notify
select public.notify(pg_temp.ctx_uuid('joao'), 'payout_paid', jsonb_build_object('amount_kz', 5000, 'payout_id', gen_random_uuid()), false);
select is((select count(*) from jsonb_object_keys(pg_temp.last_payload('joao', 'payout_paid'))), 2::bigint, 'payload without a trip is untouched');
select public.notify(pg_temp.ctx_uuid('joao'), 'trip_reminder_6h',
  jsonb_build_object('trip_id', pg_temp.ctx_uuid('trip'), 'departure_at', '2030-01-01T00:00:00+00:00'), false);
select is(pg_temp.last_payload('joao', 'trip_reminder_6h') ->> 'departure_at', '2030-01-01T00:00:00+00:00', 'payload departure_at wins over the context');
select lives_ok($$ select public.notify(pg_temp.ctx_uuid('joao'), 'moderation_action', '{"trip_id": "not-a-uuid"}'::jsonb, false) $$,
  'malformed id does not break notify');
select is(pg_temp.last_payload('joao', 'moderation_action'), '{"trip_id": "not-a-uuid"}'::jsonb, 'malformed payload stored as is');

-- 5. mark_read гасит уведомления new_message этого чата и только их
select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select public.send_message('Olá, a que horas saímos?', null, pg_temp.ctx_uuid('trip'));
select public.send_message('Levo uma mala.', null, pg_temp.ctx_uuid('trip'));
select pg_temp.as_owner();
insert into ctx select 'conversation', id::text from public.conversations
  where trip_id = pg_temp.ctx_uuid('trip') and passenger_id = pg_temp.ctx_uuid('ana');
select is((select count(*) from public.notifications
           where user_id = pg_temp.ctx_uuid('joao') and type = 'new_message' and channel = 'inapp' and read_at is null),
  2::bigint, 'driver has two unread message notifications');
select is(pg_temp.last_payload('joao', 'new_message') ->> 'conversation_id', pg_temp.ctx_text('conversation'), 'message notification points to the chat');

select pg_temp.as_user(pg_temp.ctx_uuid('joao'));
select public.mark_read(pg_temp.ctx_uuid('conversation'),
  (select max(id) from public.messages where conversation_id = pg_temp.ctx_uuid('conversation')));
select pg_temp.as_owner();
select is((select count(*) from public.notifications
           where user_id = pg_temp.ctx_uuid('joao') and type = 'new_message' and channel = 'inapp' and read_at is null),
  0::bigint, 'opening the chat marks its message notifications read');
select ok((select read_at is null from public.notifications
           where user_id = pg_temp.ctx_uuid('joao') and type = 'booking_confirmed' and channel = 'inapp'
             and payload ->> 'booking_id' = pg_temp.ctx_text('booking')), 'other notifications stay unread');
select is((select count(*) from public.notifications
           where user_id = pg_temp.ctx_uuid('ana') and type = 'new_message' and read_at is not null),
  0::bigint, 'the other side is not affected');

select * from finish();
rollback;
