-- Boleia - поездку начинает и завершает водитель (ТЗ разделы 4, 5, 6, 9, 10)
--
-- Как в такси: водитель вводит PIN, начинает и завершает поездку; пассажир после завершения оценивает
-- или оспаривает. Старт один раз фиксирует, кто сел. Деньги уходят после оценки пассажира или 24 ч
-- тишины, а не в момент нажатия водителя. План и решения: docs/plans/0025_trip_start_finish.md

-- ---------------------------------------------------------------------------
-- 1. Колонки
-- ---------------------------------------------------------------------------
alter table public.trips
  add column started_at        timestamptz,
  add column finished_at       timestamptz,
  add column start_reminded_at timestamptz,
  -- поездку закрыла страховка cron, а не водитель
  add column closed_by_system  boolean not null default false;

alter table public.bookings
  add column not_boarded_at  timestamptz,
  add column dispute_reason  text,
  add column dispute_details text;

-- dispute_details, как и pin_code, читается только через my_bookings (0021)
grant select (not_boarded_at, dispute_reason) on public.bookings to anon, authenticated;

-- Срок на возражение пассажира после завершения поездки и после "поездка началась без вас"
create function public.response_window()
returns interval language sql immutable as $$ select interval '24 hours' $$;

-- ---------------------------------------------------------------------------
-- 2. Выезд одной поездки: общее для cron (по времени) и для раннего старта водителем
-- ---------------------------------------------------------------------------
create function public.depart_trip(p_trip_id uuid, p_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; v_amount integer;
begin
  select * into t from public.trips where id = p_trip_id for update;
  if t.status not in ('published', 'full') then return; end if;

  for b in select * from public.bookings where trip_id = t.id and status = 'pending_payment' for update loop
    update public.bookings set status = 'payment_failed', cancel_reason = 'trip_departed' where id = b.id;
    update public.payments set status = 'expired' where booking_id = b.id and status in ('created', 'pending');
    perform public.notify(b.passenger_id, 'payment_failed', jsonb_build_object('booking_id', b.id, 'reason', 'trip_departed'), true);
  end loop;

  -- неотвеченный запрос не должен пережить выезд: после старта его уже нельзя принять
  for b in select * from public.bookings where trip_id = t.id and status = 'requested' for update loop
    v_amount := public.escrow_balance_kz(b.id);
    update public.bookings set status = 'expired', responded_at = p_at, cancel_reason = 'no_response' where id = b.id;
    if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
    perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
      'O condutor não respondeu a tempo. O reembolso total chega em 1 a 3 dias úteis.');
    perform public.notify(b.passenger_id, 'booking_expired', jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'refund_kz', v_amount), true);
  end loop;

  if exists (select 1 from public.bookings where trip_id = t.id and status = 'accepted') then
    update public.trips set status = 'departed', departed_at = p_at where id = t.id;
    update public.bookings set status = 'awaiting_confirm' where trip_id = t.id and status = 'accepted';
  else
    update public.trips set status = 'expired' where id = t.id;
    perform public.forfeit_trip_holds(t.id);
  end if;
end $$;

