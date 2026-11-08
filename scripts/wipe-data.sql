-- Чистка данных разработки перед релизом. Оставляет справочники (places, route_durations),
-- расписание pg_cron и секреты Vault. Удаляет всех пользователей вместе с auth.users.
-- Запуск: psql ... -v ON_ERROR_STOP=1 -f scripts/wipe-data.sql (локально через docker exec,
-- в облаке через SQL editor или supabase db query). Необратимо.

begin;

-- ledger insert-only: на время чистки триггер снимается и возвращается
alter table public.ledger_entries disable trigger ledger_no_update;

truncate table
  public.events,
  public.notifications,
  public.devices,
  public.contact_reveals,
  public.moderation_actions,
  public.reports,
  public.reviews,
  public.messages,
  public.conversations,
  public.ledger_entries,
  public.payouts,
  public.payments,
  public.bookings,
  public.trip_stops,
  public.trips,
  public.driver_verifications,
  public.vehicles,
  public.banned_phones,
  public.scheduler_jobs
restart identity cascade;

alter table public.ledger_entries enable trigger ledger_no_update;

-- профили удаляются каскадом вместе с auth.users
delete from auth.users;

-- Storage запрещает delete из storage.objects: файлы бакетов avatars, vehicles, verifications
-- удалить через dashboard (Storage -> bucket -> select all -> delete) или Storage API.

refresh materialized view public.route_stats;

do $$
begin
  assert (select count(*) from public.profiles) = 0, 'profiles not empty';
  assert (select count(*) from public.ledger_entries) = 0, 'ledger not empty';
  assert (select count(*) from public.places) > 0, 'places must stay';
  assert (select count(*) from public.route_durations) > 0, 'route_durations must stay';
end $$;

commit;
