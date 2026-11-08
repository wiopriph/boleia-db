begin;
create extension if not exists pgtap with schema extensions;
select plan(135);

-- ---------------------------------------------------------------------------
-- Контекст и хелперы
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
create function pg_temp.conv(trip_k text, passenger_k text) returns uuid language sql as $$
  select id from public.conversations where trip_id = pg_temp.cu(trip_k) and passenger_id = pg_temp.cu(passenger_k)
$$;
create function pg_temp.notif_n(user_k text, type text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = pg_temp.cu(user_k) and notifications.type = notif_n.type and channel = 'inapp'
$$;

insert into ctx values
  ('admin',  '11111111-1111-1111-1111-111111111111'),
  ('joao',   '22222222-2222-2222-2222-222222222222'),
  ('teresa', '33333333-3333-3333-3333-333333333333'),
  ('pedro',  '44444444-4444-4444-4444-444444444444'),
  ('ana',    '55555555-5555-5555-5555-555555555555');
-- поездки João по 7 000 (j1, j2) и любые другие опубликованные (x1..x6)
insert into ctx select 'j' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id = pg_temp.cu('joao') and price_per_seat_kz = 7000 and status = 'published') t where rn <= 2;
insert into ctx select 'x' || rn, id::text from (select id, row_number() over (order by departure_at) rn from public.trips
  where driver_id <> pg_temp.cu('joao') and status = 'published') t where rn <= 6;

-- ---------------------------------------------------------------------------
-- 1. Чат до брони, маскирование, лимиты
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.send_message('   ', null, pg_temp.cu('j1')) $$, 'P0001', 'BOLEIA_MESSAGE_EMPTY', 'empty message');
select throws_ok($$ select public.send_message(repeat('x', 1001), null, pg_temp.cu('j1')) $$, 'P0001', 'BOLEIA_MESSAGE_TOO_LONG', 'too long');
select throws_ok($$ select public.send_message('Olá') $$, 'P0001', 'BOLEIA_TRIP_NOT_FOUND', 'neither conversation nor trip');
insert into ctx values ('m1', public.send_message('Olá, ainda há lugar?', null, pg_temp.cu('j1'))::text);
reset role;
insert into ctx values ('conv_j1', pg_temp.conv('j1', 'ana')::text);
select ok(pg_temp.conv('j1', 'ana') is not null, 'conversation created from trip card');
select is((select booking_id from public.conversations where id = pg_temp.conv('j1', 'ana')), null, 'no booking yet');
select is((select (body, masked) from public.messages where id = pg_temp.c('m1')::bigint), ('Olá, ainda há lugar?'::text, false), 'plain text untouched');
select is(pg_temp.notif_n('joao', 'new_message'), 1::bigint, 'driver notified');
select is((select payload ->> 'preview' from public.notifications where user_id = pg_temp.cu('joao') and type = 'new_message' limit 1), 'Olá, ainda há lugar?', 'preview in payload');

select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('m2', public.send_message('liga +244912345678', pg_temp.conv('j1', 'ana'))::text);
insert into ctx values ('m3', public.send_message('ou 912345678 ok', pg_temp.conv('j1', 'ana'))::text);
reset role;
select is((select count(*) from public.reports where reason = 'cash_offer'), 0::bigint, 'no report after 2 masked');
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx values ('m4', public.send_message('wa.me/244912345678 escreve', pg_temp.conv('j1', 'ana'))::text);
insert into ctx values ('m5', public.send_message('ver http://exemplo.com/x', pg_temp.conv('j1', 'ana'))::text);
insert into ctx values ('m6', public.send_message('Saída às 6h, ano 2024, 12345', pg_temp.conv('j1', 'ana'))::text);
reset role;
select is((select body from public.messages where id = pg_temp.c('m2')::bigint), 'liga [oculto]', 'phone with +244 masked');
select is((select body from public.messages where id = pg_temp.c('m3')::bigint), 'ou [oculto] ok', 'local 9-digit masked');
select is((select body from public.messages where id = pg_temp.c('m4')::bigint), '[oculto] escreve', 'wa.me masked');
select is((select body from public.messages where id = pg_temp.c('m5')::bigint), 'ver [oculto]', 'link masked');
select is((select (body, masked) from public.messages where id = pg_temp.c('m6')::bigint), ('Saída às 6h, ano 2024, 12345'::text, false), 'short numbers untouched');
select is((select count(*) from public.messages where conversation_id = pg_temp.conv('j1', 'ana') and masked), 4::bigint, '4 masked messages');
select is((select (reporter_id, target_user_id, reason::text, message_id) from public.reports where reason = 'cash_offer'),
  (null::uuid, pg_temp.cu('ana'), 'cash_offer'::text, pg_temp.c('m4')::bigint), 'auto report on 3rd masked message, system as reporter');
