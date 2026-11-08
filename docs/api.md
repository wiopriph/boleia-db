# Boleia API: контракт для клиентов

Сгенерировано `scripts/gen-api-doc.py` из локальной базы после `supabase db reset`. Источник правил -
`docs/spec.md`; здесь только то, что нужно, чтобы вызывать бэкенд. Машинные типы - `types/database.ts`.

Контракт = схема Postgres: **чтение** через views и таблицы под RLS (PostgREST `select`), **запись**
только через RPC (`supabase.rpc(...)`), статусы - enum'ы. Прямой insert/update в `trips`, `bookings`,
`messages` и т. п. закрыт.

## Подключение

| Что | Локально | Облако |
| --- | --- | --- |
| URL | `http://127.0.0.1:54321` (Android-эмулятор: `http://10.0.2.2:54321`) | `https://<ref>.supabase.co` |
| Ключ клиента | `anon` из `supabase status` | anon key проекта |
| Вход | только телефон + OTP; тестовые номера ниже с кодом `123456` | те же тестовые номера до появления SMS-провайдера |

Тестовые пользователи (seed, пароль-OTP `123456`):

| Телефон | Кто | Роль |
| --- | --- | --- |
| 244900000001 | Admin B. | admin (`app_metadata.role = admin` в JWT) |
| 244900000002 | João M. | водитель, verified, instant booking |
| 244900000003 | Teresa S. | водитель, verified, approval booking |
| 244900000004 | Pedro K. | водитель, не verified |
| 244900000005 | Ana R. | пассажир |

## Ошибки RPC

`PostgrestException` с `code = P0001` и `message = BOLEIA_<CODE>`. Клиент мапит код на текст pt-AO.
Коды: `AMOUNT_INVALID`, `BALANCE_NOT_ZERO`, `BOOKING_CLOSED`, `BOOKING_DUPLICATE`, `BOOKING_LIMIT_REACHED`, `BOOKING_NOT_FOUND`, `CHAT_CLOSED`, `CHAT_LIMIT_REACHED`, `CONTACT_LOCKED`, `DAYS_REQUIRED`, `DEPARTURE_TOO_SOON`, `DISPUTE_AMOUNT_INVALID`, `DISPUTE_OUTCOME_INVALID`, `DRIVER_LIMIT_REACHED`, `HAS_ACTIVE_BOOKINGS`, `INSUFFICIENT_BALANCE`, `LEDGER_IMMUTABLE`, `LEDGER_UNBALANCED`, `MESSAGE_EMPTY`, `MESSAGE_TOO_LONG`, `MODERATION_ACTION_INVALID`, `NAME_INVALID`, `NOT_ADMIN`, `NOT_AUTHENTICATED`, `NOT_PARTICIPANT`, `NO_SHOW_NEEDS_PIN`, `NO_SHOW_WINDOW_CLOSED`, `OWN_TRIP`, `PAYMENT_NOT_FOUND`, `PAYMENT_PENDING`, `PAYMENT_REF_MISMATCH`, `PAYMENT_RETRY_LIMIT`, `PAYMENT_STATUS_INVALID`, `PAYOUT_CLOSED`, `PAYOUT_METHOD_INVALID`, `PAYOUT_NOT_FOUND`, `PAYOUT_PENDING`, `PAYOUT_STATUS_INVALID`, `PIN_INVALID`, `PIN_WINDOW_CLOSED`, `PLACE_INVALID`, `PLACE_NOT_FOUND`, `PLACE_SLUG_TAKEN`, `PRICE_INVALID`, `PROFILE_INCOMPLETE`, `PROFILE_NOT_FOUND`, `PROFILE_RESTRICTED`, `PROTECTED_FIELD`, `RATE_LIMITED`, `RATING_INVALID`, `REASON_REQUIRED`, `REPORT_CLOSED`, `REPORT_NOT_FOUND`, `REPORT_OUTCOME_INVALID`, `REVIEW_DUPLICATE`, `REVIEW_WINDOW_CLOSED`, `SAME_PLACE`, `SEATS_INVALID`, `TAGS_INVALID`, `TARGET_INVALID`, `TARGET_IS_ADMIN`, `TOO_LATE_TO_CANCEL`, `TRIP_CLOSED`, `TRIP_DUPLICATE`, `TRIP_FIELD_LOCKED`, `TRIP_FULL`, `TRIP_HAS_BOOKINGS`, `TRIP_NOT_BOOKABLE`, `TRIP_NOT_FOUND`, `VEHICLE_INCOMPLETE`, `VEHICLE_LIMIT_REACHED`, `VEHICLE_NOT_FOUND`, `VERIFICATION_CLOSED`, `VERIFICATION_INCOMPLETE`, `VERIFICATION_PENDING`.

