begin;
create extension if not exists pgtap with schema extensions;
select plan(99);

create temp table ctx (k text primary key, v text);
grant all on ctx to anon, authenticated;
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
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
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
create function pg_temp.mod_n(target_k text, act text) returns bigint language sql as $$
  select count(*) from public.moderation_actions where target_user_id = pg_temp.cu(target_k) and action::text = act
$$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555');
insert into ctx select 'j' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;
insert into ctx select 'p' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('pedro') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 3;
insert into ctx select 't' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('teresa') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;

-- ---------------------------------------------------------------------------
-- 1. Доступ и валидация
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.admin_stats() $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'stats: not admin');
select throws_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'warn', 'x') $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'moderate: not admin');
select throws_ok($$ select * from public.admin_search_users('Ana') $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'search: not admin');
select pg_temp.as_admin();
select throws_ok($$ select public.admin_moderate(pg_temp.cu('admin'), 'warn', 'x') $$, 'P0001', 'BOLEIA_TARGET_IS_ADMIN', 'cannot moderate an admin');
select throws_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'verify_id', 'x') $$, 'P0001', 'BOLEIA_MODERATION_ACTION_INVALID', 'verify_id is not a moderation action');
select throws_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'warn', '  ') $$, 'P0001', 'BOLEIA_REASON_REQUIRED', 'reason required');
select throws_ok($$ select public.admin_moderate('00000000-0000-0000-0000-000000000000', 'warn', 'x') $$, 'P0001', 'BOLEIA_TARGET_INVALID', 'unknown target');
select is((select count(*) from public.admin_search_users('+244 900 000 005')), 1::bigint, 'search by phone tolerates + and spaces');
select is((select (r ->> 'display_name') from public.admin_search_users('tere') r), 'Teresa S.', 'search by name');
select is((select (r ->> 'balance_kz')::int from public.admin_search_users('Ana R.') r), 0, 'search returns balance');
reset role;

-- ---------------------------------------------------------------------------
-- 2. warn / restrict / unban
-- ---------------------------------------------------------------------------
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'warn', 'Linguagem imprópria') $$, 'warn');
select lives_ok($$ select public.admin_moderate(pg_temp.cu('ana'), 'restrict', 'Pagamentos de números alheios') $$, 'restrict');
reset role;
select is((select status::text from public.profiles where id = pg_temp.cu('pedro')), 'active', 'warn keeps status');
select is(pg_temp.mod_n('pedro', 'warn'), 1::bigint, 'warn logged');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('pedro') and type = 'moderation_action' and payload ->> 'reason' = 'Linguagem imprópria'), 'target notified with reason');
select is((select status::text from public.profiles where id = pg_temp.cu('ana')), 'restricted', 'restricted');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.request_booking(pg_temp.cu('p1'), 1) $$, 'P0001', 'BOLEIA_PROFILE_RESTRICTED', 'restricted cannot book');
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('ana'), 'unban', 'Esclarecido') $$, 'unban lifts restrict');
reset role;
select is((select status::text from public.profiles where id = pg_temp.cu('ana')), 'active', 'active again');