create or replace function public.sch_depart_trips(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id from public.trips where status in ('published', 'full') and departure_at <= as_of loop
    perform public.depart_trip(r.id, as_of);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 3. PIN: до завершения поездки; опоздавший, которого посадили после старта, перестаёт быть "не сел"
-- ---------------------------------------------------------------------------
create or replace function public.enter_pin(booking_id uuid, pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  v_pin        text := btrim(pin);
  b            public.bookings;
  t            public.trips;
  v_failed     integer;
begin
  if v_pin !~ '^\d{4}$' then perform public.raise_boleia('PIN_INVALID'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if t.driver_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status not in ('accepted', 'awaiting_confirm') then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if now() < t.departure_at - interval '3 hours' or t.finished_at is not null then
    perform public.raise_boleia('PIN_WINDOW_CLOSED');
  end if;
  if b.pin_entered_at is not null then
    return jsonb_build_object('ok', true, 'pin_entered_at', b.pin_entered_at, 'already', true);
  end if;
  if public.pin_attempts_blocked(p.id) then perform public.raise_boleia('RATE_LIMITED'); end if;

  if b.pin_code is null or b.pin_code <> v_pin then
    insert into public.events (user_id, name, props) values (p.id, 'pin_failed', jsonb_build_object('booking_id', b.id));
    select count(*) into v_failed from public.events
    where user_id = p.id and name = 'pin_failed' and created_at > now() - interval '10 minutes';
    return jsonb_build_object('ok', false, 'attempts_left', greatest(5 - v_failed, 0));
  end if;

  update public.bookings set pin_entered_at = now(), not_boarded_at = null where id = b.id;
  perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id), 'Passageiro a bordo. PIN confirmado.');
  perform public.log_event('pin_entered', jsonb_build_object('booking_id', b.id, 'late', b.not_boarded_at is not null));
  return jsonb_build_object('ok', true, 'pin_entered_at', now());
end $$;

-- ---------------------------------------------------------------------------
-- 4. Старт и завершение: ядро общее для водителя и для страховки cron
-- ---------------------------------------------------------------------------
create function public.start_trip_core(p_trip_id uuid, p_at timestamptz, p_by_system boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; v_on_board integer := 0; v_not_boarded integer := 0;
begin
  perform public.depart_trip(p_trip_id, p_at);
  select * into t from public.trips where id = p_trip_id for update;

  for b in select * from public.bookings where trip_id = t.id and status = 'awaiting_confirm' for update loop
    if b.pin_entered_at is null then
      update public.bookings set not_boarded_at = p_at where id = b.id;
      perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
        'A viagem começou sem o passageiro. O passageiro tem 24 horas para contestar.');
      perform public.notify(b.passenger_id, 'trip_started_without_you', jsonb_build_object(
        'booking_id', b.id, 'trip_id', t.id, 'respond_until', p_at + public.response_window()), true);
      v_not_boarded := v_not_boarded + 1;
    else
      perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id), 'Viagem iniciada.');
      v_on_board := v_on_board + 1;
    end if;
  end loop;

  -- без пассажиров на борту завершать нечего
  update public.trips
  set started_at = p_at,
      finished_at = case when v_on_board = 0 then p_at else finished_at end,
      closed_by_system = closed_by_system or p_by_system
  where id = t.id;

  insert into public.events (user_id, name, props)
  values (t.driver_id, 'trip_started', jsonb_build_object('trip_id', t.id, 'on_board', v_on_board, 'not_boarded', v_not_boarded, 'by_system', p_by_system));
  return jsonb_build_object('started_at', p_at, 'on_board', v_on_board, 'not_boarded', v_not_boarded);
end $$;

create function public.finish_trip_core(p_trip_id uuid, p_at timestamptz, p_by_system boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; v_asked integer := 0;
begin
  select * into t from public.trips where id = p_trip_id for update;
  update public.trips set finished_at = p_at, closed_by_system = closed_by_system or p_by_system where id = t.id;

  for b in select * from public.bookings where trip_id = t.id and status = 'awaiting_confirm' and pin_entered_at is not null loop
    perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
      case when p_by_system then 'A viagem foi dada como concluída. O passageiro pode avaliar ou contestar em 24 horas.'
           else 'Viagem concluída pelo condutor. O passageiro pode avaliar ou contestar em 24 horas.' end);
    perform public.notify(b.passenger_id, 'trip_finished', jsonb_build_object(
      'booking_id', b.id, 'trip_id', t.id, 'respond_until', p_at + public.response_window(), 'by_system', p_by_system), true);
    v_asked := v_asked + 1;
  end loop;

  insert into public.events (user_id, name, props)
  values (t.driver_id, 'trip_finished', jsonb_build_object('trip_id', t.id, 'asked', v_asked, 'by_system', p_by_system));
  return jsonb_build_object('finished_at', p_at, 'asked', v_asked);
end $$;