Значения кодов - ТЗ раздел 7. `42501` (permission denied) означает вызов RPC не той ролью.

## Основные флоу

**Поиск и бронь (пассажир).** `search_trips` -> карточка из `trips_public` -> (опционально чат
`send_message(body, null, trip_id)`) -> `request_booking(trip_id, seats, message)` -> получить
`booking_id`, `payment_id`, `amount_kz` -> `functions.invoke('payments-init', { booking_id })` ->
показать `instructions` (подтверждение в MCX Express / QR) -> ждать realtime по `bookings`
(`pending_payment -> accepted` или `requested`) или кнопка "Verificar" -> `payments-status`.
Оплата не прошла за 15 мин -> `payment_failed` -> `retry_payment(booking_id)`.

**Отмена.** `cancel_quote(booking_id)` показывает сумму и правило -> `cancel_booking(booking_id, reason)`.

**День поездки.** С `departure_at - 2 ч` в `my_bookings.pin_code` появляется PIN, `reveal_contact`
отдаёт телефон. Водитель вводит PIN: `enter_pin`. После выезда пассажиру приходит `trip_completed_ask`:
`confirm_trip(booking_id, true|false)`. Водитель может отметить `mark_no_show`.

**Водитель.** `upsert_profile` (аватар, payout_method) -> `upsert_vehicle` -> `publish_trip(payload)`.
Запросы по approval-поездкам: `respond_booking`. Кошелёк: `driver_wallet`, `request_payout`.

**Чат.** Список: `my_conversations`. Экран: `messages where conversation_id = ...` + realtime insert
на `messages`; отправка `send_message(body, conversation_id)`; при входе и новых сообщениях `mark_read`.
Телефоны и ссылки до оплаченной брони и до `departure_at - 2 ч` приходят как `[oculto]`.

## Realtime (ровно три подписки, ТЗ раздел 7)

- водитель: `bookings` where `trip_id in (мои активные)` - новые оплаченные запросы, отмены;
- пассажир: `bookings` where `passenger_id = uid` - accept/decline, статус платежа;
- открытый чат: `messages` where `conversation_id = <текущий>`, отписка при уходе с экрана.

Таблицы `bookings` и `messages` в publication `supabase_realtime`; RLS применяется к событиям.

## Edge Functions (`supabase.functions.invoke`)

| Функция | Вызов | Тело | Ответ |
| --- | --- | --- | --- |
| `payments-init` | POST, JWT пользователя | `{ "booking_id": uuid, "simulate"?: "paid|failed|mismatch|silent|silent_failed|qr|redirect" }` (`simulate` только с моком: `qr`/`redirect` меняют `instructions`, `silent*` без вебхука) | `{ payment_id, booking_id, amount_kz, expires_at, instructions: { type: "push"|"qr"|"redirect", deep_link?, qr_payload?, url? } }` |
| `payments-status` | POST, JWT | `{ "payment_id": uuid }` | `{ payment_id, payment_status, booking_status }` |

Ошибки функций: HTTP 4xx с `{ "code": "BOLEIA-код без префикса" }`, например `{ "code": "PAYMENT_NOT_FOUND" }`.
Остальные функции (`payments-webhook`, `payments-refund`, `notify`, `send-sms`, `payments-mock`) клиент не вызывает.

## Storage

| Бакет | Доступ | Путь |
| --- | --- | --- |
| `avatars` | чтение все, запись владелец | `<uid>/<file>` -> `profiles.avatar_url` через `upsert_profile` |
| `vehicles` | чтение все, запись владелец | `<uid>/<file>` -> `vehicles.photo_url` через `upsert_vehicle` |
| `verifications` | чтение владелец и admin, запись владелец | `<uid>/<file>`; пути передаются в `submit_verification` |

Лимит 5 MiB, изображения (для верификации ещё PDF). Сжимать на клиенте.

## Уведомления