-- ---------------------------------------------------------------------------
-- 3. ban водителя с активной поездкой и пассажира с бронью
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a_j1', 'j1', 'ana', 1);
select pg_temp.book_pending('t_j1', 'j1', 'teresa', 1);
insert into ctx values ('joao_cancels', (select cancels_total::text from public.profiles where id = pg_temp.cu('joao')));
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('joao'), 'ban', 'Fraude confirmada') $$, 'ban driver');
reset role;
select is((select (status::text, cancel_reason) from public.trips where id = pg_temp.cu('j1')), ('cancelled'::text, 'moderation'::text), 'driver trip cancelled by platform');
select is((select (status::text, cancelled_by::text, refund_kz) from public.bookings where id = pg_temp.cu('a_j1')), ('cancelled'::text, 'system'::text, 8000), 'passenger refunded in full');
select is((select status::text from public.bookings where id = pg_temp.cu('t_j1')), 'payment_failed', 'pending booking failed');
select is((select cancels_total from public.profiles where id = pg_temp.cu('joao')), pg_temp.c('joao_cancels')::smallint, 'no cancels_total for platform cancel');
select is((select status::text from public.profiles where id = pg_temp.cu('joao')), 'banned', 'banned');
select ok(exists (select 1 from public.banned_phones where phone = '+244900000002'), 'phone banned');
select is(public.before_user_created_hook('{"user":{"phone":"244900000002"}}') -> 'error' ->> 'http_code', '403', 'banned phone cannot re-register');
select ok((select banned_until is not null from auth.users where id = pg_temp.cu('joao')), 'auth banned');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.upsert_profile('{"bio":"x"}') $$, 'P0001', 'BOLEIA_PROFILE_RESTRICTED', 'banned cannot call RPC');
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('joao'), 'unban', 'Erro de moderação') $$, 'unban driver');
reset role;
select is((select (status::text, suspended_until) from public.profiles where id = pg_temp.cu('joao')), ('active'::text, null::timestamptz), 'driver active again');
select is((select count(*) from public.banned_phones), 0::bigint, 'phone unbanned');
select ok((select banned_until is null from auth.users where id = pg_temp.cu('joao')), 'auth unbanned');

select pg_temp.book_paid('a_p1', 'p1', 'ana', 1);
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('ana'), 'ban', 'Conta falsa') $$, 'ban passenger');
reset role;
select is((select (status::text, cancelled_by::text, refund_kz) from public.bookings where id = pg_temp.cu('a_p1')), ('cancelled'::text, 'system'::text, 8000), 'passenger booking refunded to the passenger');
select is((select seats_available from public.trips where id = pg_temp.cu('p1')), 3::smallint, 'seat released');
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('ana'), 'unban', 'ok') $$, 'unban passenger');
reset role;

-- ---------------------------------------------------------------------------
-- 4. Жалобы
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('rep1', public.report_user(pg_temp.cu('pedro'), 'harassment', 'Mensagens', pg_temp.cu('p1'))::text);
insert into ctx values ('rep2', public.report_user(pg_temp.cu('pedro'), 'other', 'Nada')::text);
select pg_temp.as_admin();
select throws_ok($$ select public.admin_resolve_report(pg_temp.cu('rep1'), 'actioned') $$, 'P0001', 'BOLEIA_REPORT_OUTCOME_INVALID', 'actioned only via admin_moderate');
select throws_ok($$ select public.admin_resolve_report('00000000-0000-0000-0000-000000000000', 'reviewed') $$, 'P0001', 'BOLEIA_REPORT_NOT_FOUND', 'unknown report');
select lives_ok($$ select public.admin_resolve_report(pg_temp.cu('rep1'), 'reviewed') $$, 'taken into review');
reset role;
select is((select status::text from public.reports where id = pg_temp.cu('rep1')), 'reviewed', 'reviewed');
select pg_temp.as_admin();
select lives_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'warn', 'Confirmado', null, pg_temp.cu('rep1')) $$, 'warn with report');
select throws_ok($$ select public.admin_resolve_report(pg_temp.cu('rep1'), 'dismissed') $$, 'P0001', 'BOLEIA_REPORT_CLOSED', 'closed report');
select lives_ok($$ select public.admin_resolve_report(pg_temp.cu('rep2'), 'dismissed', 'Sem fundamento') $$, 'dismissed');
reset role;
select is((select (status::text, resolved_by) from public.reports where id = pg_temp.cu('rep1')), ('actioned'::text, pg_temp.cu('admin')), 'report actioned by moderation');
select is((select status::text from public.reports where id = pg_temp.cu('rep2')), 'dismissed', 'dismissed');
select is(pg_temp.mod_n('pedro', 'report_dismissed'), 1::bigint, 'dismissal logged');

