# boleia-db

Бэкенд Boleia: схема Postgres, RLS, RPC, триггеры, cron, Edge Functions, тесты. Один источник
истины для web (Nuxt) и mobile (Flutter), отдельного API-сервера нет.

| Кому | Что читать |
| --- | --- |
| Клиенты (Flutter, Nuxt) | `docs/flutter-handoff.md`, контракт `docs/api.md`, типы `types/database.ts` |
| Бизнес-правила | `docs/spec.md` (ТЗ), решения по миграциям `docs/plans/` |
| Claude Code | `CLAUDE.md` |

## Запуск локально

Нужны Docker Desktop и Supabase CLI 3.x (`brew install supabase/tap/supabase`). `config.toml` уже в
репозитории, `supabase init` не нужен.

```bash
git clone <repo> boleia-db && cd boleia-db
supabase start           # первый раз качает образы
supabase db reset        # миграции + seed.sql
supabase test db         # pgTAP, все тесты
```

| Что | Где |
| --- | --- |
| API (для клиентов) | http://127.0.0.1:54321, с Android-эмулятора http://10.0.2.2:54321 |
| Studio | http://127.0.0.1:54323 |
| Postgres | postgresql://postgres:postgres@127.0.0.1:54322/postgres |
| Mailpit (письма в dev) | http://127.0.0.1:54324 |

Ключи - в выводе `supabase start` или `supabase status`. `psql` на хосте не обязателен:
`docker exec -i supabase_db_boleia-db psql -U postgres -d postgres`.

Edge Functions локально: `supabase functions serve` в отдельном терминале; `scripts/dev-vault.sh` после
каждого `db reset`, иначе cron не дозовётся до функций; сквозная проверка `scripts/edge-smoke.sh`.
Подробности - `supabase/functions/README.md`.

## Тестовые пользователи

Вход только по телефону с OTP. Для этих номеров SMS не уходит, код всегда `123456`; номер передаётся
без `+` (`signInWithOtp(phone: '244900000005')`).

| Телефон | Кто | Роль |
| --- | --- | --- |
| 244900000001 | Admin B. | admin (`app_metadata.role = admin` в JWT) |
| 244900000002 | João M. | водитель, verified, instant booking |
| 244900000003 | Teresa S. | водитель, verified, approval booking |
| 244900000004 | Pedro K. | водитель, не verified |
| 244900000005 | Ana R. | пассажир |
| 244900000099 | - | свободный номер для регистрации |

Seed: 35 мест, 14 маршрутов в `route_durations`, 20 опубликованных поездок на две недели вперёд.
Платежи идут через мок шлюза (`payments-mock`): оплата подтверждается сама через 5 секунд.

## Цикл разработки

```bash
# новый файл supabase/migrations/2026111000000N_<name>.sql, нумерация продолжается
supabase db reset                     # с нуля: миграции + seed
supabase test db                      # pgTAP из supabase/tests/
scripts/gen-types.sh                  # types/database.ts + docs/api.md, коммитить вместе с миграцией
scripts/deploy.sh <project-ref>       # в облако
```

Правила: `db reset` обязан проходить чисто; каждый RPC с деньгами или переходом статуса - с pgTAP-тестом;
в облаке схему руками не трогаем, только `db push`. План и решения каждой миграции - `docs/plans/`.

## Облако

Один общий проект на время разработки обоих клиентов; данные общие, перед релизом `scripts/wipe-data.sql`.
URL и ключи в репозитории не хранятся (клиентам передаются отдельно).

```bash
supabase login
scripts/deploy.sh <project-ref> --seed       # первый раз: link, миграции + seed, config, функции, секреты, Vault
scripts/deploy.sh <project-ref>              # дальше: без seed
scripts/edge-smoke.sh --cloud <project-ref>  # сквозная проверка
```

Ключи провайдеров (castbrick, FCM, шлюз) - в `supabase/functions/.env.cloud` (в `.gitignore`),
`deploy.sh` подхватит через `supabase secrets set --env-file`. Пока ключей нет, SMS и push пишутся в
лог функций, вход работает только с тестовых номеров.

## Структура

```
supabase/
  migrations/                   0001 схема, 0002 views, 0003 RLS, 0004 базовые RPC,
                                0005 брони и платежи, 0006 поездка и споры, 0007 scheduler,
                                0008 чат/отзывы/выплаты/верификация, 0009 поддержка Edge
  seed.sql                      места, маршруты, тестовые пользователи, поездки
  tests/                        pgTAP, один файл на миграцию
  functions/                    Edge Functions: payments-*, notify, send-sms, payments-mock; _shared/
  config.toml                   локальный конфиг, он же пушится в облако (`config push`)
scripts/                        deploy.sh, dev-vault.sh, edge-smoke.sh, gen-types.sh, gen-api-doc.py, wipe-data.sql
types/database.ts               supabase gen types
docs/
  spec.md                       ТЗ, источник истины
  api.md                        контракт для клиентов, генерируется из базы
  flutter-handoff.md            точка входа для Flutter
  gateway-contract.md           контракт платёжного шлюза; мок и адаптер написаны под него
  plans/                        план и решения по каждой миграции
CLAUDE.md                       контекст для Claude Code
```

## Статус

I0 и I1 по разделу 13 ТЗ закрыты: все RPC раздела 6 реализованы, cron работает, Edge Functions
задеплоены, сквозной сценарий проходит локально и в облаке. Дальше клиенты (I2 web, I3 Flutter),
затем I4: Telegram-бот модерации, реальные ключи castbrick и FCM, адаптер под реальный шлюз
(`functions/_shared/gateway.ts`).