`notifications where user_id = uid and channel = 'inapp'` - лента в приложении; push через FCM по
`register_device`. Типы: `booking_accepted`, `booking_cancelled_by_driver`, `booking_cancelled_by_passenger`, `booking_confirmed`, `booking_declined`, `booking_expired`, `booking_no_show`, `booking_requested`, `dispute_opened`, `dispute_resolved`, `driver_unconfirmed`, `moderation_action`, `new_message`, `payment_failed`, `payment_pending`, `payout_failed`, `payout_paid`, `payout_released`, `payout_requested`, `pin_ready`, `reconciliation_alert`, `refund_done`, `refund_manual`, `report_opened`, `review_request`, `trip_cancelled`, `trip_completed_ask`, `trip_reminder_24h`, `trip_reminder_2h`, `trip_reminder_6h`, `verification_approved`, `verification_rejected`, `verification_submitted`. Payload содержит `booking_id` / `trip_id` /
`conversation_id` для deep link (`boleia://booking/<id>`, `boleia://trip/<id>`).

## Формы jsonb

Аргументы `payload`/`doc_urls` и возвраты `jsonb` не выводятся из схемы; это их контракт.

**Аргументы**

| RPC | Ключи |
| --- | --- |
| `upsert_profile(payload)` | `display_name` (2-40), `avatar_url` (путь в `avatars/<uid>/`), `bio` (<= 300), `birth_year`, `chat_level` (enum), `locale`, `payout_method`: `{"type":"mcx_express","phone":"+244XXXXXXXXX"}` или `{"type":"iban","iban":"<25 знаков>","bank":"..."}`, `terms_accepted: true`, `adult_confirmed: true` (фиксируются один раз). Любой ключ опционален |
| `upsert_vehicle(payload)` | `id` (если есть - изменить), `make`*, `model`*, `color`, `year`, `plate`, `seats_total`* (1-8), `photo_url`, `status` (`active`/`removed`). Смена `plate` сбрасывает `verified` |
| `publish_trip(payload)` | `vehicle_id`*, `origin_place_id`*, `destination_place_id`* (только `city`/`town`), `origin_detail`, `destination_detail` (точка посадки, в т. ч. landmark), `departure_at`* (>= now + 2 ч), `seats_offered`* (1-4), `price_per_seat_kz`* (500-100000), `booking_mode` (`instant` по умолчанию), `luggage`, `allows_smoking`, `allows_pets`, `max_two_in_back`, `notes` (<= 500) |
| `update_trip(trip_id, payload)` | подмножество: `price_per_seat_kz`, `seats_offered`, `notes`, `luggage`, `allows_smoking`, `allows_pets`, `max_two_in_back`, `origin_detail`, `destination_detail`, `departure_at`, `booking_mode`; другие ключи -> `TRIP_FIELD_LOCKED` |
| `submit_verification(vehicle_id, doc_urls)` | `id_doc_url`, `licence_url`, `vehicle_photo_url`, `selfie_url` - все четыре, значения как пути `<uid>/<file>` в бакете `verifications` |

**Возвраты**

| RPC | Ключи |
| --- | --- |
| `request_booking`, `retry_payment` | `booking_id`, `payment_id`, `amount_kz` (= `price_total_kz` + `fee_kz`), `price_total_kz`, `fee_kz`, `expires_at` |
| `cancel_quote` | `refund_kz`, `gateway_fee_kz`, `held_kz`, `rule`, `counter` (bool: вырастет ли `cancels_total`) |
| `cancel_booking` | `status` (`cancelled` или `declined`), `refund_kz`, `held_kz`, `rule` |
| `enter_pin` | `ok` (bool); при `ok=false` `attempts_left`; при `ok=true` `pin_entered_at`, `already` (повторный ввод) |
| `reveal_contact` | `user_id`, `display_name`, `phone` (E.164) |
| `publish_trip` | `id`, `price_hint_kz` (может быть null) |
| `price_hint` | `price_hint_kz`, `minutes` (null, если маршрута нет в `route_durations`) |
| `upsert_profile` | строка `profiles` целиком |
| `my_bookings.pin_code` | 4 цифры или null до `departure_at - 2 ч` |

