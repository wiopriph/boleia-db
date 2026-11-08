-- Boleia — Row Level Security (ТЗ раздел 8)
--
-- Принцип: клиенты читают через views и прямые select под RLS, пишут ТОЛЬКО через RPC.
-- Все RPC — security definer и работают от владельца функции (postgres), поэтому
-- на таблицах с деньгами/статусами нет ни одной insert/update политики для authenticated.
-- service_role обходит RLS всегда (Edge Functions).

-- ---------------------------------------------------------------------------
-- Включаем RLS везде
-- ---------------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.banned_phones        enable row level security;
alter table public.vehicles             enable row level security;
alter table public.driver_verifications enable row level security;
alter table public.places               enable row level security;
alter table public.route_durations      enable row level security;
alter table public.trips                enable row level security;
alter table public.trip_stops           enable row level security;
alter table public.bookings             enable row level security;
alter table public.payments             enable row level security;
alter table public.ledger_entries       enable row level security;
alter table public.payouts              enable row level security;
alter table public.conversations        enable row level security;
alter table public.messages             enable row level security;
alter table public.reviews              enable row level security;
alter table public.reports              enable row level security;
alter table public.contact_reveals      enable row level security;
alter table public.moderation_actions   enable row level security;
alter table public.notifications        enable row level security;
alter table public.devices              enable row level security;
alter table public.events               enable row level security;

-- Отзываем прямые права на запись у клиентских ролей: только RPC.
-- (Supabase по умолчанию выдаёт anon/authenticated все права на public.*)
revoke insert, update, delete on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke insert, update, delete on tables from anon, authenticated;

-- Исключения: таблицы, куда клиент пишет сам под RLS
grant update (display_name, avatar_url, bio, birth_year, chat_level, payout_method, locale, last_seen_at)
  on public.profiles to authenticated;
grant insert, update, delete on public.devices to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- ---------------------------------------------------------------------------
-- profiles: свой — полностью, чужой — через profiles_public
-- ---------------------------------------------------------------------------
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());

create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- banned_phones: только admin (и auth-hook через service_role)
-- ---------------------------------------------------------------------------
create policy banned_phones_admin on public.banned_phones
  for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------------------
-- vehicles: владелец; публично — через trips_public
-- ---------------------------------------------------------------------------
create policy vehicles_select_own on public.vehicles
  for select to authenticated using (owner_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------------
-- driver_verifications: владелец — свои (URL документов скрываются в RPC/view после решения); admin — все
-- ---------------------------------------------------------------------------
create policy verifications_select_own on public.driver_verifications
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------------
-- places, route_durations: все читают
-- ---------------------------------------------------------------------------
create policy places_select_all on public.places
  for select to anon, authenticated using (is_active or public.is_admin());

create policy route_durations_select_all on public.route_durations
  for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- trips: владелец видит свои (любой статус); публично — trips_public
-- ---------------------------------------------------------------------------
create policy trips_select_own on public.trips
  for select to authenticated using (driver_id = auth.uid() or public.is_admin());

create policy trip_stops_select on public.trip_stops
  for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- bookings: пассажир — свои; водитель — по своим поездкам
-- ---------------------------------------------------------------------------
create policy bookings_select_participants on public.bookings
  for select to authenticated using (
    passenger_id = auth.uid()
    or exists (select 1 from public.trips t where t.id = bookings.trip_id and t.driver_id = auth.uid())
    or public.is_admin()
  );

-- ---------------------------------------------------------------------------
-- payments: плательщик — свои (raw_* скрыты через column grants); admin — все
-- ---------------------------------------------------------------------------
revoke select on public.payments from anon, authenticated;
grant select (id, booking_id, payer_id, amount_kz, provider, status, refund_kz, expires_at, paid_at, refunded_at, created_at)
  on public.payments to authenticated;

create policy payments_select_own on public.payments
  for select to authenticated using (payer_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------------
-- ledger_entries: владелец — строки с user_id = uid; admin — все; писать — никому кроме RPC
-- ---------------------------------------------------------------------------
create policy ledger_select_own on public.ledger_entries
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------------
-- payouts: владелец; admin
-- ---------------------------------------------------------------------------
create policy payouts_select_own on public.payouts
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------------
-- conversations, messages: только участники
-- ---------------------------------------------------------------------------
create policy conversations_select_participants on public.conversations
  for select to authenticated using (
    passenger_id = auth.uid() or driver_id = auth.uid() or public.is_admin()
  );

create policy messages_select_participants on public.messages
  for select to authenticated using (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.passenger_id = auth.uid() or c.driver_id = auth.uid())
    )
    or public.is_admin()
  );

-- ---------------------------------------------------------------------------
-- reviews: видимые — все; свои невидимые — автор
-- ---------------------------------------------------------------------------
create policy reviews_select on public.reviews
  for select to anon, authenticated using (
    is_visible or author_id = auth.uid() or public.is_admin()
  );

-- ---------------------------------------------------------------------------
-- reports: автор — свои; admin — все
-- ---------------------------------------------------------------------------
create policy reports_select on public.reports
  for select to authenticated using (reporter_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------------
-- contact_reveals, moderation_actions: только admin
-- ---------------------------------------------------------------------------
create policy contact_reveals_admin on public.contact_reveals
  for select to authenticated using (public.is_admin());

create policy moderation_actions_admin on public.moderation_actions
  for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------------------
-- notifications: владелец читает и отмечает прочитанным
-- ---------------------------------------------------------------------------
create policy notifications_select_own on public.notifications
  for select to authenticated using (user_id = auth.uid());

create policy notifications_update_own on public.notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- devices: владелец — полностью
-- ---------------------------------------------------------------------------
create policy devices_all_own on public.devices
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- events: читает admin; пишет RPC (включая anon-поиск)
-- ---------------------------------------------------------------------------
create policy events_admin on public.events
  for select to authenticated using (public.is_admin());
