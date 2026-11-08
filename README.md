# boleia-db

Бэкенд Boleia: схема Postgres, RLS, RPC, триггеры, Edge Functions, тесты. Один источник истины для web (Nuxt) и mobile (Flutter).

ТЗ — `docs/spec.md`. Контекст для Claude Code — `CLAUDE.md`.

Для Flutter-клиента: `docs/flutter-handoff.md`, контракт `docs/api.md`, типы `types/database.ts`.

## Первый запуск

Нужны Docker Desktop и Supabase CLI (`brew install supabase/tap/supabase` или `npm i -g supabase`).

```bash
git clone <repo> boleia-db && cd boleia-db
supabase init            # создаст supabase/config.toml; миграции и seed уже лежат рядом
# → примените правки из раздела «config.toml» ниже
supabase start           # первый раз качает образы, 3–5 минут
supabase db reset        # применяет миграции + seed.sql
supabase test db         # pgTAP
```

После `supabase start` в консоли — URL и ключи:

| Что | Где |
|---|---|
| API (для Nuxt/Flutter) | http://127.0.0.1:54321 |
| Studio (дашборд) | http://127.0.0.1:54323 |
| Postgres | postgresql://postgres:postgres@127.0.0.1:54322/postgres |
| Inbucket (ловит SMS/email в dev) | http://127.0.0.1:54324 |

С Android-эмулятора API доступен как `http://10.0.2.2:54321`.

## config.toml — что поменять после `supabase init`

```toml
[db]
major_version = 15          # или 17 — что предложит CLI; схема работает на обоих

[auth]
enable_signup = true

[auth.sms]
enable_signup = true
enable_confirmations = true

# тестовые номера: OTP не отправляется, код всегда 123456
[auth.sms.test_otp]
"244900000001" = "123456"
"244900000002" = "123456"
"244900000003" = "123456"
"244900000004" = "123456"
"244900000005" = "123456"
"244900000099" = "123456"

# CLI 3.x отключает вход по телефону без SMS-провайдера; заглушка, test_otp до неё не доходит
[auth.sms.twilio]
enabled = true
account_sid = "local-dev"
message_service_sid = "local-dev"
auth_token = "local-dev"

[realtime]
enabled = true

[storage]
enabled = true
file_size_limit = "5MiB"
```

CLI 3.x: если в сгенерированном `config.toml` есть секция `[inbucket]`, переименуйте её в `[local_smtp]`, иначе `supabase status` и `start` падают. Если `supabase start` уже делали старой версией CLI, перед первым стартом новой выполните `supabase stop --no-backup`: старый том Postgres не совместим с новым образом (ошибка "collation version mismatch").

Пользователи из `seed.sql` имеют те же номера, так что вход в dev — любой из них + `123456`.

## Тестовые данные (seed)

| Телефон | Кто | Роль |
|---|---|---|
| +244900000001 | Admin B. | admin (`app_metadata.role = admin`) |
| +244900000002 | João M. | водитель, verified, instant booking |
| +244900000003 | Teresa S. | водитель, verified, approval booking |
| +244900000004 | Pedro K. | водитель, не verified, 1 отмена |
| +244900000005 | Ana R. | пассажир |

35 мест, 14 маршрутов в `route_durations`, 20 опубликованных поездок на ближайшие две недели.

## Цикл разработки

```bash
supabase migration new <что_меняем>   # новый файл в supabase/migrations/
# пишем SQL
supabase db reset                     # с нуля: миграции + seed
supabase test db                      # pgTAP из supabase/tests/
scripts/gen-types.sh                  # types/database.ts + docs/api.md, коммитить вместе с миграцией
```

Правила: одна миграция = один PR; `db reset` обязан проходить чисто; каждый RPC с деньгами или переходом статуса — с pgTAP-тестом; в облаке схему руками не трогаем, только `supabase db push`.

## Структура

```
supabase/
  migrations/
    20261110000001_schema.sql   enum'ы, таблицы, триггеры-инварианты
    20261110000002_views.sql    trips_public, profiles_public, my_*, driver_wallet, route_stats
    20261110000003_rls.sql      политики и grants
    20261110000004_rpc.sql      RPC: рабочие + заглушки I1
    20261110000005_booking_core.sql  брони и платежи: request/retry/confirm/respond/cancel, ledger
    20261110000006_trip_lifecycle.sql  PIN, подтверждение, no-show, споры, отмена поездки, update/return
    20261110000007_scheduler.sql  run_scheduler(as_of): протухания, выезд, напоминания, PIN, автозавершение, чистка, сверка; pg_cron
    20261110000008_chat_payouts_misc.sql  чат и маскирование, отзывы, жалобы, выплаты, верификация, delete_me, Storage
    20261110000009_edge_support.sql  сервисные RPC для Edge, Auth hooks (pg-functions), edge_call через pg_net + Vault
  seed.sql
  tests/                        pgTAP
  functions/                    Edge Functions: payments-*, notify, send-sms, payments-mock; _shared/
scripts/                        dev-vault.sh, edge-smoke.sh, gen-types.sh (+ gen-api-doc.py), wipe-data.sql
types/database.ts               supabase gen types, коммитится вместе с миграцией
docs/api.md                     контракт для клиентов, генерируется из базы
docs/flutter-handoff.md         точка входа для Manuel
docs/gateway-contract.md        контракт шлюза, под него написан мок и адаптер
docs/spec.md                    ТЗ
CLAUDE.md                       контекст для Claude Code
```

