-- Boleia - scheduler (ТЗ раздел 6, таблица Cron; разделы 5, 9, 10)
--
-- run_scheduler(as_of) каждые 5 минут через pg_cron. Каждый шаг - отдельная функция sch_<name>,
-- запускается через scheduler_step в своём блоке исключений: ошибка одного шага пишется в
-- scheduler_jobs и events, остальные шаги идут дальше. as_of подменяет "сейчас" для тестов;
-- денежные переходы (complete_booking, ledger_refund) используют now().
-- План и решения: docs/plans/0007_scheduler.md

create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Схема: отметки "уже сделано", попытки возврата, журнал задач
-- ---------------------------------------------------------------------------
alter table public.trips
  add column reminded_24h_at  timestamptz,
  add column reminded_6h_at   timestamptz,
  add column completed_ask_at timestamptz;

alter table public.bookings add column pin_sent_at timestamptz;

alter table public.payments
  add column refund_attempts  smallint not null default 0,
  add column refund_failed_at timestamptz;

create table public.scheduler_jobs (
  name        text primary key,
  last_run_at timestamptz,
  last_ok_at  timestamptz,
  last_error  text,
  runs        integer not null default 0
);
alter table public.scheduler_jobs enable row level security;
create policy scheduler_jobs_admin on public.scheduler_jobs for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.scheduler_jobs from anon, authenticated;

-- Очередь возвратов для Edge payments-refund (service role). refund_ref ставит Edge.
create view public.pending_refunds as
select p.id as payment_id, p.booking_id, p.payer_id, pr.phone as payer_phone, p.provider_ref,
       p.amount_kz, p.refund_kz, p.refund_attempts, p.refund_failed_at, p.updated_at
from public.payments p
join public.profiles pr on pr.id = p.payer_id
where p.refund_kz > 0 and p.refund_ref is null and p.refund_attempts < 3;
revoke all on public.pending_refunds from public, anon, authenticated;
grant select on public.pending_refunds to service_role;

-- ---------------------------------------------------------------------------
-- notify: тихие часы 22:00-07:00 Africa/Luanda для несрочных типов (ТЗ раздел 9)
-- ---------------------------------------------------------------------------
create or replace function public.notify(
  p_user_id uuid, p_type text, p_payload jsonb default '{}', p_allow_sms boolean default true,
  p_scheduled_for timestamptz default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_at    timestamptz := coalesce(p_scheduled_for, now());
  v_local timestamp   := v_at at time zone 'Africa/Luanda';
  v_deliver_at timestamptz := p_scheduled_for;
  v_urgent boolean := p_type like 'payment\_%' or p_type like 'booking\_%' or p_type like 'dispute\_%'
                   or p_type in ('trip_cancelled', 'refund_done', 'pin_ready', 'trip_reminder_2h', 'reconciliation_alert');
begin
  if not v_urgent and (v_local::time >= '22:00' or v_local::time < '07:00') then
    v_deliver_at := (date_trunc('day', v_local) + case when v_local::time >= '22:00' then interval '1 day' else interval '0' end
                     + interval '7 hours') at time zone 'Africa/Luanda';
  end if;

  insert into public.notifications (user_id, type, channel, payload, scheduled_for)
  values (p_user_id, p_type, 'inapp', p_payload, p_scheduled_for);
  if exists (select 1 from public.devices where user_id = p_user_id) then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'push', p_payload, v_deliver_at);
  elsif p_allow_sms then
    insert into public.notifications (user_id, type, channel, payload, scheduled_for)
    values (p_user_id, p_type, 'sms', p_payload, v_deliver_at);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Шаги. Каждый возвращает число обработанных строк.
-- ---------------------------------------------------------------------------