-- ---------------------------------------------------------------------------
-- 5. admin_cancel_trip / admin_cancel_booking
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a_t2', 't2', 'ana', 1);  -- approval: requested
insert into ctx values ('teresa_cancels', (select cancels_total::text from public.profiles where id = pg_temp.cu('teresa')));
select pg_temp.as_admin();
select throws_ok($$ select public.admin_cancel_trip(pg_temp.cu('t2'), '') $$, 'P0001', 'BOLEIA_REASON_REQUIRED', 'reason required');
insert into ctx values ('ct', public.admin_cancel_trip(pg_temp.cu('t2'), 'Preço abusivo')::text);
select throws_ok($$ select public.admin_cancel_trip(pg_temp.cu('t2'), 'x') $$, 'P0001', 'BOLEIA_TOO_LATE_TO_CANCEL', 'already cancelled');
reset role;
select is(pg_temp.c('ct')::jsonb, '{"cancelled_bookings": 1, "refunded_kz": 8000}'::jsonb, 'cascade result');
select is((select cancels_total from public.profiles where id = pg_temp.cu('teresa')), pg_temp.c('teresa_cancels')::smallint, 'hide_trip does not count against the driver');
select is(pg_temp.mod_n('teresa', 'hide_trip'), 1::bigint, 'hide_trip logged');
select is(public.escrow_balance_kz(pg_temp.cu('a_t2')), 0, 'passenger refunded');

select pg_temp.book_paid('t_p2', 'p2', 'teresa', 1);
select pg_temp.as_admin();
insert into ctx values ('cb', public.admin_cancel_booking(pg_temp.cu('t_p2'), 'A pedido do passageiro')::text);
select throws_ok($$ select public.admin_cancel_booking(pg_temp.cu('t_p2'), 'x') $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'already cancelled');
reset role;
select is(pg_temp.c('cb')::jsonb, '{"status": "cancelled", "refund_kz": 8000}'::jsonb, 'booking cancelled with full refund');
select is((select cancels_total from public.profiles where id = pg_temp.cu('teresa')), pg_temp.c('teresa_cancels')::smallint, 'passenger counter untouched');
select is(pg_temp.mod_n('teresa', 'cancel_booking'), 1::bigint, 'cancel_booking logged');

-- ---------------------------------------------------------------------------
-- 6. Ручной возврат
-- ---------------------------------------------------------------------------
select pg_temp.book_pending('a_p3', 'p3', 'ana', 1);
select public.confirm_payment(pg_temp.cu('a_p3_pay'), 'gw-p3', 'paid', '+244999999999');
select public.payment_refund_result(pg_temp.cu('a_p3_pay'), false), public.payment_refund_result(pg_temp.cu('a_p3_pay'), false), public.payment_refund_result(pg_temp.cu('a_p3_pay'), false);
select is((select count(*) from public.payments where refund_kz > 0 and refund_ref is null and refund_attempts >= 3), 1::bigint, 'one manual refund pending');
select pg_temp.as_admin();
select throws_ok($$ select public.admin_mark_refund_manual(pg_temp.cu('a_p3_pay'), '') $$, 'P0001', 'BOLEIA_PAYMENT_REF_MISMATCH', 'ref required');
select is(public.admin_mark_refund_manual(pg_temp.cu('a_p3_pay'), 'MCX-REF-1', 'transferência manual') ->> 'status', 'refunded', 'marked refunded');
reset role;
select is((select refund_ref from public.payments where id = pg_temp.cu('a_p3_pay')), 'manual:MCX-REF-1', 'manual ref stored');
select is(pg_temp.mod_n('ana', 'manual_refund'), 1::bigint, 'manual refund logged');

