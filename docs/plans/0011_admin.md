# План миграции 0011_admin

ТЗ: раздел 11 (модерация и админка), раздел 5 (строка "Платформа отменила поездку (бан водителя)"
в таблице возвратов), раздел 8 (`banned_phones`, статусы профиля, admin в JWT), раздел 4
(`moderation_actions`, `reports`, `places`). Запрос: `boleia-web`, шаг "админка" (`/admin/*`).

Что уже есть: `review_verification`, `resolve_dispute`, `mark_payout`, admin-select почти на всех
таблицах, hooks `admin` в JWT. Чего нет: действия над пользователем, работа с жалобами, скрытие
поездки, ручной возврат, справочник мест, чаты для модератора, агрегаты для дашборда.

Все RPC ниже: `is_admin()` иначе `NOT_ADMIN`; каждое действие над человеком пишет строку в
`moderation_actions` и уведомление `moderation_action` цели (ТЗ раздел 9).

## 1. Схема

| Что | Зачем |
| --- | --- |
| `profiles.suspended_until timestamptz` | "приостановить на N дней": cron снимает `suspended`, когда срок вышел |
| `moderation_actions.until timestamptz`, `moderation_actions.payload jsonb default '{}'` | срок приостановки; детали (например, id скрытой поездки) |
| enum `mod_action` + `hide_trip`, `manual_refund`, `report_dismissed` | действия, которых нет в enum, но они есть в разделе 11 |
| RLS `conversations`/`messages` для admin | только чаты с открытой жалобой (`reports.status in (open, reviewed)` по брони, поездке или участникам) или спором (`bookings.status = disputed`); сейчас список виден весь, сообщения не видны вовсе |
| `reports.status`: `reviewed` = взято в работу | уже в enum, нужен только RPC |

## 2. RPC

### Пользователи

| RPC | Что делает |
| --- | --- |
| `admin_search_users(q text, lim int default 20) -> setof jsonb` | по телефону (цифры, `same_phone`) или имени (`ilike`); id, имя, телефон, статус, driver_status, счётчики, дата регистрации |
| `admin_moderate(target_id, action mod_action, reason text, days int default null, report_id uuid default null)` | `warn` → только запись и уведомление; `restrict` → `status = restricted`; `suspend` → `status = suspended`, `suspended_until = now() + days` (`days` обязателен, `DAYS_REQUIRED`), сессии удаляются; `ban` → `status = banned`, телефон в `banned_phones`, `auth.users.banned_until = infinity`, сессии удаляются, активные поездки водителя отменяются платформой с полным возвратом (ТЗ раздел 5), активные брони пассажира отменяются с полным возвратом (вопрос 1); `unban` → `status = active`, телефон из `banned_phones`, `banned_until = null`. `reason` обязателен (`REASON_REQUIRED`). Нельзя над admin (`TARGET_IS_ADMIN`) и над `deleted` (`TARGET_INVALID`). С `report_id` жалоба → `actioned`, `resolved_by` |
| `admin_resolve_report(report_id, outcome text, note text default null)` | `reviewed` (взял в работу) или `dismissed`; `actioned` ставится через `admin_moderate`. Закрытая жалоба → `REPORT_CLOSED` |

### Поездки и деньги

| RPC | Что делает |
| --- | --- |
| `admin_cancel_trip(trip_id, reason)` | "скрыть поездку": отмена платформой, каскад возвратов 100 %, `cancelled_by = system`, `cancel_reason = 'moderation'`, водителю `cancels_total` не растёт (ТЗ раздел 5), `moderation_actions(hide_trip)`. Внутри общий `cancel_trip_cascade(t, by party, reason)`, который используют и `cancel_trip`, и cron, и бан |
| `admin_mark_refund_manual(payment_id, ref text, note text default null)` | возврат сделан вручную переводом в MCX Express: `payment_refund_result(ok, 'manual:' || ref)`, `moderation_actions(manual_refund)` с суммой. Это закрытие строки из очереди `refund_manual` (ТЗ раздел 10) |

Редактирование поездки админом (цена, места, время) не делаю (вопрос 2).

### Справочник мест

| RPC | Что делает |
| --- | --- |
| `admin_upsert_place(payload jsonb) -> uuid` | создать или изменить: `name`, `province`, `slug` (уникален, `PLACE_SLUG_TAKEN`), `kind`, `lat`, `lng`, `aliases`, `is_active`. Деактивация не трогает поездки, место просто уходит из автокомплита и `trips_public` его всё ещё показывает по имени |
| `admin_merge_places(from_id, into_id)` | дубль: `trips`, `route_durations` (конфликт пары → оставить `into`), переводятся на `into`; имя и алиасы `from` добавляются в `aliases` `into`; `from` деактивируется. `route_stats` обновится cron'ом |

### Дашборд

