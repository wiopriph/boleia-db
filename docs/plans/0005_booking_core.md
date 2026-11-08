# План миграции 0005_booking_core

ТЗ: разделы 5 (машина состояний брони, таблица возвратов), 6 (RPC `request_booking`,
`retry_payment`, `confirm_payment`, `respond_booking`, `cancel_booking`), 7 (коды ошибок),
9 (уведомления), 10 (движение денег в ledger).

Ничего из схемы не меняется, кроме одного пункта в "Вопросах" (значение enum `ledger_account`).
Views не трогаются. Все функции `security definer`, `set search_path = public`.

## 1. Внутренние функции (без grant, клиентам недоступны)

| Функция | Что делает |
| --- | --- |
| `ledger_post(op_id, memo, booking_id, rows jsonb)` | `rows` = массив `{account, user_id?, amount_kz}`. Проверяет: массив не пуст, сумма `amount_kz` = 0, иначе `LEDGER_UNBALANCED`. Вставляет строки одной операцией. Единственная точка записи в `ledger_entries`. |
| `ledger_payment(payment)` | op `payment:<payment_id>`: деньги вошли в эскроу (строки в разделе 3). |
| `ledger_refund(booking, refund_kz, gateway_fee_kz)` | op `refund:<booking_id>`: эскроу минус, `refunds` плюс; если `gateway_fee_kz > 0`, он уходит на `gateway_fees` (комиссию шлюза несёт пассажир). Поднимает `payments.refund_kz`, `refund_ref` остаётся null, это сигнал cron'у (0007) вызвать `payments-refund`. |
| `ledger_release(booking, amount_kz)` | op `release:<booking_id>`: эскроу минус, водителю и платформе пропорционально `price_total_kz : fee_kz`. Полная сумма при `completed`; половина при удержании после отмены пассажиром < 24 ч. Используется в 0006, здесь только определяется. |
| `ledger_forfeit(booking, amount_kz)` | op `forfeit:<booking_id>`: эскроу минус, `platform_fee` плюс. Поездка не состоялась, удержанные 50 % уходят платформе. Используется в 0006/0007. |
| `escrow_balance_kz(booking_id)` | `sum(amount_kz)` по `passenger_escrow` для брони. Сколько ещё лежит в эскроу по этой брони, в т.ч. удержанная половина. Новых колонок не нужно. |
| `gateway_fee_kz(amount_kz)` | Комиссия шлюза при возврате по вине пассажира. Пока договора нет, возвращает 0. Одна точка, которую меняем, когда узнаем тариф. |
| `gen_pin()` | 4 цифры, `lpad(floor(random()*10000), 4, '0')`. |
| `notify(user_id, type, payload, allow_sms)` | Всегда строка `inapp`; плюс одна строка доставки: `push`, если у пользователя есть `devices`, иначе `sms`, если `allow_sms`. Тихие часы не нужны: все события 0005 - про деньги, они исключение по разделу 9. |
| `ensure_conversation(trip_id, passenger_id, booking_id)` | Найти `conversations` по `(trip_id, passenger_id)` или создать; проставить `booking_id`, если ещё null. Возвращает id. |
| `system_message(conversation_id, body)` | `messages` с `sender_id = null`, обновляет `last_message_at`. Текст pt-AO. |
| `booking_for_update(booking_id)` | Читает бронь и поездку с `for update` в порядке trips -> bookings, одинаково во всех RPC, чтобы два параллельных вызова не пересеклись. |
| `refund_rule(booking, trip, by party)` | Чистая функция: по таблице раздела 5 возвращает `(refund_kz, gateway_fee_kz, held_kz, rule text, counter boolean)`. Одна и та же для `cancel_booking` и для показа суммы пассажиру до подтверждения. |

Все транзитные RPC блокируют строку поездки (`select ... for update`) до проверки мест. Триггер
`trips_recount_seats` считает места после вставки, без блокировки два пассажира могли бы оба
пройти проверку на последнее место.

## 2. RPC

### `request_booking(trip_id, seats, message) -> jsonb`

Проверки по порядку, код ошибки:

