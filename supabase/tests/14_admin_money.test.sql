begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

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

insert into ctx values
  ('admin', '11111111-1111-1111-1111-111111111111'),
  ('ana',   '55555555-5555-5555-5555-555555555555');
insert into ctx select 'trip', id::text from public.trips
  where driver_id = '44444444-4444-4444-4444-444444444444' and price_per_seat_kz = 7000 and status = 'published'
  order by departure_at limit 1;

-- ---------------------------------------------------------------------------
-- 1. Доступ
-- ---------------------------------------------------------------------------
select pg_temp.as_user(pg_temp.cu('ana'));
select throws_ok($$ select * from public.admin_ledger_balances() $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'balances: not admin');
select throws_ok($$ select * from public.admin_refund_queue() $$, 'P0001', 'BOLEIA_NOT_ADMIN', 'refund queue: not admin');
reset role;

-- ---------------------------------------------------------------------------
-- 2. Балансы по счетам
-- ---------------------------------------------------------------------------
insert into ctx select 'escrow_before', coalesce(sum(amount_kz), 0)::text from public.ledger_entries where account = 'passenger_escrow';
insert into ctx select 'queue_before', count(*)::text from public.payments where refund_kz > 0 and refund_ref is null;

-- оплата с чужого номера: деньги пришли и сразу поставлены на возврат
select pg_temp.as_user(pg_temp.cu('ana'));
insert into ctx select 'pay', public.request_booking(pg_temp.cu('trip'), 1) ->> 'payment_id';
reset role;
select public.confirm_payment(pg_temp.cu('pay'), 'gw-money-1', 'paid', '+244999999999');

select pg_temp.as_admin();
select is((select count(*) from public.admin_ledger_balances()),
  (select count(*) from unnest(enum_range(null::public.ledger_account))), 'one row per ledger account');
select is((select sum(balance_kz) from public.admin_ledger_balances()), 0::numeric, 'balances sum to zero');
select is((select balance_kz from public.admin_ledger_balances() where account = 'passenger_escrow'),
  pg_temp.c('escrow_before')::bigint, 'mismatched payment leaves nothing in escrow');
select ok((select entries from public.admin_ledger_balances() where account = 'refunds') > 0, 'refunds account has entries');

-- ---------------------------------------------------------------------------
-- 3. Очередь возвратов
-- ---------------------------------------------------------------------------
select is((select count(*) from public.admin_refund_queue()), pg_temp.c('queue_before')::bigint + 1, 'refund appears in the queue');
select is((select (is_manual, refund_attempts::int, payer_name, provider_ref) from public.admin_refund_queue() where payment_id = pg_temp.cu('pay')),
  (false, 0, 'Ana R.'::text, 'gw-money-1'::text), 'automatic refund: not manual, payer and gateway ref shown');
select is((select refund_kz from public.admin_refund_queue() where payment_id = pg_temp.cu('pay')),
  (select amount_kz from public.payments where id = pg_temp.cu('pay')), 'full amount to refund');
select throws_ok($$ select public.admin_mark_refund_manual(pg_temp.cu('pay'), 'MCX-EARLY') $$, 'P0001', 'BOLEIA_PAYMENT_STATUS_INVALID',
  'manual mark is refused while the refund is in the automatic queue');
select is((select count(*) from public.admin_refund_queue() where payment_id = pg_temp.cu('pay')), 1::bigint, 'refund stays in the queue');
reset role;

select public.payment_refund_result(pg_temp.cu('pay'), false), public.payment_refund_result(pg_temp.cu('pay'), false), public.payment_refund_result(pg_temp.cu('pay'), false);

select pg_temp.as_admin();
select is((select (is_manual, refund_attempts::int) from public.admin_refund_queue() where payment_id = pg_temp.cu('pay')),
  (true, 3), 'three failed attempts: manual');
select ok((select refund_failed_at is not null from public.admin_refund_queue() where payment_id = pg_temp.cu('pay')), 'last failure time shown');
select is((select payment_id from public.admin_refund_queue() limit 1), pg_temp.cu('pay'), 'manual refunds come first');
select is((select (queues ->> 'refunds_manual')::int from public.admin_stats() s(queues_root), lateral (select s.queues_root -> 'queues' as queues) q),
  (select count(*)::int from public.admin_refund_queue() where is_manual), 'queue matches the dashboard counter');

select public.admin_mark_refund_manual(pg_temp.cu('pay'), 'MCX-MONEY-1');
select is((select count(*) from public.admin_refund_queue() where payment_id = pg_temp.cu('pay')), 0::bigint, 'manual mark removes it from the queue');
select is((select sum(balance_kz) from public.admin_ledger_balances()), 0::numeric, 'balances still sum to zero');
reset role;

select * from finish();
rollback;
