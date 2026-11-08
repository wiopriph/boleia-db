# Boleia Angola — архитектура и ТЗ v1

Nov 3, 2026 · @Evgenii Korotaev

## 1. Цели и scope MVP

MVP — полный цикл с деньгами: пассажир платит через Multicaixa Express при бронировании, деньги лежат у платформы до подтверждения поездки, водитель получает их на баланс и выводит по заявке; общение — только в чате приложения, с маскированием контактов до дня поездки. Верификация водителя добровольная: даёт ✓ и поднимает поездки в выдаче, никаких других лимитов не накладывает и не снимает. Наличных и внешних мессенджеров нет: это единственный способ удержать комиссию.

Рабочее название — **Boleia** (порт. «попутка»). Язык интерфейса — pt-AO, валюта — AOA (кванзы), целые числа.

**Критерий успеха MVP:** люди начинают пользоваться сервисом — есть повторные брони и водители, которые публикуют вторую и третью поездку без напоминаний. Абсолютные цифры на старте не важны: 10 активных пользователей маркетинг превращает в 1 000; нулевой retention — нет. Что считаем: доля пассажиров со второй бронью за 60 дней, доля водителей со второй поездкой, доля чатов, закончившихся оплатой.

**Входит в MVP**

- Регистрация по телефону (OTP через castbrick), профиль с фото и рейтингом
- Верификация водителя: фото документа и машины → ✓ после ручной модерации; публикуют все на одинаковых условиях, ✓ даёт бейдж и приоритет в выдаче
- Поездка: откуда, куда, дата/время, места, цена за место, точка посадки, машина
- Поиск по маршруту и дате; SEO-страницы маршрутов на web (`/boleias/luanda-benguela`)
- Бронирование с оплатой сразу (Multicaixa Express). Два режима на выбор водителя: автобронь — место подтверждено сразу после оплаты, пассажир попадает в чат поездки; ручная — водитель принимает/отклоняет за 24 ч, отказ = автоматический возврат
- Чат водитель ↔ пассажир внутри приложения, доступен с карточки поездки до оплаты; номера и ссылки маскируются до дня поездки
- Отмены с правилами возврата, напоминания за 24 ч и 2 ч, «Вы доехали?» после
- PIN-код посадки как доказательство поездки; выплата водителю после подтверждения
- Баланс водителя и вывод на Multicaixa Express / IBAN
- Двусторонние оценки, жалобы, модерация через Telegram-бота и админку

**Не входит в MVP**

- Наличная оплата и любые «договоритесь сами» — принципиально
- WhatsApp, SMS-переписка, показ телефона до дня поездки
- GPS-трекинг поездки, промежуточные остановки с отдельной ценой
- Автоматическая проверка документов (OCR, liveness) — только ручная
- Автобусы, B2B, подписки, карты международных платёжных систем

## 2. Общая архитектура

Бэкенд — Supabase, без собственного API-сервера между клиентами и базой. Оба клиента (Nuxt и Flutter) ходят в Postgres через PostgREST, вызывают RPC-функции и подписываются на Realtime через один и тот же SDK. Состояния (кто может бронировать, когда можно отменить, пересчёт мест, движение денег в ledger) живут в Postgres-функциях — это единственное место, где транзакция атомарна. Оркестрация с внешним миром (инициировать платёж, принять вебхук, отправить SMS/push) — в Edge Functions на TypeScript. Nuxt-сервер — только SSR и SEO-страницы, не прослойка к данным.

```
Nuxt 4 (web, SSR/SEO, admin)   Flutter (iOS/Android)   Telegram-бот модерации
             \                        |                       /
              \   PostgREST + RPC + Realtime, JWT (один SDK)  /
               \______________________|______________________/
                                      v
   Supabase (отдельный проект от Ambo)
   ├─ Postgres + RLS: таблицы, RPC (security definer), триггеры, pg_cron
   ├─ Auth: телефон + OTP (Send SMS Hook → Edge send-sms → castbrick)
   ├─ Storage: аватары, фото машин (public); документы верификации (private)
   └─ Edge Functions (Deno/TS): payments-init/webhook/refund/status,
      send-sms, notify (FCM), telegram-moderation, auth-hook
   Внешние: GPO/PSP для Multicaixa Express, castbrick (SMS), Firebase Cloud Messaging
```

Для Мануэля контракт выглядит так: `supabase.from('trips_public').select()` для чтения, `supabase.rpc('request_booking', {…})` для действий, `supabase.functions.invoke('payments-init', {…})` для платежа, `supabase.channel(…)` для чата. Четыре примитива, один SDK, одна сессия с автообновлением токена. Клиенты не пишут в таблицы напрямую — RLS это запрещает.

**Почему не Nuxt-API как бэкенд** — три заявленные цели (однообразие для Flutter, меньше возни с запросами, снять нагрузку с БД) достигаются без него, а он добавляет своё

- **Однообразие.** С Nuxt-API Мануэль получает REST без SDK: сам пишет HTTP-клиент, хранение и обновление токена, ретраи, сериализацию, websocket для чата. С Supabase всё это уже в `supabase_flutter`. Своё API — больше кода на клиенте, не меньше.
- **Нагрузка на БД.** Прослойка не снимает нагрузку — те же запросы доходят до того же Postgres, плюс один сетевой хоп и свой пул соединений. Что реально снимает нагрузку: индексы, `route_stats` как materialized view, кэш SEO-страниц на Cloudflare, кэш `places` на клиенте, одна realtime-подписка на открытый экран. При 500 поездках и 5 000 сообщений в день Postgres на минимальном тарифе загружен на единицы процентов.
- **Безопасность.** Nuxt-API ходит в базу service-ролью, и каждый обработчик обязан проверить права сам; одна ошибка = доступ ко всей базе. RLS проверяет права на уровне строк, независимо от того, кто и откуда пришёл, и работает одинаково для web, Flutter и будущего партнёрского API.
- **Транзакции.** `request_booking` должен атомарно: проверить места, создать бронь, зарезервировать место, создать запись платежа. В plpgsql это одна функция; из Nuxt — цепочка запросов с ручным откатом.
- **Деплой.** Ambo переезжает на Cloudflare Workers ради цены; Workers не держат долгие соединения, cron и websockets для чата — для API-бэкенда пришлось бы держать отдельный сервер (Render/VPS), от которого вы как раз уходите.
- **Где TypeScript всё-таки нужен** — платёжный флоу, вебхуки, OTP, рассылка — он есть: Edge Functions. Это и есть «сервер на TS», только без своего хостинга, с тем же JWT и тем же `supabase.functions.invoke` в обоих клиентах.

**Ограничения, которые надо принять**

- Логика в plpgsql хуже читается, чем TS, и требует дисциплины: pgTAP-тесты в CI с первого RPC, одна миграция = один PR.
- Edge Functions — Deno, не Node: часть npm-пакетов не заведётся; для SDK платёжного шлюза проверить заранее.
- Supabase Realtime на Pro-тарифе — 500 одновременных соединений; чат идёт через `postgres_changes` по таблице `messages` под RLS (одна подписка на открытый экран чата), этого хватает до тысяч DAU. При росте чат выносится в отдельный сервис, таблица `messages` остаётся источником истины.
- Всё, что требует секретов (ключи GPO/PSP, castbrick), — только в Edge Functions, никогда в клиентах.

## 3. Доменная модель

Один пользователь — одна учётка; «пассажир» доступен всем, «водитель» — любой, кто добавил машину и способ выплаты. Верификация (`driver_status = verified`) даёт ✓ в карточке и приоритет в выдаче; лимиты у verified и unverified одинаковые. Админ/модератор — флаг в JWT, выдаётся вручную.

| Сущность | Что это | Ключевые связи |
| --- | --- | --- |
| `profiles` | Публичный профиль поверх `auth.users`: имя, фото, рейтинг, статус водителя | 1:1 с `auth.users` |
| `driver_verifications` | Заявка на верификацию: фото документа, фото машины с номером, решение модератора | N:1 к `profiles`, 1:1 к `vehicles` |
| `vehicles` | Машина водителя (марка, цвет, мест, фото) | N:1 к `profiles` |
| `places` | Справочник городов/точек Анголы с координатами и slug | сидируется вручную, растёт модерацией |
| `trips` | Поездка: откуда, куда, когда, мест, цена за место, статус | N:1 к водителю, машине, двум `places` |
| `trip_stops` | Промежуточные остановки (этап 2, таблица создаётся сразу) | N:1 к `trips` |
| `bookings` | Запрос пассажира на N мест в поездке + его жизненный цикл | N:1 к `trips` и к пассажиру |
| `payments` | Платёж по брони через Multicaixa Express: ссылка на транзакцию шлюза, статус | N:1 к `bookings` |
| `ledger_entries` | Двойная запись по деньгам: эскроу, баланс водителя, комиссия, возвраты | N:1 к `bookings`/`payouts` |
| `payouts` | Вывод средств водителем | N:1 к `profiles` |
| `conversations` | Чат по поездке: один на пару пассажир–поездка, создаётся до брони | N:1 к `trips`; `booking_id` проставляется после оплаты |
| `messages` | Сообщения чата | N:1 к `conversations` |
| `reviews` | Двусторонняя оценка по завершённой брони | 1:1 к паре (`booking`, автор) |
| `reports` | Жалоба на пользователя/поездку/сообщение | N:1 к автору и цели |
| `notifications` | Очередь исходящих сообщений (push/SMS/in-app) | N:1 к получателю |
| `devices` | Push-токены устройств | N:1 к `profiles` |
| `events` | Продуктовая аналитика (поиск, просмотр, запрос, оплата) | опционально к `profiles` |
| `moderation_actions` | Журнал действий модераторов | N:1 к админу и цели |

Телефон второй стороны хранится в `profiles`, но клиентам не отдаётся нигде, кроме RPC `reveal_contact`, которая работает только с `departure_at − 2 ч` по принятой брони — чтобы найти друг друга на месте. До этого — только чат.

## 4. Схема БД

Все таблицы в схеме `public`, `id uuid default gen_random_uuid()`, `created_at timestamptz default now()`, `updated_at` через общий триггер. Время — только `timestamptz` в UTC, клиенты показывают в Africa/Luanda (UTC+1, без перехода). Деньги — `integer` в кванзах, без дробей. Статусы — Postgres `enum`, не текст.

### profiles

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | = `auth.users.id` |
| phone | text unique | E.164, `+244…`; источник истины — auth, здесь копия для поиска |
| display\_name | text not null | имя + первая буква фамилии, например «Ana R.» |
| avatar\_url | text | Storage; обязателен для публикации поездки, для пассажира — желателен (напоминание при первой брони, не блокер) |
| bio | text | до 300 символов |
| birth\_year | smallint | для показа возраста «30 лет», не дата |
| chat\_level | enum `chat_level` | `bla`, `blabla`, `blablabla` |
| driver\_status | enum `driver_status` | `none`, `pending`, `verified`, `rejected`; в UI — два состояния: ✓ Verificado или нет |
| driver\_verified\_at | timestamptz | — |
| rating\_avg | numeric(3,2) | пересчитывается триггером по `reviews` |
| rating\_count | int | — |
| trips\_driven | int | завершённые как водитель |
| trips\_ridden | int | завершённые как пассажир |
| cancels\_total | smallint | все отмены по своей инициативе за всё время (водитель — поездки и брони, пассажир — брони); источник бейджа «Nunca cancelou» / «Às vezes cancela» |
| no\_shows | smallint | — |
| balance\_kz | integer | денормализованный баланс водителя = сумма `ledger_entries`; пересчёт триггером |
| payout\_method | jsonb | `{type: 'mcx_express', phone}` или `{type: 'iban', iban, bank}` |
| phone\_verified\_at | timestamptz | ставится при первом OTP |
| status | enum `profile_status` | `active`, `restricted`, `suspended`, `banned`, `deleted` (после `delete_me`: профиль обезличен, в публичных views не показывается, RPC недоступны) |
| locale | text default 'pt-AO' | — |
| last\_seen\_at | timestamptz | — |
| terms\_accepted\_at, adult\_confirmed\_at | timestamptz | согласие с правилами и 18+ при регистрации (раздел 15); ставятся через `upsert_profile` один раз |
| suspended\_until | timestamptz | срок `suspended`; cron возвращает `active` |

### driver\_verifications

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| user\_id | uuid FK profiles | — |
| vehicle\_id | uuid FK vehicles | какая машина проверяется |
| id\_doc\_url | text | фото BI или паспорта; private bucket, только admin |
| licence\_url | text | фото водительских прав; private bucket |
| vehicle\_photo\_url | text | машина с читаемым номером; private bucket |
| selfie\_url | text | селфи с документом; private bucket |
| status | enum `verification_status` | `pending`, `approved`, `rejected` |
| reject\_reason | text | показывается пользователю |
| reviewed\_by | uuid FK profiles | — |
| reviewed\_at | timestamptz | — |

Одна активная заявка на пользователя (`unique (user_id) where status = 'pending'`). Документы лежат в private-бакете `verifications/`, срок хранения — до решения + 30 дней, потом удаляются cron'ом; остаётся только решение. Одобрение ставит `profiles.driver_status = verified` и `vehicles.verified = true`.

