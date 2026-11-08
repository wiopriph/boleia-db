# Edge Functions

Курьеры к внешним API без бизнес-правил (CLAUDE.md, правило 3): все переходы статусов делают RPC
`service_role` из миграции 0009 (`payment_initiated`, `payment_refund_result`, `notification_delivered`)
и `confirm_payment`. Контракт шлюза - `docs/gateway-contract.md`, план и решения -
`docs/plans/0009_edge_functions.md`.

| Функция | Кто зовёт | JWT |
| --- | --- | --- |
| `payments-init` | клиент после `request_booking` | пользователь |
| `payments-webhook` | шлюз | нет, подпись `X-Gateway-Signature` |
| `payments-status` | клиент (`{payment_id}`) и cron (`?sweep=1`) | пользователь / service key |
| `payments-refund` | cron каждые 5 минут | service key |
| `payments-mock` | dev-шлюз, см. контракт | нет, `Authorization: Bearer GATEWAY_API_KEY` |
| `notify` | триггер на insert в `notifications` и cron раз в минуту | service key |
| `send-sms` | Supabase Auth Send SMS Hook | нет, standard-webhooks |

Auth hooks `custom_access_token` и `before_user_created` - Postgres-функции (миграция 0009), не Edge.

## Локально

```bash
supabase functions serve            # все функции, hot reload
scripts/dev-vault.sh                # edge_url/edge_key в Vault, чтобы cron звал функции; после каждого db reset
scripts/edge-smoke.sh               # сквозной сценарий против мока (сам делает db reset)
```

Без переменных окружения шлюз = `payments-mock`, SMS и push пишутся в консоль (`[sms:log]`, `[push:log]`).
Переменные для реальных провайдеров - в `supabase/functions/.env.local` (в `.gitignore`), шаблон в
`.env.example`; в облаке - `supabase secrets set`. `supabase functions serve --env-file supabase/functions/.env.local`.

## Переменные

| Переменная | Назначение |
| --- | --- |
| `GATEWAY_BASE_URL`, `GATEWAY_API_KEY`, `GATEWAY_SECRET` | шлюз Multicaixa Express; пусто = мок |
| `PUBLIC_FUNCTIONS_URL` | публичный адрес функций для `callback_url` вебхука (в облаке `https://<ref>.supabase.co/functions/v1`) |
| `CASTBRICK_API_KEY`, `CASTBRICK_URL`, `CASTBRICK_SENDER` | SMS; пусто = лог |
| `FCM_SERVICE_ACCOUNT_JSON` | push через FCM HTTP v1; пусто = лог |
| `SEND_SMS_HOOK_SECRET` | секрет Auth Send SMS Hook (`v1,whsec_...`) |
| `MOCK_WEBHOOK_DELAY_MS` | задержка вебхука мока, по умолчанию 5000 |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` подставляет платформа.
