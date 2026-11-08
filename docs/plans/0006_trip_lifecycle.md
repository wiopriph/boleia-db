# План миграции 0006_trip_lifecycle

ТЗ: разделы 5 (машины состояний поездки и брони, таблица возвратов), 6 (RPC `enter_pin`,
`confirm_trip`, `mark_no_show`, `resolve_dispute`, `confirm_trip_intent`, `cancel_trip`,
`create_return_trip`, `update_trip`; триггер `completed -> trips_driven/trips_ridden`),
7 (коды), 9 (уведомления), 10 (PIN, release), 11 (споры).

Опирается на 0005: `ledger_release`, `ledger_refund`, `ledger_forfeit`, `escrow_balance_kz`,
`notify`, `ensure_conversation`, `system_message`. Схема не меняется, кроме одного значения enum
(вопрос 3). Cron-переходы (`departed`, `awaiting_confirm`, автозавершение, протухание) - это 0007;
здесь только функции, которые cron потом вызовет.

## 1. Внутренние функции

| Функция | Что делает |
| --- | --- |
| `complete_booking(b, p_confirmed_by party)` | Финал брони с деньгами водителю: `completed`, `completed_at`, `passenger_confirmed_at` или `driver_confirmed_at` по `p_confirmed_by`; `ledger_release` на весь остаток эскроу; `trips_ridden` пассажира +1; `notify(driver, 'payout_released', {amount})`; `notify(passenger, 'review_request')` с `scheduled_for = now() + 24 h`; `notify(driver, 'review_request')` так же. Затем `settle_trip`. Вызывается из `confirm_trip`, `resolve_dispute` и из cron 0007 (автозавершение 48 ч / 7 дней). |
| `settle_trip(trip_id)` | Закрывает поездку, когда ни одной брони не осталось в `accepted`, `awaiting_confirm`, `disputed`, а поездка в `departed`: удержанные 50 % по броням `cancelled_by = passenger` с остатком в эскроу -> `ledger_release` (водителю его доля); `trips.status = completed`, `completed_at`; `trips_driven` водителя +1, если хотя бы одна бронь дошла до `completed` или `no_show`. Идемпотентна. Вызывается после каждого финала брони и из cron. |
| `forfeit_trip_holds(trip_id)` | Поездка не состоялась (`cancelled`): удержанные 50 % -> `ledger_forfeit`, платформе. Вызывается из `cancel_trip` и из cron 0007 для `expired`. |
| `trip_for_driver(trip_id) -> trips` | Читает поездку `for update`, проверяет `driver_id = current_profile().id`, иначе `NOT_PARTICIPANT`; нет поездки -> `TRIP_NOT_FOUND`. |
| `pin_attempts_blocked(driver_id, booking_id) -> boolean` | 5 неверных PIN за 10 минут. Счётчик: события `pin_failed` в `events` с `user_id` водителя, как `payment_phone_mismatch` в 0005. |

Триггер из раздела 6 "`bookings -> completed` -> инкремент `trips_driven` / `trips_ridden`"
делается не триггером, а внутри `complete_booking` и `settle_trip`: `trips_ridden` считается на бронь,
`trips_driven` на поездку (вопрос 5).

## 2. RPC

### `enter_pin(booking_id, pin)` водитель

1. Бронь есть (`BOOKING_NOT_FOUND`), поездка моя (`NOT_PARTICIPANT`). Блокировка trips -> bookings.
2. `status` в (`accepted`, `awaiting_confirm`), иначе `BOOKING_CLOSED`.
3. Окно `departure_at - 3 h .. departure_at + 24 h`, иначе `PIN_WINDOW_CLOSED`.
4. `pin_entered_at` уже стоит -> выход без ошибки (повторный ввод).
5. 5 неверных за 10 мин по этому водителю -> `RATE_LIMITED`.
6. `pin <> pin_code` -> событие `pin_failed`, `PIN_INVALID`.

