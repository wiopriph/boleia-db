-- Boleia - booking core (ТЗ разделы 5, 6, 10)
--
-- Тела request_booking, retry_payment, confirm_payment, respond_booking, cancel_booking,
-- новая cancel_quote; ledger-операции payment / refund / release / forfeit; уведомления
-- и системные сообщения чата. План и принятые решения: docs/plans/0005_booking_core.md

-- Счёт "деньги пришли от шлюза": операция payment становится двусторонней (ТЗ раздел 10).
alter type public.ledger_account add value if not exists 'cash_in';

-- ---------------------------------------------------------------------------
-- profiles_guard: current_setting('role') внутри security definer остаётся 'authenticated'
-- и блокировал RPC; current_user там = владелец функции.
-- ---------------------------------------------------------------------------
create or replace function public.profiles_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if new.is_admin        is distinct from old.is_admin
    or new.status          is distinct from old.status
    or new.driver_status   is distinct from old.driver_status
    or new.driver_verified_at is distinct from old.driver_verified_at
    or new.rating_avg      is distinct from old.rating_avg
    or new.rating_count    is distinct from old.rating_count
    or new.trips_driven    is distinct from old.trips_driven
    or new.trips_ridden    is distinct from old.trips_ridden
    or new.cancels_total   is distinct from old.cancels_total
    or new.no_shows        is distinct from old.no_shows
    or new.balance_kz      is distinct from old.balance_kz
    or new.phone           is distinct from old.phone
    or new.phone_verified_at is distinct from old.phone_verified_at
    then
      perform public.raise_boleia('PROTECTED_FIELD');
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Ledger
-- ---------------------------------------------------------------------------

-- Единственная точка записи в ledger_entries. entries: [{account, user_id?, payout_id?, amount_kz}]
create or replace function public.ledger_post(p_op_id uuid, p_memo text, p_booking_id uuid, p_entries jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sum bigint;
  v_n   integer;
begin
  select coalesce(sum((e ->> 'amount_kz')::bigint), 0), count(*) filter (where (e ->> 'amount_kz')::integer <> 0)
  into v_sum, v_n
  from jsonb_array_elements(coalesce(p_entries, '[]')) e;

  if v_n < 2 or v_sum <> 0 then perform public.raise_boleia('LEDGER_UNBALANCED'); end if;

  insert into public.ledger_entries (booking_id, payout_id, account, user_id, amount_kz, op_id, memo)
  select p_booking_id, (e ->> 'payout_id')::uuid, (e ->> 'account')::ledger_account,
         (e ->> 'user_id')::uuid, (e ->> 'amount_kz')::integer, p_op_id, p_memo
  from jsonb_array_elements(p_entries) e
  where (e ->> 'amount_kz')::integer <> 0;
end $$;

create or replace function public.escrow_balance_kz(p_booking_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount_kz), 0)::integer
  from public.ledger_entries
  where booking_id = p_booking_id and account = 'passenger_escrow'
$$;

-- Комиссия шлюза при возврате по вине пассажира. Тарифа до договора нет, поэтому 0.
create or replace function public.gateway_fee_kz(p_amount_kz integer)
returns integer language sql immutable as $$ select 0 $$;

create or replace function public.ledger_payment(pay public.payments)
returns void language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = pay.booking_id;
  perform public.ledger_post(gen_random_uuid(), 'payment:' || pay.id, pay.booking_id, jsonb_build_array(
    jsonb_build_object('account', 'cash_in',          'amount_kz', -pay.amount_kz),
    jsonb_build_object('account', 'passenger_escrow', 'user_id', b.passenger_id, 'amount_kz', pay.amount_kz)
  ));
end $$;