select is((select count(*) from public.reports where reason = 'cash_offer'), 1::bigint, '4th masked does not duplicate the report');
select ok(pg_temp.notif_n('admin', 'report_opened') >= 1, 'admins notified about the report');
select ok((select count(*) from public.notifications where user_id = pg_temp.cu('joao') and type = 'new_message' and channel = 'inapp') >= 6, 'driver notified while away');

-- 10 сообщений до оплаты
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.send_message('msg ' || g, pg_temp.conv('j1', 'ana')) from generate_series(7, 10) g $$, 'messages 7..10 allowed');
select throws_ok($$ select public.send_message('msg 11', pg_temp.conv('j1', 'ana')) $$, 'P0001', 'BOLEIA_CHAT_LIMIT_REACHED', '11th message before booking refused');
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.send_message('Sim, há lugar.', pg_temp.conv('j1', 'ana')) $$, 'driver is not limited');
select throws_ok($$ select public.send_message('Olá', null, pg_temp.cu('j1')) $$, 'P0001', 'BOLEIA_OWN_TRIP', 'driver cannot chat on own trip');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.send_message('Olá', pg_temp.cu('conv_j1')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'stranger refused');
select throws_ok($$ select public.mark_read(pg_temp.cu('conv_j1'), 1) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'stranger cannot mark read');

-- 5 новых чатов в сутки (j1 уже есть)
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.send_message('Olá', null, pg_temp.cu('x' || g)) from generate_series(1, 4) g $$, 'chats 2..5 allowed');
select throws_ok($$ select public.send_message('Olá', null, pg_temp.cu('x5')) $$, 'P0001', 'BOLEIA_CHAT_LIMIT_REACHED', '6th new chat per day refused');
select lives_ok($$ select public.send_message('Ainda aí?', pg_temp.conv('x1', 'ana')) $$, 'existing chat still works');
reset role;

-- системное сообщение не маскируется
select public.system_message(pg_temp.conv('j1', 'ana'), 'Contacto do condutor: +244900000002');
select is((select masked from public.messages where conversation_id = pg_temp.conv('j1', 'ana') and sender_id is null order by id desc limit 1), false, 'system message not masked');

-- закрытый чат
update public.conversations set closed_at = now() where id = pg_temp.conv('x1', 'ana');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.send_message('Olá?', pg_temp.conv('x1', 'ana')) $$, 'P0001', 'BOLEIA_CHAT_CLOSED', 'closed chat refuses messages');
reset role;

-- ---------------------------------------------------------------------------
-- 2. Оплаченный чат: 60/мин, presence, mark_read
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('t_j2', 'j2', 'teresa', 1);
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.send_message('ping ' || g, pg_temp.conv('j2', 'teresa')) from generate_series(1, 60) g $$, '60 messages in a minute allowed in a paid chat');
select throws_ok($$ select public.send_message('ping 61', pg_temp.conv('j2', 'teresa')) $$, 'P0001', 'BOLEIA_RATE_LIMITED', '61st per minute refused');
reset role;
insert into ctx values ('joao_nm', pg_temp.notif_n('joao', 'new_message')::text);
select pg_temp.as_user(pg_temp.cu('teresa'));
select is((select driver_name from public.my_bookings where id = pg_temp.cu('t_j2')), 'João M.', 'passenger sees her booking with driver name in my_bookings');
select is((select (other_user_name, unread_count) from public.my_conversations where id = pg_temp.conv('j2', 'teresa')), ('João M.'::text, 1::bigint), 'passenger sees the chat with the driver name; system message counts as unread');
reset role;
select pg_temp.as_user(pg_temp.cu('joao'));
select is((select unread_count from public.my_conversations where id = pg_temp.conv('j2', 'teresa')), 61::bigint, 'unread count before mark_read: 60 + system message');
select lives_ok($$ select public.mark_read(pg_temp.conv('j2', 'teresa'), (select max(id) from public.messages where conversation_id = pg_temp.conv('j2', 'teresa'))) $$, 'driver marks read');
select is((select unread_count from public.my_conversations where id = pg_temp.conv('j2', 'teresa')), 0::bigint, 'unread count after mark_read');
reset role;
select is((select count(*) from public.messages where conversation_id = pg_temp.conv('j2', 'teresa') and sender_id = pg_temp.cu('teresa') and read_at is null), 0::bigint, 'passenger messages marked read');
select ok((select driver_seen_at > now() - interval '5 seconds' from public.conversations where id = pg_temp.conv('j2', 'teresa')), 'driver_seen_at updated');
update public.messages set created_at = created_at - interval '2 minutes' where conversation_id = pg_temp.conv('j2', 'teresa');  -- окно 60/мин прошло
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.send_message('ainda aí?', pg_temp.conv('j2', 'teresa')) $$, 'message while driver is in the chat');
reset role;
select is(pg_temp.notif_n('joao', 'new_message'), pg_temp.c('joao_nm')::bigint, 'no push while recipient was in the chat < 60s ago');

