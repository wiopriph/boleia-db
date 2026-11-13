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
| `CASTBRICK_API_KEY` | ключ castbrick для SMS (OTP и уведомления); пусто = лог |
| `CASTBRICK_SENDER` | имя отправителя, по умолчанию `Boleia`; должно быть заведено в кабинете castbrick |
| `CASTBRICK_URL` | адрес API, по умолчанию `https://api.castbrick.co/v1/sms/send`; меняется только для тестов |
| `FCM_SERVICE_ACCOUNT_JSON` | push через FCM HTTP v1; пусто = лог |
| `SEND_SMS_HOOK_SECRET` | секрет Auth Send SMS Hook (`v1,whsec_...`, несколько через `\|` на время ротации); обязателен, когда задан `CASTBRICK_API_KEY` |
| `MOCK_WEBHOOK_DELAY_MS` | задержка вебхука мока, по умолчанию 5000 |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` подставляет платформа.

## Вход по SMS через castbrick

Код генерирует и проверяет Supabase Auth, лимиты тоже его. `send-sms` только доставляет: Auth зовёт её
через Send SMS Hook, она шлёт `POST /v1/sms/send` с телом `{recipients, content, senderId}` (формат из
рабочей интеграции amoda). Клиенты не меняются: `signInWithOtp({ phone })` и `verifyOtp`.

Функция публичная, поэтому без подписи standard-webhooks работает только адаптер `log`. Если ключ
castbrick задан, а секрета хука нет, она отвечает 500: иначе любой мог бы слать SMS за наш счёт.

Включение в облаке, по порядку:

1. Кабинет castbrick: ключ API, заведённый отправитель `Boleia`, положительный баланс.
2. Dashboard -> Authentication -> Hooks -> Send SMS hook: HTTPS, адрес
   `https://<ref>.supabase.co/functions/v1/send-sms`, сгенерировать секрет.
3. `supabase secrets set CASTBRICK_API_KEY=... SEND_SMS_HOOK_SECRET='v1,whsec_...'` (или строки в
   `supabase/functions/.env.cloud` и `scripts/deploy.sh`).
4. `supabase functions deploy send-sms`.
5. Authentication -> Sign In / Providers -> Phone: провайдер включён (любой, хук его перекрывает), срок
   жизни кода 5-10 минут, длина 6. Rate limits: SMS в час небольшим числом.
6. Проверка: вход с настоящим номером; ошибки доставки видны в логах Auth и функции `send-sms`.

Номера из `auth.sms.test_otp` до хука не доходят и SMS не тратят. Перед запуском их нужно убрать:
среди них админ с кодом `123456`.

Хук в `config.toml` закомментирован: его `uri` разный локально и в облаке, а `scripts/deploy.sh`
делает `supabase config push`. Локально он нужен только для проверки самой функции.