Успех: `pin_entered_at = now()`; системное сообщение "Passageiro a bordo. PIN confirmado.";
событие `pin_entered`. Уведомления не нужны: обе стороны рядом.

### `confirm_trip(booking_id, happened)` пассажир

1. Бронь моя (`NOT_PARTICIPANT`); `status = awaiting_confirm`, иначе `BOOKING_CLOSED`.
2. `happened = true` -> `complete_booking(b, 'passenger')`.
3. `happened = false` -> `disputed`, `passenger_confirmed_at = now()`; системное сообщение
   "O passageiro indicou que a viagem não aconteceu. A moderação vai analisar o chat e o PIN.";
   `notify(driver, 'dispute_opened')`; событие `dispute_opened`. Окно спора: вопрос 1.

Возвращает `{status}`.

### `mark_no_show(booking_id)` водитель

1. Поездка моя; `status = awaiting_confirm`, иначе `BOOKING_CLOSED`.
2. `now() <= departure_at + 48 h`, иначе `NO_SHOW_WINDOW_CLOSED`.
3. У этой брони есть `pin_entered_at` -> `NO_SHOW_NEEDS_PIN` (пассажир сел, no-show невозможен).
4. Есть другая бронь этой поездки с `pin_entered_at` -> **no_show**: `status = no_show`,
   `driver_confirmed_at = completed_at = now()`; `ledger_release` на весь эскроу (водителю цена,
   платформе комиссия); `no_shows` пассажира +1; `notify(passenger, 'booking_no_show')`;
   `settle_trip`.
5. Иначе, если это единственная оплаченная бронь поездки (нет других в `accepted`,
   `awaiting_confirm`, `completed`, `no_show`, `disputed`) -> **disputed**: `driver_confirmed_at = now()`,
   системное сообщение "O condutor indicou que o passageiro não apareceu. A moderação vai analisar.";
   `notify(passenger, 'dispute_opened')`.
6. Иначе (несколько пассажиров, ни одного PIN) -> `NO_SHOW_NEEDS_PIN`.

Возвращает `{status}`.

### `resolve_dispute(booking_id, outcome, amount_kz)` admin

1. `is_admin()`, иначе `NOT_ADMIN`. `status = disputed`, иначе `BOOKING_CLOSED`.
2. `outcome` в (`completed`, `refund_full`, `refund_partial`), иначе `DISPUTE_OUTCOME_INVALID`.
3. `completed` -> `complete_booking(b, 'driver')` (водитель прав).
4. `refund_full` -> `ledger_refund` на весь эскроу; бронь `cancelled`, `cancelled_by = system`,
   `cancel_reason = 'dispute_refund'`, `refund_kz`; `no_shows` водителя +1 (вопрос 2);
   `notify(passenger, 'refund_done')`; `settle_trip`.
5. `refund_partial` -> `amount_kz` от 1 до эскроу минус 1, иначе `DISPUTE_AMOUNT_INVALID`;
   `ledger_refund(amount)`, затем `ledger_release` на остаток (водителю минус комиссия
   пропорционально); бронь `completed`, `completed_at`, `refund_kz = amount`; `trips_ridden` +1;
   `notify` обеим сторонам `dispute_resolved`; `settle_trip`.
6. Во всех случаях `moderation_actions(admin, target = passenger, action = resolve_dispute,
   reason = outcome + сумма)` (вопрос 3) и `notify(driver, 'dispute_resolved')`.

### `confirm_trip_intent(trip_id)` водитель

Поездка моя; `status` в (`published`, `full`), иначе `TRIP_CLOSED`; `driver_confirmed_at = now()`
(повторный вызов перезаписывает, не ошибка). Без уведомлений: это ответ на напоминание.

### `cancel_trip(trip_id, reason)` водитель