-- Возврат пассажиру из эскроу. refund_ref у платежа остаётся null: сигнал cron'у вызвать payments-refund.
create or replace function public.ledger_refund(b public.bookings, p_refund_kz integer, p_gateway_fee_kz integer default 0)
returns void language plpgsql security definer set search_path = public as $$
declare v_total integer := coalesce(p_refund_kz, 0) + coalesce(p_gateway_fee_kz, 0);
begin
  if v_total <= 0 or v_total > public.escrow_balance_kz(b.id) then
    perform public.raise_boleia('LEDGER_UNBALANCED');
  end if;

  perform public.ledger_post(gen_random_uuid(), 'refund:' || b.id, b.id, jsonb_build_array(
    jsonb_build_object('account', 'passenger_escrow', 'user_id', b.passenger_id, 'amount_kz', -v_total),
    jsonb_build_object('account', 'refunds',          'user_id', b.passenger_id, 'amount_kz', p_refund_kz),
    jsonb_build_object('account', 'gateway_fees',     'amount_kz', p_gateway_fee_kz)
  ));

  update public.payments set refund_kz = refund_kz + p_refund_kz
  where id = (
    select id from public.payments
    where booking_id = b.id and status = 'paid'
    order by paid_at desc nulls last limit 1
  );
  update public.bookings set refund_kz = refund_kz + p_refund_kz where id = b.id;
end $$;

-- Выплата из эскроу водителю и платформе пропорционально price_total_kz : fee_kz.
create or replace function public.ledger_release(b public.bookings, p_amount_kz integer)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_paid   integer := b.price_total_kz + b.fee_kz;
  v_driver integer;
  v_driver_id uuid;
begin
  if p_amount_kz <= 0 or p_amount_kz > public.escrow_balance_kz(b.id) then
    perform public.raise_boleia('LEDGER_UNBALANCED');
  end if;
  select driver_id into v_driver_id from public.trips where id = b.trip_id;
  v_driver := (p_amount_kz::bigint * b.price_total_kz / v_paid)::integer;

  perform public.ledger_post(gen_random_uuid(), 'release:' || b.id, b.id, jsonb_build_array(
    jsonb_build_object('account', 'passenger_escrow', 'user_id', b.passenger_id, 'amount_kz', -p_amount_kz),
    jsonb_build_object('account', 'driver_balance',   'user_id', v_driver_id,    'amount_kz', v_driver),
    jsonb_build_object('account', 'platform_fee',     'amount_kz', p_amount_kz - v_driver)
  ));
end $$;

