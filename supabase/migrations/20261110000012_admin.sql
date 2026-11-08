-- Boleia - админка (ТЗ раздел 11; разделы 5, 8, 9)
--
-- Действия модератора над пользователями, жалобами, поездками, бронями и возвратами; справочник мест;
-- агрегаты для дашборда; доступ admin к чатам только по открытой жалобе или спору; снятие приостановки
-- по сроку в cron. План и решения: docs/plans/0012_admin.md

-- ---------------------------------------------------------------------------
-- Схема
-- ---------------------------------------------------------------------------
alter table public.profiles add column suspended_until timestamptz;
alter table public.moderation_actions
  add column until   timestamptz,
  add column payload jsonb not null default '{}';
alter type public.mod_action add value if not exists 'hide_trip';
alter type public.mod_action add value if not exists 'cancel_booking';
alter type public.mod_action add value if not exists 'manual_refund';
alter type public.mod_action add value if not exists 'report_dismissed';

-- ---------------------------------------------------------------------------
-- Доступ admin к чатам: только открытая жалоба или спор (ТЗ раздел 11)
-- ---------------------------------------------------------------------------
create or replace function public.admin_can_see_conversation(c public.conversations)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() and (
    exists (select 1 from public.bookings b where b.id = c.booking_id and b.status = 'disputed')
    or exists (
      select 1 from public.reports r
      where r.status in ('open', 'reviewed')
        and (r.booking_id = c.booking_id or r.trip_id = c.trip_id
             or r.target_user_id in (c.passenger_id, c.driver_id)
             or r.reporter_id in (c.passenger_id, c.driver_id))
    )
  )
$$;

drop policy conversations_select_participants on public.conversations;
create policy conversations_select_participants on public.conversations
  for select to authenticated using (
    passenger_id = auth.uid() or driver_id = auth.uid() or public.admin_can_see_conversation(conversations)
  );

drop policy messages_select_participants on public.messages;
create policy messages_select_participants on public.messages
  for select to authenticated using (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.passenger_id = auth.uid() or c.driver_id = auth.uid() or public.admin_can_see_conversation(c))
    )
  );

create or replace view public.my_conversations as
select
  c.id,
  c.trip_id,
  c.booking_id,
  c.passenger_id,
  c.driver_id,
  case when c.passenger_id = auth.uid() then c.driver_id else c.passenger_id end as other_user_id,
  op.display_name as other_user_name,
  op.avatar_url   as other_user_avatar_url,
  c.last_message_at,
  c.closed_at,
  t.departure_at,
  o.name as origin_name,
  d.name as destination_name,
  lm.body        as last_message_body,
  lm.sender_id   as last_message_sender_id,
  (select count(*) from public.messages m
     where m.conversation_id = c.id and m.read_at is null
       and (m.sender_id is distinct from auth.uid())) as unread_count
from public.conversations c
join public.trips  t on t.id = c.trip_id
join public.places o on o.id = t.origin_place_id
join public.places d on d.id = t.destination_place_id
join public.profiles op
  on op.id = case when c.passenger_id = auth.uid() then c.driver_id else c.passenger_id end
left join lateral (
  select body, sender_id from public.messages
  where conversation_id = c.id order by id desc limit 1
) lm on true
where c.passenger_id = auth.uid() or c.driver_id = auth.uid() or public.admin_can_see_conversation(c);

-- ---------------------------------------------------------------------------
-- Внутренние функции
-- ---------------------------------------------------------------------------
create or replace function public.require_admin()
returns public.profiles language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then perform public.raise_boleia('NOT_ADMIN'); end if;
  return public.current_profile();
end $$;