### vehicles

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| owner\_id | uuid FK profiles | — |
| make, model | text | «Toyota», «Hiace» |
| color | text | — |
| year | smallint | — |
| plate | text | хранится полностью, в API — только последние 3 символа |
| seats\_total | smallint | пассажирских мест, не считая водителя |
| photo\_url | text | публичное фото для карточки поездки |
| verified | bool default false | ставится при одобрении `driver_verifications`; ✓ в карточке поездки показывается только для verified-машины |
| status | enum `vehicle_status` | `active`, `removed` |

### places

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| name | text | «Benguela» |
| province | text | «Benguela» |
| slug | text unique | `benguela`, для URL |
| kind | enum `place_kind` | `city`, `town`, `landmark` |
| lat, lng | double precision | для сортировки «ближайшие» и будущих карт |
| aliases | text\[\] | «Lobito»→«Lobito, Benguela»; для поиска |
| is\_active | bool | скрывать, не удалять |

Сид — 30–40 городов и крупных посёлков по провинциям. Новые места добавляет только админ.

### trips

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| driver\_id | uuid FK profiles | — |
| vehicle\_id | uuid FK vehicles | — |
| origin\_place\_id | uuid FK places | — |
| destination\_place\_id | uuid FK places | check: ≠ origin |
| origin\_detail | text | точка посадки: «Gamek, у терминала Macon» |
| destination\_detail | text | точка высадки |
| departure\_at | timestamptz | check: > now() при публикации |
| seats\_offered | smallint | 1–4 в MVP (чтобы не плодить «автобусы» из Hiace) |
| seats\_available | smallint | поддерживается триггером по `bookings` |
| price\_per\_seat\_kz | integer | check: 500–100 000 |
| currency | char(3) default 'AOA' | — |
| booking\_mode | enum `booking_mode` | `instant` — место подтверждается сразу после оплаты; `approval` — водитель отвечает за 24 ч. Выбирает водитель при публикации, по умолчанию `instant` |
| luggage | enum `luggage_size` | `small`, `medium`, `large` |
| allows\_smoking, allows\_pets | bool | — |
| max\_two\_in\_back | bool | «макс. двое сзади» — не больше двух пассажиров на заднем сиденье |
| notes | text | до 500 символов |
| status | enum `trip_status` | см. раздел 5 |
| published\_at, departed\_at, completed\_at, cancelled\_at | timestamptz | — |
| cancel\_reason | text | — |
| view\_count | int | — |

Индексы: `(origin_place_id, destination_place_id, departure_at) where status = 'published'`, `(driver_id, departure_at)`, `(departure_at) where status in ('published','full')` для cron-задач.

Дополнительно в `trips`: `driver_confirmed_at timestamptz` — ответ водителя на напоминание за 24 ч (`confirm_trip_intent`); null к `departure_at − 6 ч` открывает пассажирам бесплатную отмену.
| reminded\_24h\_at, reminded\_6h\_at, completed\_ask\_at | timestamptz | отметки cron: напоминание −24 ч / −6 ч отправлено, вопрос «Вы доехали?» задан |
| wait\_minutes | smallint, 30 / 45 / 60, default 30 | сколько водитель ждёт опоздавших после `departure_at`; выбирает при публикации, меняет пока нет оплаченных броней; показывается пассажиру до оплаты, в брони и в SMS с PIN |
| driver\_arrived\_at | timestamptz | «Cheguei ao ponto de encontro» (`driver_arrived`): пассажиры видят, что водитель на месте; при споре — ответ водителя, автоотмены cron'ом нет |

### trip\_stops (этап 2)

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| trip\_id | uuid FK trips | — |
| place\_id | uuid FK places | — |
| order\_idx | smallint | порядок по маршруту |
| price\_from\_origin\_kz | integer | цена места до этой остановки |

### bookings

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| trip\_id | uuid FK trips | — |
| passenger\_id | uuid FK profiles | — |
| seats | smallint | 1–3 |
| price\_total\_kz | integer | снимок `seats × price_per_seat` на момент запроса |
| fee\_kz | integer | max(10 % × price\_total\_kz, 1 000); минимум считается один раз на всю бронь: 4 × 7 000 = 28 000 → 2 800; 2 × 3 000 = 6 000 → 1 000. Снимок на момент запроса |
| message | text | «Буду с чемоданом» |
| status | enum `booking_status` | см. раздел 5 |
| pin\_code | char(4) | генерируется при `accepted`, показывается пассажиру с `departure_at − 2 ч` |
| pin\_entered\_at | timestamptz | водитель ввёл PIN = пассажир сел |
| requested\_at | timestamptz | момент успешной оплаты |
| responded\_at | timestamptz | момент accept/decline |
| cancelled\_at | timestamptz | — |
| cancelled\_by | enum `party` | `passenger`, `driver`, `system` |
| cancel\_reason | text | — |
| refund\_kz | integer | сколько вернули пассажиру по правилам раздела 5 |
| passenger\_confirmed\_at | timestamptz | ответ на «Вы доехали?» |
| driver\_confirmed\_at | timestamptz | — |
| completed\_at | timestamptz | — |
| pin\_sent\_at | timestamptz | PIN отправлен в чат (cron за 2 ч; бронь, принятая позже, получает PIN на следующем тике) |

Ограничение: один активный запрос пассажира на поездку — `unique (trip_id, passenger_id) where status in ('pending_payment','requested','accepted','awaiting_confirm')`. Пассажир не может бронировать свою же поездку (триггер). Места резервируются уже в `pending_payment` на 15 минут, чтобы два пассажира не оплатили одно место.

### payments

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| booking\_id | uuid FK bookings | — |
| payer\_id | uuid FK profiles | — |
| amount\_kz | integer | = `price_total_kz` + fee\_kz — то, что реально списано с пассажира |
| provider | text | `mcx_express` (через GPO банка или PSP) |
| provider\_ref | text unique | id транзакции у шлюза; ключ идемпотентности вебхука |
| status | enum `payment_status` | `created`, `pending`, `paid`, `failed`, `expired`, `refunded`, `partially_refunded` |
| refund\_kz | integer | — |
| refund\_ref | text | id возврата у шлюза. `refund_kz > 0 and refund_ref is null` = возврат ожидает отправки в шлюз (cron -> `payments-refund`) |
| raw\_request, raw\_webhook | jsonb | что отправили и что пришло — для споров с шлюзом |
| expires\_at | timestamptz | `created + 15 мин`, ставится уже в `request_booking`, чтобы бронь без `payments-init` не держала место; MCX Express даёт клиенту 90 с на подтверждение, остальное — наш запас |
| paid\_at, refunded\_at | timestamptz | — |
| refund\_attempts, refund\_failed\_at | smallint, timestamptz | попытки Edge `payments-refund`; после 3 — ручная очередь |

### ledger\_entries

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | bigint identity | — |
| booking\_id | uuid, nullable | — |
| payout\_id | uuid, nullable | — |
| account | enum `ledger_account` | `cash_in`, `passenger_escrow`, `driver_balance`, `platform_fee`, `refunds`, `gateway_fees`, `cash_out`. `cash_in` - деньги пришли от шлюза, зеркало `refunds`/`cash_out`; баланс расчётного счёта платформы = `-(cash_in) - refunds - cash_out` |
| user\_id | uuid, nullable | для `driver_balance` — чей |
| amount\_kz | integer | + дебет / − кредит; сумма по операции = 0 |
| op\_id | uuid | группирует строки одной операции |
| memo | text | `payment:<id>`, `release:<booking>`, `refund:<booking>`, `payout:<id>` |

Только insert, никогда update/delete (RLS + триггер). Баланс любого счёта = `sum(amount_kz)`. Это единственный источник истины по деньгам; `profiles.balance_kz` — кэш.

### payouts

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| user\_id | uuid FK profiles | — |
| amount\_kz | integer | min 5 000 Kz |
| method | jsonb | снимок `profiles.payout_method` на момент заявки |
| status | enum `payout_status` | `requested`, `processing`, `paid`, `failed`, `cancelled` |
| provider\_ref | text | — |
| processed\_by | uuid FK profiles | в MVP выплаты делает админ вручную из MCX Express/интернет-банка и отмечает `paid` |
| processed\_at | timestamptz | — |

### conversations

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| trip\_id | uuid FK trips | — |
| passenger\_id | uuid FK profiles | — |
| driver\_id | uuid FK profiles | денормализация для RLS без join |
| booking\_id | uuid FK bookings, nullable | null, пока пассажир не оплатил; проставляется в `confirm_payment` |
| last\_message\_at | timestamptz | для сортировки списка чатов |
| closed\_at | timestamptz | `completed + 7 дней`, отмена + 24 ч, или `departure_at + 24 ч` без брони; после — только чтение |
| passenger\_seen\_at, driver\_seen\_at | timestamptz | когда сторона последний раз была в чате (`mark_read`, `send_message`); push `new_message` не шлётся, если получатель был в чате < 60 с назад |

`unique (trip_id, passenger_id)`. Создаётся при первом сообщении из карточки поездки («Perguntar ao condutor») или при оплате, если пассажир не писал. Чаты без брони: не больше 5 новых в сутки на пассажира, не больше 10 сообщений от пассажира в одном чате до оплаты.

### messages

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | bigint identity | монотонный порядок |
| conversation\_id | uuid FK conversations | — |
| sender\_id | uuid FK profiles | null = системное («Бронь принята», «PIN: 4821») |
| body | text | до 1 000 символов; только текст в MVP |
| masked | bool | true, если из текста вырезаны телефон/ссылка |
| read\_at | timestamptz | — |

Индекс `(conversation_id, id)`. Доставка — Supabase Realtime: insert в `messages` → postgres\_changes подписчикам; пуш — через `notifications`, если получатель офлайн > 60 с. Маскирование номеров и ссылок (regex в триггере) работает всегда до `departure_at − 2 ч` по оплаченной брони — и до оплаты, и после; иначе чат до оплаты превращается в канал для сделок за наличные. В чате до оплаты есть кнопка «Reservar» — путь к оплате не должен выходить из переписки.

### reviews

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| booking\_id | uuid FK bookings | по брони в `completed` или `no_show` |
| author\_id, target\_id | uuid FK profiles | — |
| direction | enum `review_direction` | `passenger_to_driver`, `driver_to_passenger` |
| rating | smallint | 1–5 |
| tags | text\[\] | `pontual`, `condução_segura`, `simpático` — фиксированный набор |
| comment | text | до 300 символов |
| is\_visible | bool | true, когда оба оставили отзыв или прошло 14 дней |

`unique (booking_id, author_id)`.

### reports

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| reporter\_id | uuid FK profiles, nullable | null = автожалоба системы (`cash_offer`) |
| target\_user\_id | uuid FK profiles | — |
| trip\_id, booking\_id, message\_id | nullable | контекст |
| reason | enum `report_reason` | `no_show`, `unsafe_driving`, `harassment`, `scam`, `cash_offer`, `wrong_price`, `other` |
| details | text | — |
| status | enum `report_status` | `open`, `reviewed`, `actioned`, `dismissed` |
| resolved\_by | uuid FK profiles | — |

### contact\_reveals

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| booking\_id | uuid FK bookings | — |
| viewer\_id | uuid FK profiles | кто посмотрел |
| revealed\_user\_id | uuid FK profiles | чей контакт |

Доступно только с `departure_at − 2 ч` по `accepted`-брони. Источник метрики и защита от скрейпинга.

### notifications

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| user\_id | uuid FK profiles | — |
| type | text | `booking_requested`, `booking_accepted`, `trip_reminder_24h`, … |
| channel | enum `notif_channel` | `push`, `sms`, `inapp` |
| payload | jsonb | данные для шаблона: trip\_id, имена, время, суммы |
| status | enum `notif_status` | `queued`, `sent`, `failed`, `read` |
| scheduled\_for | timestamptz | null = сразу |
| sent\_at, read\_at | timestamptz | — |
| error | text | ответ провайдера |

### devices

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| user\_id | uuid FK profiles | — |
| platform | enum `platform` | `ios`, `android`, `web` |
| push\_token | text unique | FCM |
| app\_version | text | — |
| last\_seen\_at | timestamptz | чистить токены старше 90 дней |

### events

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | bigint identity | — |
| user\_id | uuid, nullable | анонимный поиск тоже пишем |
| name | text | `search`, `trip_view`, `contact_reveal`, `booking_request` |
| props | jsonb | origin, destination, date, results\_count… |
| platform | enum `platform` | — |

Партиционировать по месяцу, когда перевалит за \~5 млн строк; до этого — обычная таблица.

### moderation\_actions

| Поле | Тип | Примечание |
| --- | --- | --- |
| id | uuid PK | — |
| admin\_id | uuid FK profiles | — |
| target\_user\_id | uuid FK profiles | — |
| action | enum `mod_action` | `warn`, `restrict`, `suspend`, `ban`, `unban`, `verify_id`, `resolve_dispute` (решение по спору: `reason` = outcome и сумма, target = пассажир), `hide_trip`, `cancel_booking`, `manual_refund`, `report_dismissed` |
| reason | text | — |
| report\_id | uuid, nullable | — |
| until | timestamptz | срок для `suspend` |
| payload | jsonb | детали: id поездки/брони/платежа, суммы возвратов |

