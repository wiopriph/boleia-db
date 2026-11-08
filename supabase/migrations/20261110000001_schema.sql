-- Boleia — schema (ТЗ раздел 4)
-- Все таблицы в public. Деньги — integer в кванзах (*_kz). Время — timestamptz (UTC).

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type chat_level          as enum ('bla', 'blabla', 'blablabla');
create type driver_status       as enum ('none', 'pending', 'verified', 'rejected');
create type profile_status      as enum ('active', 'restricted', 'suspended', 'banned');
create type verification_status as enum ('pending', 'approved', 'rejected');
create type vehicle_status      as enum ('active', 'removed');
create type place_kind          as enum ('city', 'town', 'landmark');
create type trip_status         as enum ('draft', 'published', 'full', 'departed', 'completed', 'cancelled', 'expired');
create type booking_mode        as enum ('instant', 'approval');
create type luggage_size        as enum ('small', 'medium', 'large');
create type booking_status      as enum (
  'pending_payment', 'payment_failed', 'requested', 'accepted', 'declined', 'expired',
  'cancelled', 'awaiting_confirm', 'completed', 'no_show', 'disputed'
);
create type party               as enum ('passenger', 'driver', 'system');
create type payment_status      as enum ('created', 'pending', 'paid', 'failed', 'expired', 'refunded', 'partially_refunded');
create type ledger_account      as enum ('passenger_escrow', 'driver_balance', 'platform_fee', 'refunds', 'gateway_fees', 'cash_out');
create type payout_status       as enum ('requested', 'processing', 'paid', 'failed', 'cancelled');
create type review_direction    as enum ('passenger_to_driver', 'driver_to_passenger');
create type report_reason       as enum ('no_show', 'unsafe_driving', 'harassment', 'scam', 'cash_offer', 'wrong_price', 'other');
create type report_status       as enum ('open', 'reviewed', 'actioned', 'dismissed');
create type notif_channel       as enum ('push', 'sms', 'inapp');
create type notif_status        as enum ('queued', 'sent', 'failed', 'read');
create type platform            as enum ('ios', 'android', 'web');
create type mod_action          as enum ('warn', 'restrict', 'suspend', 'ban', 'unban', 'verify_id');

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- admin = role 'admin' в app_metadata JWT (ТЗ раздел 8)
create or replace function public.is_admin()
returns boolean language sql stable as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false)
$$;

-- Единый формат ошибок: BOLEIA_<CODE>, SQLSTATE P0001 (ТЗ раздел 7)
create or replace function public.raise_boleia(code text)
returns void language plpgsql as $$
begin
  raise exception using message = 'BOLEIA_' || code, errcode = 'P0001';
end $$;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  phone              text unique,
  display_name       text not null default '',
  avatar_url         text,
  bio                text check (bio is null or char_length(bio) <= 300),
  birth_year         smallint check (birth_year is null or birth_year between 1920 and 2015),
  chat_level         chat_level not null default 'blabla',
  driver_status      driver_status not null default 'none',
  driver_verified_at timestamptz,
  rating_avg         numeric(3,2) not null default 0,
  rating_count       integer not null default 0,
  trips_driven       integer not null default 0,
  trips_ridden       integer not null default 0,
  cancels_total      smallint not null default 0,
  no_shows           smallint not null default 0,
  balance_kz         integer not null default 0,
  payout_method      jsonb,
  phone_verified_at  timestamptz,
  status             profile_status not null default 'active',
  is_admin           boolean not null default false,
  locale             text not null default 'pt-AO',
  last_seen_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.profiles is 'Публичный профиль поверх auth.users. Телефон и баланс наружу не отдаются.';

