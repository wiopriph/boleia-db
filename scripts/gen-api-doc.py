#!/usr/bin/env python3
"""Собирает docs/api.md из каталога локальной базы: enum'ы, views, RPC с правами, коды ошибок,
типы уведомлений. Статические разделы (флоу, realtime, Edge) живут здесь же. Запуск после db reset:
    scripts/gen-api-doc.py
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "api.md")


def container() -> str:
    names = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True, check=True).stdout.split()
    for n in names:
        if n.startswith("supabase_db_"):
            return n
    sys.exit("supabase db container not running: supabase start")


DB = container()


def q(sql: str) -> list[list[str]]:
    out = subprocess.run(
        ["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-d", "postgres", "-Atq", "-F", "\t", "-c", sql],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line]


# Описания RPC: одна строка на функцию, остальное читается из сигнатуры и ТЗ раздела 6
RPC_DOC = {
    "search_trips": "Поиск по trips_public, +-1 день от travel_date, keyset по (departure_at, id). Доступен анонимам.",
    "price_hint": "Подсказка цены по route_durations для экрана публикации.",
    "upsert_profile": "Имя, bio, год рождения, chat_level, payout_method, locale. Телефон не меняется.",
    "upsert_vehicle": "Создать или изменить машину (payload с id = изменить). Смена номера сбрасывает verified.",
    "publish_trip": "Опубликовать поездку. Профиль с аватаром и payout_method, не больше 5 активных, без дубля +-2 ч.",
    "create_return_trip": "Копия поездки с перестановкой городов через publish_trip. Возвращает id новой поездки.",
    "update_trip": "Цена/места/детали пока нет оплаченных броней; время пока нет броней; booking_mode всегда.",
    "confirm_trip_intent": "Водитель подтверждает, что едет (ответ на напоминание -24 ч).",
    "cancel_trip": "Отмена поездки водителем с каскадом возвратов по броням.",
    "driver_arrived": "Водитель на месте встречи (окно departure_at - 3 ч .. departure_at + wait_minutes). Пассажирам driver_arrived; при споре это ответ водителя. -> {driver_arrived_at, wait_until, already?}.",
    "request_booking": "Бронь pending_payment + платёж created. Дальше functions/payments-init.",
    "retry_payment": "Новая попытка оплаты из payment_failed, не больше 3 на бронь.",
    "respond_booking": "Водитель принимает или отклоняет запрос (approval-поездки).",
    "cancel_quote": "Сумма возврата и правило до подтверждения отмены: {refund_kz, gateway_fee_kz, held_kz, rule}.",
    "cancel_booking": "Отмена брони пассажиром или водителем по таблице возвратов ТЗ раздела 5.",
    "enter_pin": "Водитель вводит PIN пассажира. {ok, attempts_left}; 5 неверных за 10 мин -> RATE_LIMITED.",
    "confirm_trip": "Пассажир: доехал (true -> completed, деньги водителю) или не ехал (false -> disputed).",
    "mark_no_show": "Водитель: пассажир не пришёл. Не раньше departure_at + wait_minutes (NO_SHOW_TOO_EARLY); нужен PIN другого пассажира, иначе спор.",
    "resolve_dispute": "Admin: completed | refund_full | refund_partial(amount_kz).",
    "send_message": "Сообщение в чат; без conversation_id создаёт чат по trip_id. Лимиты и маскирование в SQL.",
    "mark_read": "Отметить чужие сообщения прочитанными до up_to_message_id.",
    "reveal_contact": "Телефон второй стороны: только accepted/awaiting_confirm и с departure_at - 2 ч.",
    "submit_review": "Отзыв по брони completed/no_show в течение 14 дней. tags: pontual, condução_segura, simpático.",
    "report_user": "Жалоба на пользователя с контекстом (trip/booking/message).",
    "request_payout": "Заявка на выплату: >= 5000, одна в работе, раз в 7 дней.",
    "mark_payout": "Admin: processing | paid | failed (failed возвращает деньги на баланс).",
    "submit_verification": "Заявка на верификацию: 4 документа в бакете verifications/<uid>/.",
    "review_verification": "Admin: одобрить или отклонить с причиной.",
    "register_device": "Push-токен устройства (upsert по токену).",
    "mark_notifications_read": "Отметить in-app уведомления прочитанными.",
    "delete_me": "Удалить аккаунт: обезличивание, история остаётся. Нельзя при активных бронях или балансе.",
    "is_admin": "role = admin в JWT. Используется в RLS.",
    "admin_search_users": "Admin: поиск по телефону (цифры, + и пробелы игнорируются), имени или id; карточка пользователя одним вызовом.",
    "admin_moderate": "Admin: warn | restrict | suspend (days) | ban | unban; пишет moderation_actions, цели moderation_action; с report_id жалоба -> actioned.",
    "admin_resolve_report": "Admin: reviewed (в работе) | dismissed.",
    "admin_cancel_trip": "Admin: скрыть поездку = отмена платформой, возвраты 100 %, без cancels_total водителю. -> {cancelled_bookings, refunded_kz}.",
    "admin_cancel_booking": "Admin: отмена одной брони платформой, возврат 100 %, счётчики сторон не меняются. -> {status, refund_kz}.",
    "admin_mark_refund_manual": "Admin: возврат сделан вручную переводом (ref), закрывает очередь refund_manual.",
    "admin_upsert_place": "Admin: payload {id?, name, province, slug, kind, lat, lng, aliases[], is_active}; slug уникален.",
    "admin_merge_places": "Admin: слить дубль from_id в into_id (поездки, route_durations, алиасы), from деактивируется.",
    "admin_stats": "Admin: {queues, today, week, health} для дашборда.",
    "admin_weekly": "Admin: по неделям воронка, GMV, fee, возвраты, отмены по сторонам, время ответа водителя и верификации, top_routes.",
    "admin_ledger_balances": "Admin: баланс и число проводок по каждому счёту ledger; сумма балансов = 0.",
    "admin_refund_queue": "Admin: возвраты без refund_ref: автоочередь (refund_attempts < 3) и ручные (is_manual, закрывает admin_mark_refund_manual), ручные первыми.",
    "confirm_payment": "Вебхук шлюза (service role): paid/failed/expired по платежу.",
    "payment_initiated": "payments-init создал транзакцию: created -> pending.",
    "payment_refund_result": "payments-refund сходил в шлюз: refund_ref или попытка.",
    "notification_delivered": "notify отправил push/SMS: sent или повтор/failed.",
    "run_scheduler": "Cron каждые 5 минут; as_of для тестов.",
}

CLIENT_RPC_ORDER = [
    "search_trips", "price_hint", "upsert_profile", "upsert_vehicle", "register_device", "mark_notifications_read",
    "publish_trip", "create_return_trip", "update_trip", "confirm_trip_intent", "driver_arrived", "cancel_trip",
    "request_booking", "retry_payment", "respond_booking", "cancel_quote", "cancel_booking",
    "enter_pin", "confirm_trip", "mark_no_show", "resolve_dispute",
    "send_message", "mark_read", "reveal_contact", "submit_review", "report_user",
    "request_payout", "mark_payout", "submit_verification", "review_verification", "delete_me", "is_admin",
    "admin_search_users", "admin_moderate", "admin_resolve_report", "admin_cancel_trip", "admin_cancel_booking",
    "admin_mark_refund_manual", "admin_upsert_place", "admin_merge_places", "admin_stats", "admin_weekly",
    "admin_ledger_balances", "admin_refund_queue",
]


def enums() -> str:
    rows = q("""select t.typname, string_agg(e.enumlabel, ', ' order by e.enumsortorder)
                from pg_type t join pg_enum e on e.enumtypid = t.oid
                join pg_namespace n on n.oid = t.typnamespace where n.nspname = 'public'
                group by t.typname order by 1""")
    lines = ["| Enum | Значения |", "| --- | --- |"]
    for name, vals in rows:
        lines.append(f"| `{name}` | {', '.join('`' + v + '`' for v in vals.split(', '))} |")
    return "\n".join(lines)


VIEW_DOC = {
    "trips_public": "Поездки в published/full для поиска и карточки. Без телефона и номера машины. В UI MVP из опций только luggage и max_two_in_back; allows_smoking, allows_pets, driver_chat_level не показывать (ТЗ раздел 15).",
    "profiles_public": "Публичный профиль: доверие, рейтинг, бейдж отмен. Без телефона и баланса.",
    "my_bookings": "Брони текущего пользователя с обеих сторон: пассажир видит свои, водитель - брони своих поездок; wait_until и driver_arrived_at - контракт ожидания; "
                   "(фильтр по auth.uid() внутри view). Для водителя заполнены passenger_*; для пассажира - driver_* и "
                   "vehicle_*; pin_code появляется с departure_at - 2 ч. cancel_reason объясняет payment_failed и cancelled. "
                   "passenger_rating_count = 0 значит оценок нет: рейтинг 0,00 не показывать.",
    "my_conversations": "Чаты текущего пользователя с собеседником, последним сообщением и unread_count (системные тоже считаются).",
    "driver_wallet": "Кошелёк водителя: balance_kz, pending_kz (будущие поездки), earned_total_kz (только выплаты за завершённые брони, "
                     "возврат после неудачной выплаты заработком не считается), payouts_pending_kz. Только своя строка.",
    "reviews_public": "Видимые отзывы с именем и аватаром автора. Для /perfil/<id>/avaliacoes: where target_id = ...",
    "route_stats": "Маршруты для SEO: все пары из route_durations плюс пары с поездками; счётчики, минимальная цена, "
                   "длительность и подсказка цены. Materialized, refresh раз в час.",
    "pending_refunds": "Очередь возвратов для Edge payments-refund. Только service role.",
}


def views() -> str:
    names = [r[0] for r in q("""select table_name from information_schema.views where table_schema = 'public'
                                union select matviewname from pg_matviews where schemaname = 'public' order by 1""")]
    out = []
    for v in names:
        grants = q(f"""select string_agg(r, ', ' order by r) from unnest(array['anon', 'authenticated', 'service_role']) r
                       where has_table_privilege(r, 'public.{v}', 'select')""")
        who = grants[0][0] if grants and grants[0][0] else "-"
        cols = q(f"""select a.attname, format_type(a.atttypid, a.atttypmod) from pg_attribute a
                     join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relname = '{v}' and a.attnum > 0 and not a.attisdropped
                     order by a.attnum""")
        out.append(f"### `{v}`\n\n{VIEW_DOC.get(v, '')} Читают: {who}.\n")
        out.append("| Колонка | Тип |\n| --- | --- |")
        out.extend(f"| `{c}` | `{t}` |" for c, t in cols)
        out.append("")
    return "\n".join(out)


def rpcs() -> tuple[str, str]:
    rows = q("""select p.proname, pg_get_function_arguments(p.oid), pg_get_function_result(p.oid),
                       has_function_privilege('anon', p.oid, 'execute'),
                       has_function_privilege('authenticated', p.oid, 'execute'),
                       has_function_privilege('service_role', p.oid, 'execute')
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and pg_get_function_result(p.oid) <> 'trigger'
                  and p.proname not like 'gtrgm%' and p.proname not like 'gin_%'
                order by 1""")
    by_name = {r[0]: r for r in rows}
    client, service = [], []
    for name in CLIENT_RPC_ORDER:
        if name not in by_name:
            continue
        _, args, ret, anon, auth, _svc = by_name[name]
        roles = ", ".join(r for r, f in (("anon", anon), ("authenticated", auth)) if f == "t") or "service_role"
        client.append(f"### `{name}({args})`\n\nВозвращает `{ret}`. Кто: {roles}.\n\n{RPC_DOC.get(name, '')}\n")
    for name in ("confirm_payment", "payment_initiated", "payment_refund_result", "notification_delivered", "run_scheduler"):
        if name in by_name:
            _, args, ret, *_ = by_name[name]
            service.append(f"- `{name}({args})` -> `{ret}`: {RPC_DOC.get(name, '')}")
    return "\n".join(client), "\n".join(service)


def error_codes() -> str:
    codes = set()
    for f in glob.glob(os.path.join(ROOT, "supabase", "migrations", "*.sql")):
        codes.update(re.findall(r"raise_boleia\('([A-Z_]+)'\)", open(f, encoding="utf-8").read()))
    codes.discard("NOT_IMPLEMENTED")
    return ", ".join(f"`{c}`" for c in sorted(codes))


def notification_types() -> str:
    types = set()
    for f in glob.glob(os.path.join(ROOT, "supabase", "migrations", "*.sql")):
        s = open(f, encoding="utf-8").read()
        types.update(re.findall(r"notify\([^,]+,\s*'([a-z_0-9]+)'", s))
        types.update(re.findall(r"notify_admins\('([a-z_0-9]+)'", s))
    return ", ".join(f"`{t}`" for t in sorted(types))


def table_access() -> str:
    rows = q("""select c.relname,
                       bool_or(g.grantee = 'anon' and g.privilege_type = 'SELECT'),
                       bool_or(g.grantee = 'authenticated' and g.privilege_type = 'SELECT'),
                       bool_or(g.grantee = 'authenticated' and g.privilege_type in ('INSERT','UPDATE','DELETE'))
                from pg_class c join pg_namespace n on n.oid = c.relnamespace
                left join information_schema.role_table_grants g on g.table_schema = 'public' and g.table_name = c.relname
                where n.nspname = 'public' and c.relkind = 'r'
                group by c.relname order by 1""")
    lines = ["| Таблица | anon select | authenticated select | authenticated write |", "| --- | --- | --- | --- |"]
    for name, a, s, w in rows:
        mark = lambda v: "да" if v == "t" else "-"
        note = ""
        if name == "payments":
            note = " (без raw_*)"
        if name == "profiles":
            note = " (update своих полей)"
        if name == "notifications":
            note = " (update read_at)"
        lines.append(f"| `{name}` | {mark(a)} | {mark(s)} | {mark(w)}{note if w == 't' else ''} |")
    return "\n".join(lines)


client_rpc, service_rpc = rpcs()

DOC = f"""# Boleia API: контракт для клиентов

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
Коды: {error_codes()}.