### banned\_phones

| Поле | Тип | Примечание |
| --- | --- | --- |
| phone | text PK | E.164 |
| reason | text | — |
| banned\_by | uuid FK profiles | — |
| created\_at | timestamptz | — |

Проверяется в auth-хуке при регистрации: номер из списка не получает OTP. Снятие бана — только admin.

### route\_durations

| Поле | Тип | Примечание |
| --- | --- | --- |
| origin\_place\_id, destination\_place\_id | uuid PK (пара) | — |
| minutes | smallint | типичное время в пути |
| price\_hint\_kz | integer | ориентир цены за место для подсказки водителю |

Заполняется руками для стартовых маршрутов (Luanda–Benguela ≈ 7 ч, 6–8 тыс. Kz); для пары без строки cron берёт +8 ч, подсказка цены не показывается. После 20 завершённых поездок по паре `price_hint_kz` пересчитывается медианой.

### scheduler\_jobs

| Поле | Тип | Примечание |
| --- | --- | --- |
| name | text PK | имя шага `run_scheduler` |
| last\_run\_at, last\_ok\_at | timestamptz | гейт для часовых/дневных шагов и мониторинг |
| last\_error | text | текст последней ошибки шага; ошибка одного шага не останавливает остальные |
| runs | integer | — |

Читает только admin. Тот же журнал ошибок дублируется в `events('scheduler_error')`.

### Представления (views)

- `trips_public` — поездка + водитель (имя, фото, рейтинг, число поездок, ✓ verified) + машина (марка, цвет) + названия мест; без телефона и номера. Единственное, что читают анонимы.
- `my_bookings` — брони текущего пользователя с данными поездки, платежа и чата.
- `my_conversations` — список чатов с последним сообщением и счётчиком непрочитанных.
- `driver_wallet` — баланс, в ожидании (escrow по будущим поездкам), история выплат.
- `route_stats` (materialized, обновляется раз в час) — для SEO-страниц: пара городов, поездок за 30 дней, минимальная цена, ближайшая дата.

## 5. Машины состояний

Две машины — поездка и бронь. Переходы делают только RPC-функции, вебхук платежей и cron; прямой `update status` запрещён RLS. Каждый переход пишет строку в `notifications`, а переходы с деньгами — пару строк в `ledger_entries` в той же транзакции.

**Поездка (`trip_status`)**

1. `draft` — создана, не видна в поиске.
2. `published` — в поиске, принимает брони. Требует: аватар, машина, `payout_method` заполнен, `departure_at` не раньше чем через 2 часа. Для `driver_status ≠ verified` — те же условия, в карточке без ✓.
3. `full` — `seats_available = 0`; в поиске видна с пометкой, запросы закрыты. Обратно в `published` при отмене брони или протухании неоплаченного запроса.
4. `departed` — cron переводит в `departure_at`; новые запросы невозможны, отмена невозможна.
5. `completed` — все брони дошли до финала или прошло 7 дней после выезда.
6. `cancelled` — водитель отменил (до `departed`); все активные брони → `cancelled` с `cancelled_by = driver` и полным возвратом.
7. `expired` — опубликована, ни одной принятой брони, время выезда прошло. Не считается в статистике водителя.

**Бронь (`booking_status`)**

```
pending_payment ──(оплата OK)──► [instant] accepted ──(cron: выезд)──► awaiting_confirm ──("доехал" / 48 ч с PIN / 7 дней)──► completed
      │                          [approval] requested ──(водитель принял)──► accepted
      │ 15 мин без оплаты                  │ отказ / 24 ч / departure−1ч → declined/expired (возврат 100%)
      ▼                                    │
payment_failed (retry ≤3)                  └─ любая сторона до выезда → cancelled (возврат по таблице раздела 5)
awaiting_confirm ──(водитель: "не пришёл", есть PIN других)──► no_show
awaiting_confirm ──(пассажир: "не ехал")──► disputed ──(модератор)──► completed | refund
```

**Ожидание опоздавших.** Резерв — контракт обеих сторон: пассажир на месте к `departure_at`, водитель ждёт `trips.wait_minutes` (30 / 45 / 60, выбирает при публикации, по умолчанию 30). До `departure_at + wait_minutes` водитель не может отметить «não apareceu» (`NO_SHOW_TOO_EARLY`); после — может, если введён PIN хотя бы одного другого пассажира, и опоздавший теряет оплату (строка «Пассажир не пришёл» в таблице ниже). Водитель отмечает «Cheguei» (`driver_arrived`) с −3 ч до конца ожидания: пассажиры получают уведомление и время, до которого он ждёт. Опоздал водитель: пассажир после выезда нажимает «não viajei», открывается спор; без PIN на поездке, без ответа водителя в чате и без отметки «Cheguei» cron через 24 ч отменяет поездку с полным возвратом и санкциями водителю (строка «Водитель не приехал»); с отметкой или ответом — решает модератор.

`pending_payment` — бронь создана, место зарезервировано, платёж отправлен в Multicaixa Express; 15 минут на подтверждение, иначе `payment_failed` и место освобождается. Дальше зависит от `trips.booking_mode`: при `instant` оплата сразу переводит бронь в `accepted` (PIN генерируется, пассажир попадает в чат поездки); при `approval` — в `requested`, деньги на эскроу, у водителя 24 ч, отказ или молчание → полный возврат. Чат доступен с карточки поездки до брони («Perguntar ao condutor»); если пассажир не писал, чат создаётся в момент брони. PIN и телефон — с `departure_at − 2 ч` по `accepted`. Отзывы — только из `completed` и `no_show`. Из `cancelled` переход возможен и из `requested`, и из `accepted` — на схеме показана одна стрелка; переход `pending_payment → accepted` для instant на схеме не показан.

**Правила отмены и возврата** (возврат пассажиру из эскроу; остаток делится между водителем и платформой по `fee_kz`)

| Кто | Когда | Возврат пассажиру (от уплаченной суммы = цена + комиссия) | Счётчик |
| --- | --- | --- | --- |
| Водитель отклонил / не ответил (24 ч или до `departure_at − 1 ч`) | — | 100 % | — |
| Пассажир снял запрос, бронь ещё `requested` | — | 100 % минус комиссия шлюза; штраф 50 % только за принятую бронь | `cancels_total` +1 |
| Водитель отменил поездку или одну бронь | > 24 ч до выезда | 100 % | `cancels_total` +1 |
| Водитель отменил поездку или одну бронь | < 24 ч | 100 % | `cancels_total` +1 |
| Водитель не подтвердил поездку к `departure_at − 6 ч` | — | пассажир может отменить сам, 100 % | — |
| Водитель не приехал (ни одного PIN, ≥ 1 пассажир сообщил «не ехал», водитель не оспорил за 24 ч) | после выезда | 100 % всем броням | `cancels_total` +1, `no_shows` +1; поездки скрыты до разбора модератором |
| Пассажир отменил | > 24 ч | 100 % минус комиссия шлюза | `cancels_total` +1 |
| Пассажир отменил | < 24 ч | 50 %; остаток — водителю после `completed` этой поездки, если поездка не состоялась — платформе | `cancels_total` +1 |
| Пассажир не пришёл (`no_show`, водитель ввёл PIN других) | — | 0 %; сумма водителю минус комиссия | `no_shows` +1 |
| Пассажир: «не ехал» (`disputed`) | пока бронь в `awaiting_confirm` (с PIN это до 48 ч, дальше автозавершение; без PIN до 7 дней) | решает модератор по чату и PIN; без PIN — в пользу пассажира. `refund_full` → бронь `cancelled`, `cancelled_by = system`, `cancel_reason = dispute_refund`, водителю `no_shows` +1; `refund_partial` → бронь `completed`, счётчики не трогаются | — |
| Платформа отменила поездку (бан водителя) | — | 100 % | — |

Санкций в MVP нет: счётчики видны в профиле как бейдж («Nunca cancelou» / «Às vezes cancela») и в админке. Автоматическое отключение злостных отменяющих — после теста, когда будет понятно, где порог; до этого — вручную модератором.

Комиссию шлюза при возврате по вине пассажира (> 24 ч) несёт пассажир — вычитается из возврата и показывается на экране отмены до подтверждения. Во всех остальных случаях возврат полный, комиссию шлюза платит платформа. Комиссия платформы (`fee_kz`) возвращается вместе с ценой везде, где возврат 100 %.

## 6. Бизнес-логика на сервере

Три слоя: RPC-функции (то, что вызывает клиент), триггеры (инварианты, которые нельзя обойти) и cron-задачи (всё, что зависит от времени). Edge Functions — только доставка во внешние API.

**RPC-функции** (`security definer`, проверяют `auth.uid()` сами, возвращают json или бросают ошибку с кодом)

