# План шага 5: Edge Functions и миграция 0009_edge_support

ТЗ: раздел 6 (Edge Functions, Cron), раздел 8 (auth, Send SMS Hook, `banned_phones`, admin в JWT),
раздел 9 (доставка уведомлений), раздел 10 (флоу оплаты, возвраты). NEXT.md, пункт 5.

Edge Functions - курьеры к внешним API без бизнес-правил (CLAUDE.md, правило 3). Все переходы
статусов делают RPC `service_role`: ни одна функция не пишет в таблицы напрямую. Поэтому шаг
состоит из двух частей: маленькая миграция с тремя сервисными RPC и cron-вызовами, и сами функции.

## 1. Миграция `0009_edge_support.sql`

| Объект | Назначение |
| --- | --- |
| `payment_initiated(payment_id, provider_ref, raw)` service_role | `payments-init` создал транзакцию в шлюзе: `created -> pending`, `provider_ref`, `raw_request`, `expires_at = now() + 15 мин` (отсчёт с момента, когда у пассажира появилась инструкция). Идемпотентна по `provider_ref` |
| `payment_refund_result(payment_id, ok, refund_ref, raw)` service_role | `payments-refund` сходил в шлюз: ok -> `refund_ref`, `refunded_at`, статус `refunded`/`partially_refunded`, пассажиру `refund_done`; fail -> `refund_attempts + 1`, `refund_failed_at`; на третьей неудаче админам `refund_manual` |
| `notification_delivered(id, ok, error)` service_role | `notify` отправил push/SMS: `sent` + `sent_at`, либо `failed` + `error` и `scheduled_for = now() + 5 мин`, не больше 3 попыток (`payload -> attempts`) |
| `custom_access_token_hook(event jsonb)` | Auth Custom Access Token Hook как Postgres-функция: кладёт `app_metadata.role = 'admin'`, если `profiles.is_admin` (вопрос 1) |
| `before_user_created_hook(event jsonb)` | Auth Before User Created Hook: телефон в `banned_phones` -> отказ с кодом 403 (вопрос 1) |
| `edge_call(path, body)` | обёртка над `net.http_post` к `vault` секретам `edge_url` и `edge_key`; используется cron-джобами (вопрос 3) |
| pg_cron jobs | `boleia_payments_status` каждую минуту -> `payments-status?sweep=1`; `boleia_payments_refund` каждые 5 минут -> `payments-refund`; `boleia_notify_sweep` каждую минуту -> `notify?sweep=1` |
| триггер `notifications_dispatch` after insert | строки `push`/`sms` без `scheduled_for` -> `edge_call('notify', {id})` сразу, без ожидания минутного тика (вопрос 4) |

Тесты `08_edge_support.test.sql`: три RPC по веткам, идемпотентность `payment_initiated`, лимит
трёх попыток, hooks на admin/не admin и на забаненный номер, наличие cron-джобов. `net.http_post`
в тестах не вызывается: `edge_call` выходит молча, если секретов в Vault нет.

## 2. Контракт шлюза: `docs/gateway-contract.md`

Реального договора с GPO/PST нет (ТЗ раздел 10), поэтому контракт описывается нейтрально, как его
видит наш код, а адаптер под конкретный шлюз подставляется в `_shared/gateway.ts`.

| Операция | Запрос | Ответ |
| --- | --- | --- |
| создать | `POST {GATEWAY_BASE_URL}/payments` `{reference, amount, currency, payer_phone, callback_url, expires_in_seconds, metadata}` | `{transaction_id, status: "pending", instructions: {type: "push" \| "qr", qr_payload?, deep_link?}}` |
| статус | `GET /payments/{transaction_id}` | `{transaction_id, status: pending \| paid \| failed \| expired, payer_phone?, paid_at?}` |
| возврат | `POST /refunds` `{transaction_id, amount, reference}` | `{refund_id, status: accepted \| failed}` |
| вебхук | `POST callback_url` `{event: "payment.updated", transaction_id, reference, status, payer_phone, amount}`, заголовок `X-Gateway-Signature: sha256=HMAC(body, GATEWAY_SECRET)` | всегда 200 |

`reference` = `payments.id`. Авторизация к шлюзу - `Authorization: Bearer GATEWAY_API_KEY`.

## 3. Функции `supabase/functions/`

