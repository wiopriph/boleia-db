# Boleia: бэкенд для Flutter-клиента

Этот репозиторий - весь бэкенд Boleia: схема Postgres, RLS, RPC, cron, Edge Functions, тесты.
Flutter-приложение ходит в него через `supabase_flutter` и ничего больше: отдельного API-сервера нет.

Читать в таком порядке:

1. `docs/api.md` - контракт: подключение, тестовые пользователи, флоу, RPC, views, ошибки, realtime,
   Edge Functions, Storage. Генерируется из базы, поэтому всегда совпадает со схемой.
2. `types/database.ts` - машинное описание всех таблиц, views, enum'ов и RPC (аргументы и возврат).
   Из него выводятся Dart-модели; это источник правды по колонкам и типам.
3. `docs/spec.md` - ТЗ целиком: разделы 5 (машины состояний), 7 (контракт и коды ошибок),
   9 (уведомления), 12 (экраны P0 с привязкой к RPC и views).
4. `docs/plans/000N_*.md` - почему бэкенд устроен именно так: решения по каждой миграции.

## Окружение

Два варианта, выбирается `SUPABASE_URL` и anon key в приложении:

- **Общий облачный проект** на время разработки - URL и anon key дают отдельно, в репозитории их нет.
  Данные общие на всех, перед релизом чистятся (`scripts/wipe-data.sql`).
- **Локально**: Docker Desktop, Supabase CLI, `supabase start`, `supabase db reset`, при желании
  `supabase functions serve`. URL `http://127.0.0.1:54321`, с Android-эмулятора `http://10.0.2.2:54321`,
  ключи в `supabase status`. Подробности в `README.md`.

Вход в обоих окружениях - только по телефону с OTP. Пока нет SMS-провайдера, работают тестовые
номера с кодом `123456`: `244900000001` (admin), `...02` и `...03` (водители), `...04` (водитель без
верификации), `...05` (пассажир). Номера передаются GoTrue без `+`.

## Правила, которые нельзя обойти с клиента

- **Запись только через RPC.** `insert`/`update` в таблицы с клиента отклоняет RLS. Исключения: свои
  поля `profiles`, `devices`, `notifications.read_at`.
- **Деньги и статусы считает база.** Клиент не вычисляет комиссию, возврат и статус: `request_booking`
  возвращает суммы, `cancel_quote` - сумму возврата, `my_bookings` - статус и `pin_code`, когда
  его можно показать.
- **Телефон второй стороны только через `reveal_contact`** и только с `departure_at - 2 ч`. Публичные
  views телефонов не содержат.
- **Ошибки** приходят как `PostgrestException` с `message = BOLEIA_<CODE>`; текст pt-AO подбирает
  клиент по коду (список в `docs/api.md`). Не парсить текст, только код.
- **Realtime** - три подписки из `docs/api.md`, не больше; остальное pull при открытии экрана.

## Платёжный экран

1. `rpc('request_booking', {trip_id, seats, message})` -> `{booking_id, payment_id, amount_kz, fee_kz, expires_at}`.
2. `functions.invoke('payments-init', body: {booking_id})` -> `instructions`: `push` (пользователь
   подтверждает в приложении Multicaixa Express), `qr` (показать `qr_payload`) или `redirect` (`url`).
3. Подписка на `bookings` по своей брони: `pending_payment -> accepted` (instant) или `-> requested`
   (approval); `-> payment_failed` с `cancel_reason` (`PAYMENT_PHONE_MISMATCH`, `payment_expired`).
4. Кнопка "Verificar pagamento": `functions.invoke('payments-status', body: {payment_id})`.
5. Ещё раз: `rpc('retry_payment', {booking_id})`, до трёх попыток.

Пока договора со шлюзом нет, в обоих окружениях работает мок: он сам присылает "оплачено" через
5 секунд. Для сценариев ошибок в `payments-init` можно передать `simulate`: `failed`, `mismatch`
(оплата с чужого номера, автовозврат), `silent` (без вебхука, статус подтянет cron в течение минуты).

## Push

`rpc('register_device', {device_platform: 'android'|'ios', token, app_version})` после получения FCM-токена.
Payload уведомления: `type` и один из `booking_id` / `trip_id` / `conversation_id` для deep link.
Пока ключа FCM в бэкенде нет, push пишутся в лог функции `notify`; in-app лента (`notifications`
where `channel = 'inapp'`) работает всегда.

## Обновление контракта

Контракт меняется только миграцией в этом репозитории. После каждой миграции перегенерируются
`types/database.ts` и `docs/api.md` (`scripts/gen-types.sh`), поля в views не удаляются и не
переименовываются минимум два релиза приложения. Если чего-то не хватает для экрана - это задача
сюда, а не обход на клиенте.
