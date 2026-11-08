-- Boleia — seed для dev/staging. Выполняется после миграций при `supabase db reset`.
-- Координаты приблизительные (для сортировки и будущих карт), не для навигации.

-- ---------------------------------------------------------------------------
-- places
-- ---------------------------------------------------------------------------
insert into public.places (name, province, slug, kind, lat, lng, aliases) values
  -- Luanda
  ('Luanda',            'Luanda',        'luanda',             'city',     -8.8390, 13.2894, '{"Lda"}'),
  ('Viana',             'Luanda',        'viana',              'town',     -8.9043, 13.3701, '{}'),
  ('Cacuaco',           'Luanda',        'cacuaco',            'town',     -8.7767, 13.3661, '{}'),
  ('Kilamba',           'Luanda',        'kilamba',            'town',     -8.9977, 13.2706, '{"Centralidade do Kilamba"}'),
  ('Catete',            'Luanda',        'catete',             'town',     -9.1000, 13.6833, '{}'),
  ('Terminal Macon (Gamek)', 'Luanda',   'terminal-macon-gamek','landmark',-8.8890, 13.2220, '{"Gamek","Macon"}'),
  ('Aeroporto 4 de Fevereiro', 'Luanda', 'aeroporto-luanda',   'landmark', -8.8584, 13.2312, '{"LAD"}'),
  -- Bengo
  ('Caxito',            'Bengo',         'caxito',             'city',     -8.5783, 13.6642, '{}'),
  -- Cuanza Norte
  ('N''dalatando',      'Cuanza Norte',  'ndalatando',         'city',     -9.2967, 14.9117, '{"Ndalatando"}'),
  ('Dondo',             'Cuanza Norte',  'dondo',              'town',     -9.6850, 14.4300, '{}'),
  -- Cuanza Sul
  ('Sumbe',             'Cuanza Sul',    'sumbe',              'city',    -11.2061, 13.8436, '{}'),
  ('Porto Amboim',      'Cuanza Sul',    'porto-amboim',       'town',    -10.7300, 13.7500, '{}'),
  ('Gabela',            'Cuanza Sul',    'gabela',             'town',    -10.8500, 14.3833, '{}'),
  ('Waku Kungo',        'Cuanza Sul',    'waku-kungo',         'town',    -11.3500, 15.1167, '{"Uaco Cungo","Cela"}'),
  -- Benguela
  ('Benguela',          'Benguela',      'benguela',           'city',    -12.5763, 13.4055, '{}'),
  ('Lobito',            'Benguela',      'lobito',             'city',    -12.3644, 13.5361, '{}'),
  ('Catumbela',         'Benguela',      'catumbela',          'town',    -12.4300, 13.5470, '{}'),
  ('Aeroporto da Catumbela', 'Benguela', 'aeroporto-catumbela','landmark',-12.4792, 13.4869, '{"CBT"}'),
  ('Terminal Rodoviário de Benguela', 'Benguela', 'terminal-benguela', 'landmark', -12.5800, 13.4100, '{}'),
  -- Huambo
  ('Huambo',            'Huambo',        'huambo',             'city',    -12.7761, 15.7392, '{}'),
  ('Caála',             'Huambo',        'caala',              'town',    -12.8525, 15.5606, '{}'),
  -- Bié
  ('Cuito',             'Bié',           'cuito',              'city',    -12.3833, 16.9333, '{"Kuito"}'),
  -- Huíla
  ('Lubango',           'Huíla',         'lubango',            'city',    -14.9167, 13.4925, '{}'),
  ('Chibia',            'Huíla',         'chibia',             'town',    -15.1833, 13.6833, '{}'),
  -- Namibe
  ('Moçâmedes',         'Namibe',        'mocamedes',          'city',    -15.1961, 12.1522, '{"Namibe"}'),
  -- Cunene
  ('Ondjiva',           'Cunene',        'ondjiva',            'city',    -17.0667, 15.7333, '{}'),
  -- Malanje
  ('Malanje',           'Malanje',       'malanje',            'city',     -9.5402, 16.3410, '{"Malange"}'),
  -- Uíge
  ('Uíge',              'Uíge',          'uige',               'city',     -7.6087, 15.0613, '{}'),
  -- Zaire
  ('Soyo',              'Zaire',         'soyo',               'city',     -6.1349, 12.3689, '{}'),
  ('M''banza Kongo',    'Zaire',         'mbanza-kongo',       'city',     -6.2667, 14.2500, '{}'),
  -- Cabinda
  ('Cabinda',           'Cabinda',       'cabinda',            'city',     -5.5500, 12.2000, '{}'),
  -- Lunda Norte / Lunda Sul / Moxico / Cuando Cubango
  ('Dundo',             'Lunda Norte',   'dundo',              'city',     -7.3833, 20.8333, '{}'),
  ('Saurimo',           'Lunda Sul',     'saurimo',            'city',     -9.6608, 20.3917, '{}'),
  ('Luena',             'Moxico',        'luena',              'city',    -11.7833, 19.9167, '{}'),
  ('Menongue',          'Cuando Cubango','menongue',           'city',    -14.6585, 17.6910, '{}');