1. `current_profile()` (NOT_AUTHENTICATED, PROFILE_RESTRICTED для suspended/banned).
2. Поездка существует, иначе `TRIP_NOT_FOUND`. Блокировка `for update`.
3. `status = 'published'`; `full` -> `TRIP_FULL`; остальное -> `TRIP_NOT_BOOKABLE`.
4. `departure_at > now() + 1 h`, иначе `TRIP_NOT_BOOKABLE`.
5. `seats` от 1 до 3 -> `SEATS_INVALID`; `seats <= seats_available` -> `TRIP_FULL`.
6. Активных броней пассажира (`pending_payment, requested, accepted, awaiting_confirm`) < 3,
   иначе `BOOKING_LIMIT_REACHED`.
7. Активная бронь на эту поездку уже есть -> `BOOKING_DUPLICATE` (ловим 23505 от уникального
   индекса и перебрасываем своим кодом). Свою поездку запрещает триггер `OWN_TRIP`.

Действия: `price_total_kz = seats * price_per_seat_kz`, `fee_kz = calc_fee_kz(price_total_kz)`;
insert `bookings(pending_payment)`; insert `payments(created, amount_kz = total + fee,
expires_at = now() + 15 min)`; `notify(passenger, 'payment_pending', push only)`;
`log_event('booking_requested')`.

Возвращает `{booking_id, payment_id, amount_kz, price_total_kz, fee_kz, expires_at}` для
`payments-init`.

### `retry_payment(booking_id) -> jsonb`

1. Бронь принадлежит вызывающему, иначе `NOT_PARTICIPANT`.
2. `status = 'payment_failed'`; `pending_payment` -> `PAYMENT_PENDING`; иное -> `BOOKING_CLOSED`.
3. Строк в `payments` по брони < 3, иначе `PAYMENT_RETRY_LIMIT`.
4. Те же проверки поездки, что в `request_booking` (published, > 1 ч, мест хватает).

Бронь -> `pending_payment` (триггер снова резервирует места), новая строка `payments(created)`,
снимок цены и комиссии не пересчитывается. Возвращает то же, что `request_booking`.

### `confirm_payment(payment_id, provider_ref, new_status, payer_phone, raw)` только service_role

Идемпотентность: платёж уже не в `created`/`pending` -> выход без действий (вебхук пришёл
второй раз). `provider_ref` записывается, если был null; если был и отличается -> `PAYMENT_REF_MISMATCH`.
`raw` сохраняется в `raw_webhook`. `new_status` допускается `paid | failed | expired`,
иначе `PAYMENT_STATUS_INVALID`.

Ветки:

- **failed / expired**: `payments.status` соответственно; бронь `pending_payment -> payment_failed`,
  места освобождает триггер; `notify(passenger, 'payment_failed', sms ok)`.
- **paid, телефон не совпал** (сравнение E.164 с `profiles.phone`): деньги реально пришли, поэтому
  `ledger_payment`, затем сразу `ledger_refund` на всю сумму; `payments.status = paid`,
  `refund_kz = amount` (cron сделает возврат в шлюз); бронь -> `payment_failed`,
  `cancel_reason = 'PAYMENT_PHONE_MISMATCH'`; `notify(passenger, 'payment_failed')` с причиной.
  Счётчик "3 несовпадения -> restricted" (раздел 8): считаем по `bookings.cancel_reason`,
  на третьем ставим `profiles.status = restricted`.
- **paid, бронь уже не `pending_payment`** (протухла по cron, поездка уехала): та же пара
  `payment` + `refund` на всю сумму, бронь не трогаем, уведомление пассажиру `refund_done`.
  В ТЗ случая нет, см. вопрос 5.
- **paid, всё совпало**: `payments.status = paid`, `paid_at`; `ledger_payment`;
  `ensure_conversation(..., booking_id)`; `requested_at = now()`. Дальше по `trips.booking_mode`:
  - `instant`: бронь -> `accepted`, `pin_code = gen_pin()`, `responded_at = now()`;
    системное сообщение "Lugar confirmado. O PIN e o telefone chegam 2 h antes da partida.";
    `notify(passenger, 'booking_accepted', sms ok)`; `notify(driver, 'booking_confirmed')`,
    см. вопрос 4.
  - `approval`: бронь -> `requested`; системное сообщение "Pedido pago. O condutor responde
    em 24 h."; `notify(driver, 'booking_requested', sms ok)`.

  `log_event('payment_paid')`.