-- ---------------------------------------------------------------------------
-- 7. Справочник мест
-- ---------------------------------------------------------------------------
select pg_temp.as_admin();
select throws_ok($$ select public.admin_upsert_place('{"name":"X","province":"Y","slug":"luanda"}') $$, 'P0001', 'BOLEIA_PLACE_SLUG_TAKEN', 'duplicate slug');
select throws_ok($$ select public.admin_upsert_place('{"name":"X","province":"Y","slug":"Bad Slug"}') $$, 'P0001', 'BOLEIA_PLACE_INVALID', 'bad slug');
select throws_ok($$ select public.admin_upsert_place('{"name":"X"}') $$, 'P0001', 'BOLEIA_PLACE_INVALID', 'missing fields');
insert into ctx values ('pl', public.admin_upsert_place('{"name":"Ndalatando Sul","province":"Cuanza Norte","slug":"ndalatando-sul","kind":"town","aliases":["N. Sul"]}')::text);
select lives_ok($$ select public.admin_upsert_place(jsonb_build_object('id', pg_temp.cu('pl'), 'name', 'Ndalatando Sul 2')) $$, 'rename');
reset role;
select is((select (name, kind::text, aliases) from public.places where id = pg_temp.cu('pl')), ('Ndalatando Sul 2'::text, 'town'::text, array['N. Sul']), 'place created and renamed');
insert into ctx values ('nd', (select id::text from public.places where slug = 'ndalatando'));
insert into public.route_durations (origin_place_id, destination_place_id, minutes, price_hint_kz) values ((select id from public.places where slug = 'luanda'), pg_temp.cu('pl'), 100, 3000);
with ins as (
  insert into public.trips (driver_id, vehicle_id, origin_place_id, destination_place_id, departure_at, seats_offered, seats_available, price_per_seat_kz, status, published_at)
  values (pg_temp.cu('teresa'), (select id from public.vehicles where owner_id = pg_temp.cu('teresa') limit 1), pg_temp.cu('pl'), (select id from public.places where slug = 'luanda'), now() + interval '40 days', 3, 3, 3000, 'published', now())
  returning id
) insert into ctx select 'mt', id::text from ins;
select pg_temp.as_admin();
select throws_ok($$ select public.admin_merge_places(pg_temp.cu('pl'), pg_temp.cu('pl')) $$, 'P0001', 'BOLEIA_PLACE_INVALID', 'merge into itself');
select throws_ok($$ select public.admin_merge_places(pg_temp.cu('pl'), '00000000-0000-0000-0000-000000000000') $$, 'P0001', 'BOLEIA_PLACE_NOT_FOUND', 'merge into unknown');
select lives_ok($$ select public.admin_merge_places(pg_temp.cu('pl'), pg_temp.cu('nd')) $$, 'merge duplicate into Ndalatando');
reset role;
select is((select origin_place_id from public.trips where id = pg_temp.cu('mt')), pg_temp.cu('nd'), 'trip repointed');
select is((select count(*) from public.route_durations where destination_place_id = pg_temp.cu('nd') and origin_place_id = (select id from public.places where slug = 'luanda')), 1::bigint, 'route moved');
select ok((select 'Ndalatando Sul 2' = any(aliases) and 'N. Sul' = any(aliases) from public.places where id = pg_temp.cu('nd')), 'aliases merged');
select is((select is_active from public.places where id = pg_temp.cu('pl')), false, 'duplicate deactivated');
select pg_temp.as_anon();
select is((select count(*) from public.places where id = pg_temp.cu('pl')), 0::bigint, 'inactive place hidden from anon');
reset role;