Значения кодов - ТЗ раздел 7. `42501` (permission denied) означает вызов RPC не той ролью.

## Основные флоу

**Поиск и бронь (пассажир).** `search_trips` -> карточка из `trips_public` -> (опционально чат
`send_message(body, null, trip_id)`) -> `request_booking(trip_id, seats, message)` -> получить
`booking_id`, `payment_id`, `amount_kz` -> `functions.invoke('payments-init', {{ booking_id }})` ->
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
| `payments-init` | POST, JWT пользователя | `{{ "booking_id": uuid, "simulate"?: "paid|failed|mismatch|silent|silent_failed|qr|redirect" }}` (`simulate` только с моком: `qr`/`redirect` меняют `instructions`, `silent*` без вебхука) | `{{ payment_id, booking_id, amount_kz, expires_at, instructions: {{ type: "push"|"qr"|"redirect", deep_link?, qr_payload?, url? }} }}` |
| `payments-status` | POST, JWT | `{{ "payment_id": uuid }}` | `{{ payment_id, payment_status, booking_status }}` |

Ошибки функций: HTTP 4xx с `{{ "code": "BOLEIA-код без префикса" }}`, например `{{ "code": "PAYMENT_NOT_FOUND" }}`.
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
`register_device`. Типы: {notification_types()}. Payload содержит `booking_id` / `trip_id` /
`conversation_id` для deep link (`boleia://booking/<id>`, `boleia://trip/<id>`).