-- Удержанная часть уходит платформе: поездка не состоялась.
create or replace function public.ledger_forfeit(b public.bookings, p_amount_kz integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_amount_kz <= 0 or p_amount_kz > public.escrow_balance_kz(b.id) then
    perform public.raise_boleia('LEDGER_UNBALANCED');
  end if;
  perform public.ledger_post(gen_random_uuid(), 'forfeit:' || b.id, b.id, jsonb_build_array(
    jsonb_build_object('account', 'passenger_escrow', 'user_id', b.passenger_id, 'amount_kz', -p_amount_kz),
    jsonb_build_object('account', 'platform_fee',     'amount_kz', p_amount_kz)
  ));
end $$;

-- ---------------------------------------------------------------------------
-- Уведомления, чат, мелочи
-- ---------------------------------------------------------------------------

-- inapp всегда; доставка push при живом токене, иначе sms, если событие это допускает (ТЗ раздел 9).
create or replace function public.notify(p_user_id uuid, p_type text, p_payload jsonb default '{}', p_allow_sms boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, channel, payload) values (p_user_id, p_type, 'inapp', p_payload);
  if exists (select 1 from public.devices where user_id = p_user_id) then
    insert into public.notifications (user_id, type, channel, payload) values (p_user_id, p_type, 'push', p_payload);
  elsif p_allow_sms then
    insert into public.notifications (user_id, type, channel, payload) values (p_user_id, p_type, 'sms', p_payload);
  end if;
end $$;

create or replace function public.ensure_conversation(p_trip_id uuid, p_passenger_id uuid, p_booking_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.conversations (trip_id, passenger_id, driver_id, booking_id)
  select t.id, p_passenger_id, t.driver_id, p_booking_id from public.trips t where t.id = p_trip_id
  on conflict (trip_id, passenger_id) do update
    set booking_id = coalesce(public.conversations.booking_id, excluded.booking_id)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.system_message(p_conversation_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.messages (conversation_id, sender_id, body) values (p_conversation_id, null, p_body);
  update public.conversations set last_message_at = now() where id = p_conversation_id;
end $$;

create or replace function public.gen_pin()
returns char(4) language sql volatile as $$
  select lpad(floor(random() * 10000)::integer::text, 4, '0')::char(4)
$$;

-- Сравнение по последним 9 цифрам: шлюз может прислать номер с +244, с 244 или без кода.
create or replace function public.same_phone(a text, b text)
returns boolean language sql immutable as $$
  select a is not null and b is not null
     and length(regexp_replace(a, '\D', '', 'g')) >= 9
     and length(regexp_replace(b, '\D', '', 'g')) >= 9
     and right(regexp_replace(a, '\D', '', 'g'), 9) = right(regexp_replace(b, '\D', '', 'g'), 9)
$$;

-- Таблица возвратов раздела 5. Возвращает {refund_kz, gateway_fee_kz, held_kz, rule, counter}.
create or replace function public.refund_rule(b public.bookings, t public.trips, p_by party)
returns jsonb language plpgsql stable as $$
declare
  v_paid   integer := b.price_total_kz + b.fee_kz;
  v_fee    integer := 0;
  v_refund integer;
  v_rule   text;
  v_counter boolean := true;
begin
  if p_by = 'driver' then
    v_refund := v_paid; v_rule := 'driver_cancel';
  elsif t.driver_confirmed_at is null and now() >= t.departure_at - interval '6 hours' then
    v_refund := v_paid; v_rule := 'driver_unconfirmed'; v_counter := false;
  elsif b.status = 'requested' then
    v_fee := public.gateway_fee_kz(v_paid); v_refund := v_paid - v_fee; v_rule := 'passenger_withdraw';
  elsif now() < t.departure_at - interval '24 hours' then
    v_fee := public.gateway_fee_kz(v_paid); v_refund := v_paid - v_fee; v_rule := 'passenger_early';
  else
    v_refund := (v_paid + 1) / 2; v_rule := 'passenger_late';
  end if;

  return jsonb_build_object(
    'refund_kz', v_refund, 'gateway_fee_kz', v_fee,
    'held_kz', v_paid - v_refund - v_fee, 'rule', v_rule, 'counter', v_counter
  );
end $$;

-- ---------------------------------------------------------------------------
-- request_booking - пассажир (ТЗ раздел 6)
-- ---------------------------------------------------------------------------
create or replace function public.request_booking(trip_id uuid, seats integer, message text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_trip_id    uuid := trip_id;
  v_seats      integer := seats;
  v_msg        text := nullif(btrim(message), '');
  t            public.trips;
  v_total      integer;
  v_fee        integer;
  v_booking_id uuid;
  v_payment_id uuid;
  v_expires    timestamptz := now() + interval '15 minutes';
begin
  if p.status = 'restricted' then perform public.raise_boleia('PROFILE_RESTRICTED'); end if;

  select * into t from public.trips where id = v_trip_id for update;
  if t.id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
  if t.status = 'full' then perform public.raise_boleia('TRIP_FULL'); end if;
  if t.status <> 'published' or t.departure_at <= now() + interval '1 hour' then
    perform public.raise_boleia('TRIP_NOT_BOOKABLE');
  end if;
  if v_seats is null or v_seats not between 1 and 3 then perform public.raise_boleia('SEATS_INVALID'); end if;
  if v_msg is not null and char_length(v_msg) > 300 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;

  if exists (
    select 1 from public.bookings
    where bookings.trip_id = v_trip_id and passenger_id = p.id
      and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm')
  ) then perform public.raise_boleia('BOOKING_DUPLICATE'); end if;

  if (select count(*) from public.bookings
      where passenger_id = p.id and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm')) >= 3 then
    perform public.raise_boleia('BOOKING_LIMIT_REACHED');
  end if;

  if v_seats > t.seats_available then perform public.raise_boleia('TRIP_FULL'); end if;

  v_total := v_seats * t.price_per_seat_kz;
  v_fee   := public.calc_fee_kz(v_total);

  insert into public.bookings (trip_id, passenger_id, seats, price_total_kz, fee_kz, message)
  values (t.id, p.id, v_seats, v_total, v_fee, v_msg)
  returning id into v_booking_id;

  insert into public.payments (booking_id, payer_id, amount_kz, expires_at)
  values (v_booking_id, p.id, v_total + v_fee, v_expires)
  returning id into v_payment_id;

  perform public.notify(p.id, 'payment_pending',
    jsonb_build_object('booking_id', v_booking_id, 'payment_id', v_payment_id,
                       'amount_kz', v_total + v_fee, 'expires_at', v_expires), false);
  perform public.log_event('booking_requested', jsonb_build_object('trip_id', t.id, 'seats', v_seats, 'amount_kz', v_total + v_fee));

  return jsonb_build_object(
    'booking_id', v_booking_id, 'payment_id', v_payment_id,
    'amount_kz', v_total + v_fee, 'price_total_kz', v_total, 'fee_kz', v_fee, 'expires_at', v_expires
  );
end $$;

-- ---------------------------------------------------------------------------
-- retry_payment - пассажир, из payment_failed, не больше 3 попыток
-- ---------------------------------------------------------------------------
create or replace function public.retry_payment(booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
  v_payment_id uuid;
  v_expires    timestamptz := now() + interval '15 minutes';
begin
  if p.status = 'restricted' then perform public.raise_boleia('PROFILE_RESTRICTED'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  if b.passenger_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;

  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if b.status = 'pending_payment' then perform public.raise_boleia('PAYMENT_PENDING'); end if;
  if b.status <> 'payment_failed' then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if (select count(*) from public.payments where payments.booking_id = b.id) >= 3 then
    perform public.raise_boleia('PAYMENT_RETRY_LIMIT');
  end if;

  if t.status = 'full' then perform public.raise_boleia('TRIP_FULL'); end if;
  if t.status <> 'published' or t.departure_at <= now() + interval '1 hour' then
    perform public.raise_boleia('TRIP_NOT_BOOKABLE');
  end if;
  if b.seats > t.seats_available then perform public.raise_boleia('TRIP_FULL'); end if;

  update public.bookings set status = 'pending_payment' where id = b.id;

  insert into public.payments (booking_id, payer_id, amount_kz, expires_at)
  values (b.id, p.id, b.price_total_kz + b.fee_kz, v_expires)
  returning id into v_payment_id;

  perform public.notify(p.id, 'payment_pending',
    jsonb_build_object('booking_id', b.id, 'payment_id', v_payment_id,
                       'amount_kz', b.price_total_kz + b.fee_kz, 'expires_at', v_expires), false);
  perform public.log_event('payment_retry', jsonb_build_object('booking_id', b.id));

  return jsonb_build_object(
    'booking_id', b.id, 'payment_id', v_payment_id,
    'amount_kz', b.price_total_kz + b.fee_kz, 'price_total_kz', b.price_total_kz, 'fee_kz', b.fee_kz, 'expires_at', v_expires
  );
end $$;

-- ---------------------------------------------------------------------------
-- confirm_payment - только service_role (Edge payments-webhook / payments-status)
-- ---------------------------------------------------------------------------
create or replace function public.confirm_payment(
  payment_id uuid, provider_ref text, new_status text, payer_phone text, raw jsonb default '{}'
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_payment_id uuid := payment_id;
  v_ref        text := nullif(btrim(provider_ref), '');
  pay          public.payments;
  b            public.bookings;
  t            public.trips;
  passenger    public.profiles;
  v_conv       uuid;
  v_mismatches integer;
begin
  if new_status not in ('paid', 'failed', 'expired') then perform public.raise_boleia('PAYMENT_STATUS_INVALID'); end if;

  select * into pay from public.payments where id = v_payment_id;
  if pay.id is null then perform public.raise_boleia('PAYMENT_NOT_FOUND'); end if;

  select * into b from public.bookings where id = pay.booking_id;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = b.id for update;
  select * into pay from public.payments where id = v_payment_id for update;

  -- вебхук пришёл повторно
  if pay.status not in ('created', 'pending') then return; end if;
  if pay.provider_ref is not null and v_ref is not null and pay.provider_ref <> v_ref then
    perform public.raise_boleia('PAYMENT_REF_MISMATCH');
  end if;

  update public.payments
  set provider_ref = coalesce(pay.provider_ref, v_ref), raw_webhook = coalesce(raw, '{}')
  where id = pay.id;

  if new_status in ('failed', 'expired') then
    update public.payments set status = new_status::payment_status where id = pay.id;
    if b.status = 'pending_payment' then
      update public.bookings set status = 'payment_failed' where id = b.id;
      perform public.notify(b.passenger_id, 'payment_failed',
        jsonb_build_object('booking_id', b.id, 'reason', new_status), true);
    end if;
    return;
  end if;

  -- paid: деньги пришли в любом случае
  update public.payments set status = 'paid', paid_at = now() where id = pay.id returning * into pay;
  perform public.ledger_payment(pay);
  insert into public.events (user_id, name, props)
  values (b.passenger_id, 'payment_paid', jsonb_build_object('booking_id', b.id, 'amount_kz', pay.amount_kz));

  select * into passenger from public.profiles where id = b.passenger_id;

  if not public.same_phone(payer_phone, passenger.phone) then
    perform public.ledger_refund(b, pay.amount_kz, 0);
    if b.status = 'pending_payment' then
      update public.bookings set status = 'payment_failed', cancel_reason = 'PAYMENT_PHONE_MISMATCH' where id = b.id;
    end if;
    insert into public.events (user_id, name, props)
    values (b.passenger_id, 'payment_phone_mismatch', jsonb_build_object('booking_id', b.id, 'payment_id', pay.id));

    -- ТЗ раздел 8: три несовпадения -> restricted
    select count(*) into v_mismatches from public.events
    where user_id = b.passenger_id and name = 'payment_phone_mismatch';
    if v_mismatches >= 3 then
      update public.profiles set status = 'restricted' where id = b.passenger_id and status = 'active';
    end if;

    perform public.notify(b.passenger_id, 'payment_failed',
      jsonb_build_object('booking_id', b.id, 'reason', 'PAYMENT_PHONE_MISMATCH', 'refund_kz', pay.amount_kz), true);
    return;
  end if;

  -- оплата опоздала: бронь уже протухла или поездка закрыта
  if b.status <> 'pending_payment' then
    perform public.ledger_refund(b, pay.amount_kz, 0);
    perform public.notify(b.passenger_id, 'refund_done',
      jsonb_build_object('booking_id', b.id, 'reason', 'late_payment', 'refund_kz', pay.amount_kz), true);
    return;
  end if;

  v_conv := public.ensure_conversation(t.id, b.passenger_id, b.id);

  if t.booking_mode = 'instant' then
    update public.bookings
    set status = 'accepted', pin_code = public.gen_pin(), requested_at = now(), responded_at = now()
    where id = b.id;
    perform public.system_message(v_conv, 'Lugar confirmado. O PIN e o telefone chegam 2 h antes da partida.');
    perform public.notify(b.passenger_id, 'booking_accepted', jsonb_build_object('booking_id', b.id, 'trip_id', t.id), true);
    perform public.notify(t.driver_id, 'booking_confirmed',
      jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'seats', b.seats, 'passenger_name', passenger.display_name), true);
  else
    update public.bookings set status = 'requested', requested_at = now() where id = b.id;
    perform public.system_message(v_conv, 'Pedido pago. O condutor responde em 24 h.');
    perform public.notify(t.driver_id, 'booking_requested',
      jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'seats', b.seats, 'passenger_name', passenger.display_name), true);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- respond_booking - водитель, approval-поездки
-- ---------------------------------------------------------------------------
create or replace function public.respond_booking(booking_id uuid, accept boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
  v_conv       uuid;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;

  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if t.driver_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status <> 'requested' or now() >= t.departure_at - interval '1 hour' then
    perform public.raise_boleia('BOOKING_CLOSED');
  end if;

  v_conv := public.ensure_conversation(t.id, b.passenger_id, b.id);

  if accept then
    update public.bookings set status = 'accepted', pin_code = public.gen_pin(), responded_at = now() where id = b.id;
    perform public.system_message(v_conv, 'Lugar confirmado. O PIN e o telefone chegam 2 h antes da partida.');
    perform public.notify(b.passenger_id, 'booking_accepted', jsonb_build_object('booking_id', b.id, 'trip_id', t.id), true);
  else
    update public.bookings set status = 'declined', responded_at = now(), cancel_reason = nullif(btrim(reason), '') where id = b.id;
    perform public.ledger_refund(b, b.price_total_kz + b.fee_kz, 0);
    perform public.system_message(v_conv, 'O condutor não aceitou o pedido. O reembolso chega em 1 a 3 dias úteis.');
    perform public.notify(b.passenger_id, 'booking_declined',
      jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'refund_kz', b.price_total_kz + b.fee_kz), true);
  end if;
  perform public.log_event('booking_responded', jsonb_build_object('booking_id', b.id, 'accept', accept));
end $$;

-- ---------------------------------------------------------------------------
-- cancel_quote / cancel_booking - пассажир или водитель
-- ---------------------------------------------------------------------------
create or replace function public.cancel_quote(booking_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  b            public.bookings;
  t            public.trips;
  v_by         party;
begin
  select * into b from public.bookings where id = cancel_quote.booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id;

  v_by := case when b.passenger_id = p.id then 'passenger'::party
               when t.driver_id = p.id then 'driver'::party end;
  if v_by is null then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status = 'pending_payment' then perform public.raise_boleia('PAYMENT_PENDING'); end if;
  if b.status not in ('requested', 'accepted') then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if t.status not in ('published', 'full') then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;

  return public.refund_rule(b, t, v_by);
end $$;

create or replace function public.cancel_booking(booking_id uuid, reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  v_reason     text := nullif(btrim(reason), '');
  b            public.bookings;
  t            public.trips;
  v_by         party;
  v_rule       jsonb;
  v_conv       uuid;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;

  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  v_by := case when b.passenger_id = p.id then 'passenger'::party
               when t.driver_id = p.id then 'driver'::party end;
  if v_by is null then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status = 'pending_payment' then perform public.raise_boleia('PAYMENT_PENDING'); end if;
  if b.status not in ('requested', 'accepted') then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if t.status not in ('published', 'full') then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;

  -- водитель на неотвеченный запрос: это отказ, без санкции
  if v_by = 'driver' and b.status = 'requested' then
    perform public.respond_booking(b.id, false, v_reason);
    return jsonb_build_object('status', 'declined', 'refund_kz', b.price_total_kz + b.fee_kz, 'held_kz', 0, 'rule', 'driver_decline');
  end if;

  v_rule := public.refund_rule(b, t, v_by);

  update public.bookings
  set status = 'cancelled', cancelled_at = now(), cancelled_by = v_by, cancel_reason = v_reason
  where id = b.id;

  perform public.ledger_refund(b, (v_rule ->> 'refund_kz')::integer, (v_rule ->> 'gateway_fee_kz')::integer);

  if (v_rule ->> 'counter')::boolean then
    update public.profiles set cancels_total = cancels_total + 1
    where id = case when v_by = 'passenger' then b.passenger_id else t.driver_id end;
  end if;

  v_conv := public.ensure_conversation(t.id, b.passenger_id, b.id);
  if v_by = 'passenger' then
    perform public.system_message(v_conv, 'Reserva cancelada pelo passageiro.');
    perform public.notify(t.driver_id, 'booking_cancelled_by_passenger',
      jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'seats', b.seats), false);
  else
    perform public.system_message(v_conv, 'Reserva cancelada pelo condutor. O reembolso total chega em 1 a 3 dias úteis.');
    perform public.notify(b.passenger_id, 'booking_cancelled_by_driver',
      jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'refund_kz', (v_rule ->> 'refund_kz')::integer), true);
  end if;

  perform public.log_event('booking_cancelled', jsonb_build_object('booking_id', b.id, 'by', v_by, 'rule', v_rule ->> 'rule'));

  return jsonb_build_object(
    'status', 'cancelled',
    'refund_kz', (v_rule ->> 'refund_kz')::integer,
    'held_kz', (v_rule ->> 'held_kz')::integer,
    'rule', v_rule ->> 'rule'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------
-- Новые функции получают execute для public по умолчанию: внутренним отзываем явно.
revoke all on function
  public.ledger_post(uuid, text, uuid, jsonb),
  public.escrow_balance_kz(uuid),
  public.gateway_fee_kz(integer),
  public.ledger_payment(public.payments),
  public.ledger_refund(public.bookings, integer, integer),
  public.ledger_release(public.bookings, integer),
  public.ledger_forfeit(public.bookings, integer),
  public.notify(uuid, text, jsonb, boolean),
  public.ensure_conversation(uuid, uuid, uuid),
  public.system_message(uuid, text),
  public.gen_pin(),
  public.same_phone(text, text),
  public.refund_rule(public.bookings, public.trips, party),
  public.cancel_quote(uuid)
from public, anon, authenticated;

grant execute on function public.cancel_quote(uuid) to authenticated;