**Значения `rule`** (правило возврата, ТЗ раздел 5): `driver_cancel` (водитель отменил, 100 %),
`driver_decline` (водитель отклонил запрос, 100 %), `driver_unconfirmed` (водитель не подтвердил поездку
к -6 ч, 100 %), `passenger_withdraw` (пассажир снял неотвеченный запрос, 100 % минус комиссия шлюза),
`passenger_early` (> 24 ч, 100 % минус комиссия шлюза), `passenger_late` (< 24 ч, 50 %).

**Значения `bookings.cancel_reason`**, которые ставит система (остальное - свободный текст стороны):
`PAYMENT_PHONE_MISMATCH` (оплата с чужого номера, деньги возвращаются), `payment_expired` (15 минут
вышли), `trip_departed` (не оплачено к выезду), `trip_cancelled` (водитель отменил поездку, бронь была
не оплачена), `no_response` (водитель не ответил, запрос истёк), `dispute_refund` (модератор вернул
деньги), `driver_no_show` (водитель не приехал, автоотмена), `moderation` (поездка скрыта платформой).

## Enum'ы

| Enum | Значения |
| --- | --- |
| `booking_mode` | `instant`, `approval` |
| `booking_status` | `pending_payment`, `payment_failed`, `requested`, `accepted`, `declined`, `expired`, `cancelled`, `awaiting_confirm`, `completed`, `no_show`, `disputed` |
| `chat_level` | `bla`, `blabla`, `blablabla` |
| `driver_status` | `none`, `pending`, `verified`, `rejected` |
| `ledger_account` | `passenger_escrow`, `driver_balance`, `platform_fee`, `refunds`, `gateway_fees`, `cash_out`, `cash_in` |
| `luggage_size` | `small`, `medium`, `large` |
| `mod_action` | `warn`, `restrict`, `suspend`, `ban`, `unban`, `verify_id`, `resolve_dispute`, `hide_trip`, `cancel_booking`, `manual_refund`, `report_dismissed` |
| `notif_channel` | `push`, `sms`, `inapp` |
| `notif_status` | `queued`, `sent`, `failed`, `read` |
| `party` | `passenger`, `driver`, `system` |
| `payment_status` | `created`, `pending`, `paid`, `failed`, `expired`, `refunded`, `partially_refunded` |
| `payout_status` | `requested`, `processing`, `paid`, `failed`, `cancelled` |
| `place_kind` | `city`, `town`, `landmark` |
| `platform` | `ios`, `android`, `web` |
| `profile_status` | `active`, `restricted`, `suspended`, `banned`, `deleted` |
| `report_reason` | `no_show`, `unsafe_driving`, `harassment`, `scam`, `cash_offer`, `wrong_price`, `other` |
| `report_status` | `open`, `reviewed`, `actioned`, `dismissed` |
| `review_direction` | `passenger_to_driver`, `driver_to_passenger` |
| `trip_status` | `draft`, `published`, `full`, `departed`, `completed`, `cancelled`, `expired` |
| `vehicle_status` | `active`, `removed` |
| `verification_status` | `pending`, `approved`, `rejected` |

## Views

### `driver_wallet`

Кошелёк водителя: баланс, в ожидании, заработано, заявки в работе. Только своя строка. Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `user_id` | `uuid` |
| `balance_kz` | `integer` |
| `pending_kz` | `bigint` |
| `earned_total_kz` | `bigint` |
| `payouts_pending_kz` | `bigint` |
| `payout_method` | `jsonb` |

### `my_bookings`