## Что уже работает (I0)

- Полная схема, enum'ы, индексы, инварианты: `seats_available` пересчитывается триггером, `ledger_entries` insert-only, `balance_kz` — кэш суммы ledger, рейтинг пересчитывается по отзывам, профиль создаётся при регистрации.
- RLS: клиенты пишут только через RPC; `profiles` — column-level update своих полей; `payments.raw_*` не отдаются.
- RPC: `search_trips` (анонимам тоже), `upsert_profile`, `upsert_vehicle`, `publish_trip`, `price_hint`, `register_device`, `mark_notifications_read`.
- Остальные RPC объявлены с окончательными сигнатурами и бросают `BOLEIA_NOT_IMPLEMENTED`.

## I1, шаг 1: брони и платежи (0005)

`request_booking`, `retry_payment`, `confirm_payment` (service role), `respond_booking`, `cancel_booking`, `cancel_quote`; ledger-операции `payment` / `refund` / `release` / `forfeit` через единую `ledger_post` с проверкой баланса; уведомления и системные сообщения чата. План и решения: `docs/plans/0005_booking_core.md`.

## I1, шаг 2: жизненный цикл поездки (0006)

`enter_pin`, `confirm_trip`, `mark_no_show`, `resolve_dispute`, `confirm_trip_intent`, `cancel_trip`, `create_return_trip`, `update_trip`; финализация `complete_booking` / `settle_trip` для RPC и cron. План и решения: `docs/plans/0006_trip_lifecycle.md`.

## I1, шаг 3: scheduler (0007)

`run_scheduler(as_of)` в `pg_cron` каждые 5 минут: 14 шагов по таблице cron раздела 6, каждый в своём блоке ошибок, журнал в `scheduler_jobs`. Тихие часы в `notify()`. Очередь возвратов для Edge: view `pending_refunds`. План и решения: `docs/plans/0007_scheduler.md`.

## I1, шаг 4: чат, выплаты, остальное (0008)

`send_message`, `mark_read`, `reveal_contact`, `submit_review`, `report_user`, `request_payout`, `mark_payout`, `submit_verification`, `review_verification`, `delete_me`; триггер маскирования с автожалобой `cash_offer`; бакеты `avatars`, `vehicles`, `verifications`. После 0008 все RPC раздела 6 ТЗ имеют тела. План и решения: `docs/plans/0008_chat_payouts_misc.md`.

## I1, шаг 5: Edge Functions (0009 + functions/)

`payments-init`, `payments-webhook`, `payments-status`, `payments-refund`, `payments-mock`, `notify`, `send-sms`; сервисные RPC `payment_initiated`, `payment_refund_result`, `notification_delivered`; Auth hooks как Postgres-функции; `edge_call` через `pg_net` с ключом в Vault. Сквозная проверка: `supabase functions serve` в одном терминале, `scripts/edge-smoke.sh` в другом. План и решения: `docs/plans/0009_edge_functions.md`, контракт шлюза: `docs/gateway-contract.md`.

Локально cron тикает в контейнере базы; вручную: `select public.run_scheduler();` или с подменой времени `select public.run_scheduler(now() + interval '1 day');`.

## Что дальше

I1 закрыт. Следующие итерации по разделу 13 ТЗ: клиенты (web на Nuxt, Flutter), затем I4 — Telegram-бот модерации, реальные ключи castbrick/FCM и договор со шлюзом (адаптер в `functions/_shared/gateway.ts`).

## Облако

```bash
supabase login
scripts/deploy.sh <project-ref> --seed     # link, db push (+seed), config push, functions deploy, secrets, Vault
scripts/edge-smoke.sh --cloud <project-ref>
```

Реальные ключи провайдеров - в `supabase/functions/.env.cloud` (в .gitignore), `deploy.sh` подхватит через `supabase secrets set --env-file`. На время разработки один общий проект для web и Flutter; перед релизом `scripts/wipe-data.sql`, потом отдельные staging и prod. Отдельная организация от Ambo.