1. Поездка моя; `status` в (`draft`, `published`, `full`), иначе `TOO_LATE_TO_CANCEL`.
2. По каждой брони, под блокировкой поездки:
   - `pending_payment` -> `payment_failed` (оплата, если придёт, уйдёт по ветке поздней оплаты 0005);
   - `requested`, `accepted` -> `cancelled`, `cancelled_by = driver`, `cancel_reason`, `ledger_refund`
     100 %; `notify(passenger, 'trip_cancelled', sms)`; системное сообщение в чат;
   - `cancelled` пассажиром с остатком в эскроу -> `forfeit_trip_holds` (ТЗ: поездка не
     состоялась, удержанное платформе).
3. `trips.status = cancelled`, `cancelled_at`, `cancel_reason`.
4. `cancels_total` водителя +1, если была хотя бы одна бронь в `requested`/`accepted` (вопрос 4).

Возвращает `{cancelled_bookings, refunded_kz}`.

### `create_return_trip(trip_id, departure_at) -> jsonb`

Исходная поездка моя (любой статус). Собирает payload: города и детали местами, та же машина,
цена, `seats_offered`, `booking_mode`, багаж, флаги, заметки; вызывает `publish_trip(payload)`:
все проверки (профиль, машина, +2 ч, лимит 5, дубль +-2 ч) и возврат те же. Если машина с тех пор
удалена -> `VEHICLE_NOT_FOUND` из `publish_trip`.

### `update_trip(trip_id, payload)` водитель

1. Поездка моя; `status` в (`published`, `full`), иначе `TRIP_CLOSED`.
2. Разрешённые ключи: `price_per_seat_kz`, `seats_offered`, `notes`, `luggage`, `allows_smoking`,
   `allows_pets`, `max_two_in_back`, `origin_detail`, `destination_detail`, `departure_at`,
   `booking_mode`. Любой другой ключ (`origin_place_id`, `vehicle_id`, ...) -> `TRIP_FIELD_LOCKED`
   (вопрос 6).
3. `booking_mode` - всегда, действует на новые брони.
4. Цена, места, заметки, багаж, флаги, детали - только пока нет оплаченных броней
   (`requested`, `accepted`, `awaiting_confirm`), иначе `TRIP_HAS_BOOKINGS`. Валидация как в
   `publish_trip` (`PRICE_INVALID`, `SEATS_INVALID`); новые `seats_offered` не меньше занятых
   `pending_payment`; `seats_available` пересчитывается.
5. `departure_at` - только пока нет ни одной брони, включая `pending_payment`, иначе
   `TRIP_HAS_BOOKINGS`; не раньше `now() + 2 h` (`DEPARTURE_TOO_SOON`); дубль +-2 ч без самой
   поездки (`TRIP_DUPLICATE`); `driver_confirmed_at` сбрасывается.

Возвращает обновлённую строку `trips_public`-полей как jsonb.

## 3. Строки ledger по переходам (пример 7 000 + 1 000)

| Переход | op | Строки |
| --- | --- | --- |
| `confirm_trip(true)`, автозавершение, `resolve_dispute(completed)` | `release:<booking>` | `passenger_escrow -8 000`, `driver_balance +7 000`, `platform_fee +1 000` |
| `mark_no_show` -> `no_show` | `release:<booking>` | то же: пассажир не пришёл, водитель получает цену |
| `resolve_dispute(refund_full)` | `refund:<booking>` | `passenger_escrow -8 000`, `refunds +8 000` |
| `resolve_dispute(refund_partial, 3 000)` | `refund` + `release` | `escrow -3 000`, `refunds +3 000`; затем `escrow -5 000`, `driver_balance +4 375`, `platform_fee +625` |
| `cancel_trip`, бронь `requested`/`accepted` | `refund:<booking>` | `escrow -8 000`, `refunds +8 000` |
| `settle_trip`, удержанные 50 % после отмены пассажиром | `release:<booking>` | `escrow -4 000`, `driver_balance +3 500`, `platform_fee +500` |
| `cancel_trip`, удержанные 50 % | `forfeit:<booking>` | `escrow -4 000`, `platform_fee +4 000` |

