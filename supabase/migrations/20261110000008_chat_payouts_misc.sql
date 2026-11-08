-- Boleia - chat, reviews, reports, payouts, verification, delete_me (ТЗ разделы 4, 6, 8, 9, 10, 11)
--
-- Последняя SQL-миграция I1: тела send_message, mark_read, reveal_contact, submit_review, report_user,
-- request_payout, mark_payout, submit_verification, review_verification, delete_me; триггер
-- маскирования; Storage-бакеты. План и решения: docs/plans/0008_chat_payouts_misc.md

-- ---------------------------------------------------------------------------
-- Схема
-- ---------------------------------------------------------------------------
-- reporter_id = null: автожалоба от системы (cash_offer)
alter table public.reports alter column reporter_id drop not null;

-- presence для push new_message: "получатель не в этом чате последние 60 с" (ТЗ раздел 9)
alter table public.conversations
  add column passenger_seen_at timestamptz,
  add column driver_seen_at    timestamptz;

alter type public.profile_status add value if not exists 'deleted';

-- deleted-профили из публичной выдачи. Сравнение по тексту: новое значение enum в этой транзакции
-- ещё нельзя использовать в DDL.
create or replace view public.profiles_public as
select
  p.id,
  p.display_name,
  p.avatar_url,
  p.bio,
  p.birth_year,
  p.chat_level,
  (p.driver_status = 'verified')          as driver_verified,
  p.rating_avg,
  p.rating_count,
  p.trips_driven,
  p.trips_ridden,
  p.cancels_total,
  case
    when p.cancels_total = 0 and (p.trips_driven + p.trips_ridden) > 0 then 'never_cancelled'
    when p.cancels_total > 0 then 'sometimes_cancels'
    else null
  end                                     as cancel_badge,
  p.created_at                            as member_since
from public.profiles p
where p.status::text not in ('banned', 'deleted');

-- deleted-аккаунт не может вызывать RPC даже с живым токеном
create or replace function public.current_profile()
returns public.profiles language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  if auth.uid() is null then perform public.raise_boleia('NOT_AUTHENTICATED'); end if;
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then perform public.raise_boleia('PROFILE_NOT_FOUND'); end if;
  if p.status::text in ('suspended', 'banned', 'deleted') then perform public.raise_boleia('PROFILE_RESTRICTED'); end if;
  return p;
end $$;

-- my_bookings / my_conversations были security_invoker и джойнили trips и profiles: RLS этих таблиц
-- не отдаёт пассажиру чужие строки, и брони пропадали из вида. Теперь фильтр по auth.uid() явный.
alter view public.my_bookings reset (security_invoker);
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
  c.id                as conversation_id
from public.bookings b
join public.trips    t  on t.id = b.trip_id
join public.places   o  on o.id = t.origin_place_id
join public.places   d  on d.id = t.destination_place_id
join public.profiles dp on dp.id = t.driver_id
left join lateral (
  select status, expires_at from public.payments
  where booking_id = b.id order by created_at desc limit 1
) pay on true
left join public.conversations c on c.trip_id = b.trip_id and c.passenger_id = b.passenger_id
where b.passenger_id = auth.uid() or t.driver_id = auth.uid() or public.is_admin();

alter view public.my_conversations reset (security_invoker);
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
where c.passenger_id = auth.uid() or c.driver_id = auth.uid() or public.is_admin();

-- Storage: аватары и фото машин публичные, документы верификации приватные (ТЗ раздел 8)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars',       'avatars',       true,  5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('vehicles',      'vehicles',      true,  5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('verifications', 'verifications', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy boleia_public_read on storage.objects
  for select to anon, authenticated using (bucket_id in ('avatars', 'vehicles'));
create policy boleia_own_folder_insert on storage.objects
  for insert to authenticated
  with check (bucket_id in ('avatars', 'vehicles', 'verifications') and (storage.foldername(name))[1] = auth.uid()::text);
create policy boleia_own_folder_update on storage.objects
  for update to authenticated
  using (bucket_id in ('avatars', 'vehicles') and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id in ('avatars', 'vehicles') and (storage.foldername(name))[1] = auth.uid()::text);
