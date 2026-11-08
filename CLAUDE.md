# Boleia — контекст проекта для Claude Code

## Что это

Boleia — сервис междугородних попуток в Анголе (аналог BlaBlaCar) с онлайн-оплатой через Multicaixa Express. Пассажир бронирует место и платит сразу, деньги лежат у платформы до подтверждения поездки, водитель получает их на баланс и выводит по заявке. Общение — только в чате внутри приложения, контакты маскируются до дня поездки. Наличных и внешних мессенджеров нет принципиально.

Язык интерфейса — pt-AO. Валюта — AOA (кванзы), целые числа. Время — timestamptz в UTC, показ в Africa/Luanda.

**Полное ТЗ — `docs/spec.md`. Это источник истины.** Перед любым изменением схемы, RPC или бизнес-правила — найди соответствующий раздел там. Если ТЗ и код расходятся — прав ТЗ, если ТЗ молчит — спроси, не придумывай бизнес-правило сам.

## Этот репозиторий

`boleia-db` — бэкенд целиком: миграции Postgres, RLS, RPC, триггеры, cron, Edge Functions, pgTAP. Клиенты (`boleia-web` на Nuxt, `boleia-app` на Flutter) ходят сюда через Supabase SDK. Контракт между всеми клиентами = схема Postgres: views для чтения, RPC для записи, enum'ы как типы.

Команда — два человека, part-time. Evgenii — этот репозиторий и web; Manuel — Flutter, он потребитель бэкенда, не ревьюер. Для Manuel и его Claude точка входа — `docs/flutter-handoff.md`, контракт — `docs/api.md` и `types/database.ts` (генерируются `scripts/gen-types.sh`).

Окружения: на время разработки обоих клиентов один общий облачный проект Supabase (данные общие, перед релизом `scripts/wipe-data.sql`) плюс локальный `supabase start` у каждого. URL и ключи проекта в репозитории не хранятся.

## Состояние: I0 сделан

Миграции `0001–0004` подняты и проверены: схема, views, RLS, рабочие RPC (`search_trips`, `upsert_profile`, `upsert_vehicle`, `publish_trip`, `price_hint`, `register_device`, `mark_notifications_read`). Остальные RPC — заглушки с окончательными сигнатурами, бросают `BOLEIA_NOT_IMPLEMENTED`. Seed и тесты в `supabase/seed.sql`, `supabase/tests/`.

I1 идёт по `NEXT.md`. Сделано: `0005_booking_core` (брони, платежи, ledger-операции, `cancel_quote`), `0006_trip_lifecycle` (PIN, подтверждение, споры, отмена поездки, `update_trip`, `create_return_trip`), `0007_scheduler` (`run_scheduler(as_of)`, pg_cron, тихие часы, `pending_refunds`), `0008_chat_payouts_misc` (чат с маскированием, отзывы, жалобы, выплаты, верификация, `delete_me`, Storage-бакеты); решения в `docs/plans/000N_*.md`. `0009_edge_support` + `supabase/functions/` (payments-*, notify, send-sms, мок шлюза, Auth hooks как pg-functions, `edge_call` через pg_net + Vault). I1 закрыт: все RPC раздела 6 имеют тела, smoke `scripts/edge-smoke.sh` проходит против мока. Контракт шлюза: `docs/gateway-contract.md`.

## Архитектура — правила, которые не обсуждаются

1. **Бэкенд — только Supabase.** Никакого отдельного API-сервера.
2. **Клиенты не пишут в таблицы напрямую.** Все мутации — через RPC (`security definer`, проверяют `auth.uid()` через `current_profile()`). Исключения уже сделаны в `0003_rls.sql`: свои поля `profiles`, `devices`, `notifications.read_at`.
3. **Все инварианты — в Postgres.** Переходы статусов, пересчёт мест, движение денег — в plpgsql и триггерах, атомарно. Edge Functions — курьеры к внешним API, без бизнес-логики.
4. **`ledger_entries` — insert-only, двойная запись.** Сумма строк одной операции (`op_id`) = 0. `profiles.balance_kz` — кэш, триггер `ledger_sync_balance`. Любой RPC, трогающий деньги, пишет ledger в той же транзакции.
5. **Статусы — enum.** Машины состояний — раздел 5 ТЗ. Переходы делают только RPC, вебхук и cron.
6. **Views не ломаются.** Поля добавляются, не удаляются и не переименовываются минимум 2 релиза Flutter.
7. **Секреты — только в Edge Functions и `supabase secrets`.** Ничего в репозитории.
8. **Ошибки RPC** — `perform raise_boleia('<CODE>')` → `BOLEIA_<CODE>`, SQLSTATE `P0001`. Коды — раздел 7 ТЗ; новые добавляй туда же.
9. **Новая функция = новая строка в блоке grants** в конце `0004_rpc.sql` (или в новой миграции). По умолчанию execute отозван у всех.