create or replace function public.mod_log(
  p_admin uuid, p_target uuid, p_action mod_action, p_reason text,
  p_until timestamptz default null, p_payload jsonb default '{}', p_report uuid default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.moderation_actions (admin_id, target_user_id, action, reason, report_id, until, payload)
  values (p_admin, p_target, p_action, p_reason, p_report, p_until, coalesce(p_payload, '{}'))
  returning id into v_id;
  return v_id;
end $$;

-- Отмена одной брони платформой: полный возврат, счётчики сторон не трогаются
create or replace function public.cancel_booking_by_system(b public.bookings, p_reason text)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.trips; v_amount integer;
begin
  select * into t from public.trips where id = b.trip_id;
  if b.status = 'pending_payment' then
    update public.bookings set status = 'payment_failed', cancel_reason = p_reason where id = b.id;
    update public.payments set status = 'expired' where booking_id = b.id and status in ('created', 'pending');
    perform public.notify(b.passenger_id, 'payment_failed', jsonb_build_object('booking_id', b.id, 'reason', p_reason), true);
    return 0;
  end if;

  v_amount := public.escrow_balance_kz(b.id);
  update public.bookings
  set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system', cancel_reason = p_reason
  where id = b.id;
  if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
  perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
    'Reserva cancelada pela plataforma. Reembolso total em 1 a 3 dias úteis.');
  perform public.notify(b.passenger_id, 'booking_cancelled_by_driver',
    jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'refund_kz', v_amount, 'by', 'system'), true);
  perform public.notify(t.driver_id, 'booking_cancelled_by_passenger',
    jsonb_build_object('booking_id', b.id, 'trip_id', t.id, 'seats', b.seats, 'by', 'system'), false);
  if t.status = 'departed' then perform public.settle_trip(t.id); end if;
  return v_amount;
end $$;

-- Каскад отмены поездки: водителем (счётчик +1 при оплаченных бронях) или платформой (без счётчика)
create or replace function public.cancel_trip_cascade(t public.trips, p_by party, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_amount integer; v_paid integer := 0; v_refunded integer := 0;
begin
  for b in select * from public.bookings where trip_id = t.id
           and status in ('pending_payment', 'requested', 'accepted') for update loop
    if b.status = 'pending_payment' then
      update public.bookings set status = 'payment_failed', cancel_reason = 'trip_cancelled' where id = b.id;
      update public.payments set status = 'expired' where booking_id = b.id and status in ('created', 'pending');
      perform public.notify(b.passenger_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'refund_kz', 0), true);
    else
      v_amount := public.escrow_balance_kz(b.id);
      update public.bookings
      set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = p_reason
      where id = b.id;
      if v_amount > 0 then perform public.ledger_refund(b, v_amount, 0); end if;
      v_paid := v_paid + 1; v_refunded := v_refunded + v_amount;
      perform public.system_message(public.ensure_conversation(t.id, b.passenger_id, b.id),
        case when p_by = 'driver' then 'Viagem cancelada pelo condutor. O reembolso total chega em 1 a 3 dias úteis.'
             else 'Viagem cancelada pela plataforma. O reembolso total chega em 1 a 3 dias úteis.' end);
      perform public.notify(b.passenger_id, 'trip_cancelled',
        jsonb_build_object('trip_id', t.id, 'booking_id', b.id, 'refund_kz', v_amount, 'by', p_by), true);
    end if;
  end loop;

  update public.trips set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = t.id;
  perform public.forfeit_trip_holds(t.id);
  if p_by = 'driver' and v_paid > 0 then
    update public.profiles set cancels_total = cancels_total + 1 where id = t.driver_id;
  end if;
  return jsonb_build_object('cancelled_bookings', v_paid, 'refunded_kz', v_refunded);
end $$;

