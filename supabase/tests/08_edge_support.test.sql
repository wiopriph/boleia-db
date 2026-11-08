begin;
create extension if not exists pgtap with schema extensions;
select plan(51);

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;
create function pg_temp.c(text)  returns text language sql as $$ select v from ctx where k = $1 $$;
create function pg_temp.cu(text) returns uuid language sql as $$ select v::uuid from ctx where k = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
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

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('ana',    '55555555-5555-5555-5555-555555555555')
;
insert into ctx select 'j' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;
insert into ctx select 't' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('teresa') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 1;

-- ---------------------------------------------------------------------------
-- 1. payment_initiated
-- ---------------------------------------------------------------------------
select pg_temp.book_pending('b1', 'j1', 'ana', 1);
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.payment_initiated(pg_temp.cu('b1_pay'), 'gw-1') $$, '42501', null, 'authenticated cannot call payment_initiated');
reset role;
select throws_ok($$ select public.payment_initiated(pg_temp.cu('b1_pay'), '  ') $$, 'P0001', 'BOLEIA_PAYMENT_REF_MISMATCH', 'empty provider_ref refused');
select throws_ok($$ select public.payment_initiated('00000000-0000-0000-0000-000000000000', 'gw-1') $$, 'P0001', 'BOLEIA_PAYMENT_NOT_FOUND', 'unknown payment');
insert into ctx values ('init1', public.payment_initiated(pg_temp.cu('b1_pay'), 'gw-1', '{"instructions":{"type":"push"}}')::text);
select is(pg_temp.c('init1')::jsonb ->> 'status', 'pending', 'created -> pending');
select is((select (status::text, provider_ref, raw_request -> 'instructions' ->> 'type') from public.payments where id = pg_temp.cu('b1_pay')),
  ('pending'::text, 'gw-1'::text, 'push'::text), 'provider_ref and raw_request stored');
select ok((select expires_at between now() + interval '14 minutes' and now() + interval '16 minutes' from public.payments where id = pg_temp.cu('b1_pay')), 'expires_at restarted from init');
select is(public.payment_initiated(pg_temp.cu('b1_pay'), 'gw-1') ->> 'already', 'true', 'same ref again is idempotent');
select throws_ok($$ select public.payment_initiated(pg_temp.cu('b1_pay'), 'gw-other') $$, 'P0001', 'BOLEIA_PAYMENT_STATUS_INVALID', 'different ref on pending payment refused');
select lives_ok($$ select public.confirm_payment(pg_temp.cu('b1_pay'), 'gw-1', 'paid', '+244900000005') $$, 'webhook completes the pending payment');
select is((select status::text from public.bookings where id = pg_temp.cu('b1')), 'accepted', 'booking accepted');

-- бронь уже не pending_payment -> BOOKING_CLOSED
select pg_temp.book_pending('b2', 'j2', 'ana', 1);
update public.bookings set status = 'payment_failed' where id = pg_temp.cu('b2');
select throws_ok($$ select public.payment_initiated(pg_temp.cu('b2_pay'), 'gw-2') $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'init on a closed booking refused');

-- ---------------------------------------------------------------------------
-- 2. payment_refund_result
-- ---------------------------------------------------------------------------
-- возврат ожидает: несовпадение телефона
select pg_temp.book_pending('b3', 't1', 'ana', 1);
select public.payment_initiated(pg_temp.cu('b3_pay'), 'gw-3');
select lives_ok($$ select public.confirm_payment(pg_temp.cu('b3_pay'), 'gw-3', 'paid', '+244999999999') $$, 'paid from another phone');
select is((select count(*) from public.pending_refunds where payment_id = pg_temp.cu('b3_pay')), 1::bigint, 'refund queued');
select throws_ok($$ select public.payment_refund_result(pg_temp.cu('b1_pay'), true, 'rf-x') $$, 'P0001', 'BOLEIA_PAYMENT_STATUS_INVALID', 'no refund due on b1');
select throws_ok($$ select public.payment_refund_result(pg_temp.cu('b3_pay'), true, '') $$, 'P0001', 'BOLEIA_PAYMENT_REF_MISMATCH', 'success needs a refund_ref');
select is(public.payment_refund_result(pg_temp.cu('b3_pay'), false, null, '{"error":"timeout"}') ->> 'refund_attempts', '1', 'first failure counted');
select is(public.payment_refund_result(pg_temp.cu('b3_pay'), false) ->> 'refund_attempts', '2', 'second failure counted');
select is((select count(*) from public.notifications where user_id = pg_temp.cu('admin') and type = 'refund_manual'), 0::bigint, 'no manual queue before 3 failures');
select is(public.payment_refund_result(pg_temp.cu('b3_pay'), false) ->> 'refund_attempts', '3', 'third failure counted');
select is((select count(*) from public.notifications where user_id = pg_temp.cu('admin') and type = 'refund_manual'), 1::bigint, 'admins told to refund manually');
select is((select count(*) from public.pending_refunds where payment_id = pg_temp.cu('b3_pay')), 0::bigint, 'left the automatic queue');
select is((select (status::text, refund_failed_at is not null) from public.payments where id = pg_temp.cu('b3_pay')), ('paid'::text, true), 'payment still paid, failure timestamp set');
-- успешный возврат на другом платеже: отказ водителя
select pg_temp.book_pending('b4', 't1', 'ana', 1);
select public.payment_initiated(pg_temp.cu('b4_pay'), 'gw-4');
select lives_ok($$ select public.confirm_payment(pg_temp.cu('b4_pay'), 'gw-4', 'paid', '+244900000005') $$, 'paid');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.respond_booking(pg_temp.cu('b4'), false, 'Cheio') $$, 'declined');
reset role;
select is((select refund_kz from public.payments where id = pg_temp.cu('b4_pay')), 8000, 'full refund due');
select is(public.payment_refund_result(pg_temp.cu('b4_pay'), true, 'rf-4', '{"gw":"ok"}') ->> 'status', 'refunded', 'refund recorded');
select is((select (refund_ref, refunded_at is not null, raw_webhook -> 'refund' ->> 'gw') from public.payments where id = pg_temp.cu('b4_pay')),
  ('rf-4'::text, true, 'ok'::text), 'refund_ref, refunded_at, raw stored');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('ana') and type = 'refund_done' and payload ->> 'refund_ref' = 'rf-4'), 'passenger told money is back');