Без денег: `enter_pin`, `confirm_trip(false)`, `mark_no_show -> disputed`, `confirm_trip_intent`,
`update_trip`, `create_return_trip`.

## 4. Новые коды (в раздел 7 ТЗ)

`NOT_ADMIN`, `TRIP_CLOSED`, `TRIP_HAS_BOOKINGS`, `TRIP_FIELD_LOCKED`, `NO_SHOW_WINDOW_CLOSED`,
`NO_SHOW_NEEDS_PIN`, `DISPUTE_OUTCOME_INVALID`, `DISPUTE_AMOUNT_INVALID`. Из раздела 7 используются:
`PIN_INVALID`, `PIN_WINDOW_CLOSED`, `RATE_LIMITED`, `BOOKING_CLOSED`, `NOT_PARTICIPANT`,
`TOO_LATE_TO_CANCEL`, `TRIP_NOT_FOUND`, `BOOKING_NOT_FOUND`, `PRICE_INVALID`, `SEATS_INVALID`,
`DEPARTURE_TOO_SOON`, `TRIP_DUPLICATE`.

Новые типы уведомлений (в раздел 9): `dispute_opened` (второй стороне), `dispute_resolved` (обеим),
`booking_no_show` (пассажиру). Уже есть: `payout_released`, `trip_cancelled`, `review_request`.

## 5. Grants

Все восемь RPC уже в блоке grants 0004. `resolve_dispute` остаётся `authenticated` с проверкой
`is_admin()` внутри, как решено для админских RPC (раздел 8: admin = роль в JWT). Внутренние
функции - revoke.

## 6. Тесты `supabase/tests/05_trip_lifecycle.test.sql`

Cron'а ещё нет, поэтому переходы `departed` / `awaiting_confirm` тест делает сам под superuser:
сдвигает `departure_at` в прошлое и ставит статусы напрямую.

1. **PIN**: до окна -> `PIN_WINDOW_CLOSED`; в окне неверный -> `PIN_INVALID`, 5 раз -> `RATE_LIMITED`;
   верный -> `pin_entered_at`, системное сообщение; повторный верный -> без ошибки; чужой
   водитель -> `NOT_PARTICIPANT`; пассажир -> `NOT_PARTICIPANT`.
2. **confirm_trip(true)**: `completed`, release 8 000 -> водитель 7 000 (`balance_kz`), платформа 1 000;
   `trips_ridden` +1; уведомления `payout_released`, `review_request` с `scheduled_for`; поездка с
   единственной бронью -> `completed`, `trips_driven` +1.
3. **confirm_trip(false)**: `disputed`, уведомление водителю; из `accepted` (до выезда) -> `BOOKING_CLOSED`.
4. **mark_no_show**: с PIN другого пассажира -> `no_show`, release водителю, `no_shows` пассажира +1;
   единственный пассажир без PIN -> `disputed`; два пассажира без PIN -> `NO_SHOW_NEEDS_PIN`;
   бронь с собственным PIN -> `NO_SHOW_NEEDS_PIN`; после 48 ч -> `NO_SHOW_WINDOW_CLOSED`.
5. **resolve_dispute**: не admin -> `NOT_ADMIN`; `completed`; `refund_full` -> `cancelled`, эскроу 0,
   `no_shows` водителя +1; `refund_partial(3 000)` -> пассажиру 3 000, водителю 4 375, платформе 625,
   `moderation_actions` строка; неверный outcome и сумма -> ошибки.
6. **settle_trip с удержанием**: отмена пассажиром < 24 ч (0005), затем вторая бронь `completed` ->
   поездка `completed`, удержанные 7 700 -> водитель 7 000, платформа 700.
7. **cancel_trip**: 1 `pending_payment` + 1 `requested` + 1 `accepted` + 1 отменённая пассажиром
   с удержанием -> `payment_failed` / `cancelled` x2 с полным возвратом / forfeit удержания;
   `cancels_total` +1; уведомления `trip_cancelled` с SMS; после `departed` -> `TOO_LATE_TO_CANCEL`;
   пустая поездка -> отменена, `cancels_total` без изменений.