-- ---------------------------------------------------------------------------
-- 8. Чаты для admin: только жалоба или спор
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('m1', public.send_message('Olá, há lugar?', null, pg_temp.cu('t1'))::text);
reset role;
insert into ctx values ('conv', (select id::text from public.conversations where trip_id = pg_temp.cu('t1') and passenger_id = pg_temp.cu('ana')));
select pg_temp.as_admin();
select is((select count(*) from public.messages where conversation_id = pg_temp.cu('conv')), 0::bigint, 'admin sees no messages without a report');
select is((select count(*) from public.my_conversations where id = pg_temp.cu('conv')), 0::bigint, 'admin chat list empty without a report');
select pg_temp.as_user(pg_temp.cu('teresa'));
insert into ctx values ('rep3', public.report_user(pg_temp.cu('ana'), 'cash_offer', 'Propôs dinheiro vivo', pg_temp.cu('t1'))::text);
select pg_temp.as_admin();
select is((select count(*) from public.messages where conversation_id = pg_temp.cu('conv')), 1::bigint, 'admin sees messages once a report is open');
select is((select count(*) from public.my_conversations where id = pg_temp.cu('conv')), 1::bigint, 'admin chat list shows the reported chat');
select lives_ok($$ select public.admin_resolve_report(pg_temp.cu('rep3'), 'dismissed') $$, 'dismiss');
select is((select count(*) from public.messages where conversation_id = pg_temp.cu('conv')), 0::bigint, 'access closes with the report');
reset role;
select pg_temp.book_paid('a_t1', 't1', 'ana', 1);
update public.bookings set status = 'disputed', passenger_confirmed_at = now() where id = pg_temp.cu('a_t1');
select pg_temp.as_admin();
select ok((select count(*) >= 1 from public.messages where conversation_id = pg_temp.cu('conv')), 'admin sees the chat of a disputed booking');
reset role;

-- ---------------------------------------------------------------------------
-- 9. Дашборд
-- ---------------------------------------------------------------------------
select pg_temp.as_admin();
insert into ctx values ('stats', public.admin_stats()::text);
select is((pg_temp.c('stats')::jsonb -> 'queues' ->> 'disputes')::int, 1, 'stats: one dispute');
select is((pg_temp.c('stats')::jsonb -> 'queues' ->> 'reports_open')::int, 0, 'stats: no open reports');
select is((pg_temp.c('stats')::jsonb -> 'queues' ->> 'refunds_manual')::int, 0, 'stats: manual queue cleared');
select ok((pg_temp.c('stats')::jsonb -> 'today' ->> 'bookings_paid')::int >= 5, 'stats: paid today counted');
select ok((pg_temp.c('stats')::jsonb -> 'health') ? 'scheduler_errors', 'stats: health block');
select is((select count(*) from public.admin_weekly(3)), 3::bigint, 'weekly: 3 rows');
select ok((select (w ->> 'paid')::int >= 5 and jsonb_typeof(w -> 'top_routes') = 'array' from public.admin_weekly(1) w), 'weekly: current week has payments and top routes');
reset role;

-- ---------------------------------------------------------------------------
-- 10. suspend и снятие по сроку (as_of двигает время, поэтому в конце)
-- ---------------------------------------------------------------------------
select pg_temp.as_admin();
select throws_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'suspend', 'Reincidente') $$, 'P0001', 'BOLEIA_DAYS_REQUIRED', 'suspend needs days');
select lives_ok($$ select public.admin_moderate(pg_temp.cu('pedro'), 'suspend', 'Reincidente', 3) $$, 'suspend 3 days');
reset role;
select is((select (status::text, suspended_until > now() + interval '2 days') from public.profiles where id = pg_temp.cu('pedro')), ('suspended'::text, true), 'suspended with until');
select is((select until is not null from public.moderation_actions where target_user_id = pg_temp.cu('pedro') and action = 'suspend'), true, 'until logged');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.upsert_profile('{"bio":"x"}') $$, 'P0001', 'BOLEIA_PROFILE_RESTRICTED', 'suspended cannot call RPC');
reset role;
select is((public.run_scheduler(now() + interval '2 days') ->> 'lift_suspensions')::int, 0, 'not lifted before the term');
select is((public.run_scheduler(now() + interval '4 days') ->> 'lift_suspensions')::int, 1, 'lifted after the term');
select is((select (status::text, suspended_until) from public.profiles where id = pg_temp.cu('pedro')), ('active'::text, null::timestamptz), 'active again');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('pedro') and type = 'moderation_action' and payload ->> 'action' = 'unsuspend'), 'told about the end of suspension');

select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x), 0::bigint, 'every ledger op sums to zero');

select * from finish();
rollback;