-- ---------------------------------------------------------------------------
-- 3. reveal_contact и снятие маскирования за 2 ч
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('teresa'));
select throws_ok($$ select public.reveal_contact(pg_temp.cu('t_j2')) $$, 'P0001', 'BOLEIA_CONTACT_LOCKED', 'contact locked before departure - 2h');
reset role;
update public.trips set departure_at = now() + interval '90 minutes' where id = pg_temp.cu('j2');
select pg_temp.as_user(pg_temp.cu('teresa'));
select is(public.reveal_contact(pg_temp.cu('t_j2')) ->> 'phone', '+244900000002', 'passenger sees driver phone');
select lives_ok($$ select public.send_message('o meu número é +244900000003', pg_temp.conv('j2', 'teresa')) $$, 'phone after -2h');
select pg_temp.as_user(pg_temp.cu('joao'));
select is(public.reveal_contact(pg_temp.cu('t_j2')) ->> 'phone', '+244900000003', 'driver sees passenger phone');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.reveal_contact(pg_temp.cu('t_j2')) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'stranger cannot reveal');
reset role;
select is((select count(*) from public.contact_reveals where booking_id = pg_temp.cu('t_j2')), 2::bigint, 'both reveals logged');
select is((select masked from public.messages where conversation_id = pg_temp.conv('j2', 'teresa') order by id desc limit 1), false, 'phone not masked after -2h with paid booking');

select pg_temp.book_paid('a_x2', 'x2', 'ana', 1);
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.cancel_booking(pg_temp.cu('a_x2')) $$, 'Ana cancels x2');
select throws_ok($$ select public.reveal_contact(pg_temp.cu('a_x2')) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'no contact on cancelled booking');
reset role;

-- ---------------------------------------------------------------------------
-- 4. Отзывы
-- ---------------------------------------------------------------------------
update public.trips set departure_at = now() - interval '2 hours', status = 'departed', departed_at = now() - interval '2 hours' where id = pg_temp.cu('j2');
update public.bookings set status = 'awaiting_confirm' where id = pg_temp.cu('t_j2');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ select public.confirm_trip(pg_temp.cu('t_j2'), true) $$, 'Teresa confirms trip');
select throws_ok($$ select public.submit_review(pg_temp.cu('t_j2'), 6) $$, 'P0001', 'BOLEIA_RATING_INVALID', 'rating 6');
select throws_ok($$ select public.submit_review(pg_temp.cu('t_j2'), 5, array['rápido']) $$, 'P0001', 'BOLEIA_TAGS_INVALID', 'unknown tag');
insert into ctx values ('rev1', public.submit_review(pg_temp.cu('t_j2'), 5, array['pontual', 'simpático'], 'Ótima viagem')::text);
select throws_ok($$ select public.submit_review(pg_temp.cu('t_j2'), 4) $$, 'P0001', 'BOLEIA_REVIEW_DUPLICATE', 'second review refused');
reset role;
select is((select (direction::text, target_id, is_visible) from public.reviews where id = pg_temp.cu('rev1')), ('passenger_to_driver'::text, pg_temp.cu('joao'), false), 'review stored, hidden until the other side');
select is((select (rating_avg, rating_count) from public.profiles where id = pg_temp.cu('joao')), (5.00::numeric(3,2), 1), 'driver rating recalculated from review rows');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.submit_review(pg_temp.cu('t_j2'), 5) $$, 'P0001', 'BOLEIA_NOT_PARTICIPANT', 'stranger cannot review');
select pg_temp.as_user(pg_temp.cu('joao'));
select lives_ok($$ select public.submit_review(pg_temp.cu('t_j2'), 4, '{}', null) $$, 'driver reviews passenger');
reset role;
select is((select bool_and(is_visible) from public.reviews where booking_id = pg_temp.cu('t_j2')), true, 'both reviews visible once both exist');