create or replace function public.cancel_trip(trip_id uuid, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips := public.trip_for_driver(trip_id); r jsonb;
begin
  if t.status not in ('draft', 'published', 'full') then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;
  r := public.cancel_trip_cascade(t, 'driver', nullif(btrim(reason), ''));
  perform public.log_event('trip_cancelled', jsonb_build_object('trip_id', t.id, 'paid_bookings', r -> 'cancelled_bookings'));
end $$;

-- ---------------------------------------------------------------------------
-- Пользователи
-- ---------------------------------------------------------------------------
create or replace function public.admin_search_users(q text, lim integer default 20)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
declare v_digits text := regexp_replace(coalesce(q, ''), '\D', '', 'g'); v_q text := nullif(btrim(q), '');
begin
  perform public.require_admin();
  return query
    select jsonb_build_object(
      'id', p.id, 'display_name', p.display_name, 'phone', p.phone, 'avatar_url', p.avatar_url,
      'status', p.status, 'suspended_until', p.suspended_until, 'is_admin', p.is_admin,
      'driver_status', p.driver_status, 'rating_avg', p.rating_avg, 'rating_count', p.rating_count,
      'trips_driven', p.trips_driven, 'trips_ridden', p.trips_ridden,
      'cancels_total', p.cancels_total, 'no_shows', p.no_shows, 'balance_kz', p.balance_kz,
      'created_at', p.created_at, 'last_seen_at', p.last_seen_at)
    from public.profiles p
    where v_q is not null and (
      (length(v_digits) >= 6 and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') like '%' || v_digits || '%')
      or p.display_name ilike '%' || v_q || '%'
      or p.id::text = v_q
    )
    order by p.last_seen_at desc nulls last, p.created_at desc
    limit least(coalesce(lim, 20), 100);
end $$;

create or replace function public.admin_moderate(
  target_id uuid, action mod_action, reason text, days integer default null, report_id uuid default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  a         public.profiles := public.require_admin();
  v_target  uuid := target_id;
  v_action  mod_action := action;
  v_reason  text := nullif(btrim(reason), '');
  v_days    integer := days;
  v_report  uuid := report_id;
  tgt       public.profiles;
  t         public.trips;
  b         public.bookings;
  v_until   timestamptz;
  v_payload jsonb := '{}';
begin
  if v_action not in ('warn', 'restrict', 'suspend', 'ban', 'unban') then perform public.raise_boleia('MODERATION_ACTION_INVALID'); end if;
  if v_reason is null then perform public.raise_boleia('REASON_REQUIRED'); end if;

  select * into tgt from public.profiles where id = v_target for update;
  if tgt.id is null or tgt.status::text = 'deleted' then perform public.raise_boleia('TARGET_INVALID'); end if;
  if tgt.is_admin then perform public.raise_boleia('TARGET_IS_ADMIN'); end if;

  if v_action = 'restrict' then
    update public.profiles set status = 'restricted' where id = tgt.id;

  elsif v_action = 'suspend' then
    if v_days is null or v_days < 1 then perform public.raise_boleia('DAYS_REQUIRED'); end if;
    v_until := now() + make_interval(days => v_days);
    update public.profiles set status = 'suspended', suspended_until = v_until where id = tgt.id;
    delete from auth.sessions where user_id = tgt.id;

  elsif v_action = 'ban' then
    update public.profiles set status = 'banned', suspended_until = null where id = tgt.id;
    if tgt.phone is not null then
      insert into public.banned_phones (phone, reason, banned_by) values (tgt.phone, v_reason, a.id) on conflict (phone) do nothing;
    end if;
    update auth.users set banned_until = 'infinity' where id = tgt.id;
    delete from auth.sessions where user_id = tgt.id;
    -- поездки водителя: отмена платформой, 100 % пассажирам (ТЗ раздел 5)
    for t in select * from public.trips where driver_id = tgt.id and status in ('draft', 'published', 'full') for update loop
      v_payload := v_payload || jsonb_build_object('trip_' || t.id, public.cancel_trip_cascade(t, 'system', 'moderation'));
    end loop;
    -- брони пассажира: деньги возвращаются ему же
    for b in select * from public.bookings where passenger_id = tgt.id
             and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm', 'disputed') for update loop
      perform public.cancel_booking_by_system(b, 'moderation');
    end loop;

  elsif v_action = 'unban' then
    update public.profiles set status = 'active', suspended_until = null where id = tgt.id;
    delete from public.banned_phones bp where tgt.phone is not null and public.same_phone(bp.phone, tgt.phone);
    update auth.users set banned_until = null where id = tgt.id;
  end if;

  perform public.mod_log(a.id, tgt.id, v_action, v_reason, v_until, v_payload, v_report);
  if v_report is not null then
    update public.reports set status = 'actioned', resolved_by = a.id where id = v_report and status in ('open', 'reviewed');
  end if;
  perform public.notify(tgt.id, 'moderation_action',
    jsonb_build_object('action', v_action, 'reason', v_reason, 'until', v_until), true);
end $$;

create or replace function public.admin_resolve_report(report_id uuid, outcome text, note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a public.profiles := public.require_admin(); v_id uuid := report_id; r public.reports;
begin
  if outcome not in ('reviewed', 'dismissed') then perform public.raise_boleia('REPORT_OUTCOME_INVALID'); end if;
  select * into r from public.reports where id = v_id for update;
  if r.id is null then perform public.raise_boleia('REPORT_NOT_FOUND'); end if;
  if r.status not in ('open', 'reviewed') then perform public.raise_boleia('REPORT_CLOSED'); end if;

  update public.reports set status = outcome::report_status, resolved_by = case when outcome = 'dismissed' then a.id else resolved_by end
  where id = r.id;
  if outcome = 'dismissed' then
    perform public.mod_log(a.id, r.target_user_id, 'report_dismissed', coalesce(nullif(btrim(note), ''), 'sem fundamento'), null, '{}', r.id);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Поездки и деньги
-- ---------------------------------------------------------------------------
create or replace function public.admin_cancel_trip(trip_id uuid, reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.profiles := public.require_admin(); v_id uuid := trip_id; v_reason text := nullif(btrim(reason), ''); t public.trips; r jsonb;
begin
  if v_reason is null then perform public.raise_boleia('REASON_REQUIRED'); end if;
  select * into t from public.trips where id = v_id for update;
  if t.id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
  if t.status not in ('draft', 'published', 'full') then perform public.raise_boleia('TOO_LATE_TO_CANCEL'); end if;
  r := public.cancel_trip_cascade(t, 'system', 'moderation');
  perform public.mod_log(a.id, t.driver_id, 'hide_trip', v_reason, null, jsonb_build_object('trip_id', t.id) || r);
  perform public.notify(t.driver_id, 'trip_cancelled', jsonb_build_object('trip_id', t.id, 'reason', 'moderation', 'note', v_reason), true);
  return r;
end $$;

create or replace function public.admin_cancel_booking(booking_id uuid, reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.profiles := public.require_admin(); v_id uuid := booking_id; v_reason text := nullif(btrim(reason), ''); b public.bookings; v_refund integer;
begin
  if v_reason is null then perform public.raise_boleia('REASON_REQUIRED'); end if;
  select * into b from public.bookings where id = v_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  perform 1 from public.trips where id = b.trip_id for update;
  select * into b from public.bookings where id = v_id for update;
  if b.status not in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm', 'disputed') then
    perform public.raise_boleia('BOOKING_CLOSED');
  end if;
  v_refund := public.cancel_booking_by_system(b, 'moderation');
  perform public.mod_log(a.id, b.passenger_id, 'cancel_booking', v_reason, null, jsonb_build_object('booking_id', b.id, 'refund_kz', v_refund));
  return jsonb_build_object('status', (select status from public.bookings where id = b.id), 'refund_kz', v_refund);
end $$;

create or replace function public.admin_mark_refund_manual(payment_id uuid, ref text, note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.profiles := public.require_admin(); v_ref text := nullif(btrim(ref), ''); pay public.payments; r jsonb;
begin
  if v_ref is null then perform public.raise_boleia('PAYMENT_REF_MISMATCH'); end if;
  select * into pay from public.payments where id = admin_mark_refund_manual.payment_id;
  if pay.id is null then perform public.raise_boleia('PAYMENT_NOT_FOUND'); end if;
  r := public.payment_refund_result(pay.id, true, 'manual:' || v_ref, jsonb_build_object('manual', true, 'note', note, 'admin', a.id));
  perform public.mod_log(a.id, pay.payer_id, 'manual_refund', coalesce(nullif(btrim(note), ''), v_ref), null,
    jsonb_build_object('payment_id', pay.id, 'booking_id', pay.booking_id, 'refund_kz', pay.refund_kz, 'ref', v_ref));
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Справочник мест
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_place(payload jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  a      public.profiles := public.require_admin();
  v_id   uuid := (payload ->> 'id')::uuid;
  v_slug text := lower(btrim(payload ->> 'slug'));
  pl     public.places;
begin
  if v_id is not null then
    select * into pl from public.places where id = v_id;
    if pl.id is null then perform public.raise_boleia('PLACE_NOT_FOUND'); end if;
  end if;
  if v_slug is not null and v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then perform public.raise_boleia('PLACE_INVALID'); end if;
  if v_slug is not null and exists (select 1 from public.places where slug = v_slug and id is distinct from v_id) then
    perform public.raise_boleia('PLACE_SLUG_TAKEN');
  end if;

  if v_id is null then
    if nullif(btrim(payload ->> 'name'), '') is null or nullif(btrim(payload ->> 'province'), '') is null or v_slug is null then
      perform public.raise_boleia('PLACE_INVALID');
    end if;
    insert into public.places (name, province, slug, kind, lat, lng, aliases, is_active)
    values (btrim(payload ->> 'name'), btrim(payload ->> 'province'), v_slug,
            coalesce((payload ->> 'kind')::place_kind, 'city'),
            (payload ->> 'lat')::double precision, (payload ->> 'lng')::double precision,
            coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(payload -> 'aliases', '[]')) x), '{}'),
            coalesce((payload ->> 'is_active')::boolean, true))
    returning id into v_id;
  else
    update public.places set
      name      = coalesce(nullif(btrim(payload ->> 'name'), ''), name),
      province  = coalesce(nullif(btrim(payload ->> 'province'), ''), province),
      slug      = coalesce(v_slug, slug),
      kind      = coalesce((payload ->> 'kind')::place_kind, kind),
      lat       = case when payload ? 'lat' then (payload ->> 'lat')::double precision else lat end,
      lng       = case when payload ? 'lng' then (payload ->> 'lng')::double precision else lng end,
      aliases   = case when payload ? 'aliases' then coalesce((select array_agg(x) from jsonb_array_elements_text(payload -> 'aliases') x), '{}') else aliases end,
      is_active = coalesce((payload ->> 'is_active')::boolean, is_active)
    where id = v_id;
  end if;
  perform public.log_event('admin_place_upsert', jsonb_build_object('place_id', v_id, 'admin', a.id));
  return v_id;
end $$;

create or replace function public.admin_merge_places(from_id uuid, into_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.profiles := public.require_admin(); src public.places; dst public.places;
begin
  if from_id = into_id then perform public.raise_boleia('PLACE_INVALID'); end if;
  select * into src from public.places where id = from_id for update;
  select * into dst from public.places where id = into_id for update;
  if src.id is null or dst.id is null then perform public.raise_boleia('PLACE_NOT_FOUND'); end if;

  update public.trips set origin_place_id = dst.id where origin_place_id = src.id and destination_place_id <> dst.id;
  update public.trips set destination_place_id = dst.id where destination_place_id = src.id and origin_place_id <> dst.id;

  insert into public.route_durations (origin_place_id, destination_place_id, minutes, price_hint_kz)
  select case when origin_place_id = src.id then dst.id else origin_place_id end,
         case when destination_place_id = src.id then dst.id else destination_place_id end,
         minutes, price_hint_kz
  from public.route_durations
  where (origin_place_id = src.id or destination_place_id = src.id)
    and case when origin_place_id = src.id then dst.id else origin_place_id end
        <> case when destination_place_id = src.id then dst.id else destination_place_id end
  on conflict (origin_place_id, destination_place_id) do nothing;
  delete from public.route_durations where origin_place_id = src.id or destination_place_id = src.id;

  update public.places set
    aliases = (select array_agg(distinct x) from unnest(dst.aliases || src.name || src.aliases) x where x <> dst.name)
  where id = dst.id;
  update public.places set is_active = false where id = src.id;
  perform public.log_event('admin_place_merge', jsonb_build_object('from', src.id, 'into', dst.id, 'admin', a.id));
end $$;

-- ---------------------------------------------------------------------------
-- Дашборд
-- ---------------------------------------------------------------------------
create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_today timestamptz := date_trunc('day', now() at time zone 'Africa/Luanda') at time zone 'Africa/Luanda';
begin
  perform public.require_admin();
  return jsonb_build_object(
    'queues', jsonb_build_object(
      'reports_open',        (select count(*) from public.reports where status in ('open', 'reviewed')),
      'disputes',            (select count(*) from public.bookings where status = 'disputed'),
      'verifications',       (select count(*) from public.driver_verifications where status = 'pending'),
      'payouts',             (select count(*) from public.payouts where status in ('requested', 'processing')),
      'refunds_pending',     (select count(*) from public.pending_refunds),
      'refunds_manual',      (select count(*) from public.payments where refund_kz > 0 and refund_ref is null and refund_attempts >= 3)
    ),
    'today', jsonb_build_object(
      'new_users',           (select count(*) from public.profiles where created_at >= v_today),
      'trips_published',     (select count(*) from public.trips where published_at >= v_today),
      'bookings_paid',       (select count(*) from public.payments where paid_at >= v_today),
      'gmv_kz',              (select coalesce(sum(amount_kz), 0) from public.payments where paid_at >= v_today),
      'payment_failed',      (select count(*) from public.bookings where status = 'payment_failed' and updated_at >= v_today)
    ),
    'week', jsonb_build_object(
      'new_users',           (select count(*) from public.profiles where created_at >= now() - interval '7 days'),
      'trips_published',     (select count(*) from public.trips where published_at >= now() - interval '7 days'),
      'bookings_paid',       (select count(*) from public.payments where paid_at >= now() - interval '7 days'),
      'gmv_kz',              (select coalesce(sum(amount_kz), 0) from public.payments where paid_at >= now() - interval '7 days'),
      'fee_kz',              (select coalesce(sum(amount_kz), 0) from public.ledger_entries where account = 'platform_fee' and amount_kz > 0 and created_at >= now() - interval '7 days')
    ),
    'health', jsonb_build_object(
      'notifications_failed_24h', (select count(*) from public.notifications where status = 'failed' and created_at >= now() - interval '24 hours'),
      'reconciliation_mismatches_7d', (select count(*) from public.events where name = 'reconciliation_mismatch' and created_at >= now() - interval '7 days'),
      'scheduler_errors', (select coalesce(jsonb_agg(jsonb_build_object('job', name, 'error', last_error, 'at', last_run_at)), '[]') from public.scheduler_jobs where last_error is not null),
      'scheduler_last_run', (select max(last_run_at) from public.scheduler_jobs)
    )
  );
end $$;

create or replace function public.admin_weekly(weeks integer default 8)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin();
  return query
    with w as (
      select date_trunc('week', now()) - make_interval(weeks => g) as ws
      from generate_series(0, greatest(least(coalesce(weeks, 8), 52), 1) - 1) g
    )
    select jsonb_build_object(
      'week_start', w.ws,
      'new_users',       (select count(*) from public.profiles p where p.created_at >= w.ws and p.created_at < w.ws + interval '7 days'),
      'trips_published', (select count(*) from public.trips t where t.published_at >= w.ws and t.published_at < w.ws + interval '7 days'),
      'requests',        (select count(*) from public.bookings b where b.created_at >= w.ws and b.created_at < w.ws + interval '7 days'),
      'paid',            (select count(*) from public.payments p where p.paid_at >= w.ws and p.paid_at < w.ws + interval '7 days'),
      'accepted',        (select count(*) from public.bookings b where b.responded_at >= w.ws and b.responded_at < w.ws + interval '7 days' and b.status <> 'declined'),
      'completed',       (select count(*) from public.bookings b where b.completed_at >= w.ws and b.completed_at < w.ws + interval '7 days' and b.status in ('completed', 'no_show')),
      'cancelled_by_passenger', (select count(*) from public.bookings b where b.cancelled_at >= w.ws and b.cancelled_at < w.ws + interval '7 days' and b.cancelled_by = 'passenger'),
      'cancelled_by_driver',    (select count(*) from public.bookings b where b.cancelled_at >= w.ws and b.cancelled_at < w.ws + interval '7 days' and b.cancelled_by = 'driver'),
      'cancelled_by_system',    (select count(*) from public.bookings b where b.cancelled_at >= w.ws and b.cancelled_at < w.ws + interval '7 days' and b.cancelled_by = 'system'),
      'gmv_kz',          (select coalesce(sum(p.amount_kz), 0) from public.payments p where p.paid_at >= w.ws and p.paid_at < w.ws + interval '7 days'),
      'fee_kz',          (select coalesce(sum(l.amount_kz), 0) from public.ledger_entries l where l.account = 'platform_fee' and l.amount_kz > 0 and l.created_at >= w.ws and l.created_at < w.ws + interval '7 days'),
      'refunds_kz',      (select coalesce(sum(l.amount_kz), 0) from public.ledger_entries l where l.account = 'refunds' and l.created_at >= w.ws and l.created_at < w.ws + interval '7 days'),
      'driver_response_hours', (select round(avg(extract(epoch from (b.responded_at - b.requested_at)) / 3600)::numeric, 1)
                                from public.bookings b join public.trips t on t.id = b.trip_id
                                where t.booking_mode = 'approval' and b.responded_at >= w.ws and b.responded_at < w.ws + interval '7 days'),
      'verification_hours',    (select round(avg(extract(epoch from (v.reviewed_at - v.created_at)) / 3600)::numeric, 1)
                                from public.driver_verifications v where v.reviewed_at >= w.ws and v.reviewed_at < w.ws + interval '7 days'),
      'top_routes',      (select coalesce(jsonb_agg(r), '[]') from (
                            select jsonb_build_object('origin', o.slug, 'destination', d.slug, 'paid', count(*)) as r
                            from public.payments p join public.bookings b on b.id = p.booking_id
                            join public.trips t on t.id = b.trip_id
                            join public.places o on o.id = t.origin_place_id join public.places d on d.id = t.destination_place_id
                            where p.paid_at >= w.ws and p.paid_at < w.ws + interval '7 days'
                            group by o.slug, d.slug order by count(*) desc limit 10) x)
    )
    from w order by w.ws desc;
end $$;

-- ---------------------------------------------------------------------------
-- Cron: снятие приостановки по сроку
-- ---------------------------------------------------------------------------
create or replace function public.sch_lift_suspensions(as_of timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id from public.profiles where status = 'suspended' and suspended_until is not null and suspended_until <= as_of loop
    update public.profiles set status = 'active', suspended_until = null where id = r.id;
    perform public.notify(r.id, 'moderation_action', jsonb_build_object('action', 'unsuspend'), true);
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
  r := r || public.scheduler_step('ask_completed',       as_of);
  r := r || public.scheduler_step('autocomplete',        as_of);
  r := r || public.scheduler_step('driver_no_show',      as_of);
  r := r || public.scheduler_step('lift_suspensions',    as_of);
  r := r || public.scheduler_step('close_chats',         as_of);
  r := r || public.scheduler_step('review_visibility',   as_of);
  r := r || public.scheduler_step('refresh_route_stats', as_of, interval '1 hour');
  r := r || public.scheduler_step('cleanup',             as_of, interval '1 day');
  r := r || public.scheduler_step('reconcile',           as_of, interval '1 day');
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------
revoke all on function
  public.admin_can_see_conversation(public.conversations),
  public.require_admin(),
  public.mod_log(uuid, uuid, mod_action, text, timestamptz, jsonb, uuid),
  public.cancel_booking_by_system(public.bookings, text),
  public.cancel_trip_cascade(public.trips, party, text),
  public.sch_lift_suspensions(timestamptz),
  public.admin_search_users(text, integer),
  public.admin_moderate(uuid, mod_action, text, integer, uuid),
  public.admin_resolve_report(uuid, text, text),
  public.admin_cancel_trip(uuid, text),
  public.admin_cancel_booking(uuid, text),
  public.admin_mark_refund_manual(uuid, text, text),
  public.admin_upsert_place(jsonb),
  public.admin_merge_places(uuid, uuid),
  public.admin_stats(),
  public.admin_weekly(integer)
from public, anon, authenticated;

-- admin_can_see_conversation вызывается из RLS от имени запрашивающего
grant execute on function public.admin_can_see_conversation(public.conversations) to authenticated;
grant execute on function
  public.admin_search_users(text, integer),
  public.admin_moderate(uuid, mod_action, text, integer, uuid),
  public.admin_resolve_report(uuid, text, text),
  public.admin_cancel_trip(uuid, text),
  public.admin_cancel_booking(uuid, text),
  public.admin_mark_refund_manual(uuid, text, text),
  public.admin_upsert_place(jsonb),
  public.admin_merge_places(uuid, uuid),
  public.admin_stats(),
  public.admin_weekly(integer)
to authenticated;