Брони текущего пользователя с обеих сторон: пассажир видит свои, водитель - брони своих поездок (фильтр по auth.uid() внутри view). Для водителя заполнены passenger_*; для пассажира - driver_* и vehicle_*; pin_code появляется с departure_at - 2 ч. cancel_reason объясняет payment_failed и cancelled. Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `id` | `uuid` |
| `trip_id` | `uuid` |
| `passenger_id` | `uuid` |
| `seats` | `smallint` |
| `price_total_kz` | `integer` |
| `fee_kz` | `integer` |
| `paid_total_kz` | `integer` |
| `status` | `booking_status` |
| `pin_code` | `bpchar` |
| `pin_entered_at` | `timestamp with time zone` |
| `requested_at` | `timestamp with time zone` |
| `responded_at` | `timestamp with time zone` |
| `cancelled_at` | `timestamp with time zone` |
| `cancelled_by` | `party` |
| `refund_kz` | `integer` |
| `passenger_confirmed_at` | `timestamp with time zone` |
| `completed_at` | `timestamp with time zone` |
| `created_at` | `timestamp with time zone` |
| `departure_at` | `timestamp with time zone` |
| `trip_status` | `trip_status` |
| `booking_mode` | `booking_mode` |
| `origin_detail` | `text` |
| `destination_detail` | `text` |
| `origin_name` | `text` |
| `origin_slug` | `text` |
| `destination_name` | `text` |
| `destination_slug` | `text` |
| `driver_id` | `uuid` |
| `driver_name` | `text` |
| `driver_avatar_url` | `text` |
| `payment_status` | `payment_status` |
| `payment_expires_at` | `timestamp with time zone` |
| `conversation_id` | `uuid` |
| `vehicle_make` | `text` |
| `vehicle_model` | `text` |
| `vehicle_color` | `text` |
| `vehicle_photo_url` | `text` |
| `vehicle_plate_suffix` | `text` |
| `cancel_reason` | `text` |
| `message` | `text` |
| `passenger_name` | `text` |
| `passenger_avatar_url` | `text` |
| `passenger_rating_avg` | `numeric(3,2)` |
| `passenger_trips_ridden` | `integer` |
| `passenger_cancels_total` | `smallint` |

### `my_conversations`

Чаты текущего пользователя с собеседником, последним сообщением и unread_count (системные тоже считаются). Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `id` | `uuid` |
| `trip_id` | `uuid` |
| `booking_id` | `uuid` |
| `passenger_id` | `uuid` |
| `driver_id` | `uuid` |
| `other_user_id` | `uuid` |
| `other_user_name` | `text` |
| `other_user_avatar_url` | `text` |
| `last_message_at` | `timestamp with time zone` |
| `closed_at` | `timestamp with time zone` |
| `departure_at` | `timestamp with time zone` |
| `origin_name` | `text` |
| `destination_name` | `text` |
| `last_message_body` | `text` |
| `last_message_sender_id` | `uuid` |
| `unread_count` | `bigint` |

### `pending_refunds`

Очередь возвратов для Edge payments-refund. Только service role. Читают: service_role.

| Колонка | Тип |
| --- | --- |
| `payment_id` | `uuid` |
| `booking_id` | `uuid` |
| `payer_id` | `uuid` |
| `payer_phone` | `text` |
| `provider_ref` | `text` |
| `amount_kz` | `integer` |
| `refund_kz` | `integer` |
| `refund_attempts` | `smallint` |
| `refund_failed_at` | `timestamp with time zone` |
| `updated_at` | `timestamp with time zone` |

### `profiles_public`

Публичный профиль: доверие, рейтинг, бейдж отмен. Без телефона и баланса. Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `id` | `uuid` |
| `display_name` | `text` |
| `avatar_url` | `text` |
| `bio` | `text` |
| `birth_year` | `smallint` |
| `chat_level` | `chat_level` |
| `driver_verified` | `boolean` |
| `rating_avg` | `numeric(3,2)` |
| `rating_count` | `integer` |
| `trips_driven` | `integer` |
| `trips_ridden` | `integer` |
| `cancels_total` | `smallint` |
| `cancel_badge` | `text` |
| `member_since` | `timestamp with time zone` |

### `reviews_public`

Видимые отзывы с именем и аватаром автора. Для /perfil/<id>/avaliacoes: where target_id = ... Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `id` | `uuid` |
| `booking_id` | `uuid` |
| `target_id` | `uuid` |
| `author_id` | `uuid` |
| `author_name` | `text` |
| `author_avatar_url` | `text` |
| `direction` | `review_direction` |
| `rating` | `smallint` |
| `tags` | `text[]` |
| `comment` | `text` |
| `created_at` | `timestamp with time zone` |

### `route_stats`

Маршруты для SEO: все пары из route_durations плюс пары с поездками; счётчики, минимальная цена, длительность и подсказка цены. Materialized, refresh раз в час. Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `origin_slug` | `text` |
| `origin_name` | `text` |
| `destination_slug` | `text` |
| `destination_name` | `text` |
| `trips_30d` | `bigint` |
| `trips_upcoming` | `bigint` |
| `min_price_kz` | `integer` |
| `next_departure_at` | `timestamp with time zone` |
| `refreshed_at` | `timestamp with time zone` |
| `minutes` | `smallint` |
| `price_hint_kz` | `integer` |