### `respond_booking(booking_id, accept, reason)` водитель

1. Вызывающий - водитель поездки, иначе `NOT_PARTICIPANT`.
2. `status = 'requested'`, иначе `BOOKING_CLOSED`.
3. `now() < departure_at - 1 h`, иначе `BOOKING_CLOSED` (cron ещё не успел протухнуть запрос).

- accept: -> `accepted`, `pin_code`, `responded_at`; системное сообщение "Lugar confirmado...";
  `notify(passenger, 'booking_accepted', sms ok)`.
- decline: -> `declined`, `responded_at`, `cancel_reason = reason`; `ledger_refund` на 100 %
  (цена + комиссия, комиссию шлюза платит платформа); `bookings.refund_kz = amount`;
  `notify(passenger, 'booking_declined', sms ok)`. `cancels_total` водителя не растёт
  (таблица раздела 5, строка "Водитель отклонил").

### `cancel_booking(booking_id, reason) -> jsonb`

1. Вызывающий - пассажир брони или водитель поездки, иначе `NOT_PARTICIPANT`.
2. `status` в (`requested`, `accepted`); `pending_payment` -> `PAYMENT_PENDING`
   (ждать 15 мин или `payment_failed`); остальное -> `BOOKING_CLOSED`.
3. Поездка в `published`/`full`, иначе `TOO_LATE_TO_CANCEL` (после `departed` отмены нет).

Возврат по `refund_rule`:

| Кто | Условие | Возврат пассажиру | Удержано в эскроу | Счётчик |
| --- | --- | --- | --- | --- |
| водитель | всегда | 100 % | 0 | `cancels_total` водителя +1 |
| пассажир | бронь ещё `requested` | 100 % минус комиссия шлюза | 0 | +1, см. вопрос 2 |
| пассажир | `driver_confirmed_at` null и `now() >= departure_at - 6 h` | 100 % | 0 | нет |
| пассажир | `> 24 h` до выезда | 100 % минус комиссия шлюза | 0 | `cancels_total` пассажира +1 |
| пассажир | `< 24 h` до выезда | 50 % от (цена + комиссия), округление вверх в пользу пассажира | 50 % | +1 |

Действия: бронь -> `cancelled`, `cancelled_at`, `cancelled_by`, `cancel_reason`, `refund_kz`;
`ledger_refund(refund_kz, gateway_fee_kz)`; места освобождает триггер (и `full -> published`);
уведомление второй стороне: `booking_cancelled_by_passenger` (push) или
`booking_cancelled_by_driver` (push + SMS). Удержанные 50 % остаются на `passenger_escrow` по
`booking_id`, их судьбу решает 0006 при `completed` (release 50/50 пропорционально) или 0007 при
`cancelled`/`expired` поездки (forfeit).

Возвращает `{status, refund_kz, held_kz, rule}`.

### Показ суммы возврата до подтверждения

ТЗ: "сумма показывается до подтверждения", но RPC для этого в разделе 6 нет. Клиент не должен
дублировать таблицу возвратов. Предлагаю `cancel_quote(booking_id) -> jsonb` с тем же
`{refund_kz, held_kz, rule}` через `refund_rule`, `stable`, grant `authenticated`. См. вопрос 3.

## 3. Строки ledger по переходам (пример: 1 место по 7 000, комиссия 1 000, оплачено 8 000)

