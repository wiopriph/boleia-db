# Стартовый промпт для boleia-web

Скопировать целиком в Claude Code, запущенный в пустой папке `boleia-web` (рядом с `boleia-db`).

---

Делаем `boleia-web`: web-клиент сервиса междугородних попуток Boleia (Ангола, pt-AO, оплата через
Multicaixa Express). Бэкенд уже готов и живёт в соседнем репозитории `/Users/admin/Project/boleia-db`;
это Supabase: Postgres + RLS + RPC + Edge Functions. Отдельного API нет, клиент ходит в Supabase напрямую.

## Сначала прочитай, в этом порядке

1. `/Users/admin/Project/boleia-db/docs/api.md` - контракт: подключение, тестовые пользователи, флоу,
   все RPC с сигнатурами и ролями, views с колонками, коды ошибок, realtime, Edge Functions, Storage.
2. `/Users/admin/Project/boleia-db/types/database.ts` - типы `Database` для `@nuxtjs/supabase`.
   Копируем в `types/database.ts` этого репозитория скриптом `scripts/sync-types.sh` (сделать), не
   правим руками.
3. `/Users/admin/Project/boleia-db/docs/spec.md` - ТЗ. Нужны разделы 5 (статусы и возвраты), 7
   (контракт), 9 (уведомления), 11 (админка), 12 (экраны P0 и SEO-страницы web).
4. `/Users/admin/Project/boleia-db/docs/flutter-handoff.md` - правила клиента, они те же для web.
5. `/Users/admin/Project/boleia-db/CLAUDE.md` - как работать с бэкендом, если понадобится что-то в нём.

Ключи проекта Supabase (общий dev-проект, данные общие с Flutter): `/Users/admin/Project/boleia-db/.env`.
Скопировать `SUPABASE_URL` и `SUPABASE_ANON_KEY` в `.env` этого репозитория, в git не коммитить.

## Стек

- Nuxt 4, TypeScript strict, Composition API, `<script setup>`.
- `@nuxt/ui` (компоненты, формы, тосты, модалки) с минимальной кастомизацией темы.
- `@nuxtjs/supabase` с типами `Database`; auth только телефон + OTP (`signInWithOtp`, `verifyOtp`),
  номер передаётся без "+": `244900000005`.
- `@nuxt/content` для статики pt-AO: Правила, Безопасность, Платежи и возвраты, FAQ, Контакты, тексты
  SEO-страниц маршрутов.
- Только португальский (pt-AO), без i18n-модуля: тексты пишутся прямо в компонентах. Единственный
  словарь - `app/utils/errors.ts`: код ошибки `BOLEIA_*` -> текст для пользователя.
- `@nuxt/image` для аватаров и фото машин из Storage; сжатие перед загрузкой на клиенте.
- `@nuxtjs/seo` (или `nuxt-og-image` + `@nuxtjs/sitemap`) для `/boleias/*` и `/t/<id>`.
- Деньги форматируются как `8 000 Kz` (целые кванзы), время показывается в Africa/Luanda.

## Маршруты

За основу взят привычный роутинг сервисов попуток, пути на португальском, потому что это и SEO, и
язык интерфейса. Это мой выбор, можно поменять на первом шаге.

| Путь | Экран (ТЗ раздел 12) |
| --- | --- |
| `/` | поиск: откуда, куда (автокомплит по `places`), дата, мест; популярные маршруты из `route_stats`; блок "Pagamento protegido" |
| `/pesquisa?de=<slug>&para=<slug>&data=YYYY-MM-DD&lugares=1` | результаты `search_trips`, фильтры по времени дня и цене |
| `/viagem/<id>` | поездка: детали, водитель, "Reservar N lugares", "Perguntar ao condutor" |
| `/t/<id>` | публичная короткая ссылка для шеринга, OG-теги с маршрутом и ценой, редирект или та же страница |
| `/perfil/<id>`, `/perfil/<id>/avaliacoes` | публичный профиль и отзывы, "Denunciar" |
| `/entrar` | телефон, OTP, согласие с правилами |
| `/conta/perfil` | онбординг и редактирование: имя, фото, год рождения, chat_level, машины, способ выплаты, удалить аккаунт |
| `/conta/reservas`, `/conta/reservas/<id>` | брони пассажира: статус с деньгами, PIN и телефон в день поездки, отмена с `cancel_quote`, "Chegou bem?" |
| `/conta/reservas/<id>/pagamento` | оплата: сумма, QR или инструкция, таймер 15 мин, "Verificar pagamento", результат |
| `/conta/viagens`, `/conta/viagens/<id>` | поездки водителя: запросы принять/отклонить, PIN, "não apareceu", отмена |
| `/publicar` | мастер публикации в 4 шага с превью, выбор режима брони; для unverified плашка про верификацию |
| `/conta/condutor` | стать водителем: машина, документы, способ выплаты, статус заявки |
| `/conta/carteira` | баланс, в ожидании, история, "Levantar", выплаты |
| `/conta/mensagens`, `/conta/mensagens/<id>` | чаты и экран чата с системными вставками и плашкой про скрытые номера |
| `/avaliar/<booking_id>` | оценка: звёзды, теги, комментарий |
| `/boleias/<origem>-<destino>`, `/boleias/<origem>` | SEO-страницы маршрутов и города из `route_stats` + sitemap |
| `/regras`, `/seguranca`, `/pagamentos-e-reembolsos`, `/faq`, `/contactos` | статика из `@nuxt/content` |
| `/admin/*` | раздел 11 ТЗ, вторая половина итерации, только для `app_metadata.role = admin` |

