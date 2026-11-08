begin;
create extension if not exists pgtap with schema extensions;
select plan(45);

-- таблицы
select has_table('public', t, 'table ' || t || ' exists') from unnest(array[
  'profiles','banned_phones','vehicles','driver_verifications','places','route_durations',
  'trips','trip_stops','bookings','payments','ledger_entries','payouts','conversations',
  'messages','reviews','reports','contact_reveals','moderation_actions','notifications',
  'devices','events'
]) as t;

-- enum'ы
select has_type('public', t, 'enum ' || t || ' exists') from unnest(array[
  'trip_status','booking_status','booking_mode','payment_status','ledger_account','driver_status'
]) as t;

-- views
select has_view('public', 'trips_public',     'trips_public exists');
select has_view('public', 'profiles_public',  'profiles_public exists');
select has_view('public', 'my_bookings',      'my_bookings exists');
select has_view('public', 'my_conversations', 'my_conversations exists');
select has_view('public', 'driver_wallet',    'driver_wallet exists');
select has_materialized_view('public', 'route_stats', 'route_stats exists');

-- публичные views не содержат чувствительных колонок
select hasnt_column('public', 'trips_public',    'phone',      'trips_public has no phone');
select hasnt_column('public', 'trips_public',    'plate',      'trips_public has no plate');
select hasnt_column('public', 'profiles_public', 'phone',      'profiles_public has no phone');
select hasnt_column('public', 'profiles_public', 'balance_kz', 'profiles_public has no balance');

-- ключевые RPC
select has_function('public', 'publish_trip',    array['jsonb'], 'publish_trip exists');
select has_function('public', 'request_booking', array['uuid','integer','text'], 'request_booking exists');
select has_function('public', 'confirm_payment', array['uuid','text','text','text','jsonb'], 'confirm_payment exists');

-- ledger immutable
insert into public.ledger_entries (account, amount_kz, op_id, memo)
values ('platform_fee', 100, gen_random_uuid(), 'test'), ('refunds', -100, gen_random_uuid(), 'test');
select throws_ok(
  $$ update public.ledger_entries set amount_kz = 0 where memo = 'test' $$,
  'P0001', 'BOLEIA_LEDGER_IMMUTABLE', 'ledger rows cannot be updated'
);
select throws_ok(
  $$ delete from public.ledger_entries where memo = 'test' $$,
  'P0001', 'BOLEIA_LEDGER_IMMUTABLE', 'ledger rows cannot be deleted'
);

-- fee formula: max(10%, 1000) один раз на бронь
select is(public.calc_fee_kz(28000), 2800, 'fee 10% above minimum');
select is(public.calc_fee_kz(6000),  1000, 'fee hits 1000 minimum');
select is(public.calc_fee_kz(7000),  1000, 'fee 7000 -> 1000');

select * from finish();
rollback;
