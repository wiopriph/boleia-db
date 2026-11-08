# Контракт платёжного шлюза (Multicaixa Express)

Договора с GPO/PST пока нет (ТЗ раздел 10), поэтому здесь описан контракт так, как его видит наш
код. Реальный шлюз подключается адаптером в `supabase/functions/_shared/gateway.ts`; остальной код
(RPC, Edge Functions, клиенты) от конкретного провайдера не зависит. Dev-реализация контракта -
`supabase/functions/payments-mock`.

Все суммы - целые кванзы (AOA). Время - ISO 8601 UTC. `reference` всегда равен `payments.id`.

## Авторизация

`Authorization: Bearer <GATEWAY_API_KEY>` на каждом запросе к шлюзу. Вебхуки шлюза подписаны
`X-Gateway-Signature: sha256=<hex HMAC-SHA256(body, GATEWAY_SECRET)>`.

## Создать транзакцию

`POST {GATEWAY_BASE_URL}/payments`

```json
{
  "reference": "payments.id",
  "amount": 8000,
  "currency": "AOA",
  "payer_phone": "+244900000005",
  "callback_url": "https://<project>.supabase.co/functions/v1/payments-webhook",
  "expires_in_seconds": 900,
  "metadata": { "booking_id": "..." }
}
```

Ответ `201`:

```json
{
  "transaction_id": "gw_...",
  "status": "pending",
  "instructions": { "type": "push", "deep_link": "mcx://...", "qr_payload": null }
}
```

`instructions.type`: `push` (подтверждение в приложении MCX Express на телефоне плательщика) или
`qr` (web: показать `qr_payload`). Клиент показывает инструкцию и ждёт realtime по брони.

## Статус транзакции

`GET {GATEWAY_BASE_URL}/payments/{transaction_id}` -> `200`:

```json
{ "transaction_id": "gw_...", "status": "paid", "payer_phone": "+244900000005", "paid_at": "2026-11-08T10:00:00Z" }
```

`status`: `pending | paid | failed | expired`. Используется `payments-status` (кнопка "Verificar
pagamento" и sweep по платежам с истёкшим `expires_at`).

## Возврат

`POST {GATEWAY_BASE_URL}/refunds`

```json
{ "transaction_id": "gw_...", "amount": 8000, "reference": "payments.id" }
```

Ответ `200`: `{ "refund_id": "rf_...", "status": "accepted" }` или `{ "status": "failed", "error": "..." }`.
Частичный возврат разрешён (`amount` < суммы транзакции).

## Вебхук

`POST callback_url`, тело:

```json
{
  "event": "payment.updated",
  "transaction_id": "gw_...",
  "reference": "payments.id",
  "status": "paid",
  "payer_phone": "+244900000005",
  "amount": 8000,
  "occurred_at": "2026-11-08T10:00:00Z"
}
```

`payments-webhook` проверяет подпись, вызывает `confirm_payment(reference, transaction_id, status,
payer_phone, body)` и отвечает `200` всегда; повторная доставка безопасна (идемпотентность по
`provider_ref` в SQL). Несовпадение подписи - `401`, шлюз должен повторить с правильной.

## Что меняется под реальный шлюз

Только `_shared/gateway.ts`: URL и имена полей, способ подписи вебхука, формат инструкции для
клиента. Если шлюз даёт только iFrame без API (вариант из ТЗ раздела 10), `payments-init` возвращает
`instructions.type = "redirect"` с URL, а вебхук остаётся.