## Дизайн

Минималистичный и понятный. Одна акцентная цветовая роль, нейтральная палитра, системный шрифт или
Inter, сетка 8px, много воздуха. Mobile-first: большинство пользователей на телефонах с нестабильной
связью, поэтому крупные зоны нажатия, одна основная кнопка на экран, явные состояния загрузки и ошибок,
без анимаций ради анимаций. Статус брони и деньги всегда словами и цифрами ("7 700 Kz retidos",
"Reembolsado"), не только цветом. Иконки только Nuxt UI (Lucide). Никаких логотипов и названий
других сервисов.

## Правила клиента

- Запись только через `supabase.rpc(...)`; `from(...).insert/update` только для своих полей
  `profiles`, `devices`, `notifications.read_at`. Всё остальное RLS отклонит.
- Клиент не считает деньги и статусы: суммы берёт из ответов RPC и views (`request_booking`,
  `cancel_quote`, `my_bookings`).
- Ошибки RPC: `PostgrestError` с `message = BOLEIA_<CODE>`. Один composable `useBoleiaError`, который
  достаёт код и берёт текст из `app/utils/errors.ts`; коды в `docs/api.md`. Текст ошибки из базы
  не показывать.
- Realtime ровно три подписки (`docs/api.md`, раздел Realtime), подписка на чат живёт только на
  открытом экране чата.
- Платёжный флоу: `request_booking` -> `functions.invoke('payments-init')` -> показать инструкцию ->
  ждать realtime по брони -> кнопка "Verificar" через `payments-status`. Без вечного поллинга. В dev
  работает мок шлюза: оплата подтверждается сама через 5 секунд; для ошибок в `payments-init`
  можно передать `simulate: 'failed' | 'mismatch' | 'silent'`.
- Телефон второй стороны только через `reveal_contact`, кнопка "Ligar" как `tel:`.
- Сжатие изображений на клиенте перед загрузкой в Storage (бакеты `avatars`, `vehicles`,
  `verifications`, путь `<uid>/<file>`), лимит 5 MiB.
- Никаких секретов в репозитории: только `SUPABASE_URL` и anon key через `.env`.
- Если для экрана не хватает поля или RPC, это задача в `boleia-db`, а не обход на клиенте: опиши,
  что нужно, я заведу миграцию.

## Как работаем

Сначала план, потом код, как делали бэкенд:

1. Прочитай файлы выше и покажи план скелета: модули и их конфиг, структура папок (`app/`, `layouts/`,
   `pages/`, `components/`, `composables/`, `utils/`, `content/`), слои: `useSupabaseTyped`, composables
   на домены (search, booking, payment, chat, driver, wallet), middleware auth и admin, обработка
   ошибок, realtime, форматирование денег и дат. В конце плана - пронумерованные вопросы, где ТЗ или
   контракт не дают ответа, по каждому твой вариант. Я отвечаю номерами.
2. После одобрения: скелет с одним работающим экраном `/entrar` против облачного проекта, проверка
   входа тестовым номером в браузере.
3. Дальше экраны по одному в порядке: поиск и результаты -> поездка -> бронь и оплата -> мои брони ->
   чаты -> публикация и поездки водителя -> стать водителем -> кошелёк -> профили и отзывы -> статика
   и SEO -> админка. Каждый экран проверяется в браузере против облака с тестовыми пользователями,
   коммит в `master` после каждого.
4. Компоненты из Nuxt UI, без своих UI-библиотек.

Начни с шага 1.