-- ---------------------------------------------------------------------------
-- route_durations — стартовые маршруты (ТЗ раздел 15), минуты и подсказка цены
-- ---------------------------------------------------------------------------
with r(o, d, minutes, hint) as (values
  ('luanda', 'benguela', 420, 7000),
  ('benguela', 'luanda', 420, 7000),
  ('luanda', 'lobito',   400, 7000),
  ('lobito', 'luanda',   400, 7000),
  ('luanda', 'huambo',   540, 8000),
  ('huambo', 'luanda',   540, 8000),
  ('luanda', 'sumbe',    300, 5000),
  ('sumbe',  'luanda',   300, 5000),
  ('luanda', 'lubango',  660, 10000),
  ('lubango','luanda',   660, 10000),
  ('benguela','huambo',  240, 4000),
  ('huambo', 'benguela', 240, 4000),
  ('benguela','lubango', 330, 5000),
  ('lubango','benguela', 330, 5000)
)
insert into public.route_durations (origin_place_id, destination_place_id, minutes, price_hint_kz)
select po.id, pd.id, r.minutes, r.hint
from r
join public.places po on po.slug = r.o
join public.places pd on pd.slug = r.d;

-- ---------------------------------------------------------------------------
-- Тестовые пользователи (auth.users → триггер создаёт profiles)
-- Телефоны совпадают с test_otp в config.toml: код 123456
-- ---------------------------------------------------------------------------
insert into auth.users (
  id, instance_id, aud, role, phone, phone_confirmed_at, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token
) values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '244900000001', now(), '',
   '{"provider":"phone","providers":["phone"],"role":"admin"}', '{"display_name":"Admin B."}', now(), now(), '', '', '', '', '', '', '', ''),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '244900000002', now(), '',
   '{"provider":"phone","providers":["phone"]}', '{"display_name":"João M."}', now(), now(), '', '', '', '', '', '', '', ''),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '244900000003', now(), '',
   '{"provider":"phone","providers":["phone"]}', '{"display_name":"Teresa S."}', now(), now(), '', '', '', '', '', '', '', ''),
  ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '244900000004', now(), '',
   '{"provider":"phone","providers":["phone"]}', '{"display_name":"Pedro K."}', now(), now(), '', '', '', '', '', '', '', ''),
  ('55555555-5555-5555-5555-555555555555', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '244900000005', now(), '',
   '{"provider":"phone","providers":["phone"]}', '{"display_name":"Ana R."}', now(), now(), '', '', '', '', '', '', '', '');