create policy boleia_own_folder_delete on storage.objects
  for delete to authenticated
  using (bucket_id in ('avatars', 'vehicles') and (storage.foldername(name))[1] = auth.uid()::text);
create policy boleia_verifications_read on storage.objects
  for select to authenticated
  using (bucket_id = 'verifications' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------------------------------------------------------------------------
-- Хелперы
-- ---------------------------------------------------------------------------
create or replace function public.notify_admins(p_type text, p_payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare a record;
begin
  for a in select id from public.profiles where is_admin and status = 'active' loop
    perform public.notify(a.id, p_type, p_payload, false);
  end loop;
end $$;

-- Телефоны, wa.me и ссылки -> [oculto] (ТЗ раздел 6, триггеры)
create or replace function public.mask_text(p_body text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(p_body, '(https?://\S+|wa\.me/?\S*)', '[oculto]', 'gi'),
             '\+?244\d{9}', '[oculto]', 'g'),
           '(?<!\d)9\d{8}(?!\d)', '[oculto]', 'g')
$$;

-- Чат с оплаченной бронью: деньги в эскроу или поездка состоялась
create or replace function public.conversation_paid(c public.conversations)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bookings b where b.id = c.booking_id
      and b.status in ('requested', 'accepted', 'awaiting_confirm', 'completed', 'no_show', 'disputed')
  )
$$;

-- Маскирование до departure_at - 2 ч по оплаченной брони; до оплаты всегда (ТЗ раздел 4, messages)
create or replace function public.messages_mask()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c      public.conversations;
  v_open boolean;
  v_body text;
begin
  if new.sender_id is null then return new; end if;
  select * into c from public.conversations where id = new.conversation_id;

  v_open := exists (
    select 1 from public.bookings b join public.trips t on t.id = b.trip_id
    where b.id = c.booking_id
      and b.status in ('accepted', 'awaiting_confirm', 'completed', 'no_show', 'disputed')
      and now() >= t.departure_at - interval '2 hours'
  );
  if v_open then return new; end if;

  v_body := public.mask_text(new.body);
  if v_body <> new.body then
    new.body := v_body;
    new.masked := true;
  end if;
  return new;
end $$;
create trigger messages_mask before insert on public.messages
  for each row execute function public.messages_mask();

-- Третье замаскированное сообщение одного отправителя в чате -> автожалоба cash_offer, один раз
create or replace function public.messages_cash_offer_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_cnt integer; v_report uuid;
begin
  if not new.masked or new.sender_id is null then return null; end if;
  select count(*) into v_cnt from public.messages
  where conversation_id = new.conversation_id and sender_id = new.sender_id and masked;
  if v_cnt <> 3 then return null; end if;

  select * into c from public.conversations where id = new.conversation_id;
  if exists (
    select 1 from public.reports where reporter_id is null and reason = 'cash_offer'
      and target_user_id = new.sender_id and trip_id = c.trip_id
  ) then return null; end if;

  insert into public.reports (reporter_id, target_user_id, trip_id, booking_id, message_id, reason, details)
  values (null, new.sender_id, c.trip_id, c.booking_id, new.id, 'cash_offer', 'Automático: 3 mensagens com contacto ou link ocultados')
  returning id into v_report;
  perform public.notify_admins('report_opened', jsonb_build_object('report_id', v_report, 'reason', 'cash_offer', 'auto', true));
  return null;
end $$;
create trigger messages_cash_offer_report after insert on public.messages
  for each row execute function public.messages_cash_offer_report();