-- 1. Протухание платежей: 5 минут запаса, чтобы Edge payments-status успел опросить шлюз
create or replace function public.sch_expire_payments(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; b public.bookings; pay public.payments; n integer := 0;
begin
  for r in
    select pm.id as payment_id, bk.id as booking_id, bk.trip_id
    from public.payments pm join public.bookings bk on bk.id = pm.booking_id
    where pm.status in ('created', 'pending') and pm.expires_at + interval '5 minutes' <= as_of
  loop
    perform 1 from public.trips where id = r.trip_id for update;
    select * into b   from public.bookings where id = r.booking_id for update;
    select * into pay from public.payments where id = r.payment_id for update;
    if pay.status not in ('created', 'pending') then continue; end if;

    update public.payments set status = 'expired' where id = pay.id;
    if b.status = 'pending_payment' then
      update public.bookings set status = 'payment_failed', cancel_reason = 'payment_expired' where id = b.id;
      perform public.notify(b.passenger_id, 'payment_failed', jsonb_build_object('booking_id', b.id, 'reason', 'expired'), true);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 2. Протухание запросов: 24 ч без ответа или departure_at - 1 ч
create or replace function public.sch_expire_requests(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; b public.bookings; t public.trips; v_amount integer; n integer := 0;
begin
  for r in
    select bk.id, bk.trip_id from public.bookings bk join public.trips tr on tr.id = bk.trip_id
    where bk.status = 'requested' and (bk.requested_at + interval '24 hours' <= as_of or tr.departure_at - interval '1 hour' <= as_of)
  loop
    select * into t from public.trips where id = r.trip_id for update;
    select * into b from public.bookings where id = r.id for update;
    if b.status <> 'requested' then continue; end if;

    v_amount := public.escrow_balance_kz(b.id);
    update public.bookings set status = 'expired', responded_at = as_of, cancel_reason = 'no_response' where id = b.id;
    if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
    perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
      'O condutor não respondeu a tempo. O reembolso total chega em 1 a 3 dias úteis.');
    perform public.notify(b.passenger_id, 'booking_expired', jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'refund_kz', v_amount), true);
    n := n + 1;
  end loop;
  return n;
end $$;