| Функция | Кто вызывает | Что делает |
| --- | --- | --- |
| `search_trips(origin, destination, date, seats, cursor)` | все, включая анонимов | поиск по `trips_public`, ±1 день; сортировка: сначала по времени, при равном — verified выше; пишет `events.search` |
| `upsert_profile(payload)` | владелец | имя, bio, год рождения, chat\_level, payout\_method, `terms_accepted` / `adult_confirmed` (один раз); телефон не меняется здесь |
| `upsert_vehicle(payload)` | владелец | макс. 3 активные машины; смена номера сбрасывает `verified` |
| `submit_verification(vehicle_id, doc_urls)` | владелец | `doc_urls` — четыре пути в бакете `verifications/<uid>/` (`VERIFICATION_INCOMPLETE`); одна `pending` (`VERIFICATION_PENDING`); после `rejected` не раньше чем через 24 ч (`RATE_LIMITED`); `driver_status → pending`, если был `none`/`rejected` (verified водитель с новой машиной остаётся verified); админам `verification_submitted` |
| `review_verification(id, approve, reason)` | admin | approve → `driver_status = verified`, `vehicles.verified = true`, `moderation_actions(verify_id)`; reject → `reason` обязателен (`REASON_REQUIRED`), `driver_status = rejected`, если не verified по другой машине; уведомление с причиной |
| `publish_trip(payload)` | любой водитель с машиной и `payout_method` | валидация; `origin`/`destination` только `city`/`town` (landmark — в `origin_detail`), иначе `PLACE_INVALID`; `booking_mode` (instant по умолчанию); `wait_minutes` 30 / 45 / 60 (`WAIT_INVALID`); не больше 5 активных поездок; запрет дубля ±2 ч; подсказка цены из `route_durations` |
| `create_return_trip(trip_id, departure_at) → uuid` | водитель | копия поездки с перестановкой городов и точек, та же машина, цена, места, режим брони, багаж, флаги, заметки; внутри вызывает `publish_trip`, поэтому все его проверки и ошибки те же |
| `update_trip(trip_id, payload)` | водитель | цена/места/заметки/багаж/флаги/детали точек/`wait_minutes` — только пока нет оплаченных броней (`TRIP_HAS_BOOKINGS`); время — пока нет ни одной брони, включая `pending_payment`, сбрасывает `driver_confirmed_at`; `booking_mode` — в любой момент, действует на новые брони; любой другой ключ (`vehicle_id`, города) → `TRIP_FIELD_LOCKED`; поездка не в `published`/`full` → `TRIP_CLOSED` |
| `driver_arrived(trip_id)` | водитель | «Cheguei»: окно `departure_at − 3 ч … departure_at + wait_minutes` (`ARRIVAL_WINDOW_CLOSED`), идемпотентна; `driver_arrived_at`, пассажирам `driver_arrived` и системное сообщение с временем ожидания |
| `confirm_trip_intent(trip_id)` | водитель | ответ на напоминание −24 ч: ставит `driver_confirmed_at` (повторный вызов не ошибка); без него к −6 ч пассажирам открывается бесплатная отмена; поездка не в `published`/`full` → `TRIP_CLOSED` |
| `cancel_trip(trip_id, reason)` | водитель | каскад по броням: `pending_payment` → `payment_failed`, `requested`/`accepted` → `cancelled` с полным возвратом, удержанные 50 % поздних отмен → `forfeit`; `cancels_total` +1, только если была хотя бы одна оплаченная бронь; после `departed` → `TOO_LATE_TO_CANCEL` |
| `request_booking(trip_id, seats, message)` | пассажир | атомарно: проверка мест, статуса профиля и поездки (`published`, до `departure_at − 1 ч`), резерв места, бронь `pending_payment`, запись `payments(created, expires_at = +15 мин)`; лимит 3 активные брони (`BOOKING_LIMIT_REACHED`); `restricted` не может; возвращает `booking_id` + `payment_id` + суммы для `payments-init` |
| `retry_payment(booking_id)` | пассажир | из `payment_failed`, если места ещё есть и поездка открыта: новый резерв, новая строка `payments`, бронь снова `pending_payment`; не больше 3 попыток на бронь |
| `confirm_payment(payment_id, provider_ref, status, payer_phone, raw)` | только Edge `payments-webhook` (service role) | идемпотентно по `provider_ref`; `paid` и телефон совпал → ledger `escrow +`, чат найден или создан с `booking_id`, затем по `booking_mode`: instant → `accepted` + PIN + системное сообщение «Lugar confirmado»; approval → `requested`, водителю уведомление; `paid` и телефон не совпал → `payment_failed` + автоматический полный возврат; `paid`, а бронь уже не `pending_payment` (протухла, поездка закрыта) → полный возврат, бронь не трогается, пассажиру `refund_done`; `failed`/`expired` → `payment_failed`, место назад |
| `respond_booking(booking_id, accept, reason)` | водитель, только для approval-поездок | accept → `accepted` + pin; decline → `declined` + возврат (ledger `escrow − / refunds +`, задача на refund в шлюз) |
| `cancel_quote(booking_id)` | пассажир или водитель | сумма возврата, удержание и правило по таблице раздела 5 для показа на экране отмены до подтверждения; та же функция `refund_rule`, что и в `cancel_booking` |
| `cancel_booking(booking_id, reason)` | пассажир или водитель | `cancelled_by`, возврат по таблице раздела 5, место назад, `cancels_total` +1 где положено; водитель на бронь в `requested` = отказ (`declined`, без санкции); из `pending_payment` нельзя (`PAYMENT_PENDING`), после `departed` нельзя (`TOO_LATE_TO_CANCEL`) |
| `enter_pin(booking_id, pin) → {ok, attempts_left}` | водитель | только в `accepted`/`awaiting_confirm`, окно от `departure_at − 3 ч` до `departure_at + 24 ч` (`PIN_WINDOW_CLOSED`); верный → `pin_entered_at`, `{ok: true}`; неверный → `{ok: false, attempts_left}` без ошибки (ошибка откатила бы запись о попытке); 5 неверных за 10 мин → `RATE_LIMITED`; не 4 цифры → `PIN_INVALID` |
| `confirm_trip(booking_id, happened bool)` | пассажир | только из `awaiting_confirm`; true → `completed` + ledger `escrow − / driver_balance + / platform_fee +`, `trips_ridden` +1, обеим сторонам `review_request` через 24 ч; false → `disputed`, водителю `dispute_opened` |
| `mark_no_show(booking_id)` | водитель | только из `awaiting_confirm`, не раньше `departure_at + wait_minutes` (`NO_SHOW_TOO_EARLY`), в первые 48 ч (`NO_SHOW_WINDOW_CLOSED`), и только если по этой поездке введён PIN хотя бы одного другого пассажира: → `no_show`, ledger release водителю, пассажиру `no_shows` +1; поездка с единственным пассажиром без PIN → `disputed`, решает модератор; несколько пассажиров без PIN или PIN самой брони → `NO_SHOW_NEEDS_PIN` |
| `resolve_dispute(booking_id, outcome, amount_kz)` | admin (`NOT_ADMIN`) | `outcome` ∈ {`completed`, `refund_full`, `refund_partial`} (`DISPUTE_OUTCOME_INVALID`); `completed` → как подтверждение пассажира; `refund_full` → возврат, бронь `cancelled` от `system`, водителю `no_shows` +1; `refund_partial` → `amount_kz` пассажиру (`DISPUTE_AMOUNT_INVALID` вне 1..эскроу−1), остаток водителю минус комиссия пропорционально, бронь `completed`; пишет `moderation_actions(resolve_dispute)`, обеим сторонам `dispute_resolved` |
| `request_payout(amount_kz)` | любой водитель с `payout_method` | `amount ≥ 5 000` (`AMOUNT_INVALID`); одна заявка в работе (`PAYOUT_PENDING`); не чаще раза в 7 дней (`RATE_LIMITED`); `balance_kz ≥ amount` (`INSUFFICIENT_BALANCE`); ledger `payout:<id>` `driver_balance − / cash_out +`; заявка `requested` со снимком `payout_method`; админам `payout_requested` |
| `mark_payout(payout_id, status, ref)` | admin | `processing` / `paid` / `failed` из `requested`/`processing`; `paid` → `provider_ref`, `processed_by/at`, водителю `payout_paid`; `failed` → ledger `payout_failed:<id>` `cash_out − / driver_balance +`, водителю `payout_failed` |
| `send_message(body, conversation_id?, trip_id?) → message_id` | участник | без `conversation_id` — создаёт чат по (trip, passenger) для поездки в `published`/`full`; лимиты: 5 новых чатов без брони за сутки и 10 сообщений пассажира до оплаченной брони (`CHAT_LIMIT_REACHED`), 60 сообщений/мин (`RATE_LIMITED`); только в открытом чате (`CHAT_CLOSED`); маскирование триггером; получателю push `new_message` с превью, если он не был в чате последние 60 с |
| `mark_read(conversation_id, up_to_message_id)` | участник | — |
| `reveal_contact(booking_id) → {user_id, display_name, phone}` | обе стороны | только `accepted`/`awaiting_confirm` (`BOOKING_CLOSED`) и `now() ≥ departure_at − 2 ч` (`CONTACT_LOCKED`); пишет `contact_reveals` |
| `submit_review(booking_id, rating, tags, comment)` | обе стороны | только `completed`/`no_show`; 14 дней от `completed_at` (`REVIEW_WINDOW_CLOSED`); `rating` 1–5, `tags` из `pontual`/`condução_segura`/`simpático`, `comment` ≤ 300; один отзыв на автора (`REVIEW_DUPLICATE`) |
| `report_user(target_id, reason, details, trip_id?, booking_id?, message_id?)` | любой | не на себя (`TARGET_INVALID`); ≤ 10 жалоб в сутки; `reports(open)`; админам in-app `report_opened` |
| `register_device(platform, token, app_version)` | клиент | upsert по токену |
| `mark_notifications_read(ids[])` | владелец | — |
| `admin_search_users(q, lim)` | admin | поиск по телефону (цифры), имени или id; карточка пользователя одним вызовом |
| `admin_moderate(target_id, action, reason, days?, report_id?)` | admin | `warn` / `restrict` / `suspend` на `days` / `ban` (телефон в `banned_phones`, вход закрыт, поездки водителя отменяются платформой с возвратом 100 %, брони пассажира отменяются с возвратом ему) / `unban`; пишет `moderation_actions`, цели `moderation_action`; с `report_id` жалоба → `actioned` |
| `admin_resolve_report(report_id, outcome, note?)` | admin | `reviewed` (в работе) или `dismissed` |
| `admin_cancel_trip(trip_id, reason)` | admin | скрыть поездку: отмена платформой, возвраты 100 %, без `cancels_total` водителю |
| `admin_cancel_booking(booking_id, reason)` | admin | отмена одной брони платформой, возврат 100 %, счётчики сторон не меняются |
| `admin_mark_refund_manual(payment_id, ref, note?)` | admin | возврат сделан вручную переводом: закрывает строку очереди `refund_manual` |
| `admin_upsert_place(payload)`, `admin_merge_places(from_id, into_id)` | admin | справочник мест: добавить, переименовать, деактивировать, объединить дубли (поездки и `route_durations` переводятся, алиасы объединяются) |
| `admin_stats()`, `admin_weekly(weeks)` | admin | очереди, сегодня / 7 дней, здоровье; воронка и деньги по неделям, топ маршрутов |
| `delete_me()` | владелец | запрещено при активных бронях или активных поездках водителя (`HAS_ACTIVE_BOOKINGS`), при `balance_kz ≠ 0` или заявке на выплату в работе (`BALANCE_NOT_ZERO`); обезличивает профиль (`status = deleted`, имя «Utilizador removido», телефон и метод выплаты null), снимает машины, закрывает чаты, удаляет устройства, в `auth.users` обнуляет телефон и ставит `banned_until = infinity`; поездки, брони, отзывы, ledger остаются |

**Триггеры**

- `bookings` after insert/update → пересчёт `trips.seats_available` (резерв считается уже с `pending_payment`) и перевод `published ↔ full`.
- `bookings` → `requested` → найти `conversations` по (trip\_id, passenger\_id) или создать, проставить `booking_id` + системное сообщение «Запрос оплачен, водитель ответит за 24 ч».
- `bookings` → `accepted` → системное сообщение с PIN отправляется в чат только в `departure_at − 2 ч` (cron), не триггером.
- `ledger_entries` after insert → пересчёт `profiles.balance_kz`; before update/delete → raise.
- `messages` before insert → маскирование `\+?244\d{9}`, `9\d{8}` (отдельным числом), `wa.me`, `http(s)://` → «[oculto]», `masked = true`; пока у чата нет брони в `accepted`/`awaiting_confirm`/`completed`/`no_show`/`disputed` или до `departure_at − 2 ч`; системные сообщения не маскируются. After insert: третье замаскированное сообщение одного отправителя в чате → `reports(reporter_id = null, cash_offer)` один раз на чат и отправителя, админам `report_opened`.
- `reviews` after insert → пересчёт `profiles.rating_avg`, `rating_count`; `is_visible`, если второй отзыв уже есть.
- Финал брони: `complete_booking` (внутренняя, её вызывают `confirm_trip`, `resolve_dispute` и cron) → `completed`, ledger release, `trips_ridden` +1 на бронь, `review_request` обеим сторонам через 24 ч. Затем `settle_trip`: когда у поездки `departed` не осталось броней в `accepted`/`awaiting_confirm`/`disputed`, удержанные 50 % поздних отмен → release водителю, поездка → `completed`, `trips_driven` +1 на поездку (не на бронь), если хотя бы одна бронь дошла до `completed`/`no_show`.
- Уведомления о переходах статусов пишут сами RPC и cron через `notify()` (inapp всегда, плюс push при живом токене, иначе SMS, если событие это допускает). Общего триггера нет: тексты и адресаты у каждого перехода разные. Инвариант "каждый переход пишет уведомление" проверяют тесты.
- `profiles` before update → запрет менять `is_admin`, `status`, `driver_status`, `rating_*`, `balance_kz` не из `security definer`-функций.
- `auth.users` after insert → создание строки в `profiles` с телефоном.

**Cron (pg\_cron, каждые 5 минут одна функция `run_scheduler(as_of default now())`)**

Каждый шаг — отдельная функция `sch_<name>`, вызывается через `scheduler_step` в своём блоке исключений: ошибка шага пишется в `scheduler_jobs.last_error` и `events('scheduler_error')`, остальные шаги выполняются. Часовые и дневные шаги гейтятся по `scheduler_jobs.last_ok_at`. Параметр `as_of` подменяет «сейчас» для тестов; денежные переходы используют `now()`. Postgres не ходит во внешние API: шаги, которым нужен шлюз или FCM, готовят данные (`pending_refunds`, `notifications`), а Edge Functions забирают их по своему расписанию (`pg_cron` + `pg_net`, раздел 6, Edge Functions).

| Задача | Когда | Действие |
| --- | --- | --- |
| Протухание платежей | `payments.expires_at + 5 мин` прошёл, статус `created` или `pending` | → `payments.expired`, бронь `payment_failed`, место назад. 5 минут запаса — окно для Edge `payments-status`, которая опрашивает шлюз по `pending` с истёкшим `expires_at` и вызывает `confirm_payment`; оплата, пришедшая после протухания, возвращается автоматически (ветка поздней оплаты) |
| Протухание запросов | `requested` старше 24 ч **или** `departure_at − 1 ч` наступил | → `expired`, полный возврат |
| Напоминание −24 ч | `departure_at − 24 ч`, `reminded_24h_at is null` | водителю — «подтвердите, что едете» (`confirm_trip_intent`); пассажирам — время и место; отметка `reminded_24h_at` |
| Водитель не подтвердил | `departure_at − 6 ч`, нет `driver_confirmed_at`, `reminded_6h_at is null` | пассажирам `driver_unconfirmed` («можно отменить бесплатно», правило уже работает в `cancel_quote`); водителю `trip_reminder_6h`; отметка |
| PIN и телефон | `departure_at − 2 ч`, по броням `accepted`/`awaiting_confirm` с `pin_sent_at is null` | системное сообщение с PIN в чат; пассажиру `pin_ready` (PIN + телефон водителя, push + SMS); водителю один раз `trip_reminder_2h` со списком пассажиров и телефонами; `pin_sent_at`. Бронь, принятая позже −2 ч, получает PIN на следующем тике. `reveal_contact` и маскирование смотрят на `departure_at − 2 ч` сами |
| Выезд | `departure_at` | есть `accepted` → `trip → departed`, `accepted → awaiting_confirm`; нет → `expired` + удержания поздних отмен → `forfeit`; оставшиеся `pending_payment` → `payment_failed`, их платежи → `expired` |
| «Вы доехали?» | `departure_at + minutes` из `route_durations` (по умолчанию +8 ч), `completed_ask_at is null` | `trip_completed_ask` пассажирам в `awaiting_confirm`; отметка |
| Автозавершение быстрое | `awaiting_confirm`, есть `pin_entered_at`, прошло 48 ч после выезда, спора нет | `complete_booking(b, 'system')`: `completed`, ledger release, `settle_trip` |
| Автозавершение | `awaiting_confirm` без PIN старше 7 дней | то же |
| Водитель не приехал | поездка `departed`, ни одного PIN и ни одной `completed`/`no_show`, ≥ 1 спор пассажира (`disputed` с `passenger_confirmed_at`) старше 24 ч, и водитель не ответил: ни сообщения водителя в чате спорной брони после открытия спора, ни PIN, ни отметки «Cheguei» (`driver_arrived_at`) | все `awaiting_confirm`/`disputed` → `cancelled`, `cancelled_by = driver`, `cancel_reason = driver_no_show`, полный возврат; поездка → `cancelled`; водителю `cancels_total` +1, `no_shows` +1; удержания → `forfeit`. Если водитель ответил — ждём модератора (`resolve_dispute`) |
| Истечение поездок | `published`/`full` без `accepted`, `departure_at` в прошлом | → `expired` (внутри шага «Выезд») |
| Возвраты в шлюз | view `pending_refunds` | не в `run_scheduler`: Edge `payments-refund` по своему `pg_cron`-расписанию читает view, ходит в шлюз, пишет `refund_ref` или `refund_attempts` +1 и `refund_failed_at`; после 3 попыток — ручная очередь в Telegram |
| Закрытие чатов | бронь `completed`/`no_show` + 7 дней; бронь `cancelled`/`declined`/`expired` + 24 ч; бронь `payment_failed` или без брони — `departure_at + 24 ч`; поездка `cancelled`/`expired` + 24 ч | `conversations.closed_at` |
| Видимость отзывов | 14 дней после `completed` | `is_visible = true` для одиночных |
| Чистка | ежедневно | `devices` без активности > 90 дней удаляются; URL документов верификации обнуляются через 30 дней после решения; тела сообщений старше 12 мес → «[mensagem apagada]» (строка остаётся); `events` > 12 мес удаляются, кроме `scheduler_error` и `reconciliation_mismatch` |
| `route_stats` | ежечасно | refresh materialized view |
| Сверка | ежедневно | инварианты по всему ledger: `−Σ cash_in = Σ payments.amount_kz (paid/refunded/partially_refunded)`, `Σ refunds = Σ payments.refund_kz`, каждый `op_id` в нуле, `balance_kz = Σ driver_balance`; расхождение → `events('reconciliation_mismatch')` + `reconciliation_alert` всем admin (Telegram-бот I4 читает) |

