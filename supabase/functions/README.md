# Edge Functions (I1)

Появятся в I1 (см. NEXT.md): payments-init, payments-webhook, payments-status, payments-refund,
payments-mock (dev), send-sms, notify, auth-hook, telegram-moderation.

Секреты для локального запуска — в `supabase/.env.local` (в .gitignore):

    CASTBRICK_API_KEY=
    GATEWAY_BASE_URL=
    GATEWAY_SECRET=
    FCM_SERVICE_ACCOUNT_JSON=
    TELEGRAM_BOT_TOKEN=

`supabase functions serve` подхватывает их автоматически.
