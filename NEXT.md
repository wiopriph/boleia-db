# Первое сообщение для Claude Code — I1

Скопировать в Claude Code, запущенный в корне `boleia-db` после того, как `supabase start`, `supabase db reset` и `supabase test db` прошли локально.

---

Прочитай CLAUDE.md и docs/spec.md целиком. I0 закрыт: схема, views, RLS, базовые RPC, seed и тесты лежат в репозитории и проходят `supabase db reset` + `supabase test db`.

Начинаем I1 — ядро с деньгами. Работаем по одной миграции за задачу, каждая — с pgTAP-тестом, `db reset` должен проходить после каждой.

Порядок:

1. **Бронирование без денег в шлюзе** — миграция `0005_booking_core.sql`: тела `request_booking`, `retry_payment`, `confirm_payment`, `respond_booking`, `cancel_booking` по разделу 6 ТЗ и машине состояний раздела 5. Ветвление по `trips.booking_mode`. Ledger-операции `payment`, `release`, `refund`, `forfeit` — как отдельные внутренние функции `ledger_post(op_id, memo, rows jsonb)`, которые проверяют сумму = 0. Таблица возвратов раздела 5 — в `cancel_booking`. Чат: найти или создать `conversations`, проставить `booking_id`, системное сообщение. Тест: полный цикл instant и approval из SQL, проверка баланса ledger после каждого шага.
2. **Поездка и подтверждение** — `0006_trip_lifecycle.sql`: `enter_pin`, `confirm_trip`, `mark_no_show`, `resolve_dispute`, `confirm_trip_intent`, `cancel_trip`, `create_return_trip`, `update_trip`. Тест: PIN-окно, no_show только при чужом PIN, release после `completed`.
3. **Cron** — `0007_scheduler.sql`: `run_scheduler()` по таблице cron раздела 6 (протухание платежей и запросов, напоминания, выезд, автозавершение 48 ч/7 дней, истечение, закрытие чатов, сверка). Регистрация в `pg_cron` каждые 5 минут. Тест: вызываем `run_scheduler()` с подменённым `now()` через параметр `as_of timestamptz default now()`.
4. **Чат, выплаты, остальное** — `0008_chat_payouts_misc.sql`: `send_message` с маскированием и лимитами, `mark_read`, `reveal_contact`, `request_payout`, `mark_payout`, `submit_review`, `report_user`, `submit_verification`, `review_verification`, `delete_me`. Триггер маскирования + автожалоба `cash_offer`.
5. **Edge Functions** — `supabase/functions/`: `payments-init`, `payments-webhook`, `payments-status`, `payments-refund` против мока шлюза (`payments-mock`, который через 5 с сам дёргает `confirm_payment`); `send-sms` (castbrick), `notify` (FCM), `auth-hook` (admin role в JWT + `banned_phones`). Контракт вебхука описать в `docs/gateway-contract.md`, чтобы потом подставить реальный GPO.

Сначала покажи план миграции 0005: список функций, какие ledger-строки пишет каждый переход, и какие тесты будут. Я проверю против ТЗ, потом пиши. Если в ТЗ чего-то не хватает — спроси списком, не додумывай.