create function public.start_trip(trip_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t       public.trips := public.trip_for_driver(trip_id);
  v_until timestamptz;
begin
  if t.status not in ('published', 'full', 'departed') then perform public.raise_boleia('TRIP_CLOSED'); end if;
  if t.started_at is not null then
    return jsonb_build_object('started_at', t.started_at, 'already', true);
  end if;
  if not exists (select 1 from public.bookings where bookings.trip_id = t.id and status in ('accepted', 'awaiting_confirm')) then
    perform public.raise_boleia('TRIP_NO_PASSENGERS');
  end if;
  if now() < t.departure_at - interval '3 hours' then perform public.raise_boleia('START_TOO_EARLY'); end if;

  -- контракт ожидания: пока есть брони без PIN, водитель ждёт wait_minutes после departure_at
  v_until := t.departure_at + make_interval(mins => t.wait_minutes);
  if now() < v_until and exists (
    select 1 from public.bookings where bookings.trip_id = t.id and status in ('accepted', 'awaiting_confirm') and pin_entered_at is null
  ) then
    perform public.raise_boleia('START_TOO_EARLY');
  end if;

  return public.start_trip_core(t.id, now(), false);
end $$;

create function public.finish_trip(trip_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.trips := public.trip_for_driver(trip_id);
begin
  if t.started_at is null then perform public.raise_boleia('TRIP_NOT_STARTED'); end if;
  if t.finished_at is not null then
    return jsonb_build_object('finished_at', t.finished_at, 'already', true);
  end if;
  return public.finish_trip_core(t.id, now(), false);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Пассажир: одобрение после завершения и спор с причиной
-- ---------------------------------------------------------------------------
create or replace function public.confirm_trip(booking_id uuid, happened boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
begin
  -- спор без причины больше не открывается: open_dispute(booking_id, reason, details)
  if not coalesce(happened, false) then perform public.raise_boleia('DISPUTE_REASON_REQUIRED'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if b.passenger_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status <> 'awaiting_confirm' then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if b.pin_entered_at is null or t.finished_at is null then perform public.raise_boleia('TRIP_NOT_FINISHED'); end if;

  perform public.complete_booking(b, 'passenger');
  perform public.log_event('trip_confirmed', jsonb_build_object('booking_id', b.id));
end $$;

create function public.open_dispute(booking_id uuid, reason text, details text)
returns void language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  v_reason     text := btrim(coalesce(reason, ''));
  v_details    text := btrim(coalesce(details, ''));
  b            public.bookings;
  t            public.trips;
  v_boarded    boolean;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;

  if b.passenger_id <> p.id then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status <> 'awaiting_confirm' then perform public.raise_boleia('BOOKING_CLOSED'); end if;

  v_boarded := b.pin_entered_at is not null;
  -- спор открыт после завершения поездки или после "поездка началась без вас"; в пути - report_user
  if not ((v_boarded and t.finished_at is not null) or (not v_boarded and b.not_boarded_at is not null)) then
    perform public.raise_boleia('TRIP_NOT_FINISHED');
  end if;

  if (v_boarded and v_reason not in ('not_arrived', 'left_midway', 'unsafe', 'other'))
     or (not v_boarded and v_reason not in ('was_there', 'driver_left_early', 'other')) then
    perform public.raise_boleia('DISPUTE_REASON_INVALID');
  end if;
  if char_length(v_details) not between 5 and 500 then perform public.raise_boleia('DISPUTE_DETAILS_REQUIRED'); end if;

  update public.bookings
  set status = 'disputed', passenger_confirmed_at = now(), dispute_reason = v_reason, dispute_details = v_details
  where id = b.id;
  perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
    'O passageiro contestou a viagem. A moderação vai analisar.');
  perform public.notify(t.driver_id, 'dispute_opened',
    jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'by', 'passenger', 'reason', v_reason), true);
  perform public.log_event('dispute_opened', jsonb_build_object('booking_id', b.id, 'by', 'passenger', 'reason', v_reason));
end $$;

-- Неявка: бронь без PIN, пассажир не возразил за 24 ч или модератор встал на сторону водителя
create function public.close_no_show(b public.bookings)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips; v_amount integer := public.escrow_balance_kz(b.id);
begin
  select * into t from public.trips where id = b.trip_id;
  update public.bookings set status = 'no_show', driver_confirmed_at = now(), completed_at = now() where id = b.id;
  if v_amount > 0 then
    perform public.ledger_release(b, v_amount);
    perform public.notify(t.driver_id, 'payout_released',
      jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'amount_kz', public.driver_share_kz(b, v_amount), 'reason', 'no_show'), false);
  end if;
  update public.profiles set no_shows = no_shows + 1 where id = b.passenger_id;
  perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
    'O passageiro não embarcou. Reserva fechada sem reembolso.');
  perform public.notify(b.passenger_id, 'booking_no_show', jsonb_build_object('booking_id', b.id, 'trip_id', t.id), true);
  insert into public.events (user_id, name, props) values (t.driver_id, 'no_show', jsonb_build_object('booking_id', b.id));
  perform public.settle_trip(t.id);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Cron: напоминание о старте, страховка через 24 ч, закрытие по сроку на возражение
