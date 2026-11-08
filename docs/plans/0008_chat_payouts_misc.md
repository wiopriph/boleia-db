# План миграции 0008_chat_payouts_misc

ТЗ: раздел 4 (`conversations`, `messages`, `reviews`, `reports`, `contact_reveals`, `payouts`,
`driver_verifications`), раздел 6 (RPC `send_message`, `mark_read`, `reveal_contact`, `submit_review`,
`report_user`, `request_payout`, `mark_payout`, `submit_verification`, `review_verification`, `delete_me`;
триггер маскирования), раздел 8 (RLS, Storage, удаление аккаунта), раздел 9 (`new_message`), раздел 10
(выплаты), раздел 11 (модерация).

Последняя SQL-миграция I1: после неё все RPC раздела 6 имеют тела. Сигнатуры заглушек сохраняются.

## 1. Схема (вопросы 1-4)

| Что | Зачем |
| --- | --- |
| `reports.reporter_id` nullable | автожалоба `cash_offer` от системы: `reporter_id = null` |
| `conversations.passenger_seen_at`, `driver_seen_at` timestamptz | "получатель не в этом чате последние 60 с" для push `new_message`; ставятся в `mark_read` и `send_message` |
| enum `profile_status` + `deleted` | обезличенный аккаунт после `delete_me`; `trips_public` и `profiles_public` его уже не показывают (фильтр по `active`/`restricted`) |
| Storage: бакеты `avatars` (public), `vehicles` (public), `verifications` (private) + политики на `storage.objects` | загрузка владельцем в `<uid>/...`, чтение public или admin; `submit_verification` принимает пути в `verifications` |

## 2. Чат

### Триггер `messages_mask` before insert

Для сообщений с `sender_id not null`: маскирование активно, пока у чата нет оплаченной брони
(`booking_id is null` или бронь не в `accepted`/`awaiting_confirm`/`completed`/`no_show`/`disputed`)
или до `departure_at - 2 ч`. Паттерны из ТЗ: `\+?244\d{9}`, `\b9\d{8}\b`, `wa\.me\S*`, `https?://\S*`
-> `[oculto]`, `masked = true`. Третье замаскированное сообщение одного отправителя в одном чате ->
`reports(reporter_id = null, target = отправитель, reason = cash_offer, message_id)`, один раз на чат
и отправителя. Системные сообщения (`sender_id null`) не трогаются.

### `send_message(body, conversation_id, trip_id) -> bigint`

1. `body` после `btrim`: пусто -> `MESSAGE_EMPTY`, > 1000 -> `MESSAGE_TOO_LONG`.
2. Чат: по `conversation_id` - участник, иначе `NOT_PARTICIPANT`; без него нужен `trip_id`:
   поездка в `published`/`full` (`TRIP_CLOSED`), не своя (`OWN_TRIP`), `ensure_conversation`.
   Новых чатов без брони за 24 ч у пассажира >= 5 -> `CHAT_LIMIT_REACHED`.
3. `closed_at not null` -> `CHAT_CLOSED`.
4. Чат без оплаченной брони и отправитель пассажир с >= 10 своими сообщениями -> `CHAT_LIMIT_REACHED`
   (клиент показывает "Reservar para continuar").
5. >= 60 сообщений отправителя за последнюю минуту по всем чатам -> `RATE_LIMITED`.
6. Insert (триггер маскирует), `last_message_at`, `<my>_seen_at = now()`; получателю
   `notify('new_message', {conversation_id, preview})` push-only, если его `seen_at < now() - 60 с`.
   Превью берётся уже замаскированное.

### `mark_read(conversation_id, up_to_message_id)`

Участник; `read_at = now()` у чужих сообщений с `id <= up_to` и `read_at is null`;
`<my>_seen_at = now()`.

### `reveal_contact(booking_id) -> jsonb {user_id, display_name, phone}`

Участник брони (`NOT_PARTICIPANT`); бронь в `accepted`/`awaiting_confirm` (`BOOKING_CLOSED`);
`now() >= departure_at - 2 ч`, иначе `CONTACT_LOCKED`; запись в `contact_reveals`; телефон второй
стороны в E.164.

