-- Boleia — RPC (ТЗ раздел 6)
--
-- I0: рабочие — search_trips, upsert_profile, upsert_vehicle, publish_trip,
--     register_device, mark_notifications_read.
--     Остальные — заглушки с окончательными сигнатурами, бросают BOLEIA_NOT_IMPLEMENTED.
--
-- Все функции security definer; auth.uid() проверяется внутри.
-- Ошибки: raise_boleia('<CODE>') → message 'BOLEIA_<CODE>', SQLSTATE P0001.

-- ---------------------------------------------------------------------------
-- Внутренние хелперы
-- ---------------------------------------------------------------------------
create or replace function public.current_profile()
returns public.profiles language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  if auth.uid() is null then perform public.raise_boleia('NOT_AUTHENTICATED'); end if;
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then perform public.raise_boleia('PROFILE_NOT_FOUND'); end if;
  if p.status in ('suspended', 'banned') then perform public.raise_boleia('PROFILE_RESTRICTED'); end if;
  return p;
end $$;

-- fee = max(10% × total, 1000), один раз на бронь (ТЗ раздел 10)
create or replace function public.calc_fee_kz(price_total_kz integer)
returns integer language sql immutable as $$
  select greatest((price_total_kz * 10 + 50) / 100, 1000)
$$;

create or replace function public.log_event(name text, props jsonb default '{}', plat platform default null)
returns void language sql security definer set search_path = public as $$
  insert into public.events (user_id, name, props, platform) values (auth.uid(), name, props, plat)
$$;

-- ---------------------------------------------------------------------------
-- search_trips — все, включая анонимов
-- ---------------------------------------------------------------------------
create or replace function public.search_trips(
  origin_slug       text,
  destination_slug  text,
  travel_date       date,
  seats             integer default 1,
  cursor_departure  timestamptz default null,
  cursor_id         uuid default null,
  page_size         integer default 20
)
returns setof public.trips_public
-- volatile: пишет событие в events; клиенты вызывают через POST (supabase.rpc)
language plpgsql security definer set search_path = public as $$
begin
  if seats is null or seats < 1 or seats > 3 then perform public.raise_boleia('SEATS_INVALID'); end if;
  page_size := least(coalesce(page_size, 20), 50);

  perform public.log_event('search', jsonb_build_object(
    'origin', origin_slug, 'destination', destination_slug, 'date', travel_date, 'seats', seats));

  return query
    select tp.*
    from public.trips_public tp
    where tp.origin_slug = search_trips.origin_slug
      and tp.destination_slug = search_trips.destination_slug
      and tp.departure_at >= greatest((travel_date - 1)::timestamptz, now())
      and tp.departure_at <  (travel_date + 2)::timestamptz
      and tp.seats_available >= seats
      and (cursor_departure is null
           or (tp.departure_at, tp.id) > (cursor_departure, cursor_id))
    order by tp.departure_at, tp.driver_verified desc, tp.id
    limit page_size;
end $$;

-- ---------------------------------------------------------------------------
-- upsert_profile — имя, bio, год рождения, chat_level, payout_method, locale
-- ---------------------------------------------------------------------------
create or replace function public.upsert_profile(payload jsonb)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  p  public.profiles := public.current_profile();
  pm jsonb := payload -> 'payout_method';