-- профиль создаётся автоматически при регистрации
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, phone, display_name, phone_verified_at)
  values (
    new.id,
    new.phone,
    coalesce(new.raw_user_meta_data ->> 'display_name', ''),
    new.phone_confirmed_at
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- запрет менять защищённые поля не из security definer функций (ТЗ раздел 6, триггеры)
create or replace function public.profiles_guard()
returns trigger language plpgsql as $$
begin
  if current_setting('role', true) in ('authenticated', 'anon') then
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

create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------------------------------------------------------------------------
-- banned_phones
-- ---------------------------------------------------------------------------
create table public.banned_phones (
  phone      text primary key,
  reason     text,
  banned_by  uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- vehicles
-- ---------------------------------------------------------------------------
create table public.vehicles (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles(id) on delete cascade,
  make        text not null,
  model       text not null,
  color       text,
  year        smallint check (year is null or year between 1980 and 2030),
  plate       text,
  seats_total smallint not null check (seats_total between 1 and 8),
  photo_url   text,
  verified    boolean not null default false,
  status      vehicle_status not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index vehicles_owner_idx on public.vehicles (owner_id) where status = 'active';

-- ---------------------------------------------------------------------------
-- driver_verifications
-- ---------------------------------------------------------------------------
create table public.driver_verifications (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles(id) on delete cascade,
  vehicle_id        uuid not null references public.vehicles(id) on delete cascade,
  id_doc_url        text,
  licence_url       text,
  vehicle_photo_url text,
  selfie_url        text,
  status            verification_status not null default 'pending',
  reject_reason     text,
  reviewed_by       uuid references public.profiles(id),
  reviewed_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index driver_verifications_one_pending
  on public.driver_verifications (user_id) where status = 'pending';

-- ---------------------------------------------------------------------------
-- places, route_durations
-- ---------------------------------------------------------------------------
create table public.places (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  province   text not null,
  slug       text not null unique,
  kind       place_kind not null default 'city',
  lat        double precision,
  lng        double precision,
  aliases    text[] not null default '{}',
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index places_name_trgm_idx on public.places using gin (name gin_trgm_ops);

create table public.route_durations (
  origin_place_id      uuid not null references public.places(id),
  destination_place_id uuid not null references public.places(id),
  minutes              smallint not null check (minutes > 0),
  price_hint_kz        integer check (price_hint_kz is null or price_hint_kz > 0),
  primary key (origin_place_id, destination_place_id)
);

-- ---------------------------------------------------------------------------
-- trips
-- ---------------------------------------------------------------------------
create table public.trips (
  id                   uuid primary key default gen_random_uuid(),
  driver_id            uuid not null references public.profiles(id),
  vehicle_id           uuid not null references public.vehicles(id),
  origin_place_id      uuid not null references public.places(id),
  destination_place_id uuid not null references public.places(id),
  origin_detail        text,
  destination_detail   text,
  departure_at         timestamptz not null,
  seats_offered        smallint not null check (seats_offered between 1 and 4),
  seats_available      smallint not null,
  price_per_seat_kz    integer not null check (price_per_seat_kz between 500 and 100000),
  currency             char(3) not null default 'AOA',
  booking_mode         booking_mode not null default 'instant',
  luggage              luggage_size not null default 'medium',
  allows_smoking       boolean not null default false,
  allows_pets          boolean not null default false,
  max_two_in_back      boolean not null default false,
  notes                text check (notes is null or char_length(notes) <= 500),
  status               trip_status not null default 'draft',
  published_at         timestamptz,
  departed_at          timestamptz,
  completed_at         timestamptz,
  cancelled_at         timestamptz,
  cancel_reason        text,
  driver_confirmed_at  timestamptz,
  view_count           integer not null default 0,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint trips_origin_ne_destination check (origin_place_id <> destination_place_id),
  constraint trips_seats_available_range check (seats_available between 0 and seats_offered)
);
create index trips_search_idx on public.trips (origin_place_id, destination_place_id, departure_at)
  where status in ('published', 'full');
create index trips_driver_idx on public.trips (driver_id, departure_at);
create index trips_cron_idx on public.trips (departure_at) where status in ('published', 'full', 'departed');

-- ---------------------------------------------------------------------------
-- trip_stops (этап 2, таблица создаётся сразу)
-- ---------------------------------------------------------------------------
create table public.trip_stops (
  id                   uuid primary key default gen_random_uuid(),
  trip_id              uuid not null references public.trips(id) on delete cascade,
  place_id             uuid not null references public.places(id),
  order_idx            smallint not null,
  price_from_origin_kz integer,
  unique (trip_id, order_idx)
);

-- ---------------------------------------------------------------------------
-- bookings
-- ---------------------------------------------------------------------------
create table public.bookings (
  id                     uuid primary key default gen_random_uuid(),
  trip_id                uuid not null references public.trips(id),
  passenger_id           uuid not null references public.profiles(id),
  seats                  smallint not null check (seats between 1 and 3),
  price_total_kz         integer not null check (price_total_kz > 0),
  fee_kz                 integer not null check (fee_kz >= 0),
  message                text check (message is null or char_length(message) <= 300),
  status                 booking_status not null default 'pending_payment',
  pin_code               char(4),
  pin_entered_at         timestamptz,
  requested_at           timestamptz,
  responded_at           timestamptz,
  cancelled_at           timestamptz,
  cancelled_by           party,
  cancel_reason          text,
  refund_kz              integer not null default 0,
  passenger_confirmed_at timestamptz,
  driver_confirmed_at    timestamptz,
  completed_at           timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
-- одна активная бронь пассажира на поездку
create unique index bookings_one_active_per_passenger
  on public.bookings (trip_id, passenger_id)
  where status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm');
create index bookings_trip_idx on public.bookings (trip_id, status);
create index bookings_passenger_idx on public.bookings (passenger_id, created_at desc);

-- пассажир не бронирует свою поездку
create or replace function public.bookings_not_own_trip()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.trips t where t.id = new.trip_id and t.driver_id = new.passenger_id) then
    perform public.raise_boleia('OWN_TRIP');
  end if;
  return new;
end $$;
create trigger bookings_not_own_trip before insert on public.bookings
  for each row execute function public.bookings_not_own_trip();

-- пересчёт seats_available и published <-> full (ТЗ раздел 6, триггеры)
create or replace function public.trips_recount_seats()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_trip_id uuid := coalesce(new.trip_id, old.trip_id);
  v_taken   integer;
  v_offered smallint;
  v_status  trip_status;
begin
  select coalesce(sum(seats), 0) into v_taken
  from public.bookings
  where trip_id = v_trip_id
    and status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm');

  select seats_offered, status into v_offered, v_status from public.trips where id = v_trip_id;

  update public.trips
  set seats_available = greatest(v_offered - v_taken, 0),
      status = case
        when v_status = 'published' and v_offered - v_taken <= 0 then 'full'::trip_status
        when v_status = 'full'      and v_offered - v_taken >  0 then 'published'::trip_status
        else v_status
      end
  where id = v_trip_id;
  return null;
end $$;
create trigger bookings_recount_seats
  after insert or update of status, seats or delete on public.bookings
  for each row execute function public.trips_recount_seats();

-- ---------------------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------------------
create table public.payments (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references public.bookings(id),
  payer_id     uuid not null references public.profiles(id),
  amount_kz    integer not null check (amount_kz > 0),
  provider     text not null default 'mcx_express',
  provider_ref text unique,
  status       payment_status not null default 'created',
  refund_kz    integer not null default 0,
  refund_ref   text,
  raw_request  jsonb,
  raw_webhook  jsonb,
  expires_at   timestamptz,
  paid_at      timestamptz,
  refunded_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index payments_booking_idx on public.payments (booking_id);
create index payments_pending_idx on public.payments (expires_at) where status = 'pending';

-- ---------------------------------------------------------------------------
-- ledger_entries — insert-only, двойная запись
-- ---------------------------------------------------------------------------
create table public.ledger_entries (
  id         bigint generated always as identity primary key,
  booking_id uuid references public.bookings(id),
  payout_id  uuid,
  account    ledger_account not null,
  user_id    uuid references public.profiles(id),
  amount_kz  integer not null,
  op_id      uuid not null,
  memo       text,
  created_at timestamptz not null default now()
);
create index ledger_op_idx      on public.ledger_entries (op_id);
create index ledger_user_idx    on public.ledger_entries (user_id, account);
create index ledger_booking_idx on public.ledger_entries (booking_id);

create or replace function public.ledger_immutable()
returns trigger language plpgsql as $$
begin
  perform public.raise_boleia('LEDGER_IMMUTABLE');
  return null;
end $$;
create trigger ledger_no_update before update or delete on public.ledger_entries
  for each row execute function public.ledger_immutable();

-- balance_kz — кэш суммы driver_balance по пользователю
create or replace function public.ledger_sync_balance()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.account = 'driver_balance' and new.user_id is not null then
    update public.profiles p
    set balance_kz = (
      select coalesce(sum(amount_kz), 0) from public.ledger_entries
      where user_id = new.user_id and account = 'driver_balance'
    )
    where p.id = new.user_id;
  end if;
  return null;
end $$;
create trigger ledger_sync_balance after insert on public.ledger_entries
  for each row execute function public.ledger_sync_balance();

-- ---------------------------------------------------------------------------
-- payouts
-- ---------------------------------------------------------------------------
create table public.payouts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id),
  amount_kz    integer not null check (amount_kz >= 5000),
  method       jsonb not null,
  status       payout_status not null default 'requested',
  provider_ref text,
  processed_by uuid references public.profiles(id),
  processed_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.ledger_entries
  add constraint ledger_payout_fk foreign key (payout_id) references public.payouts(id);

-- ---------------------------------------------------------------------------
-- conversations, messages
-- ---------------------------------------------------------------------------
create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  trip_id         uuid not null references public.trips(id),
  passenger_id    uuid not null references public.profiles(id),
  driver_id       uuid not null references public.profiles(id),
  booking_id      uuid references public.bookings(id),
  last_message_at timestamptz,
  closed_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (trip_id, passenger_id)
);
create index conversations_passenger_idx on public.conversations (passenger_id, last_message_at desc);
create index conversations_driver_idx    on public.conversations (driver_id, last_message_at desc);

create table public.messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid references public.profiles(id),   -- null = системное
  body            text not null check (char_length(body) between 1 and 1000),
  masked          boolean not null default false,
  read_at         timestamptz,
  created_at      timestamptz not null default now()
);
create index messages_conv_idx on public.messages (conversation_id, id);

-- ---------------------------------------------------------------------------
-- reviews
-- ---------------------------------------------------------------------------
create table public.reviews (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id),
  author_id  uuid not null references public.profiles(id),
  target_id  uuid not null references public.profiles(id),
  direction  review_direction not null,
  rating     smallint not null check (rating between 1 and 5),
  tags       text[] not null default '{}',
  comment    text check (comment is null or char_length(comment) <= 300),
  is_visible boolean not null default false,
  created_at timestamptz not null default now(),
  unique (booking_id, author_id)
);
create index reviews_target_idx on public.reviews (target_id) where is_visible;

create or replace function public.reviews_recalc_rating()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles p
  set rating_avg   = coalesce((select round(avg(rating)::numeric, 2) from public.reviews where target_id = new.target_id), 0),
      rating_count = (select count(*) from public.reviews where target_id = new.target_id)
  where p.id = new.target_id;

  -- оба отзыва по брони есть → оба видимы
  if (select count(*) from public.reviews where booking_id = new.booking_id) = 2 then
    update public.reviews set is_visible = true where booking_id = new.booking_id;
  end if;
  return null;
end $$;
create trigger reviews_recalc after insert on public.reviews
  for each row execute function public.reviews_recalc_rating();

-- ---------------------------------------------------------------------------
-- reports, contact_reveals, moderation_actions
-- ---------------------------------------------------------------------------
create table public.reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null references public.profiles(id),
  target_user_id uuid not null references public.profiles(id),
  trip_id        uuid references public.trips(id),
  booking_id     uuid references public.bookings(id),
  message_id     bigint references public.messages(id),
  reason         report_reason not null,
  details        text,
  status         report_status not null default 'open',
  resolved_by    uuid references public.profiles(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index reports_open_idx on public.reports (created_at) where status = 'open';

create table public.contact_reveals (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references public.bookings(id),
  viewer_id        uuid not null references public.profiles(id),
  revealed_user_id uuid not null references public.profiles(id),
  created_at       timestamptz not null default now()
);

create table public.moderation_actions (
  id             uuid primary key default gen_random_uuid(),
  admin_id       uuid not null references public.profiles(id),
  target_user_id uuid not null references public.profiles(id),
  action         mod_action not null,
  reason         text,
  report_id      uuid references public.reports(id),
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- notifications, devices, events
-- ---------------------------------------------------------------------------
create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  type          text not null,
  channel       notif_channel not null,
  payload       jsonb not null default '{}',
  status        notif_status not null default 'queued',
  scheduled_for timestamptz,
  sent_at       timestamptz,
  read_at       timestamptz,
  error         text,
  created_at    timestamptz not null default now()
);
create index notifications_queue_idx on public.notifications (scheduled_for, created_at) where status = 'queued';
create index notifications_user_idx  on public.notifications (user_id, created_at desc);

create table public.devices (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  platform     platform not null,
  push_token   text not null unique,
  app_version  text,
  last_seen_at timestamptz not null default now(),
  created_at   timestamptz not null default now()
);

create table public.events (
  id         bigint generated always as identity primary key,
  user_id    uuid,
  name       text not null,
  props      jsonb not null default '{}',
  platform   platform,
  created_at timestamptz not null default now()
);
create index events_name_idx on public.events (name, created_at desc);

-- ---------------------------------------------------------------------------
-- updated_at на всех таблицах, где есть колонка
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  for t in
    select table_name from information_schema.columns
    where table_schema = 'public' and column_name = 'updated_at'
  loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
                   t || '_updated_at', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Realtime: только брони и сообщения (ТЗ раздел 7)
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.bookings;
alter publication supabase_realtime add table public.messages;