## 3. Отзывы и жалобы

### `submit_review(booking_id, rating, tags, comment) -> uuid`

Участник; бронь `completed`/`no_show` (`BOOKING_CLOSED`); `completed_at + 14 дней > now()`, иначе
`REVIEW_WINDOW_CLOSED`; `rating` 1..5 (`RATING_INVALID`); `tags` из {`pontual`, `condução_segura`,
`simpático`} (`TAGS_INVALID`); `comment` <= 300 (`MESSAGE_TOO_LONG`); направление по роли; повтор ->
`REVIEW_DUPLICATE`. Рейтинг и видимость считает триггер 0001, одиночные отзывы открывает cron 0007.

### `report_user(target_id, reason, details, trip_id, booking_id, message_id) -> uuid`

Не на себя и цель существует (`TARGET_INVALID`); `details` <= 1000; >= 10 жалоб за сутки ->
`RATE_LIMITED`; `reports(open)`; админам in-app `report_opened` (вопрос 6).

## 4. Выплаты (ТЗ раздел 10)

### `request_payout(amount_kz) -> uuid`

`payout_method` есть (`PAYOUT_METHOD_INVALID`); `amount_kz >= 5000` (`AMOUNT_INVALID`); блокировка
строки профиля; `balance_kz >= amount` (`INSUFFICIENT_BALANCE`); нет заявки в `requested`/`processing`
(`PAYOUT_PENDING`); последняя заявка старше 7 дней (`RATE_LIMITED`). Ledger `payout:<id>`:
`driver_balance -N`, `cash_out +N` (строки с `payout_id`); `payouts(requested, method = снимок)`;
админам in-app `payout_requested`.

### `mark_payout(payout_id, new_status, ref)` admin

`new_status` в (`processing`, `paid`, `failed`) (`PAYOUT_STATUS_INVALID`); из `requested`/`processing`
(`BOOKING_CLOSED` не подходит -> `PAYOUT_CLOSED`). `paid` -> `provider_ref = ref`, `processed_by/at`,
водителю `payout_paid`. `failed` -> ledger `payout_failed:<id>`: `cash_out -N`, `driver_balance +N`,
водителю `payout_failed`. Любой исход пишет `moderation_actions`? Нет: выплата не модерация, только
`processed_by`.

## 5. Верификация (ТЗ разделы 6, 8)

### `submit_verification(vehicle_id, doc_urls) -> uuid`

Машина моя и `active` (`VEHICLE_NOT_FOUND`); `doc_urls` содержит все четыре ключа `id_doc_url`,
`licence_url`, `vehicle_photo_url`, `selfie_url`, каждый - путь в бакете `verifications/<uid>/`
(`VERIFICATION_INCOMPLETE`); уже есть `pending` -> `VERIFICATION_PENDING`; последний `rejected`
моложе 24 ч -> `RATE_LIMITED`. Insert; `driver_status -> pending`, если сейчас `none`/`rejected`
(verified водитель с новой машиной остаётся verified, вопрос 5); админам in-app `verification_submitted`.

### `review_verification(verification_id, approve, reason)` admin

Заявка `pending` (`VERIFICATION_CLOSED`). Approve -> `approved`, `reviewed_by/at`,
`profiles.driver_status = verified`, `driver_verified_at`, `vehicles.verified = true`,
`moderation_actions(verify_id)`, водителю `verification_approved`. Reject -> `reason` обязателен
(`REASON_REQUIRED`), `rejected`, `reject_reason`, `driver_status = rejected`, если не verified
по другой машине; водителю `verification_rejected` с причиной. Документы обнулит cron через 30 дней.

## 6. `delete_me()`