| Функция | Вызывает | Что делает |
| --- | --- | --- |
| `_shared/` | - | `supabase.ts` (service-клиент и user-клиент из `Authorization`), `gateway.ts` (create/status/refund/verifySignature), `http.ts` (JSON-ответы, маппинг `BOLEIA_*` из RPC в 4xx `{code}`), `providers/` (castbrick, fcm, log) |
| `payments-init` | клиент, JWT | `{booking_id}` -> платёж в `created` этого пассажира (`PAYMENT_NOT_FOUND`/`NOT_PARTICIPANT`), телефон аккаунта -> `gateway.create` -> `payment_initiated` -> клиенту `{payment_id, expires_at, instructions}` |
| `payments-webhook` | шлюз | проверка HMAC (401 при несовпадении), `confirm_payment(reference, transaction_id, status, payer_phone, raw)`; любая ошибка RPC логируется, ответ 200 (идемпотентность в SQL) |
| `payments-status` | клиент (JWT, `{payment_id}`) или cron (`?sweep=1`, service key) | `gateway.status`; терминальный статус -> `confirm_payment`; sweep берёт `pending` с `expires_at` в прошлом, до 50 за вызов; клиенту возвращает текущий статус |
| `payments-refund` | cron | читает `pending_refunds`, `gateway.refund`, `payment_refund_result` |
| `payments-mock` | dev | реализует контракт из раздела 2 без своего состояния: статус читает из нашей `payments`, через 5 с после создания шлёт подписанный вебхук (`EdgeRuntime.waitUntil`). `metadata.simulate` = `paid` (по умолчанию) \| `failed` \| `mismatch` (чужой номер) \| `silent` (вебхука нет, проверяет sweep). Включается `GATEWAY_BASE_URL=http://127.0.0.1:54321/functions/v1/payments-mock` (вопрос 2) |
| `notify` | триггер (`{id}`) или cron sweep (`?sweep=1`) | `queued` строки с `scheduled_for is null or <= now()`: `push` -> FCM HTTP v1 по токенам из `devices`, `sms` -> castbrick, `inapp` -> сразу `sent`; результат через `notification_delivered`. Без ключей провайдера - адаптер `log` (вопрос 5) |
| `send-sms` | Supabase Auth Send SMS Hook | подпись standard-webhooks (`SEND_SMS_HOOK_SECRET`), текст OTP pt-AO -> castbrick; в dev для `test_otp` не вызывается |

`telegram-moderation` - I4, в этом шаге не делается (вопрос 6). Auth hooks `custom_access_token` и
`before_user_created` - Postgres-функции из миграции, не Edge (вопрос 1).

## 4. Конфигурация

`config.toml`: `[auth.hook.custom_access_token]` и `[auth.hook.before_user_created]` с
`pg-functions://postgres/public/...`; `[auth.hook.send_sms] enabled = true, uri = "http://host.docker.internal:54321/functions/v1/send-sms", secrets = "env(SEND_SMS_HOOK_SECRET)"`.
Секреты локально в `supabase/.env.local` (есть в `.gitignore`), в облаке - `supabase secrets set`.
Vault: `scripts/dev-vault.sh` читает `supabase status -o json` и кладёт `edge_url`, `edge_key`
в `vault.secrets` локально; в облаке - один раз руками через SQL editor.

## 5. Проверка

- pgTAP `08_edge_support.test.sql` для миграции.
- `scripts/edge-smoke.sh`: `supabase functions serve` + сценарии через curl и psql: instant-бронь
  -> `payments-init` -> мок через 5 с -> `accepted`; `simulate=mismatch` -> `payment_failed` +
  возврат в `pending_refunds` -> `payments-refund` -> `refunded`; `simulate=silent` -> sweep
  `payments-status` -> статус; `notify` с адаптером `log` -> `sent`. Запускается руками, в CI позже.
- Критерий из ТЗ раздела 13: "опубликовал -> оплатил -> принял -> PIN -> подтвердил -> release ->
  выплата" проходит из SQL + вебхук.

## 6. Решения (приняты 8 ноя 2026, внесены в ТЗ)

1. Auth hooks - Postgres-функции `custom_access_token_hook`, `before_user_created_hook` (`pg-functions://`).
2. Мок шлюза без состояния, статус из `payments`, вебхук через 5 с, `metadata.simulate`.
3. Service key для `edge_call` в Vault (`edge_url`, `edge_key`); локально `scripts/dev-vault.sh`.
4. Доставка: триггер `notifications_dispatch` на insert + sweep раз в минуту.
5. Провайдеры за адаптерами; без ключей `log`.
6. `telegram-moderation` - I4.

Выяснилось по ходу:

- **GoTrue хранит телефон без "+".** Seed клал в `auth.users` `+244...`, поэтому вход по OTP с номером
  `244900000005` создавал нового пользователя без имени вместо сидовой Ana. Seed переведён на формат
  GoTrue, `handle_new_user` добавляет "+" при копировании в `profiles` (E.164 по ТЗ). Все сравнения
  номеров в RPC уже шли через `same_phone()` по последним 9 цифрам, они не пострадали.
- **`payment_initiated` перезапускает `expires_at`** с момента, когда у пассажира появилась инструкция
  (`request_booking` ставит +15 мин как страховку от брони без `payments-init`).
- **`refund_done` уходит дважды** в сценариях поздней оплаты и спора: при записи возврата в ledger (0005/0006)
  и при подтверждении шлюза (`payment_refund_result`). Первое - "возврат оформлен", второе - "деньги
  вернулись". Если будет шумно, убрать первое.
- **`notify` для `inapp` ставит `sent` сразу**: доставлять нечего, канал читается из приложения.
- **Smoke прошёл целиком** против мока: instant-оплата, статус по кнопке, несовпадение номера с
  автовозвратом через `payments-refund`, потерянный вебхук через sweep `payments-status`, отказ
  вебхука с неверной подписью, доставка уведомлений триггером через `pg_net`, `admin` в JWT через hook.
- **Критерий ТЗ раздела 13 для I1** ("опубликовал -> оплатил -> принял -> PIN -> подтвердил -> release ->
  выплата" из SQL + вебхук) закрыт тестами 04-08 и smoke.