### `trips_public`

Поездки в published/full для поиска и карточки. Без телефона и номера машины. Читают: anon, authenticated, service_role.

| Колонка | Тип |
| --- | --- |
| `id` | `uuid` |
| `status` | `trip_status` |
| `departure_at` | `timestamp with time zone` |
| `seats_offered` | `smallint` |
| `seats_available` | `smallint` |
| `price_per_seat_kz` | `integer` |
| `currency` | `character(3)` |
| `booking_mode` | `booking_mode` |
| `luggage` | `luggage_size` |
| `allows_smoking` | `boolean` |
| `allows_pets` | `boolean` |
| `max_two_in_back` | `boolean` |
| `notes` | `text` |
| `origin_detail` | `text` |
| `destination_detail` | `text` |
| `published_at` | `timestamp with time zone` |
| `origin_place_id` | `uuid` |
| `origin_name` | `text` |
| `origin_slug` | `text` |
| `origin_province` | `text` |
| `destination_place_id` | `uuid` |
| `destination_name` | `text` |
| `destination_slug` | `text` |
| `destination_province` | `text` |
| `duration_minutes` | `smallint` |
| `driver_id` | `uuid` |
| `driver_name` | `text` |
| `driver_avatar_url` | `text` |
| `driver_rating_avg` | `numeric(3,2)` |
| `driver_rating_count` | `integer` |
| `driver_trips_driven` | `integer` |
| `driver_verified` | `boolean` |
| `driver_cancels_total` | `smallint` |
| `driver_chat_level` | `chat_level` |
| `vehicle_make` | `text` |
| `vehicle_model` | `text` |
| `vehicle_color` | `text` |
| `vehicle_photo_url` | `text` |
| `vehicle_verified` | `boolean` |


## Таблицы: что читается напрямую

RLS: пользователь видит свои строки (пассажир - свои брони, водитель - брони своих поездок,
участники - свои чаты). Колонки - в `types/database.ts`.

| Таблица | anon select | authenticated select | authenticated write |
| --- | --- | --- | --- |
| `banned_phones` | да | да | - |
| `bookings` | да | да | - |
| `contact_reveals` | да | да | - |
| `conversations` | да | да | - |
| `devices` | да | да | да |
| `driver_verifications` | да | да | - |
| `events` | да | да | - |
| `ledger_entries` | да | да | - |
| `messages` | да | да | - |
| `moderation_actions` | да | да | - |
| `notifications` | да | да | - |
| `payments` | - | - | - |
| `payouts` | да | да | - |
| `places` | да | да | - |
| `profiles` | да | да | - |
| `reports` | да | да | - |
| `reviews` | да | да | - |
| `route_durations` | да | да | - |
| `scheduler_jobs` | да | да | - |
| `trip_stops` | да | да | - |
| `trips` | да | да | - |
| `vehicles` | да | да | - |

## RPC для клиентов

### `search_trips(origin_slug text, destination_slug text, travel_date date, seats integer DEFAULT 1, cursor_departure timestamp with time zone DEFAULT NULL::timestamp with time zone, cursor_id uuid DEFAULT NULL::uuid, page_size integer DEFAULT 20)`

Возвращает `SETOF trips_public`. Кто: anon, authenticated.

Поиск по trips_public, +-1 день от travel_date, keyset по (departure_at, id). Доступен анонимам.

### `price_hint(origin_place_id uuid, destination_place_id uuid)`

Возвращает `jsonb`. Кто: anon, authenticated.

Подсказка цены по route_durations для экрана публикации.

### `upsert_profile(payload jsonb)`

Возвращает `profiles`. Кто: authenticated.

Имя, bio, год рождения, chat_level, payout_method, locale. Телефон не меняется.

### `upsert_vehicle(payload jsonb)`

Возвращает `uuid`. Кто: authenticated.

Создать или изменить машину (payload с id = изменить). Смена номера сбрасывает verified.

### `register_device(device_platform platform, token text, app_version text DEFAULT NULL::text)`

Возвращает `void`. Кто: authenticated.

Push-токен устройства (upsert по токену).

### `mark_notifications_read(ids uuid[])`

Возвращает `void`. Кто: authenticated.

Отметить in-app уведомления прочитанными.

### `publish_trip(payload jsonb)`

Возвращает `jsonb`. Кто: authenticated.