begin
  if payload ? 'display_name' then
    if char_length(trim(payload ->> 'display_name')) not between 2 and 40 then
      perform public.raise_boleia('NAME_INVALID');
    end if;
  end if;

  if pm is not null and pm <> 'null'::jsonb then
    if not (
      (pm ->> 'type' = 'mcx_express' and (pm ->> 'phone') ~ '^\+244\d{9}$')
      or (pm ->> 'type' = 'iban' and char_length(pm ->> 'iban') = 25 and (pm ->> 'bank') is not null)
    ) then
      perform public.raise_boleia('PAYOUT_METHOD_INVALID');
    end if;
  end if;

  update public.profiles set
    display_name  = coalesce(nullif(trim(payload ->> 'display_name'), ''), display_name),
    avatar_url    = case when payload ? 'avatar_url'   then payload ->> 'avatar_url'              else avatar_url end,
    bio           = case when payload ? 'bio'          then payload ->> 'bio'                     else bio end,
    birth_year    = case when payload ? 'birth_year'   then (payload ->> 'birth_year')::smallint  else birth_year end,
    chat_level    = case when payload ? 'chat_level'   then (payload ->> 'chat_level')::chat_level else chat_level end,
    payout_method = case when payload ? 'payout_method' then pm                                   else payout_method end,
    locale        = coalesce(payload ->> 'locale', locale),
    last_seen_at  = now()
  where id = p.id
  returning * into p;

  return p;
end $$;