-- профили: водители João, Teresa, Pedro; пассажир Ana; админ
update public.profiles set
  avatar_url = 'https://api.dicebear.com/9.x/initials/svg?seed=' || display_name,
  birth_year = 1990,
  payout_method = case
    when id in ('22222222-2222-2222-2222-222222222222','33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444444')
    then jsonb_build_object('type', 'mcx_express', 'phone', phone) end,
  is_admin = (id = '11111111-1111-1111-1111-111111111111'),
  driver_status = case
    when id = '22222222-2222-2222-2222-222222222222' then 'verified'::driver_status
    when id = '33333333-3333-3333-3333-333333333333' then 'verified'::driver_status
    else 'none'::driver_status end,
  driver_verified_at = case when id in ('22222222-2222-2222-2222-222222222222','33333333-3333-3333-3333-333333333333') then now() end,
  trips_driven = case id
    when '22222222-2222-2222-2222-222222222222' then 14
    when '33333333-3333-3333-3333-333333333333' then 6
    else 0 end,
  rating_avg = case id
    when '22222222-2222-2222-2222-222222222222' then 4.80
    when '33333333-3333-3333-3333-333333333333' then 4.50
    else 0 end,
  rating_count = case id
    when '22222222-2222-2222-2222-222222222222' then 12
    when '33333333-3333-3333-3333-333333333333' then 5
    else 0 end,
  cancels_total = case id when '44444444-4444-4444-4444-444444444444' then 1 else 0 end;

-- машины
insert into public.vehicles (id, owner_id, make, model, color, year, plate, seats_total, verified) values
  ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Toyota',  'Corolla', 'branco',   2018, 'LD-12-34-AB', 4, true),
  ('aaaa0000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'Hyundai', 'Tucson',  'cinzento', 2020, 'LD-56-78-CD', 4, true),
  ('aaaa0000-0000-0000-0000-000000000003', '44444444-4444-4444-4444-444444444444', 'Toyota',  'Hilux',   'preto',    2016, 'BG-90-12-EF', 3, false);

-- ---------------------------------------------------------------------------
-- 20 поездок на ближайшие две недели (напрямую в trips, минуя publish_trip)
-- ---------------------------------------------------------------------------
with drivers(driver_id, vehicle_id, mode) as (values
  ('22222222-2222-2222-2222-222222222222'::uuid, 'aaaa0000-0000-0000-0000-000000000001'::uuid, 'instant'::booking_mode),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'aaaa0000-0000-0000-0000-000000000002'::uuid, 'approval'::booking_mode),
  ('44444444-4444-4444-4444-444444444444'::uuid, 'aaaa0000-0000-0000-0000-000000000003'::uuid, 'instant'::booking_mode)
),
routes(n, o, d, price, od, dd) as (values
  (1,  'luanda',   'benguela', 7000,  'Terminal Macon, Gamek',      'Terminal Rodoviário'),
  (2,  'benguela', 'luanda',   7000,  'Terminal Rodoviário',        'Gamek'),
  (3,  'luanda',   'lobito',   7000,  'Kilamba, entrada principal', 'Praça do Lobito'),
  (4,  'lobito',   'luanda',   7000,  'Praça do Lobito',            'Kilamba'),
  (5,  'luanda',   'huambo',   8000,  'Viana, Estalagem',           'Largo da Cidade Alta'),
  (6,  'huambo',   'luanda',   8000,  'Largo da Cidade Alta',       'Viana'),
  (7,  'luanda',   'sumbe',    5000,  'Gamek',                      'Centro'),
  (8,  'sumbe',    'luanda',   5000,  'Centro',                     'Gamek'),
  (9,  'luanda',   'lubango',  10000, 'Gamek',                      'Praça da Independência'),
  (10, 'benguela', 'huambo',   4000,  'Terminal Rodoviário',        'Largo da Cidade Alta')
),
series as (
  select r.*, g as day_offset,
         row_number() over (order by r.n, g) as rn
  from routes r cross join generate_series(1, 2) as g
)
insert into public.trips (
  driver_id, vehicle_id, origin_place_id, destination_place_id, origin_detail, destination_detail,
  departure_at, seats_offered, seats_available, price_per_seat_kz, booking_mode, luggage, max_two_in_back,
  status, published_at
)
select
  dr.driver_id, dr.vehicle_id, po.id, pd.id, s.od, s.dd,
  date_trunc('day', now()) + (s.n + s.day_offset * 3) * interval '1 day' + interval '6 hours' + (s.rn % 3) * interval '1 hour',
  3, 3, s.price, dr.mode, 'medium', (s.rn % 2 = 0),
  'published', now()
from series s
join public.places po on po.slug = s.o
join public.places pd on pd.slug = s.d
join lateral (
  select * from drivers offset (s.rn % 3) limit 1
) dr on true;

refresh materialized view public.route_stats;