select pg_temp.book_paid('a_x3', 'x3', 'ana', 1);
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.submit_review(pg_temp.cu('a_x3'), 5) $$, 'P0001', 'BOLEIA_BOOKING_CLOSED', 'no review on accepted booking');
reset role;
update public.bookings set status = 'completed', completed_at = now() - interval '15 days' where id = pg_temp.cu('a_x3');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.submit_review(pg_temp.cu('a_x3'), 5) $$, 'P0001', 'BOLEIA_REVIEW_WINDOW_CLOSED', 'review window closed after 14 days');
reset role;
update public.bookings set status = 'no_show', completed_at = now() where id = pg_temp.cu('a_x3');
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.submit_review(pg_temp.cu('a_x3'), 2, '{}', 'Não apareci, culpa minha') $$, 'review allowed on no_show');
reset role;

-- ---------------------------------------------------------------------------
-- 5. Жалобы
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.report_user(pg_temp.cu('ana'), 'other') $$, 'P0001', 'BOLEIA_TARGET_INVALID', 'cannot report self');
select throws_ok($$ select public.report_user('00000000-0000-0000-0000-000000000000', 'other') $$, 'P0001', 'BOLEIA_TARGET_INVALID', 'unknown target');
insert into ctx values ('rep1', public.report_user(pg_temp.cu('pedro'), 'harassment', 'Mensagens impróprias', pg_temp.cu('x2'))::text);
select lives_ok($$ select public.report_user(pg_temp.cu('pedro'), 'other', 'r' || g) from generate_series(2, 10) g $$, 'reports 2..10 allowed');
select throws_ok($$ select public.report_user(pg_temp.cu('pedro'), 'other', 'r11') $$, 'P0001', 'BOLEIA_RATE_LIMITED', '11th report per day refused');
reset role;
select is((select (status::text, reporter_id, target_user_id) from public.reports where id = pg_temp.cu('rep1')), ('open'::text, pg_temp.cu('ana'), pg_temp.cu('pedro')), 'report open');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('admin') and type = 'report_opened' and payload ->> 'report_id' = pg_temp.c('rep1')), 'admin notified');

-- ---------------------------------------------------------------------------
-- 6. Выплаты: баланс João = 7 000 после t_j2
-- ---------------------------------------------------------------------------
select is((select balance_kz from public.profiles where id = pg_temp.cu('joao')), 7000, 'driver balance 7000');
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.request_payout(5000) $$, 'P0001', 'BOLEIA_PAYOUT_METHOD_INVALID', 'no payout method');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.request_payout(4000) $$, 'P0001', 'BOLEIA_AMOUNT_INVALID', 'below minimum 5000');
select throws_ok($$ select public.request_payout(20000) $$, 'P0001', 'BOLEIA_INSUFFICIENT_BALANCE', 'above balance');
insert into ctx values ('po1', public.request_payout(5000)::text);
select throws_ok($$ select public.request_payout(5000) $$, 'P0001', 'BOLEIA_PAYOUT_PENDING', 'second request while pending');
reset role;
select is((select balance_kz from public.profiles where id = pg_temp.cu('joao')), 2000, 'balance reduced immediately');
select is((select (status::text, amount_kz, method ->> 'type') from public.payouts where id = pg_temp.cu('po1')), ('requested'::text, 5000, 'mcx_express'::text), 'payout requested with method snapshot');
select is((select sum(amount_kz) from public.ledger_entries where payout_id = pg_temp.cu('po1')), 0::bigint, 'payout op balanced');
select is((select amount_kz from public.ledger_entries where payout_id = pg_temp.cu('po1') and account = 'cash_out'), 5000, 'cash_out row');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('admin') and type = 'payout_requested'), 'admin notified');