| Переход | op / memo | Строки |
| --- | --- | --- |
| оплата прошла | `payment:<payment_id>` | `cash_in -8 000`, `passenger_escrow +8 000` (см. вопрос 1) |
| отказ водителя, отмена водителем, отмена пассажира > 24 ч без комиссии шлюза, свободная отмена при неподтверждённой поездке, несовпадение телефона, поздняя оплата | `refund:<booking_id>` | `passenger_escrow -8 000`, `refunds +8 000` |
| отмена пассажира > 24 ч, комиссия шлюза X | `refund:<booking_id>` | `passenger_escrow -8 000`, `refunds +(8 000 - X)`, `gateway_fees +X` |
| отмена пассажира < 24 ч, шаг 1 | `refund:<booking_id>` | `passenger_escrow -4 000`, `refunds +4 000`; 4 000 остаются |
| шаг 2 при `completed` (0006) | `release:<booking_id>` | `passenger_escrow -4 000`, `driver_balance +3 500`, `platform_fee +500` |
| шаг 2, поездка не состоялась (0007) | `forfeit:<booking_id>` | `passenger_escrow -4 000`, `platform_fee +4 000` |
| `completed` (0006) | `release:<booking_id>` | `passenger_escrow -8 000`, `driver_balance +7 000`, `platform_fee +1 000` |

Переходы без денег: `pending_payment -> payment_failed` (failed/expired), `accepted` из
`requested` (accept).

Соглашение для cron 0007: возврат ожидает отправки в шлюз, пока
`payments.refund_kz > 0 and refund_ref is null`. `payments-refund` проставляет `refund_ref`,
`refunded_at`, статус `refunded`/`partially_refunded`.

## 4. Новые коды ошибок (добавить в раздел 7 ТЗ тем же PR)

`TRIP_NOT_FOUND`, `BOOKING_NOT_FOUND`, `BOOKING_LIMIT_REACHED`, `LEDGER_UNBALANCED`,
`PAYMENT_STATUS_INVALID`, `PAYMENT_REF_MISMATCH`. Уже есть в коде, но не в списке раздела 7:
`OWN_TRIP`, `SEATS_INVALID`. Из списка раздела 7 используются: `TRIP_FULL`, `TRIP_NOT_BOOKABLE`,
`PROFILE_RESTRICTED`, `BOOKING_DUPLICATE`, `BOOKING_CLOSED`, `PAYMENT_PENDING`,
`PAYMENT_PHONE_MISMATCH` (как `cancel_reason`), `PAYMENT_RETRY_LIMIT`, `TOO_LATE_TO_CANCEL`,
`NOT_PARTICIPANT`.

## 5. Grants

`cancel_quote(uuid)` -> `authenticated`. Остальные RPC уже в блоке grants 0004, `confirm_payment`
уже только `service_role`. Внутренние функции без grant (execute отозван по умолчанию).

## 6. Тесты `supabase/tests/04_booking_core.test.sql`

Данные: Ana (5555) пассажир, João (2222) instant, Teresa (3333) approval, их сид-поездки.
Для сценария "< 24 ч" `departure_at` поездки сдвигается в тесте под superuser до смены роли.
`confirm_payment` вызывается от postgres (service_role в pgTAP не нужен), плюс один тест, что
`authenticated` получает 42501.

Проверки:

1. **Instant полный цикл**: `request_booking(2 места)` -> `pending_payment`, `payments.created`,
   `amount_kz = 14 000 + 1 400`, `seats_available` 3 -> 1, уведомление `payment_pending`;
   `confirm_payment(paid, телефон Ana)` -> `accepted`, `pin_code ~ '^\d{4}$'`, `conversations`
   с `booking_id`, системное сообщение, уведомления пассажиру и водителю; ledger: `payment` op
   две строки, сумма 0, `escrow_balance_kz = 15 400`, `payments.paid`.
2. **Идемпотентность**: второй `confirm_payment` с тем же `provider_ref` -> ledger не изменился.
3. **Несовпадение телефона**: -> `payment_failed`, `cancel_reason`, пара `payment`+`refund`,
   `escrow_balance_kz = 0`, `payments.refund_kz = amount`, `refund_ref is null`, место назад.
4. **failed от шлюза**: -> `payment_failed`, ledger пуст по брони, место назад.
5. **retry_payment**: из `payment_failed` -> `pending_payment`, вторая строка `payments`;
   из `pending_payment` -> `PAYMENT_PENDING`; четвёртая попытка -> `PAYMENT_RETRY_LIMIT`.