Опубликовать поездку. Профиль с аватаром и payout_method, не больше 5 активных, без дубля +-2 ч.

### `create_return_trip(trip_id uuid, departure_at timestamp with time zone)`

Возвращает `uuid`. Кто: authenticated.

Копия поездки с перестановкой городов через publish_trip. Возвращает id новой поездки.

### `update_trip(trip_id uuid, payload jsonb)`

Возвращает `void`. Кто: authenticated.

Цена/места/детали пока нет оплаченных броней; время пока нет броней; booking_mode всегда.

### `confirm_trip_intent(trip_id uuid)`

Возвращает `void`. Кто: authenticated.

Водитель подтверждает, что едет (ответ на напоминание -24 ч).

### `cancel_trip(trip_id uuid, reason text DEFAULT NULL::text)`

Возвращает `void`. Кто: authenticated.

Отмена поездки водителем с каскадом возвратов по броням.

### `request_booking(trip_id uuid, seats integer, message text DEFAULT NULL::text)`

Возвращает `jsonb`. Кто: authenticated.

Бронь pending_payment + платёж created. Дальше functions/payments-init.

### `retry_payment(booking_id uuid)`

Возвращает `jsonb`. Кто: authenticated.

Новая попытка оплаты из payment_failed, не больше 3 на бронь.

### `respond_booking(booking_id uuid, accept boolean, reason text DEFAULT NULL::text)`

Возвращает `void`. Кто: authenticated.

Водитель принимает или отклоняет запрос (approval-поездки).

### `cancel_quote(booking_id uuid)`

Возвращает `jsonb`. Кто: authenticated.

Сумма возврата и правило до подтверждения отмены: {refund_kz, gateway_fee_kz, held_kz, rule}.

### `cancel_booking(booking_id uuid, reason text DEFAULT NULL::text)`

Возвращает `jsonb`. Кто: authenticated.

Отмена брони пассажиром или водителем по таблице возвратов ТЗ раздела 5.

### `enter_pin(booking_id uuid, pin text)`

Возвращает `jsonb`. Кто: authenticated.

Водитель вводит PIN пассажира. {ok, attempts_left}; 5 неверных за 10 мин -> RATE_LIMITED.

### `confirm_trip(booking_id uuid, happened boolean)`

Возвращает `void`. Кто: authenticated.

Пассажир: доехал (true -> completed, деньги водителю) или не ехал (false -> disputed).

### `mark_no_show(booking_id uuid)`

Возвращает `void`. Кто: authenticated.

Водитель: пассажир не пришёл. Нужен PIN другого пассажира, иначе спор.

### `resolve_dispute(booking_id uuid, outcome text, amount_kz integer DEFAULT NULL::integer)`

Возвращает `void`. Кто: authenticated.

Admin: completed | refund_full | refund_partial(amount_kz).

### `send_message(body text, conversation_id uuid DEFAULT NULL::uuid, trip_id uuid DEFAULT NULL::uuid)`

Возвращает `bigint`. Кто: authenticated.

Сообщение в чат; без conversation_id создаёт чат по trip_id. Лимиты и маскирование в SQL.

### `mark_read(conversation_id uuid, up_to_message_id bigint)`

Возвращает `void`. Кто: authenticated.

Отметить чужие сообщения прочитанными до up_to_message_id.

### `reveal_contact(booking_id uuid)`

Возвращает `jsonb`. Кто: authenticated.

Телефон второй стороны: только accepted/awaiting_confirm и с departure_at - 2 ч.

### `submit_review(booking_id uuid, rating integer, tags text[] DEFAULT '{}'::text[], comment text DEFAULT NULL::text)`

Возвращает `uuid`. Кто: authenticated.

Отзыв по брони completed/no_show в течение 14 дней. tags: pontual, condução_segura, simpático.

### `report_user(target_id uuid, reason report_reason, details text DEFAULT NULL::text, trip_id uuid DEFAULT NULL::uuid, booking_id uuid DEFAULT NULL::uuid, message_id bigint DEFAULT NULL::bigint)`

Возвращает `uuid`. Кто: authenticated.

Жалоба на пользователя с контекстом (trip/booking/message).

### `request_payout(amount_kz integer)`

Возвращает `uuid`. Кто: authenticated.

Заявка на выплату: >= 5000, одна в работе, раз в 7 дней.