8. **confirm_trip_intent**: ставит `driver_confirmed_at`; на `cancelled` -> `TRIP_CLOSED`;
   `cancel_quote` после этого даёт `passenger_late`, а не `driver_unconfirmed`.
9. **create_return_trip**: города и детали переставлены, цена/места/режим те же; дубль +-2 ч ->
   `TRIP_DUPLICATE`; чужая поездка -> `NOT_PARTICIPANT`.
10. **update_trip**: `booking_mode` при наличии броней - ок; цена при оплаченной брони ->
    `TRIP_HAS_BOOKINGS`; `departure_at` при `pending_payment` -> `TRIP_HAS_BOOKINGS`; без броней всё
    меняется, `seats_available` пересчитан; `vehicle_id` -> `TRIP_FIELD_LOCKED`; `seats_offered = 0` ->
    `SEATS_INVALID`.
11. **Инварианты**: сумма по каждому `op_id` = 0; `balance_kz` каждого водителя = сумма его
    `driver_balance`; ни одной брони в финальном статусе с остатком в эскроу, кроме `cancelled`
    пассажиром по незакрытой поездке.

## 7. Решения (приняты 8 ноя 2026, внесены в ТЗ)

1. **Окно спора:** пока бронь в `awaiting_confirm`. С PIN это до 48 ч (дальше автозавершение cron),
   без PIN до 7 дней. Код `DISPUTE_WINDOW_CLOSED` не нужен.
2. **`refund_full`:** бронь `cancelled`, `cancelled_by = system`, `cancel_reason = 'dispute_refund'`,
   водителю `no_shows` +1. При `refund_partial` счётчики не трогаются.
3. **`moderation_actions`:** добавлено значение `resolve_dispute`, target = пассажир,
   `reason = outcome[:сумма]`.
4. **`cancels_total` при отмене поездки:** +1 только если была хотя бы одна бронь в
   `requested`/`accepted`.
5. **`trips_driven`** на поездку (в `settle_trip`), `trips_ridden` на бронь.
6. **`update_trip` с запрещённым ключом:** ошибка `TRIP_FIELD_LOCKED`.
7. **Удержанные 50 %** при отмене поездки водителем уходят платформе, как в ТЗ: пассажир отменил
   сам и видел сумму, дальнейшая судьба поездки его решения не меняет; водитель, отменивший поездку,
   права на компенсацию не имеет.

Выяснилось по ходу:

- **`enter_pin` возвращает `jsonb {ok, attempts_left}`** вместо `void` с ошибкой `PIN_INVALID` на
  неверный PIN. Ошибка откатывает транзакцию вместе с записью о попытке, и лимит "5 неверных за
  10 минут" не работал бы. Теперь неверный PIN - обычный ответ `{ok: false, attempts_left: N}`,
  `RATE_LIMITED` бросается до любой записи, `PIN_INVALID` остался для формата (не 4 цифры).
  Смена типа возврата сделана через `drop function` + `create`, grant выдан заново. Клиентов ещё
  нет, ломать нечего.
- **Сигнатуры заглушек сохранены:** `create_return_trip` возвращает `uuid`, `cancel_trip`,
  `confirm_trip`, `mark_no_show`, `update_trip` - `void`. План выше местами обещал jsonb; клиент
  читает результат через `my_bookings` / realtime.
- **Счётчик неверных PIN** - события `pin_failed` в `events` с `user_id` водителя, как счётчик
  несовпадений телефона в 0005.
- **`notify` получил пятый параметр `p_scheduled_for`** (для `review_request` через 24 ч); старые
  вызовы с четырьмя аргументами работают через default.
- **Отмена поездки с `pending_payment`:** бронь уходит в `payment_failed` с
  `cancel_reason = 'trip_cancelled'`; если оплата всё же придёт, её вернёт ветка поздней оплаты 0005.