-- ---------------------------------------------------------------------------
-- upsert_vehicle — макс. 3 активные; смена номера сбрасывает verified
-- ---------------------------------------------------------------------------
create or replace function public.upsert_vehicle(payload jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  p    public.profiles := public.current_profile();
  v_id uuid := (payload ->> 'id')::uuid;
  v    public.vehicles;
begin
  if v_id is not null then
    select * into v from public.vehicles where id = v_id and owner_id = p.id;
    if v.id is null then perform public.raise_boleia('VEHICLE_NOT_FOUND'); end if;

    update public.vehicles set
      make        = coalesce(payload ->> 'make', make),
      model       = coalesce(payload ->> 'model', model),
      color       = coalesce(payload ->> 'color', color),
      year        = coalesce((payload ->> 'year')::smallint, year),
      plate       = coalesce(payload ->> 'plate', plate),
      seats_total = coalesce((payload ->> 'seats_total')::smallint, seats_total),
      photo_url   = coalesce(payload ->> 'photo_url', photo_url),
      status      = coalesce((payload ->> 'status')::vehicle_status, status),
      verified    = case when payload ? 'plate' and payload ->> 'plate' is distinct from plate then false else verified end
    where id = v_id;
    return v_id;
  end if;

  if (select count(*) from public.vehicles where owner_id = p.id and status = 'active') >= 3 then
    perform public.raise_boleia('VEHICLE_LIMIT_REACHED');
  end if;
  if payload ->> 'make' is null or payload ->> 'model' is null or (payload ->> 'seats_total') is null then
    perform public.raise_boleia('VEHICLE_INCOMPLETE');
  end if;

  insert into public.vehicles (owner_id, make, model, color, year, plate, seats_total, photo_url)
  values (
    p.id,
    payload ->> 'make', payload ->> 'model', payload ->> 'color',
    (payload ->> 'year')::smallint, payload ->> 'plate',
    (payload ->> 'seats_total')::smallint, payload ->> 'photo_url'
  )
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- publish_trip — валидация и лимиты (ТЗ разделы 5, 6, 8)
-- ---------------------------------------------------------------------------
create or replace function public.publish_trip(payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p            public.profiles := public.current_profile();
  v            public.vehicles;
  v_origin     uuid := (payload ->> 'origin_place_id')::uuid;
  v_dest       uuid := (payload ->> 'destination_place_id')::uuid;
  v_dep        timestamptz := (payload ->> 'departure_at')::timestamptz;
  v_seats      smallint := (payload ->> 'seats_offered')::smallint;
  v_price      integer := (payload ->> 'price_per_seat_kz')::integer;
  v_mode       booking_mode := coalesce((payload ->> 'booking_mode')::booking_mode, 'instant');
  v_hint       integer;
  v_id         uuid;
begin
  -- профиль готов?
  if p.avatar_url is null or p.payout_method is null or char_length(p.display_name) < 2 then
    perform public.raise_boleia('PROFILE_INCOMPLETE');
  end if;

  -- машина
  select * into v from public.vehicles
  where id = (payload ->> 'vehicle_id')::uuid and owner_id = p.id and status = 'active';
  if v.id is null then perform public.raise_boleia('VEHICLE_NOT_FOUND'); end if;

  -- маршрут
  if v_origin is null or v_dest is null then perform public.raise_boleia('PLACE_INVALID'); end if;
  if v_origin = v_dest then perform public.raise_boleia('SAME_PLACE'); end if;
  if (select count(*) from public.places where id in (v_origin, v_dest) and is_active) <> 2 then
    perform public.raise_boleia('PLACE_INVALID');
  end if;

  -- время, места, цена
  if v_dep is null or v_dep < now() + interval '2 hours' then perform public.raise_boleia('DEPARTURE_TOO_SOON'); end if;
  if v_seats is null or v_seats < 1 or v_seats > least(4, v.seats_total) then perform public.raise_boleia('SEATS_INVALID'); end if;
  if v_price is null or v_price not between 500 and 100000 then perform public.raise_boleia('PRICE_INVALID'); end if;

  -- лимиты: 5 активных поездок, одинаково для всех
  if (select count(*) from public.trips where driver_id = p.id and status in ('published', 'full')) >= 5 then
    perform public.raise_boleia('DRIVER_LIMIT_REACHED');
  end if;

  -- дубль ±2 ч
  if exists (
    select 1 from public.trips
    where driver_id = p.id and status in ('published', 'full')
      and departure_at between v_dep - interval '2 hours' and v_dep + interval '2 hours'
  ) then
    perform public.raise_boleia('TRIP_DUPLICATE');
  end if;

  insert into public.trips (
    driver_id, vehicle_id, origin_place_id, destination_place_id,
    origin_detail, destination_detail, departure_at,
    seats_offered, seats_available, price_per_seat_kz, booking_mode,
    luggage, allows_smoking, allows_pets, max_two_in_back, notes,
    status, published_at
  ) values (
    p.id, v.id, v_origin, v_dest,
    payload ->> 'origin_detail', payload ->> 'destination_detail', v_dep,
    v_seats, v_seats, v_price, v_mode,
    coalesce((payload ->> 'luggage')::luggage_size, 'medium'),
    coalesce((payload ->> 'allows_smoking')::boolean, false),
    coalesce((payload ->> 'allows_pets')::boolean, false),
    coalesce((payload ->> 'max_two_in_back')::boolean, false),
    payload ->> 'notes',
    'published', now()
  )
  returning id into v_id;

  select price_hint_kz into v_hint from public.route_durations
  where origin_place_id = v_origin and destination_place_id = v_dest;

  perform public.log_event('trip_published', jsonb_build_object('trip_id', v_id, 'price', v_price));

  return jsonb_build_object('id', v_id, 'price_hint_kz', v_hint);
end $$;

-- подсказка цены для экрана публикации
create or replace function public.price_hint(origin_place_id uuid, destination_place_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('price_hint_kz', rd.price_hint_kz, 'minutes', rd.minutes)
  from public.route_durations rd
  where rd.origin_place_id = price_hint.origin_place_id
    and rd.destination_place_id = price_hint.destination_place_id
$$;

-- ---------------------------------------------------------------------------
-- register_device, mark_notifications_read — тривиальные, рабочие
-- ---------------------------------------------------------------------------
create or replace function public.register_device(device_platform platform, token text, app_version text default null)
returns void language plpgsql security definer set search_path = public as $$
declare p public.profiles := public.current_profile();
begin
  insert into public.devices (user_id, platform, push_token, app_version)
  values (p.id, device_platform, token, app_version)
  on conflict (push_token) do update
    set user_id = excluded.user_id, platform = excluded.platform,
        app_version = excluded.app_version, last_seen_at = now();
end $$;

create or replace function public.mark_notifications_read(ids uuid[])
returns void language sql security definer set search_path = public as $$
  update public.notifications set read_at = now(), status = 'read'
  where user_id = auth.uid() and id = any(ids) and read_at is null
$$;

-- ---------------------------------------------------------------------------
-- Заглушки I1 — сигнатуры окончательные, тела заменяются в следующей итерации
-- ---------------------------------------------------------------------------
create or replace function public.create_return_trip(trip_id uuid, departure_at timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.update_trip(trip_id uuid, payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.confirm_trip_intent(trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.cancel_trip(trip_id uuid, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.request_booking(trip_id uuid, seats integer, message text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.retry_payment(booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

-- только service_role (Edge payments-webhook)
create or replace function public.confirm_payment(
  payment_id uuid, provider_ref text, new_status text, payer_phone text, raw jsonb default '{}'
)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.respond_booking(booking_id uuid, accept boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.cancel_booking(booking_id uuid, reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.enter_pin(booking_id uuid, pin text)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.confirm_trip(booking_id uuid, happened boolean)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.mark_no_show(booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.resolve_dispute(booking_id uuid, outcome text, amount_kz integer default null)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.request_payout(amount_kz integer)
returns uuid language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.mark_payout(payout_id uuid, new_status text, ref text default null)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.send_message(body text, conversation_id uuid default null, trip_id uuid default null)
returns bigint language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.mark_read(conversation_id uuid, up_to_message_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.reveal_contact(booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.submit_review(booking_id uuid, rating integer, tags text[] default '{}', comment text default null)
returns uuid language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.report_user(
  target_id uuid, reason report_reason, details text default null,
  trip_id uuid default null, booking_id uuid default null, message_id bigint default null
)
returns uuid language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.delete_me()
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

create or replace function public.submit_verification(vehicle_id uuid, doc_urls jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); return null; end $$;

create or replace function public.review_verification(verification_id uuid, approve boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin perform public.raise_boleia('NOT_IMPLEMENTED'); end $$;

-- ---------------------------------------------------------------------------
-- Права на вызов
-- ---------------------------------------------------------------------------
-- по умолчанию всё закрыто
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- is_admin() используется в RLS-политиках и вычисляется от имени запрашивающего — execute нужен всем
grant execute on function public.is_admin() to anon, authenticated;

-- анонимам: поиск и подсказка цены
grant execute on function public.search_trips(text, text, date, integer, timestamptz, uuid, integer) to anon, authenticated;
grant execute on function public.price_hint(uuid, uuid) to anon, authenticated;

-- авторизованным: всё клиентское
grant execute on function
  public.upsert_profile(jsonb),
  public.upsert_vehicle(jsonb),
  public.publish_trip(jsonb),
  public.register_device(platform, text, text),
  public.mark_notifications_read(uuid[]),
  public.create_return_trip(uuid, timestamptz),
  public.update_trip(uuid, jsonb),
  public.confirm_trip_intent(uuid),
  public.cancel_trip(uuid, text),
  public.request_booking(uuid, integer, text),
  public.retry_payment(uuid),
  public.respond_booking(uuid, boolean, text),
  public.cancel_booking(uuid, text),
  public.enter_pin(uuid, text),
  public.confirm_trip(uuid, boolean),
  public.mark_no_show(uuid),
  public.resolve_dispute(uuid, text, integer),
  public.request_payout(integer),
  public.mark_payout(uuid, text, text),
  public.send_message(text, uuid, uuid),
  public.mark_read(uuid, bigint),
  public.reveal_contact(uuid),
  public.submit_review(uuid, integer, text[], text),
  public.report_user(uuid, report_reason, text, uuid, uuid, bigint),
  public.delete_me(),
  public.submit_verification(uuid, jsonb),
  public.review_verification(uuid, boolean, text)
to authenticated;

-- confirm_payment — только service_role (вебхук); authenticated не получает execute
grant execute on function public.confirm_payment(uuid, text, text, text, jsonb) to service_role;

-- триггерные и внутренние функции клиентам не нужны (execute уже отозван)