### `mark_payout(payout_id uuid, new_status text, ref text DEFAULT NULL::text)`

Возвращает `void`. Кто: authenticated.

Admin: processing | paid | failed (failed возвращает деньги на баланс).

### `submit_verification(vehicle_id uuid, doc_urls jsonb)`

Возвращает `uuid`. Кто: authenticated.

Заявка на верификацию: 4 документа в бакете verifications/<uid>/.

### `review_verification(verification_id uuid, approve boolean, reason text DEFAULT NULL::text)`

Возвращает `void`. Кто: authenticated.

Admin: одобрить или отклонить с причиной.

### `delete_me()`

Возвращает `void`. Кто: authenticated.

Удалить аккаунт: обезличивание, история остаётся. Нельзя при активных бронях или балансе.

### `is_admin()`

Возвращает `boolean`. Кто: anon, authenticated.

role = admin в JWT. Используется в RLS.

### `admin_search_users(q text, lim integer DEFAULT 20)`

Возвращает `SETOF jsonb`. Кто: authenticated.

Admin: поиск по телефону (цифры, + и пробелы игнорируются), имени или id; карточка пользователя одним вызовом.

### `admin_moderate(target_id uuid, action mod_action, reason text, days integer DEFAULT NULL::integer, report_id uuid DEFAULT NULL::uuid)`

Возвращает `void`. Кто: authenticated.

Admin: warn | restrict | suspend (days) | ban | unban; пишет moderation_actions, цели moderation_action; с report_id жалоба -> actioned.

### `admin_resolve_report(report_id uuid, outcome text, note text DEFAULT NULL::text)`

Возвращает `void`. Кто: authenticated.

Admin: reviewed (в работе) | dismissed.

### `admin_cancel_trip(trip_id uuid, reason text)`

Возвращает `jsonb`. Кто: authenticated.

Admin: скрыть поездку = отмена платформой, возвраты 100 %, без cancels_total водителю. -> {cancelled_bookings, refunded_kz}.

### `admin_cancel_booking(booking_id uuid, reason text)`

Возвращает `jsonb`. Кто: authenticated.

Admin: отмена одной брони платформой, возврат 100 %, счётчики сторон не меняются. -> {status, refund_kz}.

### `admin_mark_refund_manual(payment_id uuid, ref text, note text DEFAULT NULL::text)`

Возвращает `jsonb`. Кто: authenticated.

Admin: возврат сделан вручную переводом (ref), закрывает очередь refund_manual.

### `admin_upsert_place(payload jsonb)`

Возвращает `uuid`. Кто: authenticated.

Admin: payload {id?, name, province, slug, kind, lat, lng, aliases[], is_active}; slug уникален.

### `admin_merge_places(from_id uuid, into_id uuid)`

Возвращает `void`. Кто: authenticated.

Admin: слить дубль from_id в into_id (поездки, route_durations, алиасы), from деактивируется.

### `admin_stats()`

Возвращает `jsonb`. Кто: authenticated.

Admin: {queues, today, week, health} для дашборда.

### `admin_weekly(weeks integer DEFAULT 8)`

Возвращает `SETOF jsonb`. Кто: authenticated.

Admin: по неделям воронка, GMV, fee, возвраты, отмены по сторонам, время ответа водителя и верификации, top_routes.


## RPC только для service role (Edge Functions, cron)

- `confirm_payment(payment_id uuid, provider_ref text, new_status text, payer_phone text, raw jsonb DEFAULT '{}'::jsonb)` -> `void`: Вебхук шлюза (service role): paid/failed/expired по платежу.
- `payment_initiated(payment_id uuid, provider_ref text, raw jsonb DEFAULT '{}'::jsonb)` -> `jsonb`: payments-init создал транзакцию: created -> pending.
- `payment_refund_result(payment_id uuid, ok boolean, refund_ref text DEFAULT NULL::text, raw jsonb DEFAULT '{}'::jsonb)` -> `jsonb`: payments-refund сходил в шлюз: refund_ref или попытка.
- `notification_delivered(id uuid, ok boolean, error text DEFAULT NULL::text)` -> `void`: notify отправил push/SMS: sent или повтор/failed.
- `run_scheduler(as_of timestamp with time zone DEFAULT now())` -> `jsonb`: Cron каждые 5 минут; as_of для тестов.