| RPC | Что делает |
| --- | --- |
| `admin_stats() -> jsonb` | очереди: открытые жалобы, споры, заявки на верификацию, заявки на выплату, `pending_refunds`, `refund_manual` без ответа; за сегодня и 7 дней: новые пользователи, поездки, оплаченные брони, оборот в Kz, `payment_failed`; здоровье: `notifications.failed` за 24 ч, `reconciliation_mismatch` за 7 дней, шаги `scheduler_jobs` с `last_error` |

### Cron

`run_scheduler` получает шаг `lift_suspensions`: `status = suspended and suspended_until <= as_of` →
`active`, уведомление `moderation_action` с `action = unsuspend`.

## 3. Коды (в раздел 7 ТЗ)

`TARGET_IS_ADMIN`, `DAYS_REQUIRED`, `REPORT_NOT_FOUND`, `REPORT_CLOSED`, `REPORT_OUTCOME_INVALID`,
`PLACE_NOT_FOUND`, `PLACE_SLUG_TAKEN`, `MODERATION_ACTION_INVALID`. Используются: `NOT_ADMIN`,
`REASON_REQUIRED`, `TARGET_INVALID`, `TRIP_NOT_FOUND`, `TOO_LATE_TO_CANCEL`, `PAYMENT_NOT_FOUND`.

## 4. Тесты `supabase/tests/09_admin.test.sql`

1. Не admin на каждой RPC → `NOT_ADMIN`; admin на admin → `TARGET_IS_ADMIN`.
2. `warn`: запись и уведомление, статус не меняется. `restrict` → `request_booking` даёт
   `PROFILE_RESTRICTED`. `suspend 3` → `suspended_until`, `current_profile` → `PROFILE_RESTRICTED`;
   `run_scheduler(now() + 4 дня)` → `active`. `ban` водителя с активной поездкой и бронью Ana →
   поездка `cancelled` от `system`, Ana возврат 100 %, `cancels_total` водителя не изменился,
   телефон в `banned_phones`, `before_user_created_hook` для этого номера → 403, `auth.users.banned_until`;
   `unban` всё снимает.
3. Жалоба: `reviewed` → `dismissed`; `admin_moderate(..., report_id)` → `actioned`; повтор → `REPORT_CLOSED`.
4. `admin_cancel_trip`: каскад, `cancels_total` без изменений, уведомления `trip_cancelled`.
5. `admin_mark_refund_manual`: платёж из очереди `refund_manual` → `refunded`, `refund_ref = manual:...`.
6. Места: создать, переименовать, дубль slug → ошибка, деактивировать (нет в `places_select_all`
   для не-admin), слияние переводит поездки и `route_durations`, алиасы расширяются.
7. RLS чатов: admin не видит сообщения обычного чата; после `report_user` по брони видит; после
   `dismissed` снова не видит; чат спорной брони виден.
8. `admin_stats()` возвращает ожидаемые счётчики на подготовленных данных.
9. Инварианты ledger.

## 5. Вопросы

1. **Бан пассажира с активными бронями.** ТЗ описывает только бан водителя (поездки отменяются, 100 %
   пассажирам). Мой выбор: активные брони забаненного пассажира отменяются с полным возвратом ему же
   (`cancelled_by = system`), водителю место освобождается. Деньги чужие, удерживать их при бане
   нельзя.
2. **Редактирование поездки админом.** Раздел 11: "редактировать/скрыть поездку". Мой выбор: в MVP
   только скрыть (отменить платформой). Правка цены и времени админом от имени водителя порождает
   споры "я такого не ставил"; если нужно, водитель правит сам через `update_trip`.
3. **Что видит admin в чатах.** Раздел 11: только по открытой жалобе или спору. Мой выбор: жалоба
   `open`/`reviewed`, привязанная к брони, поездке или к любому из участников чата, либо бронь в
   `disputed`. После `dismissed`/`actioned` доступ закрывается.
4. **Приостановка и деньги.** `suspended` водитель с активными поездками: отменять их или оставить?
   Мой выбор: оставить, он не может публиковать новые и отвечать на запросы (`current_profile`
   блокирует RPC), а уже оплаченные поездки доезжают. Если нужно убрать и их, модератор скрывает
   поездки отдельно.
5. **`admin_search_users` как RPC или прямой select по `profiles`.** Admin уже читает `profiles`
   целиком через RLS, PostgREST умеет `ilike`. Мой выбор: RPC всё равно, потому что поиск по телефону
   должен прощать `+` и пробелы (`same_phone`), а это логика базы.
6. **Уведомление цели о `warn`/`restrict`/`suspend`/`ban`.** Раздел 9: `moderation_action` push +
   in-app с причиной. Мой выбор: отправлять всегда, включая причину; при `ban` push всё равно уйдёт на
   токен, но войти человек уже не сможет.
