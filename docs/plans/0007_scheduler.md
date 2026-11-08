# План миграции 0007_scheduler

ТЗ: раздел 6 (таблица Cron), раздел 5 (переходы по времени), раздел 9 (напоминания, тихие часы),
раздел 10 (возвраты в шлюз, сверка).

Одна функция `run_scheduler(as_of timestamptz default now())`, регистрация в `pg_cron` каждые
5 минут. Каждая задача - отдельный шаг в своём блоке `begin ... exception`: ошибка одного шага
пишется в `events('scheduler_error')` и не останавливает остальные. `as_of` подменяет "сейчас"
для тестов; сами переходы (`complete_booking`, `ledger_refund`, `notify`) используют `now()`.

## 1. Схема (вопрос 1)

Scheduler должен помнить, что уже сделал, иначе напоминания уйдут каждые 5 минут.

| Что | Зачем |
| --- | --- |
| `trips.reminded_24h_at`, `trips.reminded_6h_at`, `trips.completed_ask_at` timestamptz | отметки "напоминание отправлено", "вопрос доехали задан" |
| `bookings.pin_sent_at` timestamptz | PIN отправлен в чат; бронь, принятая после `departure_at - 2 ч`, получает PIN на следующем тике |
| `payments.refund_attempts` smallint default 0, `payments.refund_failed_at` timestamptz | до 3 попыток `payments-refund`, дальше ручная очередь |
| таблица `scheduler_jobs (name pk, last_run_at, last_ok_at, last_error, runs)` | гейт для часовых и дневных задач, видно последний прогон и ошибку каждого шага |
| view `pending_refunds` | для Edge `payments-refund`: `payments` где `refund_kz > 0 and refund_ref is null and refund_attempts < 3` |

Всё additive, views не ломаются. Расширения: `create extension pg_cron` (есть в образе Supabase).

## 2. Шаги `run_scheduler(as_of)`

Порядок важен: сначала деньги и протухания, потом переходы по выезду, потом напоминания.

| # | Шаг | Условие | Действие |
| --- | --- | --- | --- |
| 1 | Протухание платежей | `payments` в `created`/`pending`, `expires_at + 5 мин <= as_of` | `payments.status = expired`; бронь `pending_payment -> payment_failed`; `notify(payment_failed)`. 5 минут запаса, чтобы Edge `payments-status` успел опросить шлюз (вопрос 2) |
| 2 | Протухание запросов | `requested`, и (`requested_at + 24 ч <= as_of` или `departure_at - 1 ч <= as_of`) | `expired`, `ledger_refund` 100 %, системное сообщение, `notify(passenger, booking_expired)` |
| 3 | Выезд | `published`/`full`, `departure_at <= as_of` | есть `accepted` -> `departed`, `accepted -> awaiting_confirm`, `pending_payment -> payment_failed` + notify; нет `accepted` -> `expired` + `forfeit_trip_holds` (поездка не состоялась) |
| 4 | Напоминание -24 ч | `published`/`full`, `departure_at <= as_of + 24 ч`, `reminded_24h_at is null` | водителю `trip_reminder_24h` (подтвердите), пассажирам `accepted` - `trip_reminder_24h` (время и место); отметка |
| 5 | Водитель не подтвердил | `departure_at <= as_of + 6 ч`, `driver_confirmed_at is null`, `reminded_6h_at is null` | пассажирам `driver_unconfirmed` (можно отменить бесплатно, правило `driver_unconfirmed` в `cancel_quote` уже работает), водителю `trip_reminder_6h`; отметка |
| 6 | PIN и телефон | `accepted` брони поездок с `departure_at <= as_of + 2 ч`, `pin_sent_at is null` | системное сообщение "O seu PIN: 1234"; пассажиру `pin_ready` (push + SMS, payload: PIN, телефон водителя); водителю `trip_reminder_2h` один раз на поездку с телефонами пассажиров; `pin_sent_at`. Маскирование чата (0008) смотрит на `departure_at - 2 ч` само |
| 7 | "Вы доехали?" | `departed`, `departure_at + minutes(route_durations, default 480) <= as_of`, `completed_ask_at is null` | пассажирам `awaiting_confirm` - `trip_completed_ask`; отметка |
| 8 | Автозавершение 48 ч | `awaiting_confirm`, `pin_entered_at not null`, `departure_at + 48 ч <= as_of` | `complete_booking(b, 'system')` |
| 9 | Автозавершение 7 дней | `awaiting_confirm`, `departure_at + 7 дней <= as_of` | `complete_booking(b, 'system')` |
| 10 | Водитель не приехал | `departed`, ни одного `pin_entered_at`, есть `disputed`, открыт >= 24 ч, водитель не ответил (вопрос 3) | все `awaiting_confirm`/`disputed` -> `cancelled`, `cancelled_by = driver`, `cancel_reason = 'driver_no_show'`, `ledger_refund` 100 %; поездка -> `cancelled`; водителю `cancels_total` +1, `no_shows` +1; `forfeit_trip_holds`; уведомления |
| 11 | Закрытие чатов | `closed_at is null`, и: бронь `completed`/`no_show` + 7 дней; бронь `cancelled`/`declined`/`expired` + 24 ч; без брони - `departure_at + 24 ч`; поездка `cancelled` + 24 ч | `closed_at = as_of` |
| 12 | Видимость отзывов | `reviews.is_visible = false`, бронь `completed_at + 14 дней <= as_of` | `is_visible = true` (отзывы пишет 0008, шаг готов заранее) |
| 13 | `route_stats` | раз в час по `scheduler_jobs` | `refresh materialized view concurrently` |
| 14 | Чистка | раз в сутки | `devices.last_seen_at < -90 дней` удалить; `driver_verifications` с решением старше 30 дней - обнулить `*_url`; `messages` старше 12 мес - `body = '[mensagem apagada]'`, `masked = false`; `events` старше 12 мес удалить, кроме `scheduler_error` и `reconciliation_mismatch` за последние 12 мес |
| 15 | Сверка | раз в сутки | инварианты по всему ledger (вопрос 4): `-(sum cash_in) = sum(payments.amount_kz где paid/refunded/partially_refunded)`, `sum(refunds) = sum(payments.refund_kz)`, каждый `op_id` в нуле, `balance_kz = sum(driver_balance)`; расхождение -> `events('reconciliation_mismatch', детали)` и `notify` всем `is_admin` типом `reconciliation_alert` (Telegram-бот I4 читает) |

