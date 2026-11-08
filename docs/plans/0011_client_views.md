# План миграции 0011_client_views

ТЗ: разделы 4 (`profiles`, `reviews`), 6 (`publish_trip`, `upsert_profile`), 12 (экраны брони, отзывов,
SEO), 15 (галочка 18+, точки посадки). Запрос: `boleia-web`, список замечаний к контракту перед шагами 5-12.

## Что сделано

| # | Запрос web | Решение |
| --- | --- | --- |
| 1 | `my_bookings` без причины отказа платежа | добавлен `cancel_reason` в конец view |
| 2 | `my_bookings` без данных пассажира для водителя | добавлены `message`, `passenger_name`, `passenger_avatar_url`, `passenger_rating_avg`, `passenger_trips_ridden`, `passenger_cancels_total` |
| 3 | отзывы с автором для `/perfil/<id>/avaliacoes` | view `reviews_public` (только `is_visible`, авторы не `banned`/`deleted`), grant anon и authenticated |
| 4 | мок шлюза только `push` | `simulate: qr` даёт `qr_payload`, `redirect` даёт `url`; оплата проходит как обычно |
| 5 | `publish_trip` принимал landmark как город | `origin`/`destination` только `city`/`town`, иначе `PLACE_INVALID`; landmark в `origin_detail` |
| 6 | `route_stats` только от поездок | matview строится от пар `route_durations` плюс пары с поездками; добавлены `minutes`, `price_hint_kz` |
| 7 | согласие с правилами и 18+ | колонки `profiles.terms_accepted_at`, `adult_confirmed_at`; ключи `terms_accepted`, `adult_confirmed` в `upsert_profile`, фиксируются один раз и через RPC не снимаются. Выбрано хранение в `profiles`, а не в `auth.users.user_metadata`: видно админке, переживает `wipe-data`, не зависит от клиента |
| 13 | формы jsonb в контракте | раздел "Формы jsonb" в `docs/api.md`: аргументы, возвраты, значения `rule` и `cancel_reason` |
| 14 | `route_stats` "Читают: -" | генератор берёт права через `has_table_privilege`, у materialized view они теперь видны |
| 15 | `simulate` в `api.md` | полный список режимов мока |
| 16 | пометка про две стороны `my_bookings` | описания всех views в генераторе (`VIEW_DOC`) |

Не потребовалось: 12 (`platform = web` уже в enum).

## Выяснилось по ходу

- `reviews_public` фильтрует авторов со статусом `banned`/`deleted`: их отзывы остаются в базе
  (целостность рейтинга), но наружу не показываются.
- Пересборка `route_stats` через `drop` + `create`: у materialized view нельзя добавить колонки иначе.
  Уникальный индекс и grant пересозданы, `refresh concurrently` в cron работает как раньше.