6. **Approval цикл**: `confirm_payment` -> `requested`, системное сообщение, уведомление водителю;
   `respond_booking(false)` -> `declined`, `refund` 100 %, эскроу 0, `cancels_total` Teresa
   не изменился; новая бронь, `respond_booking(true)` -> `accepted` + PIN.
   `respond_booking` от Ana -> `NOT_PARTICIPANT`; повторный -> `BOOKING_CLOSED`.
7. **Отмена пассажиром > 24 ч**: возврат = сумма минус `gateway_fee_kz` (сейчас 0),
   `cancels_total` Ana +1, место назад, уведомление водителю.
8. **Отмена пассажиром < 24 ч**: возврат 50 %, `escrow_balance_kz` = 50 %, `held_kz` в ответе,
   `cancel_quote` до отмены даёт ту же сумму.
9. **Свободная отмена**: `departure_at - 5 h`, `driver_confirmed_at` null -> 100 %, счётчик не растёт.
10. **Отмена водителем**: 100 %, `cancels_total` João +1, SMS-уведомление пассажиру.
11. **Ошибки**: `OWN_TRIP`, `SEATS_INVALID` (0 и 4), `TRIP_FULL` (4-е место), `BOOKING_DUPLICATE`,
    `BOOKING_LIMIT_REACHED` (4-я активная бронь), `TRIP_NOT_BOOKABLE` (выезд через 50 мин),
    `PAYMENT_PENDING` на отмену, `TOO_LATE_TO_CANCEL` после `departed`, `NOT_PARTICIPANT`.
12. **ledger_post**: несбалансированные строки -> `LEDGER_UNBALANCED`; `update`/`delete` -> `LEDGER_IMMUTABLE`.
13. **Инвариант**: по каждому `op_id` сумма = 0; `profiles.balance_kz` не изменился ни у кого
    (release в 0005 не вызывается).

## 7. Решения (приняты 8 ноя 2026, внесены в ТЗ)

1. **`cash_in`.** В `ledger_account` добавлено значение `cash_in`; операция `payment` пишет
   `cash_in -N, passenger_escrow +N`. Правило "сумма операции = 0" без исключений.
2. **Отмена пассажиром в `requested`:** всегда 100 % минус комиссия шлюза, `cancels_total` +1.
   Штраф 50 % только за принятую бронь.
3. **`cancel_quote(booking_id)`** - отдельная RPC, `authenticated`, та же `refund_rule`.
4. **`booking_confirmed`** - уведомление водителю при instant, добавлено в раздел 9.
5. **Поздняя оплата:** `payment` + `refund` на всю сумму, бронь не трогается, пассажиру `refund_done`.
6. **Комиссия шлюза:** `gateway_fee_kz(amount)` возвращает 0 до договора.
7. **`restricted`** запрещает только `request_booking` и `retry_payment`. Счётчик несовпадений -
   события `payment_phone_mismatch` в `events` с `user_id` пассажира; на третьем профиль
   `active -> restricted`.
8. **`expires_at`** ставится в `request_booking`/`retry_payment`; cron 0007 протухает `created` и `pending`.
9. **Уведомления** пишут RPC через `notify()`, общего триггера нет.

Выяснилось по ходу:

- **`profiles_guard` из 0001 не работал с RPC.** Он смотрел на `current_setting('role')`, который
  внутри `security definer` остаётся `authenticated`, и блокировал любое изменение защищённых
  полей из RPC (`cancels_total`, `balance_kz`). Переписан на `current_user`: внутри
  `security definer` это владелец функции. Покрыто тестом (`cancels_total` +1, `balance_kz` после release).
- **Водитель вызывает `cancel_booking` на бронь в `requested`** - это отказ: `declined`, без
  санкции, как `respond_booking(false)`.
- **Порядок проверок в `request_booking`:** дубль раньше лимита и мест, чтобы пассажир с активной
  бронью получал `BOOKING_DUPLICATE`, а не `TRIP_FULL`.