Шаг 1 плюс Edge `payments-status` (I1 шаг 5) закрывают "вебхук потерялся": Edge опрашивает шлюз
по `pending` платежам, у которых `expires_at` в прошлом, и вызывает `confirm_payment`; если не
успел за 5 минут, DB протухает платёж сама, а запоздавшая оплата вернётся по ветке поздней оплаты.

Шаг "Возвраты в шлюз" из ТЗ в DB не живёт: Postgres не ходит в Edge. 0007 даёт view
`pending_refunds` и счётчик попыток; вызов `payments-refund` и `payments-status` - отдельный
`pg_cron` job с `pg_net` в шаге 5, ключ в `vault.secrets` (вопрос 5).

## 3. Тихие часы (раздел 9)

`notify` получает правило: если тип не в списке срочных (`payment_*`, `booking_*`, `trip_cancelled`,
`refund_done`, `pin_ready`, `trip_reminder_2h`, `dispute_*`, `reconciliation_alert`) и время в Луанде
между 22:00 и 07:00, строки `push`/`sms` получают `scheduled_for` = ближайшие 07:00 Africa/Luanda.
`inapp` пишется сразу. Edge `notify` (шаг 5) отправляет только строки с `scheduled_for is null or <= now()`.

## 4. Регистрация

```sql
create extension if not exists pg_cron;
select cron.unschedule('boleia_scheduler') where exists (select 1 from cron.job where jobname = 'boleia_scheduler');
select cron.schedule('boleia_scheduler', '*/5 * * * *', $$select public.run_scheduler()$$);
```

`run_scheduler` - `security definer`, execute только у `postgres`/`service_role` (cron работает от
postgres). Для ручного запуска из Edge или админки - через service role.

## 5. Коды и уведомления

Новых кодов ошибок нет: scheduler не бросает клиенту. Новые типы уведомлений (в раздел 9):
`booking_expired` (уже в таблице как `booking_declined / booking_expired`), `driver_unconfirmed`,
`trip_reminder_6h`, `pin_ready` (есть), `trip_reminder_2h` (есть), `trip_completed_ask` (есть),
`reconciliation_alert`, `trip_cancelled` с `reason = driver_no_show`.