## Формы jsonb

Аргументы `payload`/`doc_urls` и возвраты `jsonb` не выводятся из схемы; это их контракт.

**Аргументы**

| RPC | Ключи |
| --- | --- |
| `upsert_profile(payload)` | `display_name` (2-40), `avatar_url` (путь в `avatars/<uid>/`), `bio` (<= 300), `birth_year`, `chat_level` (enum; в UI MVP не показывать, ТЗ раздел 15), `locale`, `payout_method`: `{{"type":"mcx_express","phone":"+244XXXXXXXXX"}}` или `{{"type":"iban","iban":"<25 знаков>","bank":"..."}}`, `terms_accepted: true`, `adult_confirmed: true` (фиксируются один раз). Любой ключ опционален |
| `upsert_vehicle(payload)` | `id` (если есть - изменить), `make`*, `model`*, `color`, `year` (1980-2030, иначе `YEAR_INVALID`), `plate`, `seats_total`* (1-8, иначе `SEATS_INVALID`), `photo_url`, `status` (`active`/`removed`). Смена `plate` сбрасывает `verified` |
| `publish_trip(payload)` | `vehicle_id`*, `origin_place_id`*, `destination_place_id`* (только `city`/`town`), `origin_detail`, `destination_detail` (точка посадки, в т. ч. landmark), `departure_at`* (>= now + 2 ч), `seats_offered`* (1-4), `price_per_seat_kz`* (500-100000), `booking_mode` (`instant` по умолчанию), `wait_minutes` (30 | 45 | 60, по умолчанию 30: сколько водитель ждёт опоздавших), `luggage` и `max_two_in_back` (единственные опции в UI MVP), `allows_smoking`, `allows_pets` (в БД есть, в UI не показывать, ТЗ раздел 15), `allows_smoking`, `allows_pets`, `max_two_in_back`, `notes` (<= 500) |
| `update_trip(trip_id, payload)` | подмножество: `price_per_seat_kz`, `seats_offered`, `notes`, `luggage`, `allows_smoking`, `allows_pets`, `max_two_in_back`, `origin_detail`, `destination_detail`, `departure_at`, `booking_mode`, `wait_minutes`; другие ключи -> `TRIP_FIELD_LOCKED` |
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

{enums()}

## Views

{views()}

## Таблицы: что читается напрямую

RLS: пользователь видит свои строки (пассажир - свои брони, водитель - брони своих поездок,
участники - свои чаты). Колонки - в `types/database.ts`.

{table_access()}

## RPC для клиентов

{client_rpc}

## RPC только для service role (Edge Functions, cron)

{service_rpc}
"""

with open(OUT, "w", encoding="utf-8") as f:
    f.write(DOC)
print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(DOC.splitlines())} lines)")