select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.mark_payout(pg_temp.cu('po1'), 'paid', 'x') $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'non-admin cannot mark');
select pg_temp.as_admin();
select throws_ok($$ select public.mark_payout(pg_temp.cu('po1'), 'bogus') $$, 'P0001', 'BOLEIA_PAYOUT_STATUS_INVALID', 'unknown status');
select lives_ok($$ select public.mark_payout(pg_temp.cu('po1'), 'failed', 'IBAN inválido') $$, 'admin marks failed');
select throws_ok($$ select public.mark_payout(pg_temp.cu('po1'), 'paid') $$, 'P0001', 'BOLEIA_PAYOUT_CLOSED', 'closed payout');
reset role;
select is((select balance_kz from public.profiles where id = pg_temp.cu('joao')), 7000, 'failed payout returns money');
select is((select count(*) from public.ledger_entries where payout_id = pg_temp.cu('po1')), 4::bigint, 'reversal rows written');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('joao') and type = 'payout_failed'), 'driver told');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.request_payout(5000) $$, 'P0001', 'BOLEIA_RATE_LIMITED', 'one request per 7 days');
reset role;
update public.payouts set created_at = now() - interval '8 days' where id = pg_temp.cu('po1');
select pg_temp.as_user(pg_temp.cu('joao'));
insert into ctx values ('po2', public.request_payout(7000)::text);
select pg_temp.as_admin();
select lives_ok($$ select public.mark_payout(pg_temp.cu('po2'), 'processing') $$, 'processing');
select lives_ok($$ select public.mark_payout(pg_temp.cu('po2'), 'paid', 'MCX-123') $$, 'paid');
reset role;
select is((select (status::text, provider_ref, processed_by) from public.payouts where id = pg_temp.cu('po2')), ('paid'::text, 'MCX-123'::text, pg_temp.cu('admin')), 'paid with ref and admin');
select is((select balance_kz from public.profiles where id = pg_temp.cu('joao')), 0, 'balance zero after payout');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('joao') and type = 'payout_paid'), 'driver told about payment');

-- ---------------------------------------------------------------------------
-- 7. Верификация: Pedro не verified
-- ---------------------------------------------------------------------------
insert into ctx values ('pedro_car', (select id::text from public.vehicles where owner_id = pg_temp.cu('pedro') limit 1));
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.submit_verification(pg_temp.cu('pedro_car'), '{"id_doc_url":"44444444-4444-4444-4444-444444444444/bi.jpg"}') $$,
  'P0001', 'BOLEIA_VERIFICATION_INCOMPLETE', 'missing documents');
select throws_ok($$ select public.submit_verification(pg_temp.cu('pedro_car'), jsonb_build_object(
  'id_doc_url', 'other/bi.jpg', 'licence_url', '44444444-4444-4444-4444-444444444444/l.jpg',
  'vehicle_photo_url', '44444444-4444-4444-4444-444444444444/v.jpg', 'selfie_url', '44444444-4444-4444-4444-444444444444/s.jpg')) $$,
  'P0001', 'BOLEIA_VERIFICATION_INCOMPLETE', 'document outside own folder');
select throws_ok($$ select public.submit_verification('aaaa0000-0000-0000-0000-000000000001', '{}') $$, 'P0001', 'BOLEIA_VEHICLE_NOT_FOUND', 'not my vehicle');
insert into ctx values ('ver1', public.submit_verification(pg_temp.cu('pedro_car'), jsonb_build_object(
  'id_doc_url', '44444444-4444-4444-4444-444444444444/bi.jpg', 'licence_url', '44444444-4444-4444-4444-444444444444/l.jpg',
  'vehicle_photo_url', '44444444-4444-4444-4444-444444444444/v.jpg', 'selfie_url', '44444444-4444-4444-4444-444444444444/s.jpg'))::text);
select throws_ok($$ select public.submit_verification(pg_temp.cu('pedro_car'), jsonb_build_object(
  'id_doc_url', '44444444-4444-4444-4444-444444444444/bi.jpg', 'licence_url', '44444444-4444-4444-4444-444444444444/l.jpg',
  'vehicle_photo_url', '44444444-4444-4444-4444-444444444444/v.jpg', 'selfie_url', '44444444-4444-4444-4444-444444444444/s.jpg')) $$,
  'P0001', 'BOLEIA_VERIFICATION_PENDING', 'one pending at a time');