-- ---------------------------------------------------------------------------
-- Чат
-- ---------------------------------------------------------------------------
create or replace function public.send_message(body text, conversation_id uuid default null, trip_id uuid default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  p          public.profiles := public.current_profile();
  v_body     text := btrim(body);
  v_conv_id  uuid := conversation_id;
  v_trip_id  uuid := trip_id;
  c          public.conversations;
  t          public.trips;
  v_msg_id   bigint;
  v_masked   text;
  v_other    uuid;
  v_seen     timestamptz;
begin
  if v_body is null or v_body = '' then perform public.raise_boleia('MESSAGE_EMPTY'); end if;
  if char_length(v_body) > 1000 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;

  if v_conv_id is not null then
    select * into c from public.conversations where id = v_conv_id;
    if c.id is null or p.id not in (c.passenger_id, c.driver_id) then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  else
    if v_trip_id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
    select * into t from public.trips where id = v_trip_id;
    if t.id is null then perform public.raise_boleia('TRIP_NOT_FOUND'); end if;
    if t.status not in ('published', 'full') then perform public.raise_boleia('TRIP_CLOSED'); end if;
    if t.driver_id = p.id then perform public.raise_boleia('OWN_TRIP'); end if;

    if not exists (select 1 from public.conversations where conversations.trip_id = t.id and passenger_id = p.id)
       and (select count(*) from public.conversations
            where passenger_id = p.id and booking_id is null and created_at > now() - interval '24 hours') >= 5 then
      perform public.raise_boleia('CHAT_LIMIT_REACHED');
    end if;
    v_conv_id := public.ensure_conversation(t.id, p.id, null);
    select * into c from public.conversations where id = v_conv_id;
  end if;

  if c.closed_at is not null then perform public.raise_boleia('CHAT_CLOSED'); end if;

  if p.id = c.passenger_id and not public.conversation_paid(c)
     and (select count(*) from public.messages where messages.conversation_id = c.id and sender_id = p.id) >= 10 then
    perform public.raise_boleia('CHAT_LIMIT_REACHED');
  end if;
  if (select count(*) from public.messages where sender_id = p.id and created_at > now() - interval '1 minute') >= 60 then
    perform public.raise_boleia('RATE_LIMITED');
  end if;

  insert into public.messages (conversation_id, sender_id, body) values (c.id, p.id, v_body)
  returning id, messages.body into v_msg_id, v_masked;

  update public.conversations
  set last_message_at = now(),
      passenger_seen_at = case when p.id = passenger_id then now() else passenger_seen_at end,
      driver_seen_at    = case when p.id = driver_id    then now() else driver_seen_at end
  where id = c.id;

  if p.id = c.passenger_id then v_other := c.driver_id; v_seen := c.driver_seen_at;
  else v_other := c.passenger_id; v_seen := c.passenger_seen_at; end if;

  if v_seen is null or v_seen < now() - interval '60 seconds' then
    perform public.notify(v_other, 'new_message', jsonb_build_object(
      'conversation_id', c.id, 'message_id', v_msg_id, 'sender_name', p.display_name, 'preview', left(v_masked, 80)), false);
  end if;
  return v_msg_id;
end $$;

create or replace function public.mark_read(conversation_id uuid, up_to_message_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  p         public.profiles := public.current_profile();
  v_conv_id uuid := conversation_id;
  c         public.conversations;
begin
  select * into c from public.conversations where id = v_conv_id;
  if c.id is null or p.id not in (c.passenger_id, c.driver_id) then perform public.raise_boleia('NOT_PARTICIPANT'); end if;

  update public.messages set read_at = now()
  where messages.conversation_id = c.id and id <= up_to_message_id and read_at is null and sender_id is distinct from p.id;

  update public.conversations
  set passenger_seen_at = case when p.id = passenger_id then now() else passenger_seen_at end,
      driver_seen_at    = case when p.id = driver_id    then now() else driver_seen_at end
  where id = c.id;
end $$;

create or replace function public.reveal_contact(booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  b            public.bookings;
  t            public.trips;
  other        public.profiles;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id;
  if p.id not in (b.passenger_id, t.driver_id) then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status not in ('accepted', 'awaiting_confirm') then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if now() < t.departure_at - interval '2 hours' then perform public.raise_boleia('CONTACT_LOCKED'); end if;

  select * into other from public.profiles where id = case when p.id = b.passenger_id then t.driver_id else b.passenger_id end;
  insert into public.contact_reveals (booking_id, viewer_id, revealed_user_id) values (b.id, p.id, other.id);
  perform public.log_event('contact_revealed', jsonb_build_object('booking_id', b.id));
  return jsonb_build_object('user_id', other.id, 'display_name', other.display_name, 'phone', other.phone);
end $$;

-- ---------------------------------------------------------------------------
-- Отзывы и жалобы
-- ---------------------------------------------------------------------------
create or replace function public.submit_review(booking_id uuid, rating integer, tags text[] default '{}', comment text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_booking_id uuid := booking_id;
  v_rating     integer := rating;
  v_tags       text[] := coalesce(tags, '{}');
  v_comment    text := nullif(btrim(comment), '');
  b            public.bookings;
  t            public.trips;
  v_dir        review_direction;
  v_target     uuid;
  v_id         uuid;
begin
  select * into b from public.bookings where id = v_booking_id;
  if b.id is null then perform public.raise_boleia('BOOKING_NOT_FOUND'); end if;
  select * into t from public.trips where id = b.trip_id;
  if p.id not in (b.passenger_id, t.driver_id) then perform public.raise_boleia('NOT_PARTICIPANT'); end if;
  if b.status not in ('completed', 'no_show') then perform public.raise_boleia('BOOKING_CLOSED'); end if;
  if b.completed_at + interval '14 days' <= now() then perform public.raise_boleia('REVIEW_WINDOW_CLOSED'); end if;
  if v_rating is null or v_rating not between 1 and 5 then perform public.raise_boleia('RATING_INVALID'); end if;
  if not (v_tags <@ array['pontual', 'condução_segura', 'simpático']) then perform public.raise_boleia('TAGS_INVALID'); end if;
  if char_length(v_comment) > 300 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;

  if p.id = b.passenger_id then v_dir := 'passenger_to_driver'; v_target := t.driver_id;
  else v_dir := 'driver_to_passenger'; v_target := b.passenger_id; end if;

  if exists (select 1 from public.reviews where reviews.booking_id = b.id and author_id = p.id) then
    perform public.raise_boleia('REVIEW_DUPLICATE');
  end if;

  insert into public.reviews (booking_id, author_id, target_id, direction, rating, tags, comment)
  values (b.id, p.id, v_target, v_dir, v_rating, v_tags, v_comment)
  returning id into v_id;
  perform public.log_event('review_submitted', jsonb_build_object('booking_id', b.id, 'rating', v_rating));
  return v_id;
end $$;

create or replace function public.report_user(
  target_id uuid, reason report_reason, details text default null,
  trip_id uuid default null, booking_id uuid default null, message_id bigint default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p          public.profiles := public.current_profile();
  v_target   uuid := target_id;
  v_reason   report_reason := reason;
  v_details  text := nullif(btrim(details), '');
  v_trip     uuid := trip_id;
  v_booking  uuid := booking_id;
  v_message  bigint := message_id;
  v_id       uuid;
begin
  if v_target is null or v_target = p.id or not exists (select 1 from public.profiles where id = v_target) then
    perform public.raise_boleia('TARGET_INVALID');
  end if;
  if char_length(v_details) > 1000 then perform public.raise_boleia('MESSAGE_TOO_LONG'); end if;
  if (select count(*) from public.reports where reporter_id = p.id and created_at > now() - interval '24 hours') >= 10 then
    perform public.raise_boleia('RATE_LIMITED');
  end if;

  insert into public.reports (reporter_id, target_user_id, trip_id, booking_id, message_id, reason, details)
  values (p.id, v_target, v_trip, v_booking, v_message, v_reason, v_details)
  returning id into v_id;
  perform public.notify_admins('report_opened', jsonb_build_object('report_id', v_id, 'reason', v_reason, 'target_id', v_target));
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Выплаты (ТЗ раздел 10)
-- ---------------------------------------------------------------------------
create or replace function public.request_payout(amount_kz integer)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p        public.profiles := public.current_profile();
  v_amount integer := amount_kz;
  v_id     uuid;
begin
  select * into p from public.profiles where id = p.id for update;
  if p.payout_method is null then perform public.raise_boleia('PAYOUT_METHOD_INVALID'); end if;
  if v_amount is null or v_amount < 5000 then perform public.raise_boleia('AMOUNT_INVALID'); end if;
  if exists (select 1 from public.payouts where user_id = p.id and status in ('requested', 'processing')) then
    perform public.raise_boleia('PAYOUT_PENDING');
  end if;
  if exists (select 1 from public.payouts where user_id = p.id and created_at > now() - interval '7 days') then
    perform public.raise_boleia('RATE_LIMITED');
  end if;
  if p.balance_kz < v_amount then perform public.raise_boleia('INSUFFICIENT_BALANCE'); end if;

  insert into public.payouts (user_id, amount_kz, method) values (p.id, v_amount, p.payout_method) returning id into v_id;
  perform public.ledger_post(gen_random_uuid(), 'payout:' || v_id, null, jsonb_build_array(
    jsonb_build_object('account', 'driver_balance', 'user_id', p.id, 'payout_id', v_id, 'amount_kz', -v_amount),
    jsonb_build_object('account', 'cash_out', 'payout_id', v_id, 'amount_kz', v_amount)
  ));
  perform public.notify_admins('payout_requested', jsonb_build_object('payout_id', v_id, 'user_id', p.id, 'amount_kz', v_amount));
  perform public.log_event('payout_requested', jsonb_build_object('payout_id', v_id, 'amount_kz', v_amount));
  return v_id;
end $$;

create or replace function public.mark_payout(payout_id uuid, new_status text, ref text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  p           public.profiles;
  v_payout_id uuid := payout_id;
  po          public.payouts;
begin
  if not public.is_admin() then perform public.raise_boleia('NOT_ADMIN'); end if;
  p := public.current_profile();
  if new_status not in ('processing', 'paid', 'failed') then perform public.raise_boleia('PAYOUT_STATUS_INVALID'); end if;

  select * into po from public.payouts where id = v_payout_id for update;
  if po.id is null then perform public.raise_boleia('PAYOUT_NOT_FOUND'); end if;
  if po.status not in ('requested', 'processing') then perform public.raise_boleia('PAYOUT_CLOSED'); end if;

  if new_status = 'processing' then
    update public.payouts set status = 'processing', processed_by = p.id where id = po.id;
  elsif new_status = 'paid' then
    update public.payouts set status = 'paid', provider_ref = nullif(btrim(ref), ''), processed_by = p.id, processed_at = now() where id = po.id;
    perform public.notify(po.user_id, 'payout_paid', jsonb_build_object('payout_id', po.id, 'amount_kz', po.amount_kz), true);
  else
    update public.payouts set status = 'failed', provider_ref = nullif(btrim(ref), ''), processed_by = p.id, processed_at = now() where id = po.id;
    perform public.ledger_post(gen_random_uuid(), 'payout_failed:' || po.id, null, jsonb_build_array(
      jsonb_build_object('account', 'cash_out', 'payout_id', po.id, 'amount_kz', -po.amount_kz),
      jsonb_build_object('account', 'driver_balance', 'user_id', po.user_id, 'payout_id', po.id, 'amount_kz', po.amount_kz)
    ));
    perform public.notify(po.user_id, 'payout_failed', jsonb_build_object('payout_id', po.id, 'amount_kz', po.amount_kz, 'reason', ref), true);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Верификация (ТЗ разделы 6, 8)
-- ---------------------------------------------------------------------------
create or replace function public.submit_verification(vehicle_id uuid, doc_urls jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v_vehicle_id uuid := vehicle_id;
  v            public.vehicles;
  v_prefix     text := p.id::text || '/';
  k            text;
  v_id         uuid;
begin
  select * into v from public.vehicles where id = v_vehicle_id and owner_id = p.id and status = 'active';
  if v.id is null then perform public.raise_boleia('VEHICLE_NOT_FOUND'); end if;

  foreach k in array array['id_doc_url', 'licence_url', 'vehicle_photo_url', 'selfie_url'] loop
    if coalesce(doc_urls ->> k, '') = '' or left(doc_urls ->> k, length(v_prefix)) <> v_prefix then
      perform public.raise_boleia('VERIFICATION_INCOMPLETE');
    end if;
  end loop;

  if exists (select 1 from public.driver_verifications where user_id = p.id and status = 'pending') then
    perform public.raise_boleia('VERIFICATION_PENDING');
  end if;
  if exists (select 1 from public.driver_verifications
             where user_id = p.id and status = 'rejected' and reviewed_at > now() - interval '24 hours') then
    perform public.raise_boleia('RATE_LIMITED');
  end if;

  insert into public.driver_verifications (user_id, vehicle_id, id_doc_url, licence_url, vehicle_photo_url, selfie_url)
  values (p.id, v.id, doc_urls ->> 'id_doc_url', doc_urls ->> 'licence_url', doc_urls ->> 'vehicle_photo_url', doc_urls ->> 'selfie_url')
  returning id into v_id;

  if p.driver_status in ('none', 'rejected') then
    update public.profiles set driver_status = 'pending' where id = p.id;
  end if;
  perform public.notify_admins('verification_submitted', jsonb_build_object('verification_id', v_id, 'user_id', p.id, 'vehicle_id', v.id));
  return v_id;
end $$;

create or replace function public.review_verification(verification_id uuid, approve boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  p        public.profiles;
  v_id     uuid := verification_id;
  v_reason text := nullif(btrim(reason), '');
  dv       public.driver_verifications;
begin
  if not public.is_admin() then perform public.raise_boleia('NOT_ADMIN'); end if;
  p := public.current_profile();
  select * into dv from public.driver_verifications where id = v_id for update;
  if dv.id is null or dv.status <> 'pending' then perform public.raise_boleia('VERIFICATION_CLOSED'); end if;

  if approve then
    update public.driver_verifications set status = 'approved', reviewed_by = p.id, reviewed_at = now() where id = dv.id;
    update public.profiles set driver_status = 'verified', driver_verified_at = coalesce(driver_verified_at, now()) where id = dv.user_id;
    update public.vehicles set verified = true where id = dv.vehicle_id;
    insert into public.moderation_actions (admin_id, target_user_id, action, reason) values (p.id, dv.user_id, 'verify_id', v_reason);
    perform public.notify(dv.user_id, 'verification_approved', jsonb_build_object('verification_id', dv.id, 'vehicle_id', dv.vehicle_id), true);
  else
    if v_reason is null then perform public.raise_boleia('REASON_REQUIRED'); end if;
    update public.driver_verifications set status = 'rejected', reject_reason = v_reason, reviewed_by = p.id, reviewed_at = now() where id = dv.id;
    update public.profiles set driver_status = 'rejected' where id = dv.user_id and driver_status <> 'verified';
    perform public.notify(dv.user_id, 'verification_rejected', jsonb_build_object('verification_id', dv.id, 'reason', v_reason), true);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- delete_me (ТЗ раздел 8): обезличивание, история остаётся
-- ---------------------------------------------------------------------------
create or replace function public.delete_me()
returns void language plpgsql security definer set search_path = public as $$
declare p public.profiles := public.current_profile();
begin
  select * into p from public.profiles where id = p.id for update;

  if exists (select 1 from public.bookings where passenger_id = p.id
             and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm', 'disputed'))
     or exists (select 1 from public.trips where driver_id = p.id and status in ('published', 'full', 'departed')) then
    perform public.raise_boleia('HAS_ACTIVE_BOOKINGS');
  end if;
  if p.balance_kz <> 0 or exists (select 1 from public.payouts where user_id = p.id and status in ('requested', 'processing')) then
    perform public.raise_boleia('BALANCE_NOT_ZERO');
  end if;

  update public.profiles
  set display_name = 'Utilizador removido', avatar_url = null, bio = null, birth_year = null,
      payout_method = null, phone = null, status = 'deleted'
  where id = p.id;
  update public.vehicles set status = 'removed' where owner_id = p.id and status = 'active';
  update public.driver_verifications
  set id_doc_url = null, licence_url = null, vehicle_photo_url = null, selfie_url = null
  where user_id = p.id;
  delete from public.devices where user_id = p.id;
  update public.conversations set closed_at = now() where (passenger_id = p.id or driver_id = p.id) and closed_at is null;

  -- номер освобождается для новой регистрации, старые сессии и refresh-токены умирают
  update auth.users set phone = null, phone_change = '', banned_until = 'infinity', raw_user_meta_data = '{}' where id = p.id;
  delete from auth.sessions where user_id = p.id;
  delete from auth.refresh_tokens where user_id = p.id::text;

  insert into public.events (user_id, name, props) values (p.id, 'account_deleted', '{}');
end $$;

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------
revoke all on function
  public.notify_admins(text, jsonb),
  public.mask_text(text),
  public.conversation_paid(public.conversations)
from public, anon, authenticated;
