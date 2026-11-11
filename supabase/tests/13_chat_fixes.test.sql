begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

create temp table ctx (name text primary key, value text);
grant all on ctx to anon, authenticated;
create function pg_temp.ctx_uuid(text) returns uuid language sql as $$ select value::uuid from ctx where name = $1 $$;
create function pg_temp.as_user(uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', $1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.book_paid(booking_name text, trip_name text, passenger_name text, seat_count integer) returns uuid language plpgsql as $$
declare response jsonb;
begin
  perform pg_temp.as_user(pg_temp.ctx_uuid(passenger_name));
  response := public.request_booking(pg_temp.ctx_uuid(trip_name), seat_count);
  perform set_config('role', 'none', true);
  perform public.confirm_payment((response ->> 'payment_id')::uuid, 'ref-' || booking_name, 'paid',
    (select phone from public.profiles where id = pg_temp.ctx_uuid(passenger_name)));
  insert into ctx values (booking_name, response ->> 'booking_id');
  return (response ->> 'booking_id')::uuid;
end $$;
create function pg_temp.chat(trip_name text) returns public.conversations language sql as $$
  select * from public.conversations where trip_id = pg_temp.ctx_uuid(trip_name) and passenger_id = pg_temp.ctx_uuid('ana')
$$;

insert into ctx values
  ('joao', '22222222-2222-2222-2222-222222222222'),
  ('ana',  '55555555-5555-5555-5555-555555555555');
insert into ctx select 'trip', id::text from public.trips
  where driver_id = pg_temp.ctx_uuid('joao') and status = 'published' order by departure_at desc limit 1;

-- ---------------------------------------------------------------------------
-- 1. mask_text: телефоны с разделителями
-- ---------------------------------------------------------------------------
select is(public.mask_text('liga 923 456 789'), 'liga [oculto]', 'spaces between groups');
select is(public.mask_text('liga 923-456-789 hoje'), 'liga [oculto] hoje', 'dashes between groups');
select is(public.mask_text('923.456.789'), '[oculto]', 'dots between groups');
select is(public.mask_text('9 2 3 4 5 6 7 8 9'), '[oculto]', 'digit by digit');
select is(public.mask_text('+244 923 456 789'), '[oculto]', 'country code with spaces');
select is(public.mask_text('00244923456789'), '[oculto]', '00 prefix');
select is(public.mask_text('fixo 244 222 123 456'), 'fixo [oculto]', 'landline with country code');
select is(public.mask_text('liga 923456789 ou +244923456789'), 'liga [oculto] ou [oculto]', 'compact forms still masked');
select is(public.mask_text('ver https://exemplo.ao/x e wa.me/244923456789'), 'ver [oculto] e [oculto]', 'links still masked');
select is(public.mask_text('Saio às 9, levo 2 malas e cobro 7 000 Kz'), 'Saio às 9, levo 2 malas e cobro 7 000 Kz', 'time, bags and price untouched');
select is(public.mask_text('9 lugares? Não, só 3. Partida 09:30 de 12/11/2026'), '9 lugares? Não, só 3. Partida 09:30 de 12/11/2026', 'seats and date untouched');
select is(public.mask_text('ref 1923456789012'), 'ref 1923456789012', 'long number is not cut');

-- 0017: обычные форматы записи
select is(public.mask_text('liga 923  456  789'), 'liga [oculto]', 'double spaces');
select is(public.mask_text('923 - 456 - 789'), '[oculto]', 'dashes with spaces around');
select is(public.mask_text('(923) 456-789'), '[oculto]', 'operator code in parentheses');
select is(public.mask_text('+244 (923) 456 789'), '[oculto]', 'country code, then parentheses');
select is(public.mask_text('(+244) 923 456 789'), '[oculto]', 'country code in parentheses');
select is(public.mask_text('9 000, 12 000, 15 000'), '9 000, 12 000, 15 000', 'comma-separated prices untouched');
select is(public.mask_text('Preço: 9 000 (ida) e 12 000 (volta), 2 malas'), 'Preço: 9 000 (ida) e 12 000 (volta), 2 malas', 'prices with parentheses untouched');
select is(public.mask_text('Saio dia 9 (sábado) - 12h30 - 2 lugares'), 'Saio dia 9 (sábado) - 12h30 - 2 lugares', 'day, time and seats untouched');
select is(public.mask_text('IBAN AO06 0040 0000 9234 5678 9012 3'), 'IBAN AO06 0040 0000 9234 5678 9012 3', 'IBAN is not cut');

-- ---------------------------------------------------------------------------
-- 2. Повторная бронь забирает разговор и открывает его
-- ---------------------------------------------------------------------------
select pg_temp.book_paid('b1', 'trip', 'ana', 1);
select is((pg_temp.chat('trip')).booking_id, pg_temp.ctx_uuid('b1'), 'first paid booking owns the chat');

select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select lives_ok($$ select public.cancel_booking(pg_temp.ctx_uuid('b1')) $$, 'passenger cancels the first booking');
reset role;
select public.sch_close_chats(now() + interval '25 hours');
select ok((pg_temp.chat('trip')).closed_at is not null, 'chat closed 24h after the cancellation');

select pg_temp.book_paid('b2', 'trip', 'ana', 1);
select is((pg_temp.chat('trip')).booking_id, pg_temp.ctx_uuid('b2'), 'new paid booking takes the chat over');
select ok((pg_temp.chat('trip')).closed_at is null, 'chat reopened by the new booking');
select ok(public.conversation_paid(pg_temp.chat('trip')), 'chat counts as paid again');

select pg_temp.as_user(pg_temp.ctx_uuid('ana'));
select lives_ok($$ select public.send_message('Olá, voltei a reservar', (pg_temp.chat('trip')).id) $$, 'passenger can write again');
reset role;

-- системное сообщение по старой брони не возвращает разговор назад
select public.ensure_conversation(pg_temp.ctx_uuid('trip'), pg_temp.ctx_uuid('ana'), pg_temp.ctx_uuid('b1'));
select is((pg_temp.chat('trip')).booking_id, pg_temp.ctx_uuid('b2'), 'dead booking does not steal the chat');
select ok((pg_temp.chat('trip')).closed_at is null, 'and does not touch closed_at');

select * from finish();
rollback;