select is(public.payment_refund_result(pg_temp.cu('b4_pay'), true, 'rf-4') ->> 'already', 'true', 'repeat is idempotent');

-- ---------------------------------------------------------------------------
-- 3. notification_delivered и статусы каналов
-- ---------------------------------------------------------------------------
select is((select status::text from public.notifications where user_id = pg_temp.cu('ana') and type = 'booking_accepted' and channel = 'inapp' limit 1), 'sent', 'inapp is sent at insert');
insert into ctx values ('n_sms', (select id::text from public.notifications where user_id = pg_temp.cu('ana') and type = 'booking_accepted' and channel = 'sms' limit 1));
select is((select status::text from public.notifications where id = pg_temp.cu('n_sms')), 'queued', 'sms starts queued');
select lives_ok($$ select public.notification_delivered(pg_temp.cu('n_sms'), true) $$, 'delivered');
select is((select (status::text, sent_at is not null) from public.notifications where id = pg_temp.cu('n_sms')), ('sent'::text, true), 'marked sent');
select lives_ok($$ select public.notification_delivered(pg_temp.cu('n_sms'), false, 'late') $$, 'second report ignored');
select is((select status::text from public.notifications where id = pg_temp.cu('n_sms')), 'sent', 'sent stays sent');

insert into ctx values ('n_fail', (select id::text from public.notifications where user_id = pg_temp.cu('ana') and type = 'refund_done' and channel = 'sms' limit 1));
select public.notification_delivered(pg_temp.cu('n_fail'), false, 'castbrick 500');
select is((select (status::text, error, payload ->> 'attempts', scheduled_for > now() + interval '4 minutes') from public.notifications where id = pg_temp.cu('n_fail')),
  ('queued'::text, 'castbrick 500'::text, '1'::text, true), 'retry scheduled in 5 minutes');
select public.notification_delivered(pg_temp.cu('n_fail'), false, 'castbrick 500');
select public.notification_delivered(pg_temp.cu('n_fail'), false, 'castbrick 502');
select is((select (status::text, error, payload ->> 'attempts') from public.notifications where id = pg_temp.cu('n_fail')), ('failed'::text, 'castbrick 502'::text, '3'::text), 'failed after 3 attempts');
select lives_ok($$ select public.notification_delivered('00000000-0000-0000-0000-000000000000', true) $$, 'unknown id is a no-op');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.notification_delivered(pg_temp.cu('n_sms'), true) $$, '42501', null, 'authenticated cannot report delivery');
reset role;

-- ---------------------------------------------------------------------------
-- 4. Auth hooks
-- ---------------------------------------------------------------------------
select is(public.custom_access_token_hook(jsonb_build_object('user_id', pg_temp.cu('admin'), 'claims', '{"app_metadata":{"provider":"phone"}}'::jsonb))
  -> 'claims' -> 'app_metadata', '{"provider":"phone","role":"admin"}'::jsonb, 'admin gets role in app_metadata');
select is(public.custom_access_token_hook(jsonb_build_object('user_id', pg_temp.cu('ana'), 'claims', '{"app_metadata":{"provider":"phone","role":"admin"}}'::jsonb))
  -> 'claims' -> 'app_metadata', '{"provider":"phone"}'::jsonb, 'non-admin loses a stale admin role');
select is(public.custom_access_token_hook(jsonb_build_object('user_id', '00000000-0000-0000-0000-000000000000', 'claims', '{}'::jsonb))
  -> 'claims', '{"app_metadata":{}}'::jsonb, 'unknown user: no role');
select is(public.before_user_created_hook('{"user":{"phone":"244900000099"}}'), '{}'::jsonb, 'clean phone allowed');
insert into public.banned_phones (phone, reason) values ('+244900000077', 'fraude');
select is(public.before_user_created_hook('{"user":{"phone":"244900000077"}}') -> 'error' ->> 'http_code', '403', 'banned phone rejected');
select is(public.before_user_created_hook('{"user":{"email":"x@y"}}'), '{}'::jsonb, 'no phone: allowed');
select ok(has_function_privilege('supabase_auth_admin', 'public.custom_access_token_hook(jsonb)', 'execute'), 'auth admin can run the token hook');
select ok(not has_function_privilege('authenticated', 'public.custom_access_token_hook(jsonb)', 'execute'), 'authenticated cannot');

-- ---------------------------------------------------------------------------
-- 5. edge_call, триггер, cron
-- ---------------------------------------------------------------------------
select is(public.edge_call('notify', '{}'), null, 'no vault secrets: edge_call is a no-op');
select ok(exists (select 1 from pg_trigger where tgname = 'notifications_dispatch'), 'dispatch trigger installed');
select is((select count(*) from cron.job where jobname in ('boleia_payments_status', 'boleia_payments_refund', 'boleia_notify_sweep')), 3::bigint, 'three edge cron jobs');
select ok(exists (select 1 from pg_extension where extname = 'pg_net'), 'pg_net installed');

select * from finish();
rollback;