reset role;
select is((select driver_status::text from public.profiles where id = pg_temp.cu('pedro')), 'pending', 'driver_status pending');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('admin') and type = 'verification_submitted'), 'admin notified');

select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.review_verification(pg_temp.cu('ver1'), true) $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'non-admin cannot review');
select pg_temp.as_admin();
select throws_ok($$ select public.review_verification(pg_temp.cu('ver1'), false) $$, 'P0001', 'BOLEIA_REASON_REQUIRED', 'reject needs a reason');
select lives_ok($$ select public.review_verification(pg_temp.cu('ver1'), false, 'Foto ilegível') $$, 'rejected');
select throws_ok($$ select public.review_verification(pg_temp.cu('ver1'), true) $$, 'P0001', 'BOLEIA_VERIFICATION_CLOSED', 'cannot review twice');
reset role;
select is((select (status::text, reject_reason) from public.driver_verifications where id = pg_temp.cu('ver1')), ('rejected'::text, 'Foto ilegível'::text), 'rejection stored');
select is((select driver_status::text from public.profiles where id = pg_temp.cu('pedro')), 'rejected', 'driver_status rejected');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('pedro') and type = 'verification_rejected' and payload ->> 'reason' = 'Foto ilegível'), 'driver told why');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.submit_verification(pg_temp.cu('pedro_car'), jsonb_build_object(
  'id_doc_url', '44444444-4444-4444-4444-444444444444/bi2.jpg', 'licence_url', '44444444-4444-4444-4444-444444444444/l.jpg',
  'vehicle_photo_url', '44444444-4444-4444-4444-444444444444/v.jpg', 'selfie_url', '44444444-4444-4444-4444-444444444444/s.jpg')) $$,
  'P0001', 'BOLEIA_RATE_LIMITED', 'resubmit within 24h refused');
reset role;
update public.driver_verifications set reviewed_at = now() - interval '25 hours' where id = pg_temp.cu('ver1');
select pg_temp.as_user(pg_temp.cu('pedro'));
insert into ctx values ('ver2', public.submit_verification(pg_temp.cu('pedro_car'), jsonb_build_object(
  'id_doc_url', '44444444-4444-4444-4444-444444444444/bi2.jpg', 'licence_url', '44444444-4444-4444-4444-444444444444/l.jpg',
  'vehicle_photo_url', '44444444-4444-4444-4444-444444444444/v.jpg', 'selfie_url', '44444444-4444-4444-4444-444444444444/s.jpg'))::text);
select pg_temp.as_admin();
select lives_ok($$ select public.review_verification(pg_temp.cu('ver2'), true) $$, 'approved');
reset role;
select is((select (driver_status::text, driver_verified_at is not null) from public.profiles where id = pg_temp.cu('pedro')), ('verified'::text, true), 'driver verified');
select is((select verified from public.vehicles where id = pg_temp.cu('pedro_car')), true, 'vehicle verified');
select ok(exists (select 1 from public.moderation_actions where target_user_id = pg_temp.cu('pedro') and action = 'verify_id'), 'moderation action logged');
select ok(exists (select 1 from public.notifications where user_id = pg_temp.cu('pedro') and type = 'verification_approved'), 'driver told');

-- verified водитель с новой машиной остаётся verified
select pg_temp.as_user(pg_temp.cu('joao'));
insert into ctx values ('joao_car2', public.upsert_vehicle('{"make":"Kia","model":"Sportage","seats_total":4,"plate":"LD-99-99-ZZ"}')::text);
select lives_ok($$ select public.submit_verification(pg_temp.cu('joao_car2'), jsonb_build_object(
  'id_doc_url', '22222222-2222-2222-2222-222222222222/bi.jpg', 'licence_url', '22222222-2222-2222-2222-222222222222/l.jpg',
  'vehicle_photo_url', '22222222-2222-2222-2222-222222222222/v.jpg', 'selfie_url', '22222222-2222-2222-2222-222222222222/s.jpg')) $$, 'verified driver submits a second car');
reset role;
select is((select driver_status::text from public.profiles where id = pg_temp.cu('joao')), 'verified', 'driver stays verified');