**Edge Functions**

- `payments-init(booking_id)` — вызывается клиентом через `functions.invoke` после `request_booking`; проверяет по JWT, что платёж в `created` принадлежит вызывающему; создаёт транзакцию в шлюзе Multicaixa Express на телефон аккаунта (контракт — `docs/gateway-contract.md`), через RPC `payment_initiated` переводит платёж в `pending` с `provider_ref` и `expires_at = +15 мин`, возвращает клиенту `{payment_id, expires_at, instructions}` (push в приложение MCX Express, QR или deep link — зависит от шлюза, см. раздел 10). Повторный вызов возвращает прежнюю инструкцию.
- `payments-webhook` — endpoint для шлюза без JWT; проверяет подпись `X-Gateway-Signature` (HMAC-SHA256, иначе 401), вызывает `confirm_payment` service-ролью с телефоном плательщика из ответа шлюза, отвечает 200 всегда (идемпотентность — в SQL).
- `payments-refund` — вызывается `pg_cron` каждые 5 минут (`edge_call`); читает view `pending_refunds`, идёт в шлюз, результат пишет RPC `payment_refund_result`: `refund_ref` + `refunded_at` или `refund_attempts` +1; после трёх неудач админам `refund_manual`.
- `payments-status` — опрос статуса в шлюзе: клиентом по кнопке «Проверить оплату» (`{payment_id}`) и `pg_cron` раз в минуту (`?sweep=1`) по `pending` с истёкшим `expires_at` — окно 5 минут до того, как `run_scheduler` протухнет платёж сам; терминальный статус → `confirm_payment`.
- `send-sms` — Supabase Auth Send SMS Hook (standard-webhooks): получает телефон и код OTP, отправляет через castbrick. SMS-уведомления идут через `notify`, не через этот хук.
- `notify` — доставка push (FCM HTTP v1) и SMS (castbrick) из `notifications`: триггер `notifications_dispatch` после insert зовёт её через `pg_net` для строк без `scheduled_for`, а `pg_cron` раз в минуту (`?sweep=1`) добирает отложенные (тихие часы) и повторы; результат пишет RPC `notification_delivered`: `sent`, либо `failed` после трёх попыток с интервалом 5 минут. Без ключей провайдеров работает адаптер `log` (dev). `inapp` помечается `sent` в момент записи.
- `telegram-moderation` — webhook Telegram-бота: верификации, жалобы, споры, выплаты, ручные возвраты, алерты сверки (перенос из Ambo).
- Auth hooks — не Edge, а Postgres-функции (`pg-functions://`), без сети и секретов: `custom_access_token_hook` кладёт `app_metadata.role = admin` в JWT для `profiles.is_admin` (и снимает устаревший), `before_user_created_hook` отклоняет регистрацию номеров из `banned_phones` (403).
- `payments-mock` — dev-реализация контракта шлюза без своего состояния: статус читает из `payments`, вебхук шлёт через 5 с, сценарии `metadata.simulate` (`paid`, `failed`, `mismatch`, `silent`). Сквозной прогон — `scripts/edge-smoke.sh`.
- Вызов Edge из базы: `edge_call(path, body)` → `pg_net` с `edge_url`/`edge_key` из Vault; без секретов (тесты, свежий dev) — тишина. Локально секреты кладёт `scripts/dev-vault.sh`.

Изображения сжимаются на клиенте до загрузки в Storage (как решено для Ambo), сервер их не трогает.

## 7. Контракт API для клиентов

Контракт = схема Postgres: таблицы для чтения через views, RPC для записи, enum'ы как единый источник типов. Nuxt генерирует типы `supabase gen types typescript`, Flutter — вручную из того же SQL (или через `supabase_codegen`, если Мануэль захочет). Изменение схемы = PR в репозиторий `boleia-db` с миграцией; клиентские репо подтягивают типы после мержа.

**Чтение (PostgREST, прямые select по views и таблицам под RLS)**

| Что | Откуда | Кому |
| --- | --- | --- |
| Список/детали поездки | `trips_public` | все |
| Маршруты для SEO | `route_stats`: все пары из `route_durations` плюс пары с поездками | все |
| Профиль водителя публичный | `profiles_public` (без телефона, без `is_admin`, без баланса) | все |
| Отзывы о пользователе | `reviews_public` (видимые, с именем и аватаром автора) | все |
| Мои поездки как водителя | `trips` where `driver_id = uid` + вложенные `bookings` (без телефона пассажира) | владелец |
| Мои брони | `my_bookings` — с `payments.status` и `conversation_id`; view фильтрует по `auth.uid()` сама (пассажир или водитель поездки), без `security_invoker`: RLS `trips`/`profiles` не отдала бы пассажиру строки водителя | владелец |
| Мои чаты и сообщения | `my_conversations` (фильтр по `auth.uid()` внутри view; `unread_count` считает и системные сообщения), `messages` by `conversation_id` | участники |
| Кошелёк водителя | `driver_wallet` + `payouts` | владелец |
| Очередь возвратов в шлюз | `pending_refunds` (`refund_kz > 0`, `refund_ref is null`, `refund_attempts < 3`) | только service role (Edge `payments-refund`) |
| Моя верификация | `driver_verifications` where `user_id = uid` (без URL документов после решения) | владелец |
| Контакт второй стороны | только через RPC `reveal_contact` | участники, с `departure_at − 2 ч` |
| Уведомления in-app | `notifications` where `user_id = uid` and `channel = 'inapp'` | владелец |
| Справочник мест | `places` where `is_active` | все, кэшировать на клиенте на сутки |

**Запись** — только RPC из раздела 6. Прямой `insert/update` в `trips`, `bookings`, `reviews` закрыт RLS.

**Realtime** — три подписки, не больше:

- Водитель: `bookings` where `trip_id in (мои активные)` — новые оплаченные запросы и отмены.
- Пассажир: `bookings` where `passenger_id = uid` — accept/decline и статус платежа (`pending_payment → requested` приходит сюда, клиенту не нужно поллить).
- Открытый чат: `messages` where `conversation_id = <текущий>` — одна подписка на один открытый экран чата, отписка при уходе с экрана. Список чатов обновляется pull'ом и пушами, не подпиской.

Всё остальное — pull при открытии экрана. Push дублирует realtime, чтобы не держать сокет в фоне. Платёжный флоу на клиенте: `rpc('request_booking')` → `functions.invoke('payments-init')` → показать инструкцию (подтвердить в MCX Express / QR) → ждать realtime-событие по брони или нажать «Проверить оплату» (`payments-status`); без вечного поллинга.

**Соглашения**

- Имена полей `snake_case`; `*_at` — всегда `timestamptz` в ISO 8601 с `Z`; деньги — целые кванзы в полях `*_kz`.
- Пагинация — keyset по `(departure_at, id)` для поездок и по `id` для сообщений, параметр `cursor`; никакого `offset`.
- Ошибки RPC — `raise exception` с кодом `P0001` и `message = 'BOLEIA_<CODE>'`: `TRIP_FULL`, `TRIP_NOT_BOOKABLE`, `PROFILE_INCOMPLETE`, `PROFILE_RESTRICTED`, `DRIVER_``LIMIT_REACHED, BOOKING_DUPLICATE, BOOKING_CLOSED, PAYMENT_PENDING, PAYMENT_PHONE_MISMATCH, PAYMENT_RETRY_LIMIT`, `TOO_LATE_TO_CANCEL`, `PIN_INVALID`, `PIN_WINDOW_CLOSED`, `CHAT_CLOSED`, `INSUFFICIENT_BALANCE`, `RATE_LIMITED`, `NOT_PARTICIPANT`, `OWN_TRIP`, `SEATS_INVALID`, `MESSAGE_TOO_LONG`, `TRIP_NOT_FOUND`, `BOOKING_NOT_FOUND`, `BOOKING_LIMIT_REACHED`, `NOT_ADMIN`, `TRIP_CLOSED`, `TRIP_HAS_BOOKINGS`, `TRIP_FIELD_LOCKED`, `NO_SHOW_WINDOW_CLOSED`, `NO_SHOW_NEEDS_PIN`, `DISPUTE_OUTCOME_INVALID`, `DISPUTE_AMOUNT_INVALID`, `MESSAGE_EMPTY`, `CHAT_LIMIT_REACHED`, `CONTACT_LOCKED`, `REVIEW_WINDOW_CLOSED`, `REVIEW_DUPLICATE`, `RATING_INVALID`, `TAGS_INVALID`, `TARGET_INVALID`, `AMOUNT_INVALID`, `PAYOUT_PENDING`, `PAYOUT_CLOSED`, `PAYOUT_STATUS_INVALID`, `PAYOUT_NOT_FOUND`, `VERIFICATION_INCOMPLETE`, `VERIFICATION_PENDING`, `VERIFICATION_CLOSED`, `REASON_REQUIRED`, `HAS_ACTIVE_BOOKINGS`, `BALANCE_NOT_ZERO`, `TARGET_IS_ADMIN`, `DAYS_REQUIRED`, `MODERATION_ACTION_INVALID`, `REPORT_NOT_FOUND`, `REPORT_CLOSED`, `REPORT_OUTCOME_INVALID`, `PLACE_NOT_FOUND`, `PLACE_SLUG_TAKEN`, `WAIT_INVALID`, `NO_SHOW_TOO_EARLY`, `ARRIVAL_WINDOW_CLOSED`. Только для service role и внутренних проверок: `PAYMENT_NOT_FOUND`, `PAYMENT_STATUS_INVALID`, `PAYMENT_REF_MISMATCH`, `LEDGER_UNBALANCED`, `LEDGER_IMMUTABLE`, `PROTECTED_FIELD`. Клиенты мапят код на текст pt-AO локально.
- Телефон во всех ответах — только через `reveal_contact`, в формате E.164; кнопка «Позвонить» — `tel:`, никаких `wa.me`.
- Версионирование — views не ломаются: новые поля добавляются, старые не удаляются и не переименовываются минимум 2 релиза Flutter (магазины обновляют пользователей медленно).

## 8. Auth, доверие, безопасность

Вход — только по телефону с OTP: Supabase Auth с Send SMS Hook → Edge Function `send-sms` → castbrick (тот же провайдер, что уже используется). GoTrue хранит номер без «+» (`244900000005`), `profiles.phone` — в E.164 (`+244900000005`): нормализует триггер `handle_new_user`; сравнения номеров через `same_phone()` по последним 9 цифрам. Email и соцсети не нужны: номер — главный элемент доверия, он же плательщик в Multicaixa Express. В dev — тестовые номера Supabase без реальных SMS.

**RLS по таблицам**