## Ключевые решения (приняты — не пересматривать без явного запроса)

- Оплата при бронировании; `booking_mode` выбирает водитель: `instant` (по умолчанию: оплата → `accepted`) или `approval` (24 ч на ответ).
- Чат доступен **до** брони с карточки поездки; один `conversations` на пару (trip, passenger); `booking_id` проставляется после оплаты. Маскирование телефонов и ссылок до `departure_at − 2 ч`.
- Верификация водителя добровольная: ✓ и приоритет в выдаче, больше ничего. Лимиты одинаковые: 5 активных поездок, ≤ 4 места, пассажиру 3 активные брони.
- Выплаты всем водителям, вручную админом, раз в неделю, минимум 5 000 Kz.
- Комиссия `fee_kz = max(10% × price_total_kz, 1000)` — один раз на бронь (`calc_fee_kz`).
- Номер плательщика MCX Express = номер аккаунта; несовпадение → автовозврат.
- PIN при посадке; release денег: «доехал» / 48 ч с PIN / 7 дней без PIN.
- Бейдж отмен по `cancels_total` («Nunca cancelou» / «Às vezes cancela»). Санкций в MVP нет.
- Нет: промокодов, WhatsApp, наличных, фото в чате, PWA, OCR, GPS.

Полный список и открытые вопросы — разделы 15 и 16 ТЗ.

## Соглашения

- SQL: `snake_case`; `uuid default gen_random_uuid()`; `created_at`/`updated_at` на каждой таблице (общий триггер уже навешан циклом в `0001`; для новой таблицы — добавь триггер в своей миграции); деньги `integer` в `*_kz`; время `timestamptz`.
- Миграции: файлы `supabase/migrations/2026111000000N_<name>.sql` (нумерация продолжается), одна миграция = один коммит в `master`, `supabase db reset` обязан проходить чисто. Веток и PR пока нет.
- Тесты: `supabase/tests/NN_<topic>.test.sql`, pgTAP; каждый RPC с деньгами или переходом статуса — с тестом. Для имперсонации: `select set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated"}', true); set local role authenticated;`. Temp-таблицы создавай до смены роли и делай `grant all on ... to authenticated`.
- Edge Functions: Deno/TS в `supabase/functions/<name>/index.ts`; общий клиент в `_shared/`; вызывают RPC `service_role`-ключом; бизнес-правил не содержат.
- Коммиты — на английском, короткие, с номером раздела ТЗ в теле.

## Чего не делать

- Не писать `update ... set status` из клиента или Edge Function — только RPC.
- Не вводить новые лимиты, пороги, санкции, которых нет в ТЗ. Кажется, что нужно — предложи и спроси.
- Не отдавать телефон / номер машины / баланс в публичные views.
- Не менять сигнатуры существующих RPC без миграции и без правки раздела 6 ТЗ.
- Не трогать seed-пользователей с id `1111…`–`5555…` — на них завязаны тесты и `test_otp`.

## Как работать

- Перед задачей: прочитай нужный раздел `docs/spec.md`, назови его в ответе.
- Непонятно или ТЗ противоречит само себе — остановись и спроси, с цитатой из ТЗ.
- Новая таблица / смена enum / новый RPC — сначала план, потом код.
- После миграции: `supabase db reset` → `supabase test db` → `scripts/gen-types.sh` (обновляет `types/database.ts` и `docs/api.md`, коммитить вместе с миграцией) → в облако `supabase db push`.
- После `supabase db reset` локальный Vault пуст: `scripts/dev-vault.sh`, иначе cron не дозовётся до Edge (тесты этого не требуют).
- GoTrue хранит телефоны без `+`, `profiles.phone` в E.164; в seed `auth.users` номера без `+`. Сравнивать номера только через `same_phone()`.