Запрещено: активные брони как пассажир (`pending_payment`, `requested`, `accepted`, `awaiting_confirm`,
`disputed`) или как водитель (поездки `published`/`full`/`departed`, брони в тех же статусах) ->
`HAS_ACTIVE_BOOKINGS`; `balance_kz <> 0` или заявка на выплату в работе -> `BALANCE_NOT_ZERO`.
Обезличивание: `display_name = 'Utilizador removido'`, `avatar_url`, `bio`, `birth_year`,
`payout_method`, `phone` -> null, `status = deleted`; `devices` удалить; открытые чаты закрыть;
`driver_verifications` -> обнулить URL; `auth.users`: `phone = null`, `banned_until = infinity`,
чтобы номер можно было зарегистрировать заново, а старая сессия умерла. Поездки, брони, отзывы,
ledger остаются (ТЗ раздел 8). `moderation_actions` не пишется: действие пользователя.

## 7. Коды (в раздел 7 ТЗ)

Новые: `MESSAGE_EMPTY`, `CHAT_LIMIT_REACHED`, `CONTACT_LOCKED`, `REVIEW_WINDOW_CLOSED`,
`REVIEW_DUPLICATE`, `RATING_INVALID`, `TAGS_INVALID`, `TARGET_INVALID`, `AMOUNT_INVALID`,
`PAYOUT_PENDING`, `PAYOUT_CLOSED`, `PAYOUT_STATUS_INVALID`, `VERIFICATION_INCOMPLETE`,
`VERIFICATION_PENDING`, `VERIFICATION_CLOSED`, `REASON_REQUIRED`, `HAS_ACTIVE_BOOKINGS`,
`BALANCE_NOT_ZERO`. Используются из списка: `CHAT_CLOSED`, `RATE_LIMITED`, `NOT_PARTICIPANT`,
`MESSAGE_TOO_LONG`, `TRIP_CLOSED`, `OWN_TRIP`, `BOOKING_CLOSED`, `INSUFFICIENT_BALANCE`,
`PAYOUT_METHOD_INVALID`, `VEHICLE_NOT_FOUND`, `NOT_ADMIN`.

Уведомления (в раздел 9): `new_message` (есть), `payout_paid`/`payout_failed` (есть),
`verification_approved`/`verification_rejected` (есть); новые in-app для админов: `report_opened`,
`payout_requested`, `verification_submitted` - очередь, которую в I4 читает Telegram-бот.

## 8. Тесты `supabase/tests/07_chat_payouts_misc.test.sql`

1. **Чат до брони:** Ana пишет с карточки, чат создан; 10 сообщений, 11-е -> `CHAT_LIMIT_REACHED`;
   6-й новый чат за сутки -> `CHAT_LIMIT_REACHED`; водитель своей поездке -> `OWN_TRIP`; чужой чат ->
   `NOT_PARTICIPANT`; пустое и 1001 символ -> ошибки.
2. **Маскирование:** `+244912345678`, `912345678`, `wa.me/...`, `http://...` -> `[oculto]`,
   `masked = true`; обычный текст не тронут; после оплаты и `departure_at - 2 ч` не маскируется;
   системные сообщения не маскируются; третье замаскированное -> `reports(cash_offer)`, четвёртое
   не дублирует жалобу.
3. **60/мин:** 60 сообщений проходят, 61-е -> `RATE_LIMITED`.
4. **new_message и presence:** получатель без `seen_at` -> push-строка; после `mark_read` в
   течение 60 с - нет; `mark_read` ставит `read_at` только чужим; `unread_count` в `my_conversations`.
5. **Закрытый чат:** `closed_at` -> `CHAT_CLOSED`.
6. **reveal_contact:** до -2 ч -> `CONTACT_LOCKED`; после - телефон второй стороны, строка в
   `contact_reveals`; из `cancelled` -> `BOOKING_CLOSED`; чужой -> `NOT_PARTICIPANT`.
7. **submit_review:** из `completed` обе стороны, `rating_avg`/`rating_count` пересчитаны, второй
   отзыв делает оба видимыми; повтор -> `REVIEW_DUPLICATE`; через 15 дней -> `REVIEW_WINDOW_CLOSED`;
   из `accepted` -> `BOOKING_CLOSED`; теги вне набора -> `TAGS_INVALID`; из `no_show` разрешено.