-- ---------------------------------------------------------------------------
create function public.sch_remind_start(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; n integer := 0;
begin
  for t in
    select tr.* from public.trips tr
    where tr.status = 'departed' and tr.started_at is null and tr.start_reminded_at is null
      and tr.departure_at + make_interval(mins => tr.wait_minutes) <= as_of
      and exists (select 1 from public.bookings where trip_id = tr.id and status = 'awaiting_confirm')
  loop
    perform public.notify(t.driver_id, 'trip_start_reminder', jsonb_build_object('trip_id', t.id, 'departure_at', t.departure_at), false);
    update public.trips set start_reminded_at = as_of where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Ни PIN, ни старта за 24 ч: поездки не было, деньги возвращаются всем
create function public.cancel_unstarted_trip(p_trip_id uuid, p_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; v_amount integer;
begin
  select * into t from public.trips where id = p_trip_id for update;
  if t.status <> 'departed' or t.started_at is not null then return; end if;

  for b in select * from public.bookings where trip_id = t.id and status = 'awaiting_confirm' for update loop
    v_amount := public.escrow_balance_kz(b.id);
    update public.bookings set status = 'cancelled', cancelled_at = p_at, cancelled_by = 'driver', cancel_reason = 'trip_not_started' where id = b.id;
    if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
    perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
      'A viagem não se realizou. Reembolso total em 1 a 3 dias úteis.');
    perform public.notify(b.passenger_id, 'trip_cancelled',
      jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'reason', 'trip_not_started', 'refund_kz', v_amount), true);
  end loop;

  update public.trips set status = 'cancelled', cancelled_at = p_at, cancel_reason = 'trip_not_started', closed_by_system = true where id = t.id;
  perform public.forfeit_trip_holds(t.id);
  -- жалоба пассажира "не приехал" по этой поездке добавляет водителю неявку
  update public.profiles
  set cancels_total = cancels_total + 1,
      no_shows = no_shows + case when exists (
        select 1 from public.reports r where r.trip_id = t.id and r.target_user_id = t.driver_id and r.reason = 'no_show'
      ) then 1 else 0 end
  where id = t.driver_id;
  perform public.notify(t.driver_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'reason', 'trip_not_started'), true);
end $$;

