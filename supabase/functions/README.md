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
| `SMS_PROVIDER` | `castbrick` или `log`; без переменной castbrick включается наличием ключа. `log` выключает отправку, не трогая ключ |
| `SMS_NOTIFICATIONS` | `on` включает SMS-уведомления через тот же провайдер; без него `notify` пишет SMS в лог. Коды входа от флага не зависят |
| `SMS_SENDER_ID` | имя отправителя (старое имя `CASTBRICK_SENDER` тоже читается), по умолчанию `Boleia`; должно быть одобрено в кабинете castbrick |
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

Включено в облаке 2026-11-16. Как это собрано:

- Секреты функций (`supabase secrets`): `CASTBRICK_API_KEY`, `SMS_PROVIDER=castbrick`, `SMS_SENDER_ID`,
  `SEND_SMS_HOOK_SECRET`. Источник - `supabase/functions/.env.cloud` (в `.gitignore`), его же читает
  `scripts/deploy.sh`.
- Хук объявлен в `config.toml` в блоке `[remotes.production]`: он действует только для облачного
  проекта и применяется командой `supabase config push`. Локальный стек его не видит.
- Секрет хука один на обе стороны. Любая команда CLI против облачного проекта (`functions deploy`,
  `config push`) требует его в окружении, иначе падает с "Invalid hook config":

  ```bash
  export SEND_SMS_HOOK_SECRET="$(grep '^SEND_SMS_HOOK_SECRET=' supabase/functions/.env.cloud | cut -d= -f2-)"
  ```

- Ротация секрета: новое значение в `.env.cloud`, затем `supabase secrets set --env-file ...` и
  `supabase config push`. На время смены функция принимает несколько секретов через `|`.
- Выключить отправку, не трогая ключ: `supabase secrets set SMS_PROVIDER=log`.
- Настройки в Dashboard: срок жизни кода 5-10 минут, длина 6, лимит SMS в час небольшим числом.
- Ошибки доставки видны в логах Auth и функции `send-sms`.

Номера из `auth.sms.test_otp` до хука не доходят и SMS не тратят. Перед запуском их нужно убрать:
среди них админ с кодом `123456`.