| Таблица | select | insert / update / delete |
| --- | --- | --- |
| `profiles` | свой — полностью; чужой — через `profiles_public` | update своего, кроме защищённых полей (триггер) |
| `driver_verifications` | владелец — свои (URL документов только пока `pending`); admin — все | только RPC; Storage-бакет `verifications` — private, upload владельцем в `<uid>/…`, чтение владельцем и admin. Бакеты `avatars` и `vehicles` — public на чтение, запись владельцем в `<uid>/…`; лимит 5 MiB, только изображения (для верификации ещё PDF) |
| `vehicles` | владелец; публично — через `trips_public` (марка, цвет) | владелец, через RPC |
| `places` | все | только admin |
| `trips` | владелец; публично — `trips_public` | только RPC |
| `bookings` | пассажир — свои; водитель — по своим поездкам | только RPC |
| `payments` | плательщик — свои (без `raw_*`); admin — все | только `confirm_payment` service-ролью |
| `ledger_entries` | владелец — строки с `user_id = uid`; admin — все | только RPC; update/delete — никому |
| `payouts` | владелец; admin | insert — RPC; update — admin |
| `conversations`, `messages` | участники (`driver_id = uid or passenger_id = uid`) | только RPC `send_message` |
| `reviews` | `is_visible` — все; свои невидимые — автор | только RPC |
| `reports` | автор — свои; admin — все | insert через RPC; update — admin |
| `contact_reveals` | admin | только RPC |
| `notifications` | владелец | update `read_at` владельцем; остальное — система |
| `devices` | владелец | владелец |
| `events` | admin | insert — все (включая anon) через RPC |
| `moderation_actions` | admin | admin |

`is_admin` проверяется через `auth.jwt() -> app_metadata -> role = 'admin'`, а не через чтение `profiles` в каждой политике — дешевле и не зацикливается.

**Доверие — что показываем в профиле**

- Телефон подтверждён (всегда), дата регистрации, число поездок, рейтинг, отзывы.
- ✓ Verificado — документ, права и машина проверены модератором. Бейдж на карточке поездки и в профиле; verified-поездки в выдаче выше при равном времени. Больше ничего верификация не меняет: условия публикации, лимиты и выплаты у всех одинаковые. Непроверенный водитель — без ✓ и с пометкой «Condutor não verificado» в карточке.
- Бейдж отмен: «Nunca cancelou» (`cancels_total = 0` при ≥ 1 завершённой поездке) или «Às vezes cancela» (`cancels_total > 0`) — один символ в карточке и профиле, без цифр. Злостных отменяющих в MVP не отключаем автоматически; порог и правило — после теста, пока — вручную модератором.
- Факт, что деньги у платформы до конца поездки, — отдельный блок в карточке: «Pagamento protegido».
- Этап 2: повторная верификация раз в год и при смене машины.

**Антифрод и лимиты (в RPC)**

- Лимиты одинаковые для всех водителей: 5 активных поездок, до 4 мест в поездке. Пассажир: 3 активные брони (туда, обратно и ещё одна). Верификация лимиты не меняет.
- `request_booking` — 10 в сутки; `publish_trip` — 5 в сутки; `send_message` — 60 в минуту; `enter_pin` — 5 ошибок → 10 минут блока.
- Один номер телефона = один аккаунт; при бане — номер в `banned_phones`, повторная регистрация невозможна. Номер плательщика в MCX Express должен совпадать с номером аккаунта: `payments-init` передаёт номер аккаунта шлюзу, а `confirm_payment` сверяет номер из вебхука; несовпадение — автоматический полный возврат (комиссию шлюза платит платформа) и предупреждение на экране; 3 несовпадения → `restricted`. `restricted` запрещает только `request_booking` и `retry_payment` (`PROFILE_RESTRICTED`); чат, поездки водителя, кошелёк и профиль работают до решения модератора.
- Чат: маскирование телефонов и ссылок до `departure_at − 2 ч`, включая всю переписку до оплаты; 3 замаскированных сообщения → автожалоба `cash_offer`; лимиты на чаты без брони; модератор видит чат по жалобе. Метрика в дашборде: доля чатов, не закончившихся оплаченной бронью — рост выше 60 % = сделки уходят в наличку.
- Выплаты: любому водителю, только на `payout_method`, заполненный до первой поездки; смена `payout_method` замораживает выплаты на 48 ч и шлёт SMS на номер аккаунта.
- Поиск для анонимов — rate limit на уровне Supabase API gateway + капча на web после 50 поисков/час с IP.

**Данные**

- Номер машины и телефон не попадают в публичные views ни в каком виде. Документы верификации — private-бакет, удаляются через 30 дней после решения.
- Удаление аккаунта — RPC `delete_me`: запрещено при активных бронях или ненулевом балансе; профиль обезличивается, поездки/брони/отзывы/ledger остаются для целостности и бухгалтерии. Требование магазинов приложений.
- `raw_request`/`raw_webhook` в `payments` не содержат номеров карт (MCX Express их не передаёт), но содержат телефон — доступ только admin.
- Бэкапы — ежедневные Supabase PITR; экспорт `ledger_entries` и `payments` в CSV раз в месяц для бухгалтера.

## 9. Уведомления

Каждое событие пишет строку в `notifications` с одним каналом по приоритету: push, если у пользователя есть живой токен; иначе SMS через castbrick — но SMS только для событий с деньгами или временем (оплата, отмена, напоминание за 2 ч), остальное ждёт, пока пользователь откроет приложение. In-app копия пишется всегда. Сообщения чата — отдельный тип: push с текстом превью, если получатель не в этом чате последние 60 с.

| Событие | Кому | Канал | Текст (смысл) |
| --- | --- | --- | --- |
| `payment_pending` | пассажир | push | «Подтвердите оплату 8 000 Kz в Multicaixa Express в течение 15 мин» |
| `payment_failed` | пассажир | push / SMS | «Оплата не прошла, место освобождено. Попробовать снова →» |
| `booking_requested` | водитель | push / SMS | «Ana R. оплатила 2 места Luanda → Benguela 12 ноя. Ответьте за 24 ч» (approval) |
| `booking_confirmed` | водитель | push / SMS | «Ana R. забронировала 2 места Luanda → Benguela 12 ноя, оплата прошла» (instant) |
| `booking_accepted` | пассажир | push / SMS | «Принято. PIN и телефон водителя придут за 2 ч до выезда» |
| `booking_declined` / `booking_expired` | пассажир | push / SMS | «Не принято, 8 000 Kz возвращаются на карту за 1–3 дня. Другие поездки →» |
| `booking_cancelled_by_passenger` | водитель | push | «Ana R. отменила, место снова свободно» |
| `booking_cancelled_by_driver` / `trip_cancelled` | пассажир | push + SMS | «Поездка отменена, полный возврат. Поездки на эту дату →» |
| `refund_done` | пассажир | push | «8 000 Kz возвращены» |
| `new_message` | получатель | push | превью текста (уже замаскированного), deep link в чат; не шлётся, если получатель был в чате < 60 с назад |
| `report_opened`, `payout_requested`, `verification_submitted` | admin | in-app | очередь модерации; Telegram-бот I4 читает её из `notifications` |
| `trip_reminder_24h` | все стороны | push | водителю — «подтвердите, что едете» (кнопка); пассажиру — время и место |
| `trip_reminder_6h` / `driver_unconfirmed` | водитель / пассажиры | push / SMS | в −6 ч без подтверждения: водителю последнее напоминание; пассажиру «водитель не подтвердил, можно отменить бесплатно» |
| `booking_expired` | пассажир | push / SMS | «Водитель не ответил, 8 000 Kz возвращаются» |
| `reconciliation_alert` | admin | push / in-app | расхождение ledger и `payments` |
| `trip_reminder_2h` + `pin_ready` | все стороны | push + SMS | пассажиру — PIN, телефон водителя и «O condutor espera até HH:MM» (`wait_until`); водителю — телефоны пассажиров |
| `driver_arrived` | пассажиры | push + SMS | «Condutor no local. Espera até HH:MM» |
| `trip_completed_ask` | пассажир | push / SMS | «Вы доехали? Да / Нет» |
| `dispute_opened` | вторая сторона | push / SMS | «Пассажир сообщил, что не ехал» / «Водитель сообщил, что вы не пришли». Модерация разберёт |
| `dispute_resolved` | обе стороны | push / SMS | решение модератора |
| `booking_no_show` | пассажир | push / SMS | «Водитель отметил, что вы не пришли. Бронь закрыта без возврата» |
| `payout_released` | водитель | push | «+6 300 Kz на баланс за поездку 12 ноя» |
| `payout_paid` / `payout_failed` | водитель | push / SMS | — |
| `verification_approved` / `verification_rejected` | водитель | push / SMS | с причиной при отказе |
| `review_request` | обе стороны | push / in-app | через 24 ч после `completed` |
| `moderation_action` | цель | push + in-app | `action` ∈ warn / restrict / suspend / ban / unban / unsuspend, `reason`, `until` |

**Deep links**: `boleia://trip/<id>`, `boleia://booking/<id>` для Flutter; web — `https://boleia.ao/t/<id>` с universal links / app links на те же пути. Все уведомления ведут на экран, где можно сразу сделать действие.

**Тихие часы** — не слать push и SMS с 22:00 до 07:00 по Луанде, кроме платежей, отмен и напоминания за 2 ч; остальное откладывается через `scheduled_for`. Реализовано в `notify()`: срочные типы — `payment_*`, `booking_*`, `dispute_*`, `trip_cancelled`, `refund_done`, `pin_ready`, `trip_reminder_2h`, `reconciliation_alert`; для остальных строки `push`/`sms` получают `scheduled_for` = ближайшие 07:00 Africa/Luanda, `inapp` пишется сразу. Edge `notify` отправляет только строки с `scheduled_for is null or <= now()`. Стоимость SMS через castbrick × ожидаемый объём — посчитать до запуска (раздел 14).

## 10. Платежи — Multicaixa Express в MVP

Модель — предоплата пассажира при запросе, удержание у платформы до подтверждения поездки, выплата водителю на баланс, вывод по заявке. Наличных нет, поэтому платёжный шлюз — критический путь: без договора с ним запуска нет (итерация I1 в разделе 13).

**Как работает Multicaixa Express для мерчанта**