8. **report_user:** на себя -> `TARGET_INVALID`; обычная жалоба `open`, админу `report_opened`;
   11-я за сутки -> `RATE_LIMITED`.
9. **Выплаты:** баланс 14 000 (release из 0006-сценария): `request_payout(4000)` -> `AMOUNT_INVALID`;
   `20000` -> `INSUFFICIENT_BALANCE`; `10000` -> заявка, `balance_kz = 4000`, ledger `payout:` в нуле;
   вторая сразу -> `PAYOUT_PENDING`; `mark_payout(failed)` -> баланс 14 000 снова; новая заявка в
   течение 7 дней -> `RATE_LIMITED`; `mark_payout(paid)` -> `provider_ref`, `processed_by`,
   уведомление; не admin -> `NOT_ADMIN`.
10. **Верификация:** неполные документы -> `VERIFICATION_INCOMPLETE`; заявка -> `driver_status = pending`,
    админу `verification_submitted`; вторая -> `VERIFICATION_PENDING`; reject без причины ->
    `REASON_REQUIRED`; reject -> `rejected`, уведомление с причиной; повтор через 1 ч -> `RATE_LIMITED`
    (сдвиг `reviewed_at` под superuser); approve -> `verified`, `vehicles.verified`,
    `moderation_actions(verify_id)`; verified водитель с новой машиной остаётся verified.
11. **delete_me:** с активной бронью -> `HAS_ACTIVE_BOOKINGS`; с балансом -> `BALANCE_NOT_ZERO`;
    чистый аккаунт -> `status = deleted`, `phone = null`, имя обезличено, `auth.users.banned_until`,
    профиль пропал из `profiles_public`, его старые отзывы и поездки на месте.
12. **Storage:** бакеты существуют; политика: владелец пишет в `verifications/<uid>/x.jpg`, чужой
    путь - отказ, admin читает.
13. **Инварианты:** ledger в нуле, `balance_kz` = ledger.

## 9. Решения (приняты 8 ноя 2026, внесены в ТЗ)

1. `reports.reporter_id` nullable, `null` = система (автожалоба `cash_offer`).
2. `conversations.passenger_seen_at` / `driver_seen_at` для push `new_message`.
3. Storage-бакеты `avatars`, `vehicles` (public), `verifications` (private) и пять политик на
   `storage.objects` созданы в этой миграции.
4. `profile_status = deleted`; `delete_me` обезличивает профиль и блокирует вход через
   `auth.users.banned_until`, удаляет сессии и refresh-токены, освобождает номер.
5. Verified водитель с новой машиной остаётся verified.
6. In-app уведомления админам `report_opened`, `payout_requested`, `verification_submitted`.
7. `mark_payout`: `processing`, `paid`, `failed`.

Выяснилось по ходу:

- **`my_bookings` и `my_conversations` из 0002 не работали для пассажира.** Они были
  `security_invoker` и джойнили `trips` и `profiles`, чьи RLS отдают только свои строки: пассажир
  не видел ни одной своей брони, потому что строка поездки водителя для него закрыта. Обе view
  пересозданы без `security_invoker` с явным фильтром `passenger_id = auth.uid() or driver_id = auth.uid()
  or is_admin()`. Колонки те же, клиенты ничего не замечают.
- **`current_profile()` отвергает `deleted`** (`PROFILE_RESTRICTED`): защита на случай живого токена.
- **`unread_count` считает системные сообщения:** "Lugar confirmado" тоже непрочитано, пока чат не открыт.
- **Порядок проверок в `request_payout`:** заявка в работе проверяется до баланса, иначе повторная
  заявка получала бы `INSUFFICIENT_BALANCE` вместо `PAYOUT_PENDING`.
- **`delete_me` блокируется и активными поездками водителя**, не только бронями: иначе опубликованная
  поездка осталась бы висеть от обезличенного профиля.
- Рейтинг пересчитывается триггером только по строкам `reviews`; сидовые `rating_avg`/`rating_count`
  без строк отзывов перетираются первым реальным отзывом. Для dev это ок, для staging seed отзывов нужен.