create function public.sch_auto_close(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  -- старта нет 24 ч после времени выезда
  for r in
    select tr.id, tr.driver_id,
           exists (select 1 from public.bookings where trip_id = tr.id and status = 'awaiting_confirm' and pin_entered_at is not null) as has_pin
    from public.trips tr
    where tr.status = 'departed' and tr.started_at is null and tr.departure_at + interval '24 hours' <= as_of
  loop
    if r.has_pin then
      perform public.start_trip_core(r.id, as_of, true);
      if (select finished_at is null from public.trips where id = r.id) then
        perform public.finish_trip_core(r.id, as_of, true);
      end if;
      perform public.notify(r.driver_id, 'trip_auto_closed', jsonb_build_object('trip_id', r.id, 'step', 'start'), false);
    else
      perform public.cancel_unstarted_trip(r.id, as_of);
    end if;
    n := n + 1;
  end loop;

  -- старт есть, завершения нет 24 ч
  for r in
    select tr.id, tr.driver_id from public.trips tr
    where tr.status = 'departed' and tr.started_at is not null and tr.finished_at is null
      and tr.started_at + interval '24 hours' <= as_of
  loop
    perform public.finish_trip_core(r.id, as_of, true);
    perform public.notify(r.driver_id, 'trip_auto_closed', jsonb_build_object('trip_id', r.id, 'step', 'finish'), false);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.sch_autocomplete(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; b public.bookings; n integer := 0;
begin
  for r in
    select bk.id, bk.trip_id from public.bookings bk join public.trips tr on tr.id = bk.trip_id
    where bk.status = 'awaiting_confirm'
      and ((bk.pin_entered_at is not null and tr.finished_at + public.response_window() <= as_of)
        or (bk.pin_entered_at is null and bk.not_boarded_at + public.response_window() <= as_of))
  loop
    perform 1 from public.trips where id = r.trip_id for update;
    select * into b from public.bookings where id = r.id for update;
    if b.status <> 'awaiting_confirm' then continue; end if;
    if b.pin_entered_at is not null then
      perform public.complete_booking(b, 'system');
    else
      perform public.close_no_show(b);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.run_scheduler(as_of timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb := '{}';
begin
  r := r || public.scheduler_step('expire_payments',     as_of);
  r := r || public.scheduler_step('expire_requests',     as_of);
  r := r || public.scheduler_step('depart_trips',        as_of);
  r := r || public.scheduler_step('remind_24h',          as_of);
  r := r || public.scheduler_step('remind_6h',           as_of);
  r := r || public.scheduler_step('send_pins',           as_of);
  r := r || public.scheduler_step('remind_start',        as_of);
  r := r || public.scheduler_step('auto_close',          as_of);
  r := r || public.scheduler_step('autocomplete',        as_of);
  r := r || public.scheduler_step('lift_suspensions',    as_of);
  r := r || public.scheduler_step('close_chats',         as_of);
  r := r || public.scheduler_step('review_visibility',   as_of);
  r := r || public.scheduler_step('refresh_route_stats', as_of, interval '1 hour');
  r := r || public.scheduler_step('cleanup',             as_of, interval '1 day');
  r := r || public.scheduler_step('reconcile',           as_of, interval '1 day');
  return r;
end $$;

delete from public.scheduler_jobs where name in ('ask_completed', 'driver_no_show');

-- ---------------------------------------------------------------------------
-- 7. Удалено: отметка "Cheguei", отдельная отметка неявки, вопрос "Chegou bem?", правило "водитель не приехал"
-- ---------------------------------------------------------------------------
drop function public.mark_no_show(uuid);
drop function public.driver_arrived(uuid);
drop function public.sch_ask_completed(timestamptz);
drop function public.sch_driver_no_show(timestamptz);

-- ---------------------------------------------------------------------------
-- 8. Отмена закрыта для брони с введённым PIN: пассажир уже в машине
-- ---------------------------------------------------------------------------
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
  if b.pin_entered_at is not null then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;

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
  if b.pin_entered_at is not null then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;

  return public.refund_rule(b, t, v_by);
end $$;

create or replace function public.cancel_trip(trip_id uuid, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips := public.trip_for_driver(trip_id); r jsonb;
begin
  if t.status not in ('draft', 'published', 'full') then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;
  if exists (select 1 from public.bookings where bookings.trip_id = t.id and status = 'accepted' and pin_entered_at is not null) then
    perform public.raise_boleia('TOO_LATE_TO_CANCEL');
  end if;
  r := public.cancel_trip_cascade(t, 'driver', nullif(btrim(reason), ''));
  perform public.log_event('trip_cancelled', jsonb_build_object('trip_id', t.id, 'paid_bookings', r -> 'cancelled_bookings'));
end $$;

-- ---------------------------------------------------------------------------
-- 9. resolve_dispute: исход no_show для спора "поездка началась без вас"
-- ---------------------------------------------------------------------------
create or replace function public.resolve_dispute(booking_id uuid, outcome text, amount_kz integer default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles;
  v_booking_id uuid := booking_id;
  v_amount     integer := amount_kz;
  b            public.bookings;
  t            public.trips;
  v_escrow     integer;
begin
  if not public.is_admin() then perform public.raise_boleia('NOT_ADMIN'); end if;
  p := public.current_profile();
  if outcome not in ('completed', 'refund_full', 'refund_partial', 'no_show') then perform public.raise_boleia('DISPUTE_OUTCOME_INVALID'); end if;

  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_booking_id for update;
  if b.status <> 'disputed' then perform public.raise_boleia('BOOKING_CLOSED'); end if;

  v_escrow := public.escrow_balance_kz(b.id);

  -- no_show только для спора "поездка началась без вас": у севшего пассажира неявки быть не может
  if outcome = 'no_show' and b.pin_entered_at is not null then perform public.raise_boleia('DISPUTE_OUTCOME_INVALID'); end if;

  if outcome = 'completed' then
    perform public.complete_booking(b, 'driver');

  elsif outcome = 'no_show' then
    perform public.close_no_show(b);

  elsif outcome = 'refund_full' then
    perform public.ledger_refund(b, v_escrow, 0);
    update public.bookings
    set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system', cancel_reason = 'dispute_refund'
    where id = b.id;
    update public.profiles set no_shows = no_shows + 1 where id = t.driver_id;
    perform public.notify(b.passenger_id, 'refund_done', jsonb_build_object('booking_id', b.id, 'refund_kz', v_escrow, 'reason', 'dispute'), true);
    perform public.settle_trip(t.id);

  else
    if v_amount is null or v_amount < 1 or v_amount >= v_escrow then perform public.raise_boleia('DISPUTE_AMOUNT_INVALID'); end if;
    perform public.ledger_refund(b, v_amount, 0);
    perform public.ledger_release(b, v_escrow - v_amount);
    update public.bookings set status = 'completed', completed_at = now(), driver_confirmed_at = now() where id = b.id;
    update public.profiles set trips_ridden = trips_ridden + 1 where id = b.passenger_id;
    perform public.notify(b.passenger_id, 'refund_done', jsonb_build_object('booking_id', b.id, 'refund_kz', v_amount, 'reason', 'dispute'), true);
    perform public.notify(t.driver_id, 'payout_released',
      jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'amount_kz', public.driver_share_kz(b, v_escrow - v_amount), 'reason', 'dispute'), false);
    perform public.settle_trip(t.id);
  end if;

  insert into public.moderation_actions (admin_id, target_user_id, action, reason)
  values (p.id, b.passenger_id, 'resolve_dispute', outcome || coalesce(':' || v_amount, ''));
  perform public.notify(t.driver_id,    'dispute_resolved', jsonb_build_object('booking_id', b.id, 'outcome', outcome), true);
  perform public.notify(b.passenger_id, 'dispute_resolved', jsonb_build_object('booking_id', b.id, 'outcome', outcome), true);
end $$;

-- ---------------------------------------------------------------------------
-- 10. notify: новые срочные типы идут и в тихие часы
-- ---------------------------------------------------------------------------
create or replace function public.notify(p_user_id uuid, p_type text, p_payload jsonb default '{}'::jsonb, p_allow_sms boolean default true, p_scheduled_for timestamp with time zone default null::timestamp with time zone)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_at    timestamptz := coalesce(p_scheduled_for, now());
  v_local timestamp   := v_at at time zone 'Africa/Luanda';
  v_deliver_at timestamptz := p_scheduled_for;
  v_urgent boolean := p_type like 'payment\_%' or p_type like 'booking\_%' or p_type like 'dispute\_%'
                   or p_type in ('trip_cancelled', 'refund_done', 'pin_ready', 'trip_reminder_2h', 'reconciliation_alert',
                                'trip_started_without_you', 'trip_finished');
  v_payload jsonb := public.notification_context(p_user_id, p_payload);
begin
  if not v_urgent and (v_local::time >= '22:00' or v_local::time < '07:00') then
    v_deliver_at := (date_trunc('day', v_local) + case when v_local::time >= '22:00' then interval '1 day' else interval '0' end
                     + interval '7 hours') at time zone 'Africa/Luanda';
  end if;

  insert into public.notifications (user_id, type, channel, payload, scheduled_for, status, sent_at)
  values (p_user_id, p_type, 'inapp', v_payload, p_scheduled_for, 'sent', now());
  if exists (select 1 from public.devices where user_id = p_user_id) then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'push', v_payload, v_deliver_at);
  elsif p_allow_sms then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'sms', v_payload, v_deliver_at);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 11. my_bookings: этап брони и срок на возражение считает база (колонки добавлены в конец)
-- ---------------------------------------------------------------------------
create or replace view public.my_bookings as
select
  b.id,
  b.trip_id,
  b.passenger_id,
  b.seats,
  b.price_total_kz,
  b.fee_kz,
  b.price_total_kz + b.fee_kz as paid_total_kz,
  b.status,
  case when b.status in ('accepted', 'awaiting_confirm')
        and now() >= t.departure_at - interval '2 hours'
        and b.passenger_id = auth.uid()
       then b.pin_code else null end as pin_code,
  b.pin_entered_at,
  b.requested_at,
  b.responded_at,
  b.cancelled_at,
  b.cancelled_by,
  b.refund_kz,
  b.passenger_confirmed_at,
  b.completed_at,
  b.created_at,
  t.departure_at,
  t.status            as trip_status,
  t.booking_mode,
  t.origin_detail,
  t.destination_detail,
  o.name              as origin_name,
  o.slug              as origin_slug,
  d.name              as destination_name,
  d.slug              as destination_slug,
  t.driver_id,
  dp.display_name     as driver_name,
  dp.avatar_url       as driver_avatar_url,
  pay.status          as payment_status,
  pay.expires_at      as payment_expires_at,
  c.id                as conversation_id,
  v.make              as vehicle_make,
  v.model             as vehicle_model,
  v.color             as vehicle_color,
  v.photo_url         as vehicle_photo_url,
  right(v.plate, 3)   as vehicle_plate_suffix,
  b.cancel_reason,
  b.message,
  pp.display_name     as passenger_name,
  pp.avatar_url       as passenger_avatar_url,
  pp.rating_avg       as passenger_rating_avg,
  pp.trips_ridden     as passenger_trips_ridden,
  pp.cancels_total    as passenger_cancels_total,
  t.wait_minutes,
  t.departure_at + make_interval(mins => t.wait_minutes) as wait_until,
  t.driver_arrived_at,
  pp.no_shows         as passenger_no_shows,
  pp.rating_count     as passenger_rating_count,
  t.started_at        as trip_started_at,
  t.finished_at       as trip_finished_at,
  b.not_boarded_at,
  case when b.status = 'awaiting_confirm' and b.pin_entered_at is not null and t.finished_at is not null
         then t.finished_at + public.response_window()
       when b.status = 'awaiting_confirm' and b.pin_entered_at is null and b.not_boarded_at is not null
         then b.not_boarded_at + public.response_window()
  end as respond_until,
  b.dispute_reason,
  case when b.passenger_id = auth.uid() or public.is_admin() then b.dispute_details end as dispute_details,
  case
    when b.status in ('pending_payment', 'payment_failed') then 'payment'
    when b.status not in ('accepted', 'awaiting_confirm') then b.status::text
    when b.pin_entered_at is null and b.not_boarded_at is not null then 'not_boarded'
    when b.pin_entered_at is null and b.status = 'accepted' and now() < t.departure_at - interval '2 hours' then 'accepted'
    when b.pin_entered_at is null then 'boarding'
    when t.started_at is null then 'on_board'
    when t.finished_at is null then 'in_trip'
    else 'finished'
  end as stage
from public.bookings b
join public.trips    t  on t.id = b.trip_id
join public.places   o  on o.id = t.origin_place_id
join public.places   d  on d.id = t.destination_place_id
join public.profiles dp on dp.id = t.driver_id
join public.profiles pp on pp.id = b.passenger_id
join public.vehicles v  on v.id = t.vehicle_id
left join lateral (
  select status, expires_at from public.payments
  where booking_id = b.id order by created_at desc limit 1
) pay on true
left join public.conversations c on c.trip_id = b.trip_id and c.passenger_id = b.passenger_id
where b.passenger_id = auth.uid() or t.driver_id = auth.uid() or public.is_admin();

-- ---------------------------------------------------------------------------
-- 12. Права: по умолчанию новые функции открыты всем, закрываем и выдаём клиентские
-- ---------------------------------------------------------------------------
revoke all on function
  public.response_window(),
  public.depart_trip(uuid, timestamptz),
  public.start_trip_core(uuid, timestamptz, boolean),
  public.finish_trip_core(uuid, timestamptz, boolean),
  public.start_trip(uuid),
  public.finish_trip(uuid),
  public.open_dispute(uuid, text, text),
  public.close_no_show(public.bookings),
  public.sch_remind_start(timestamptz),
  public.cancel_unstarted_trip(uuid, timestamptz),
  public.sch_auto_close(timestamptz)
from public, anon, authenticated;

grant execute on function
  public.start_trip(uuid),
  public.finish_trip(uuid),
  public.open_dispute(uuid, text, text)
to authenticated;

-- my_bookings зовёт её от имени читающего, как is_admin()
grant execute on function public.response_window() to anon, authenticated;