- Multicaixa — национальная платёжная сеть Анголы под управлением EMIS (принадлежит BNA и коммерческим банкам); MCX Express — её мобильное приложение, по данным EMIS на сентябрь 2025 — около 2,5 млн пользователей и 3,5 млн карт ([VerAngola](https://www.verangola.net/va/pt/092025/BancaSeguros/46011/EMIS-aumenta-limite-diário-de-transferências-na-aplicação-Multicaixa-Express-para-500000-kwanzas.htm)).
- Онлайн-приём идёт через GPO (Gateway de Pagamentos Online) EMIS, который подключается через банк: варианты интеграции — API с технической сертификацией или iFrame; оплата по номеру телефона, привязанному к MCX Express, или по QR-коду ([Access Bank Angola, FAQ](https://angola.accessbankplc.com/access/media/documentos/Perguntas-Frequentes.pdf)). Полная API-интеграция может требовать сертифицированного PST — посредника, который проводит разработку и сертификацию ([Access Bank, форма подключения](https://angola.accessbankplc.com/access/media/documentos/Access-Bank-Formulario-de-Adesao-Servico-Gateway-de-Pagamentos-Online.pdf)).
- Платёж асинхронный: мерчант создаёт транзакцию, клиент подтверждает её в приложении MCX Express в течение 90 секунд, результат приходит вебхуком; есть flow с QR и deep link в приложение ([Paybyrd, документация MCX Express](https://docs.paybyrd.com/accept-payments/bank-transfers/multicaixa-express)).
- Лимиты карты: 250 000 Kz за операцию, 500 000 Kz в день — для билетов по 5–15 тыс. Kz не ограничение.

**Флоу оплаты**

1. `request_booking` → бронь `pending_payment`, место зарезервировано, `payments(created, expires_at = +15 мин)`.
2. Клиент → `payments-init` → шлюз создаёт транзакцию на номер аккаунта → `payments(pending)`, `expires_at = +15 мин`.
3. Пассажир подтверждает в MCX Express (push на телефон или QR на web).
4. Шлюз → `payments-webhook` → `confirm_payment(paid, payer_phone)`: номер совпал → ledger `cash_in −amount / passenger_escrow +amount`, чат найден или создан, бронь `accepted` (instant) или `requested` (approval), уведомления; не совпал → `payment_failed`, автоматический полный возврат, предупреждение пассажиру; бронь уже не `pending_payment` (вебхук опоздал) → полный возврат, бронь не трогается.
5. Нет подтверждения за 15 мин (платёж в `created` или `pending`) → cron опрашивает `payments-status` → `payment_failed`, место назад; пассажир может нажать «Попробовать снова» (`retry_payment`, до 3 раз).

**Движение денег в ledger** (пример: цена 7 000 Kz, комиссия платформы 10 % сверху, но не меньше 1 000 Kz за бронь → 1 000; пассажир платит 8 000)

| Момент | Операция | Строки |
| --- | --- | --- |
| Оплата прошла | `payment:<id>` | `cash_in −8 000`, `passenger_escrow +8 000` |
| Оплата опоздала (бронь уже `payment_failed`) или номер не совпал | `payment:<id>` + `refund:<booking>` | `cash_in −8 000`, `passenger_escrow +8 000`, затем `passenger_escrow −8 000`, `refunds +8 000` |
| Поездка подтверждена | `release:<booking>` | `passenger_escrow −8 000`, `driver_balance +7 000`, `platform_fee +1 000` |
| Отказ водителя / отмена водителем / отмена пассажиром > 24 ч | `refund:<booking>` | `passenger_escrow −8 000`, `refunds +8 000` → `payments-refund` (при отмене пассажиром минус комиссия шлюза) |
| Отмена пассажиром < 24 ч, шаг 1 — сразу | `refund:<booking>` | `passenger_escrow −4 000`, `refunds +4 000`; остальные 4 000 остаются в эскроу |
| Отмена пассажиром < 24 ч, шаг 2 — поездка `completed` | `release:<booking>` | `passenger_escrow −4 000`, `driver_balance +3 500`, `platform_fee +500` |
| Отмена пассажиром < 24 ч, шаг 2 — поездка не состоялась | `forfeit:<booking>` | `passenger_escrow −4 000`, `platform_fee +4 000` |
| Спор решён частично | `release:<booking>` + `refund:<booking>` | возврат пассажиру N, остаток водителю минус комиссия |
| Вывод водителем | `payout:<id>` | `driver_balance −N`, `cash_out +N` |
| Отмена пассажиром > 24 ч, комиссия шлюза X за счёт пассажира | `refund:<booking>` | `passenger_escrow −8 000`, `refunds +(8 000 − X)`, `gateway_fees +X` |
| Комиссия шлюза (если списывается с нас) | `gateway:<payment>` | `platform_fee −X`, `gateway_fees +X` |

Сумма строк одной операции всегда 0 (проверяет `ledger_post`, единственная точка записи); `cash_in` — приход от шлюза; `platform_fee` — выручка; `passenger_escrow` — обязательства перед пассажирами; `driver_balance` — обязательства перед водителями. Комиссия шлюза X считается функцией `gateway_fee_kz(amount)`: до договора со шлюзом возвращает 0, меняется одной строкой. Бухгалтеру раз в месяц уходит выгрузка.

**Комиссия** — решено: 10 % сверху с пассажира, минимум 1 000 Kz; минимум считается один раз на бронь, сколько бы мест в ней ни было (4 × 7 000 = 28 000 → 2 800; 2 × 3 000 = 6 000 → 1 000; 1 × 7 000 → 1 000). Водитель получает ровно свою цену. На экране — отдельной строкой «Taxa de serviço». Следствие для дешёвых броней: при 3 000 Kz комиссия составит 33 %, при 7 000 — 14 %; минимум бьёт по коротким поездкам с одним местом, и это надо видеть в конверсии по маршрутам.

**Выплаты в MVP** — вручную: водитель жмёт «Levantar», заявка падает в Telegram-бота, админ переводит через MCX Express / интернет-банк и отмечает `paid`. Раз в неделю, минимум 5 000 Kz. Автоматизация — когда появится API выплат у банка или объём превысит \~50 заявок в неделю.

**Возвраты** — через API шлюза, если он их поддерживает (у Access Bank в FAQ заявлен «упрощённый процесс возврата»); иначе — переводом на номер пассажира в MCX Express из той же ручной очереди. Срок возврата пассажиру обещать «1–3 рабочих дня» до выяснения.

**PIN-код**: пассажир называет 4 цифры при посадке, водитель вводит → `pin_entered_at`. Спор без PIN решается в пользу пассажира; `no_show` без PIN других пассажиров не ставится. Это главное доказательство в спорах о деньгах.

## 11. Модерация и админка

Модерация в MVP — по схеме Ambo: события летят в Telegram-бота с inline-кнопками, тяжёлые случаи — в админке на Nuxt. Один модератор справляется до \~500 поездок/неделю, дальше нужен второй.

**В Telegram-бот (мгновенно)**

- Заявка на верификацию: фото документа, прав, машины, селфи → «Одобрить» / «Отклонить: причина». Цель — ответ за < 12 ч, иначе водители уходят.
- Новая жалоба: контекст + история обоих + чат по этой брони → «Отклонить» / «Предупредить» / «Ограничить» / «Бан».
- `disputed` после «не ехал»: чат, PIN, версии сторон → `completed` или возврат.
- Автожалоба `cash_offer` (3 замаскированных сообщения) → просмотр чата → предупреждение или бан.
- Заявка на выплату: сумма, метод, история водителя → «Выплачено (ref)» / «Отклонить».
- Алерт сверки: расхождение `payments` и ledger за вчера.
- Аномалии: > 5 поездок/день от одного водителя, цена вне ±50 % от медианы маршрута, > 3 `payment_failed` подряд у одного пассажира.

**Админка на Nuxt (`/admin`, доступ по `role = admin`)**

- Поиск пользователя по телефону/имени (`admin_search_users`): профиль, верификация с документами, поездки, брони, платежи, ledger, чаты (только по открытой жалобе или спору — функция `admin_can_see_conversation` в RLS `conversations`/`messages`), отзывы, действия модераторов.
- Действия (`admin_moderate`): предупредить, ограничить, приостановить на N дней (снимается cron'ом по сроку), забанить (поездки водителя и брони пассажира отменяются платформой с полным возвратом), снять бан; одобрить/отклонить верификацию; разрешить спор; отметить выплату; скрыть поездку (`admin_cancel_trip`) и отменить бронь (`admin_cancel_booking`) платформой; ручной возврат (`admin_mark_refund_manual`). Редактирование поездки за водителя — не в MVP: водитель правит сам через `update_trip`.
- Справочник `places`: добавить, переименовать, деактивировать (`admin_upsert_place`), объединить дубли (`admin_merge_places`).
- Дашборд: `admin_stats()` — очереди, сегодня / 7 дней, здоровье cron и уведомлений; `admin_weekly(weeks)` — воронка, GMV, выручка, возвраты, отмены по сторонам, время ответа водителя и верификации, топ-10 маршрутов по неделям.
- Деньги: баланс по счетам ledger, очередь выплат и возвратов, выгрузка CSV за период.
- Дашборд недели: поездки опубликованы / с оплаченной бронью / завершены; запросы → оплачены → приняты (конверсия); GMV, выручка (`platform_fee`), возвраты; отмены по сторонам; среднее время ответа водителя; среднее время верификации; топ-10 маршрутов.

Каждое действие пишется в `moderation_actions` с причиной; цель получает уведомление `moderation_action`.

## 12. ТЗ по экранам

Один набор экранов для web и mobile; web дополнительно несёт SEO-страницы и админку. Приоритет: P0 — без этого MVP не запускается, P1 — в первый месяц после.

| Экран | P | Что на нём | RPC / данные |
| --- | --- | --- | --- |
| Поиск (главная) | P0 | откуда, куда (автокомплит по `places`), дата, мест; популярные маршруты из `route_stats`; блок «Pagamento protegido» | `search_trips`, `places` |
| Результаты | P0 | карточки: время, маршрут, цена + комиссия, водитель (фото, имя, рейтинг, ✓, поездок), мест осталось; фильтр по времени дня и цене | `search_trips` |
| Поездка | P0 | детали, точки посадки/высадки, машина, опции, профиль водителя, две кнопки — «Reservar N lugares» (сумма с комиссией; после оплаты при instant — сразу в чат поездки с подтверждённым местом, при approval — экран ожидания ответа) и «Perguntar ao condutor» (чат до брони) | `trips_public`, `request_booking` |
| Оплата | P0 | сумма, «подтвердите в Multicaixa Express» (web — QR), таймер 15 мин, «Проверить оплату», результат | `payments-init`, `payments-status`, realtime по брони |
| Вход по телефону | P0 | ввод +244, OTP, согласие с правилами | Supabase auth |
| Онбординг профиля | P0 | имя, фото (сжатие на клиенте), год рождения, chat\_level | `upsert_profile` |
| Стать водителем | P0 | мастер: машина → фото документа, прав, машины с номером, селфи → способ выплаты → отправить; экран статуса `pending` / `rejected` с причиной | `upsert_vehicle`, `submit_verification` |
| Профиль публичный | P0 | данные доверия, ✓, отзывы, «пожаловаться» | `profiles_public`, `reviews` |
| Мой профиль | P0 | редактирование, машины, способ выплаты, удалить аккаунт | `upsert_profile`, `upsert_vehicle`, `delete_me` |
| Опубликовать поездку | P0 | мастер в 4 шага: маршрут + точки, дата/время, места + цена (подсказка по медиане маршрута), опции; превью → публикация; выбор режима брони (автобронь / подтверждать вручную); для unverified — плашка «пройдите верификацию: ✓ и выше в выдаче» | `publish_trip` |
| Мои поездки (водитель) | P0 | «Предстоящие / Прошлые»; в карточке — оплаченные запросы с принять/отклонить, кнопка в чат, ввод PIN в день поездки, «не пришёл», отмена | `trips` + `bookings`, `respond_booking`, `enter_pin`, `mark_no_show`, `cancel_trip` |
| Мои брони (пассажир) | P0 | статус с деньгами («7 700 Kz удержано», «возвращено»), чат, PIN и телефон в день поездки, отмена с показом суммы возврата, «Вы доехали?» | `my_bookings`, `cancel_booking`, `confirm_trip`, `reveal_contact` |
| Чаты | P0 | список чатов с непрочитанными; экран чата: сообщения, системные вставки (статусы, PIN), плашка «номера скрыты до дня поездки» | `my_conversations`, `messages`, `send_message`, `mark_read` |
| Кошелёк (водитель) | P0 | баланс, «в ожидании» по будущим поездкам, история начислений, кнопка «Levantar», список выплат | `driver_wallet`, `request_payout`, `payouts` |
| Оценить | P0 | звёзды, теги, комментарий; открывается из уведомления | `submit_review` |
| Уведомления in-app | P1 | список, непрочитанные | `notifications` |
| Оповещение о маршруте | P1 | «сообщить, когда появится Luanda → Lubango 15 ноя» | таблица `route_alerts` (добавить) |
| Правила / Безопасность / Платежи и возвраты / FAQ / Контакты | P0 | статика; страница возвратов — обязательна для магазинов и для доверия | — |

**Только web (Nuxt)**

- `/boleias/<origem>-<destino>` — SEO-страница маршрута: ближайшие поездки, минимальная цена, число поездок за месяц, текст про маршрут, FAQ. Генерируется для всех пар из `route_stats` + sitemap.
- `/boleias/<origem>` — все поездки из города.
- `/t/<id>` — публичная страница поездки для шеринга в WhatsApp (OG-теги с маршрутом и ценой).
- `/admin/*` — раздел 11.

**Только mobile (Flutter)**

- Push-токены, deep links, биометрия для входа после первого OTP.
- Офлайн-кэш последнего поиска, своих броней и последних сообщений чатов (связь за городом).
- Deep link в приложение MCX Express для подтверждения оплаты и возврат в Boleia по завершении.
- Кнопка «Поделиться поездкой» → ссылка `/t/<id>` — главный канал роста на старте; шарить можно куда угодно, но бронь и оплата — только внутри.

## 13. Разделение работы и план итераций

Три репозитория: `boleia-db` (миграции, функции, seed, тесты — Evgenii), `boleia-web` (Nuxt — Evgenii), `boleia-app` (Flutter — Manuel). Схема и RPC — единственная зона, где нужно согласие обоих; всё остальное делается независимо.

| Зона | Владелец | Примечание |
| --- | --- | --- |
| Схема БД, RLS, RPC, триггеры, cron, ledger | Evgenii | PR в `boleia-db`; Manuel — ревьюер |
| Edge Functions: платежи, OTP, notify, Telegram | Evgenii | TypeScript, Deno |
| Nuxt: web-клиент, SEO-страницы, админка | Evgenii | — |
| Flutter: iOS/Android, включая чат и платёжный экран | Manuel | — |
| Договор с банком/PST на GPO, тестовая среда шлюза | Manuel | ангольское юрлицо, встречи в Луанде; начать первым, это самый длинный процесс |
| Seed `places`, тексты pt-AO, страница возвратов | Manuel | знает локальные названия и язык |
| Регистрация в магазинах, Firebase | Manuel | нужно юрлицо / адрес |
| Первые 20 verified-водителей на 2–3 маршрутах | Manuel | ручной набор через знакомых и дилеров с Ambo; верификация до запуска |
| Ручные выплаты и возвраты первые месяцы | Manuel | доступ к счёту юрлица |

**Итерации** — каждая заканчивается проверяемым результатом, следующая не начинается без него.

1. **I0 — Контракт.** `boleia-db` с полной схемой, RLS, заглушками RPC, seed из 30 мест и 20 фейковых поездок; `supabase start` поднимается локально у обоих. Параллельно Manuel запускает договор с банком на GPO. Результат: Manuel может делать Flutter против реальной БД.
2. **I1 — Ядро + деньги.** Все RPC из раздела 6 с pgTAP-тестами на переходы, возвраты и ledger (сумма операции = 0 — отдельный тест); cron; `payments-*` против тестовой среды шлюза (или мок, если среда ещё не выдана). Результат: сценарий «опубликовал → оплатил → принял → PIN → подтвердил → release → выплата» проходит из SQL + вебхук.
3. **I2 — Web MVP.** P0-экраны на Nuxt, включая чат, оплату, кошелёк, верификацию; SEO-страницы; статика. Результат: закрытый тест на 10 знакомых с реальными платежами по 500 Kz.
4. **I3 — Mobile MVP.** Flutter с P0-экранами, push, deep links. Параллельно с I2, после I0. Результат: TestFlight / internal testing.
5. **I4 — Уведомления и модерация.** `notify`, `send-sms`, Telegram-бот с верификацией, спорами и выплатами, `/admin`, сверка. Результат: любая заявка на верификацию закрывается за < 12 ч, выплата — за < 7 дней.
6. **Запуск** на 2–3 маршрутах с 20 verified-водителями. Критерий продолжения — повторное использование (раздел 1), не абсолютные цифры.
7. **I5 — после гейта**: автоматические выплаты, оповещения о маршрутах, промежуточные остановки, ежегодная переверификация.

**Окружения и контроль качества**

- Три Supabase-проекта: `dev` (локальный `supabase start` у каждого), `staging` (облако, sandbox шлюза, тестовые номера для OTP), `prod`. Отдельная org от Ambo.
- `boleia-db`: миграции через `supabase db diff`, pgTAP-тесты на каждый RPC и на инвариант ledger (сумма операции = 0) в GitHub Actions; merge в `main` = деплой на staging, тег = prod.
- Flutter и Nuxt ходят на staging до запуска; переключение на prod — только через переменные окружения, никаких ключей в репозиториях.
- Мониторинг: Sentry в обоих клиентах и в Edge Functions; алерты в Telegram-бот — сверка ledger, ошибки вебхука платежей, очередь уведомлений `failed` > 20 за час, рост `payment_failed` > 30 % за день.
- Логи платежей (`raw_request`, `raw_webhook`) хранятся 12 месяцев — для споров с шлюзом и бухгалтерии.

Сроков нет намеренно: оба делают это помимо основной работы. Зафиксировать после I0, когда будет понятна скорость.

## 14. Открытые вопросы и риски

**Решить до I0**

- [ ] Шлюз для Multicaixa Express: через какой банк (Access Bank, BAI e-BAI, другой) или PSP; нужен ли PST; стоимость подключения, комиссия за транзакцию, сроки settlement, API возвратов и возвращается ли комиссия при refund; sandbox и сроки. Выясняем — это определяет I1 и дату запуска.
- [x] castbrick — протестирован, работает.
- [x] Комиссия — 10 % сверху с пассажира, минимум 1 000 Kz за бронь.
- [x] Юрлицо — пока Ambo (договор с банком, магазины, Firebase, счёт для выплат).
- [ ] Юридическая квалификация: «partilha de custos» vs «transporte de passageiros», и статус удержания денег пассажиров (эскроу) с точки зрения BNA. Выясняем до договора с банком.
- [ ] IVA 14 % на комиссию — выясняем у бухгалтера.
- [x] Название Boleia и домен — пробуем.

**Решить до запуска**

- [x] Стартовые маршруты: Luanda–Benguela/Lobito, Luanda–Huambo, Luanda–Sumbe.
- [x] Доля пассажиров с MCX Express не проверяется: не можешь оплатить — не едешь.
- [x] Первых 20 водителей набираем и верифицируем сами.
- [x] Потолок цены за место — только подсказка, без жёсткого лимита.
- [x] `seats_offered` — максимум 4.

**Риски разработки**

| Риск | Вероятность | Что делаем |
| --- | --- | --- |
| Договор с банком на GPO тянется месяцами и блокирует запуск | высокая | начать в I0; I1–I3 делать на моке шлюза с тем же контрактом вебхука; при затяжке > 3 мес — обсудить PSP-посредника |
| Онлайн-only отсекает пассажиров без MCX Express | средняя | измерить до запуска (см. выше); решение «только онлайн» не пересматривать на первом месяце, но считать отказы на экране оплаты |
| Водители уводят сделки в наличку через чат | высокая | чат открыт до оплаты (решение Manuel), поэтому защита только программная: маскирование, лимиты на чаты без брони, кнопка «Reservar» в чате, автожалоба; следить за долей чатов без брони |
| Схема меняется после того, как Flutter уже написан | высокая | I0 раньше любого UI; views не ломаются (раздел 7) |
| Ошибка в ledger = реальные деньги | средняя | insert-only, pgTAP на каждую операцию, ежедневная сверка с `payments`, ручные выплаты первые месяцы |
| plpgsql-логика без тестов ломается тихо | высокая | pgTAP в CI с первого RPC |
| Supabase лимиты realtime на чате | средняя | Pro с первого реального пользователя; одна подписка на открытый чат |
| Два проекта на одном Supabase-аккаунте с Ambo | низкая | отдельный проект, отдельный org — не смешивать биллинг и доступы |
| Manuel и Evgenii оба part-time, работа встаёт | высокая | итерации с результатом, недельный созвон по `boleia-db`, ничего не начинать без I0 |
| Объём MVP вырос в \~2 раза против версии без денег и чата | факт | либо принять срок, либо вернуть верификацию и чат, а платежи оставить — чат без денег теряет смысл, деньги без чата нет |

## 15. Вопросы на уточнение по ТЗ

Решения зафиксированы 4 ноя 2026 (ответы Evgenii, часть по настоянию Manuel). Открытыми остаются только пункты без галочки.

**Бронирование и правила**

- [x] Окно ответа водителя — **24 ч**; технически обрезается в `departure_at − 1 ч`.
- [x] Бронирование закрывается за 1 ч до выезда; публикация — за 2 ч.
- [x] Имена спутников не нужны: один PIN на бронь, водитель видит «Ana R. + 2».
- [x] Отмена пассажиром < 24 ч: 50 % водителю только после `completed` этой поездки; если поездка не состоялась — платформе.
- [x] Промокодов в MVP нет: отмена водителем < 24 ч = 100 % возврат пассажиру + санкция водителю.
- [x] Instant booking в MVP как режим на выбор водителя, по умолчанию включён; approval — альтернатива.
- [x] Опции в UI: багаж и «макс. двое сзади»; курение, животные, chat\_level — поля в БД остаются, из UI убираем.
- [x] Фильтр «только женщина-водитель» и пол в профиле — нет.
- [x] Обратная поездка одной кнопкой («Criar viagem de regresso» копирует поездку с перестановкой городов) — да; повторяющиеся поездки по расписанию — нет.
- [x] Точки посадки: список `places kind = landmark` (терминал Macon, Gamek, Kilamba…) + свободный текст.
- [x] Длительность маршрута для «Вы доехали?»: таблица `route_durations` руками для стартовых маршрутов, по умолчанию +8 ч.
- [x] Ориентир цены: подсказка руками для стартовых маршрутов, потом медиана; без жёсткого потолка.

**Верификация**

- [x] Документы: BI + права + фото машины с номером + селфи; livrete и страховка — не в MVP.
- [x] Unverified-водитель: явное предупреждение пассажиру перед оплатой «Condutor não verificado. O pagamento fica protegido até ao fim da viagem».
- [x] Выплаты unverified без потолка (Manuel против блокировки; потолок — пока нет).
- [x] Модерируют Evgenii и Manuel; цель — ответ за 12 ч.

**Платежи**

- [x] Номер в MCX Express обязан совпадать с номером аккаунта.
- [x] Национальные карты Multicaixa без приложения Express — да, если шлюз даёт в том же договоре.
- [ ] Комиссия 10 % / мин. 1 000 Kz — решено; IVA 14 % — выясняем у бухгалтера.
- [x] Выплаты раз в неделю, минимум 5 000 Kz, вручную на старте.
- [x] Комиссию шлюза при возврате по вине пассажира (> 24 ч) несёт пассажир — вычитается из возврата, показывается на экране отмены.
- [ ] Бухгалтерия по ledger — кто ведёт и как часто выгрузка: разбираемся.

**Чат**

- [x] Только текст в MVP; фото — этап 2. Единственный пассажир без PIN → `disputed`.
- [x] Чат до оплаты (Manuel); защита: маскирование до дня поездки, 5 чатов/сутки и 10 сообщений до брони, «Reservar» внутри чата, метрика доли чатов без брони.
- [x] Чат 1:1 на каждую пару пассажир–поездка; общий чат поездки — этап 2.
- [x] Телефон показываем за 2 ч до выезда.
- [x] Чаты хранятся 12 месяцев, потом удаляются тела сообщений.

**Пассажир и профиль**

- [x] Фото пассажира — не обязательно, но желательно: напоминание при первой брони, без блокировки.
- [x] Галочка 18+ при регистрации.
- [x] Язык только pt-AO; английский — этап 2.

**Web и mobile**

- [x] Web — полноценный клиент: поиск, бронь, оплата по QR, чат, кошелёк, верификация.
- [x] Android 8+, APK ≤ 25 МБ (дефолт, не обсуждалось).
- [x] PWA не делаем — сразу нативное приложение.

**Операции**

- [x] Поддержка: форма в приложении → Telegram-бот; email для магазинов.
- [x] Название Boleia — пробуем; домен и бренд нужны до I2.
- [ ] Бухгалтерия по ledger — см. «Платежи».

## 16. Спорные решения и их цена

Решения ниже приняты, но у каждого есть сценарий, в котором оно бьёт по продукту. Здесь — что именно может пойти не так, по какой метрике это увидеть и что менять, если метрика пробита. Это не список на пересмотр сейчас, а список на проверку после первого месяца.

| Решение | Чем рискуем | Метрика и порог | Запасной вариант |
| --- | --- | --- | --- |
| Оплата при запросе, до ответа водителя | деньги пассажира заморожены до 24 ч без гарантии места; каждый отказ водителя = возврат и комиссия шлюза за наш счёт | доля запросов с отказом/протуханием > 30 %, расходы на комиссии возвратов > 10 % выручки | «принял → 2 ч на оплату»: водитель видит запрос без денег, пассажир платит после accept; переход — смена порядка двух статусов |
| Чат до оплаты | пассажир и водитель договариваются о наличных, платформа теряет комиссию | доля чатов без оплаченной брони > 60 %; автожалобы `cash_offer` | закрыть чат до оплаты, оставить поле «сообщение водителю» в запросе |
| Непроверенный водитель публикует и выводит деньги | пассажир платит человеку, о котором известен только номер; спор без документов | жалобы на unverified в 2 раза чаще, чем на verified; хотя бы один инцидент с безопасностью | лимиты для unverified (1 поездка, 3 места) или публикация только после загрузки документов |
| Комиссия 10 %, минимум 1 000 Kz | на дешёвых маршрутах комиссия 20–33 %, пассажиры уходят на экране оплаты | конверсия «экран оплаты → paid» по маршрутам < 10 000 Kz ниже дорогих на 20+ п.п. | минимум 500 Kz или процент без минимума на маршрутах < 5 000 Kz |
| Номер MCX Express = номер аккаунта | часть пассажиров платит с чужого телефона и получает отказ | `PAYMENT_PHONE_MISMATCH` > 5 % платежей | разрешить второй «платёжный номер» в профиле с подтверждением по OTP |
| Выплата только после подтверждения пассажира или таймаута | водитель без PIN ждёт деньги до 7 дней; уходит к наличным | среднее время от выезда до `completed` > 3 дней; жалобы водителей | быстрый release через 48 ч для всех, не только с PIN; спор пассажира после release — из баланса водителя |
| `no_show` только при PIN другого пассажира | водитель единственного пассажира, который не пришёл, не может это зафиксировать; пассажир молчит 7 дней и всё равно `completed`, но может открыть спор без доказательств | споры по поездкам с одним пассажиром > 20 % | фото точки посадки с таймстампом как доказательство водителя (этап 2) |
| Ответ водителя 24 ч | на поездку через 10 ч водитель фактически имеет 9 ч; протухание = возврат и потерянная комиссия шлюза | доля `expired` по поездкам < 24 ч до выезда > 25 % | окно 6 ч для поездок ближе 24 ч + push водителю каждые 2 ч |
| Только онлайн-оплата, без наличных | режем рынок до тех, у кого есть MCX Express и готовность платить вперёд | отказы на экране оплаты и уход после просмотра цены (события `trip_view` → `booking_request`) | не пересматривать первый месяц; дальше — «оплата в день поездки» как промежуточный шаг, не наличные |
| Ручные выплаты и возвраты | задержки, ошибки, нагрузка на одного человека | > 50 заявок в неделю или задержка выплат > 7 дней | API выплат банка или PSP; до этого — второй человек с доступом к счёту |
| Логика в plpgsql | медленная итерация по сравнению с TS, труднее отлаживать | время на правку одного RPC с тестами > 1 дня | перенос оркестрации в Edge Functions с оставлением инвариантов в SQL |

**Юридические пункты, которые не закрыты документом и не закроются кодом**

- Квалификация сервиса: partilha de custos или перевозка — определяет, нужны ли лицензии водителям и платформе.
- Удержание денег пассажиров до 7 дней — с точки зрения BNA может быть деятельностью платёжного учреждения; ответ юриста нужен до подписания договора с банком.
- Персональные данные: в Анголе действует закон о защите персональных данных (Lei n.º 22/11) и надзорный орган; документы верификации и телефоны — персональные данные, нужны согласие при регистрации и политика хранения (в документе — 30 дней для документов, 12 месяцев для чатов). Уточнить у юриста, требуется ли уведомление регулятора.
- IVA 14 % на комиссию платформы — влияет на цену, которую видит пассажир.