-- 3. Выезд: departed + awaiting_confirm, либо expired без принятых броней
create or replace function public.sch_depart_trips(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; n integer := 0;
begin
  for t in select * from public.trips where status in ('published', 'full') and departure_at <= as_of loop
    select * into t from public.trips where id = t.id for update;
    if t.status not in ('published', 'full') then continue; end if;

    for b in select * from public.bookings where trip_id = t.id and status = 'pending_payment' for update loop
      update public.bookings set status = 'payment_failed', cancel_reason = 'trip_departed' where id = b.id;
      update public.payments set status = 'expired' where booking_id = b.id and status in ('created', 'pending');
      perform public.notify(b.passenger_id, 'payment_failed', jsonb_build_object('booking_id', b.id, 'reason', 'trip_departed'), true);
    end loop;

    if exists (select 1 from public.bookings where trip_id = t.id and status = 'accepted') then
      update public.trips set status = 'departed', departed_at = as_of where id = t.id;
      update public.bookings set status = 'awaiting_confirm' where trip_id = t.id and status = 'accepted';
    else
      update public.trips set status = 'expired' where id = t.id;
      perform public.forfeit_trip_holds(t.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 4. Напоминание за 24 ч
create or replace function public.sch_remind_24h(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; n integer := 0;
begin
  for t in
    select * from public.trips where status in ('published', 'full') and reminded_24h_at is null
      and departure_at > as_of and departure_at <= as_of + interval '24 hours'
  loop
    perform public.notify(t.driver_id, 'trip_reminder_24h',
      jsonb_build_object('trip_id', t.id, 'departure_at', t.departure_at, 'action', 'confirm_trip_intent'), false);
    for b in select * from public.bookings where trip_id = t.id and status = 'accepted' loop
      perform public.notify(b.passenger_id, 'trip_reminder_24h',
        jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'departure_at', t.departure_at, 'origin_detail', t.origin_detail), false);
    end loop;
    update public.trips set reminded_24h_at = as_of where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 5. Водитель не подтвердил к -6 ч: пассажирам открыта бесплатная отмена
create or replace function public.sch_remind_6h(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; n integer := 0;
begin
  for t in
    select * from public.trips where status in ('published', 'full') and reminded_6h_at is null and driver_confirmed_at is null
      and departure_at > as_of and departure_at <= as_of + interval '6 hours'
  loop
    perform public.notify(t.driver_id, 'trip_reminder_6h', jsonb_build_object('trip_id', t.id, 'departure_at', t.departure_at), true);
    for b in select * from public.bookings where trip_id = t.id and status = 'accepted' loop
      perform public.notify(b.passenger_id, 'driver_unconfirmed', jsonb_build_object('trip_id', t.id, 'booking_id', b.id), true);
    end loop;
    update public.trips set reminded_6h_at = as_of where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 6. PIN и телефон за 2 ч (и для броней, принятых позже, на следующем тике)
create or replace function public.sch_send_pins(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v_first boolean; n integer := 0;
begin
  for r in
    select b.id as booking_id, b.passenger_id, b.pin_code, t.id as trip_id, t.driver_id, t.departure_at
    from public.bookings b join public.trips t on t.id = b.trip_id
    where b.status in ('accepted', 'awaiting_confirm') and b.pin_sent_at is null and b.pin_code is not null
      and t.status in ('published', 'full', 'departed') and t.departure_at <= as_of + interval '2 hours'
    order by t.id, b.created_at
  loop
    v_first := not exists (select 1 from public.bookings where trip_id = r.trip_id and pin_sent_at is not null);

    perform public.system_message(public.ensure_conversation(r.trip_id, r.passenger_id, r.booking_id),
      'O seu PIN de embarque: ' || r.pin_code || '. Diga-o ao condutor ao entrar no carro.');
    perform public.notify(r.passenger_id, 'pin_ready', jsonb_build_object(
      'booking_id', r.booking_id, 'trip_id', r.trip_id, 'pin', r.pin_code, 'departure_at', r.departure_at,
      'driver_phone', (select phone from public.profiles where id = r.driver_id)), true);
    update public.bookings set pin_sent_at = as_of where id = r.booking_id;

    if v_first then
      perform public.notify(r.driver_id, 'trip_reminder_2h', jsonb_build_object(
        'trip_id', r.trip_id, 'departure_at', r.departure_at,
        'passengers', (select jsonb_agg(jsonb_build_object('booking_id', b2.id, 'name', p2.display_name, 'phone', p2.phone, 'seats', b2.seats))
                       from public.bookings b2 join public.profiles p2 on p2.id = b2.passenger_id
                       where b2.trip_id = r.trip_id and b2.status in ('accepted', 'awaiting_confirm'))), true);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 7. "Вы доехали?" через route_durations.minutes, по умолчанию 8 ч
create or replace function public.sch_ask_completed(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; n integer := 0;
begin
  for t in
    select tr.* from public.trips tr
    left join public.route_durations rd on rd.origin_place_id = tr.origin_place_id and rd.destination_place_id = tr.destination_place_id
    where tr.status = 'departed' and tr.completed_ask_at is null
      and tr.departure_at + make_interval(mins => coalesce(rd.minutes, 480)::integer) <= as_of
  loop
    for b in select * from public.bookings where trip_id = t.id and status = 'awaiting_confirm' loop
      perform public.notify(b.passenger_id, 'trip_completed_ask', jsonb_build_object('booking_id', b.id, 'trip_id', t.id), true);
    end loop;
    update public.trips set completed_ask_at = as_of where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 8-9. Автозавершение: 48 ч с PIN, 7 дней без
create or replace function public.sch_autocomplete(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; b public.bookings; n integer := 0;
begin
  for r in
    select bk.id, bk.trip_id from public.bookings bk join public.trips tr on tr.id = bk.trip_id
    where bk.status = 'awaiting_confirm'
      and ((bk.pin_entered_at is not null and tr.departure_at + interval '48 hours' <= as_of)
        or tr.departure_at + interval '7 days' <= as_of)
  loop
    perform 1 from public.trips where id = r.trip_id for update;
    select * into b from public.bookings where id = r.id for update;
    if b.status <> 'awaiting_confirm' then continue; end if;
    perform public.complete_booking(b, 'system');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 10. Водитель не приехал: ни одного PIN, спор пассажира открыт >= 24 ч, водитель не ответил
create or replace function public.sch_driver_no_show(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; b public.bookings; v_amount integer; n integer := 0;
begin
  for t in
    select tr.* from public.trips tr
    where tr.status = 'departed'
      and not exists (select 1 from public.bookings where trip_id = tr.id and (pin_entered_at is not null or status in ('completed', 'no_show')))
      and exists (select 1 from public.bookings d where d.trip_id = tr.id and d.status = 'disputed'
                  and d.passenger_confirmed_at is not null and d.passenger_confirmed_at + interval '24 hours' <= as_of)
      and not exists (
        select 1 from public.messages m
        join public.conversations c on c.id = m.conversation_id
        join public.bookings d on d.id = c.booking_id
        where d.trip_id = tr.id and d.status = 'disputed' and m.sender_id = tr.driver_id and m.created_at >= d.passenger_confirmed_at
      )
  loop
    select * into t from public.trips where id = t.id for update;
    if t.status <> 'departed' then continue; end if;

    for b in select * from public.bookings where trip_id = t.id and status in ('awaiting_confirm', 'disputed') for update loop
      v_amount := public.escrow_balance_kz(b.id);
      update public.bookings set status = 'cancelled', cancelled_at = as_of, cancelled_by = 'driver', cancel_reason = 'driver_no_show' where id = b.id;
      if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
      perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
        'O condutor não compareceu. Reembolso total em 1 a 3 dias úteis.');
      perform public.notify(b.passenger_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'reason', 'driver_no_show', 'refund_kz', v_amount), true);
    end loop;

    update public.trips set status = 'cancelled', cancelled_at = as_of, cancel_reason = 'driver_no_show' where id = t.id;
    perform public.forfeit_trip_holds(t.id);
    update public.profiles set cancels_total = cancels_total + 1, no_shows = no_shows + 1 where id = t.driver_id;
    perform public.notify(t.driver_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'reason', 'driver_no_show'), true);
    n := n + 1;
  end loop;
  return n;
end $$;

-- 11. Закрытие чатов
create or replace function public.sch_close_chats(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.conversations c set closed_at = as_of
  where c.closed_at is null and exists (
    select 1 from public.trips t
    left join public.bookings b on b.id = c.booking_id
    where t.id = c.trip_id and (
         (b.status in ('completed', 'no_show') and b.completed_at + interval '7 days' <= as_of)
      or (b.status in ('cancelled', 'declined', 'expired') and coalesce(b.cancelled_at, b.responded_at, b.updated_at) + interval '24 hours' <= as_of)
      or ((b.id is null or b.status = 'payment_failed') and t.departure_at + interval '24 hours' <= as_of)
      or (t.status in ('cancelled', 'expired') and coalesce(t.cancelled_at, t.departure_at) + interval '24 hours' <= as_of)
    )
  );
  get diagnostics n = row_count;
  return n;
end $$;

-- 12. Одиночные отзывы становятся видны через 14 дней
create or replace function public.sch_review_visibility(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.reviews r set is_visible = true
  from public.bookings b
  where b.id = r.booking_id and r.is_visible = false and b.completed_at + interval '14 days' <= as_of;
  get diagnostics n = row_count;
  return n;
end $$;

-- 13. route_stats раз в час
create or replace function public.sch_refresh_route_stats(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
begin
  refresh materialized view concurrently public.route_stats;
  return 1;
end $$;

-- 14. Чистка раз в сутки
create or replace function public.sch_cleanup(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; k integer;
begin
  delete from public.devices where last_seen_at < as_of - interval '90 days';
  get diagnostics k = row_count; n := n + k;

  update public.driver_verifications
  set id_doc_url = null, licence_url = null, vehicle_photo_url = null, selfie_url = null
  where reviewed_at is not null and reviewed_at + interval '30 days' <= as_of
    and coalesce(id_doc_url, licence_url, vehicle_photo_url, selfie_url) is not null;
  get diagnostics k = row_count; n := n + k;

  update public.messages set body = '[mensagem apagada]', masked = false
  where created_at < as_of - interval '12 months' and body <> '[mensagem apagada]';
  get diagnostics k = row_count; n := n + k;

  delete from public.events
  where created_at < as_of - interval '12 months' and name not in ('scheduler_error', 'reconciliation_mismatch');
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

-- 15. Сверка ledger и payments раз в сутки
create or replace function public.sch_reconcile(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_cash_in  bigint := coalesce((select -sum(amount_kz) from public.ledger_entries where account = 'cash_in'), 0);
  v_paid     bigint := coalesce((select sum(amount_kz) from public.payments where status in ('paid', 'refunded', 'partially_refunded')), 0);
  v_refunds  bigint := coalesce((select sum(amount_kz) from public.ledger_entries where account = 'refunds'), 0);
  v_refunded bigint := coalesce((select sum(refund_kz) from public.payments), 0);
  v_unbalanced integer := (select count(*) from (select op_id from public.ledger_entries group by op_id having sum(amount_kz) <> 0) x);
  v_balances integer := (select count(*) from public.profiles p
                         where p.balance_kz <> coalesce((select sum(amount_kz) from public.ledger_entries where user_id = p.id and account = 'driver_balance'), 0));
  v_issues jsonb := '[]';
  a record;
begin
  if v_cash_in <> v_paid then v_issues := v_issues || jsonb_build_object('check', 'cash_in_vs_payments', 'ledger', v_cash_in, 'payments', v_paid); end if;
  if v_refunds <> v_refunded then v_issues := v_issues || jsonb_build_object('check', 'refunds_vs_payments', 'ledger', v_refunds, 'payments', v_refunded); end if;
  if v_unbalanced > 0 then v_issues := v_issues || jsonb_build_object('check', 'unbalanced_ops', 'count', v_unbalanced); end if;
  if v_balances > 0 then v_issues := v_issues || jsonb_build_object('check', 'balance_cache', 'count', v_balances); end if;

  if jsonb_array_length(v_issues) > 0 then
    insert into public.events (name, props) values ('reconciliation_mismatch', jsonb_build_object('as_of', as_of, 'issues', v_issues));
    for a in select id from public.profiles where is_admin loop
      perform public.notify(a.id, 'reconciliation_alert', jsonb_build_object('issues', v_issues), true);
    end loop;
  end if;
  return jsonb_array_length(v_issues);
end $$;

-- ---------------------------------------------------------------------------
-- Диспетчер
-- ---------------------------------------------------------------------------
create or replace function public.scheduler_step(p_name text, as_of timestamptz, p_every interval default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j public.scheduler_jobs; n integer;
begin
  insert into public.scheduler_jobs (name) values (p_name) on conflict (name) do nothing;
  select * into j from public.scheduler_jobs where name = p_name for update;
  if p_every is not null and j.last_ok_at is not null and j.last_ok_at + p_every > as_of then
    return jsonb_build_object(p_name, 'skipped');
  end if;

  begin
    execute format('select public.%I($1)', 'sch_' || p_name) into n using as_of;
    update public.scheduler_jobs set last_run_at = as_of, last_ok_at = as_of, last_error = null, runs = runs + 1 where name = p_name;
    return jsonb_build_object(p_name, n);
  exception when others then
    update public.scheduler_jobs set last_run_at = as_of, last_error = sqlerrm, runs = runs + 1 where name = p_name;
    insert into public.events (name, props) values ('scheduler_error', jsonb_build_object('job', p_name, 'as_of', as_of, 'error', sqlerrm));
    return jsonb_build_object(p_name, 'error: ' || sqlerrm);
  end;
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
  r := r || public.scheduler_step('ask_completed',       as_of);
  r := r || public.scheduler_step('autocomplete',        as_of);
  r := r || public.scheduler_step('driver_no_show',      as_of);
  r := r || public.scheduler_step('close_chats',         as_of);
  r := r || public.scheduler_step('review_visibility',   as_of);
  r := r || public.scheduler_step('refresh_route_stats', as_of, interval '1 hour');
  r := r || public.scheduler_step('cleanup',             as_of, interval '1 day');
  r := r || public.scheduler_step('reconcile',           as_of, interval '1 day');
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Права и регистрация
-- ---------------------------------------------------------------------------
revoke all on function
  public.notify(uuid, text, jsonb, boolean, timestamptz),
  public.sch_expire_payments(timestamptz), public.sch_expire_requests(timestamptz), public.sch_depart_trips(timestamptz),
  public.sch_remind_24h(timestamptz), public.sch_remind_6h(timestamptz), public.sch_send_pins(timestamptz),
  public.sch_ask_completed(timestamptz), public.sch_autocomplete(timestamptz), public.sch_driver_no_show(timestamptz),
  public.sch_close_chats(timestamptz), public.sch_review_visibility(timestamptz), public.sch_refresh_route_stats(timestamptz),
  public.sch_cleanup(timestamptz), public.sch_reconcile(timestamptz),
  public.scheduler_step(text, timestamptz, interval), public.run_scheduler(timestamptz)
from public, anon, authenticated;
grant execute on function public.run_scheduler(timestamptz) to service_role;

select cron.unschedule(jobid) from cron.job where jobname = 'boleia_scheduler';
select cron.schedule('boleia_scheduler', '*/5 * * * *', $$select public.run_scheduler()$$);