-- ---------------------------------------------------------------------------
-- 8. delete_me
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('a_x4', 'x4', 'ana', 1);
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select public.delete_me() $$, 'P0001', 'BOLEIA_HAS_ACTIVE_BOOKINGS', 'active booking blocks deletion');
select lives_ok($$ select public.cancel_booking(pg_temp.cu('a_x4')) $$, 'Ana cancels');
select pg_temp.as_user(pg_temp.cu('joao'));
select throws_ok($$ select public.delete_me() $$, 'P0001', 'BOLEIA_HAS_ACTIVE_BOOKINGS', 'driver with published trips blocked');
reset role;
update public.trips set status = 'cancelled', cancelled_at = now() where driver_id = pg_temp.cu('pedro') and status in ('published', 'full');
select public.ledger_post(gen_random_uuid(), 'test:bonus', null, '[{"account":"driver_balance","user_id":"44444444-4444-4444-4444-444444444444","amount_kz":1000},{"account":"platform_fee","amount_kz":-1000}]');
select pg_temp.as_user(pg_temp.cu('pedro'));
select throws_ok($$ select public.delete_me() $$, 'P0001', 'BOLEIA_BALANCE_NOT_ZERO', 'non-zero balance blocks deletion');
reset role;
insert into public.devices (user_id, platform, push_token) values (pg_temp.cu('ana'), 'android', 'tok-ana');
select pg_temp.as_user(pg_temp.cu('ana'));
select lives_ok($$ select public.delete_me() $$, 'clean account deleted');
reset role;
select is((select (status::text, display_name, phone, avatar_url, payout_method) from public.profiles where id = pg_temp.cu('ana')),
  ('deleted'::text, 'Utilizador removido'::text, null::text, null::text, null::jsonb), 'profile anonymised');
select is((select (phone, banned_until is not null) from auth.users where id = pg_temp.cu('ana')), (null::text, true), 'auth user freed and banned');
select is((select count(*) from public.devices where user_id = pg_temp.cu('ana')), 0::bigint, 'devices removed');
select is((select count(*) from public.profiles_public where id = pg_temp.cu('ana')), 0::bigint, 'hidden from profiles_public');
select ok((select count(*) >= 1 from public.reviews where author_id = pg_temp.cu('ana')), 'reviews remain');
select ok((select count(*) >= 3 from public.bookings where passenger_id = pg_temp.cu('ana')), 'bookings remain');
select is((select count(*) from public.conversations where passenger_id = pg_temp.cu('ana') and closed_at is null), 0::bigint, 'chats closed');
select throws_ok($$ select public.send_message('Olá', pg_temp.cu('conv_j1')) $$, 'P0001', 'BOLEIA_PROFILE_RESTRICTED', 'deleted profile cannot call RPC even with a live token');

-- ---------------------------------------------------------------------------
-- 9. Storage и инварианты
-- ---------------------------------------------------------------------------
select is((select count(*) from storage.buckets where id in ('avatars', 'vehicles', 'verifications')), 3::bigint, 'buckets exist');
select is((select public from storage.buckets where id = 'verifications'), false, 'verifications is private');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'boleia_%'), 5::bigint, 'storage policies installed');
select pg_temp.as_user(pg_temp.cu('teresa'));
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('verifications', '33333333-3333-3333-3333-333333333333/bi.jpg') $$, 'owner uploads into own folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('verifications', '44444444-4444-4444-4444-444444444444/bi.jpg') $$, '42501', null, 'cannot upload into another folder');
select is((select count(*) from storage.objects where bucket_id = 'verifications'), 1::bigint, 'owner reads own document');
select pg_temp.as_user(pg_temp.cu('pedro'));
select is((select count(*) from storage.objects where bucket_id = 'verifications'), 0::bigint, 'other user does not see it');
select pg_temp.as_admin();
select is((select count(*) from storage.objects where bucket_id = 'verifications'), 1::bigint, 'admin reads it');
reset role;

select is((select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x), 0::bigint, 'every ledger op sums to zero');
select is((select count(*) from public.profiles p where p.balance_kz <> coalesce((select sum(amount_kz) from public.ledger_entries where user_id = p.id and account = 'driver_balance'), 0)),
  0::bigint, 'balance cache consistent');

select * from finish();
rollback;