## 6. Тесты `supabase/tests/06_scheduler.test.sql`

Каждый шаг - свой сценарий со сдвигом `as_of`; между вызовами проверяется идемпотентность
(второй вызов с тем же `as_of` ничего не меняет и не дублирует уведомления).

1. Протухание платежа: `created` старше 20 мин -> `payment_failed`, место назад, уведомление один раз.
2. Протухание запроса по 24 ч и по `departure - 1 ч`: `expired`, возврат, эскроу 0.
3. Выезд: с `accepted` -> `departed` + `awaiting_confirm`, `pending_payment -> payment_failed`;
   без `accepted` -> `expired`, удержание поздней отмены -> forfeit.
4. Напоминания -24 ч и -6 ч: адресаты, отметки, повтор не шлёт; после `confirm_trip_intent`
   шаг -6 ч молчит.
5. PIN -2 ч: системное сообщение с PIN, `pin_ready` с телефоном водителя, `pin_sent_at`;
   бронь, принятая после отметки, получает PIN на следующем тике.
6. "Вы доехали?" по `route_durations` и по умолчанию +8 ч.
7. Автозавершение 48 ч с PIN и 7 дней без PIN: `completed`, release, поездка `completed`.
8. Водитель не приехал: спор без PIN старше 24 ч -> каскад отмен, возвраты, счётчики водителя,
   поездка `cancelled`; при ответе водителя в чате шаг молчит.
9. Закрытие чатов по всем четырём правилам.
10. Видимость отзыва через 14 дней (отзыв вставляется напрямую под superuser).
11. Чистка и `route_stats` по гейту `scheduler_jobs`; второй вызов в тот же день не повторяет.
12. Сверка: на чистых данных тишина; порча `payments.refund_kz` под superuser -> событие и алерт админу.
13. Ошибка одного шага (подменой данных) не мешает остальным, попадает в `scheduler_jobs.last_error`.
14. Тихие часы: `notify` в 23:00 Луанды для `trip_reminder_24h` ставит `scheduled_for` на 07:00,
    для `payment_failed` - нет.
15. `cron.job` содержит `boleia_scheduler`.

## 7. Решения (приняты 8 ноя 2026, внесены в ТЗ)

1. **Схема:** добавлены `trips.reminded_24h_at`, `reminded_6h_at`, `completed_ask_at`,
   `bookings.pin_sent_at`, `payments.refund_attempts`, `refund_failed_at`, таблица `scheduler_jobs`,
   view `pending_refunds` (только service role).
2. **Протухание платежа:** DB через `expires_at + 5 мин`, Edge `payments-status` опрашивает шлюз в
   это окно; опоздавшая оплата возвращается веткой поздней оплаты 0005.
3. **Ответ водителя на спор:** сообщение водителя в чате спорной брони после открытия спора или PIN
   по любой брони поездки. Есть ответ - ждём модератора; нет 24 ч - автоотмена поездки по вине водителя.
4. **Сверка:** четыре инварианта по всему ledger ежедневно, не "за вчера".
5. **Вызов Edge из cron** (`pg_net`, ключ в Vault) - в шаге 5 вместе с Edge Functions.
6. **Старые сообщения:** `body = '[mensagem apagada]'`, строка остаётся.

Выяснилось по ходу:

- **Шаг "Истечение поездок" слит с "Выездом":** на `departure_at` поездка либо `departed`
  (есть `accepted`), либо `expired` (нет) с forfeit удержаний. Отдельного шага не нужно.
- **Шаг "Возвраты в шлюз" в `run_scheduler` не живёт**, только данные для Edge.
- **`cancel_reason` для системных переходов:** `payment_expired`, `trip_departed`, `no_response`,
  `driver_no_show`, `trip_cancelled`. Клиенту для текста, в ТЗ раздел 7 не входят (это не ошибки).
- **`notify` и тихие часы** считаются от `p_scheduled_for`, если он передан, иначе от `now()`;
  так тихие часы тестируются без подмены времени.
- **В plpgsql алиасы таблиц не должны совпадать с переменными** (`b`, `t`): Postgres считает ссылку
  неоднозначной. В шагах scheduler алиасы `bk`, `tr`, `pm`.
