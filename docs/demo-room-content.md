# Demo Room Content — Apple Reviewer (STMOB-124 / STALK-276)

3 публичные комнаты на stalk.implica.ru. Аккаунт `@apple-review:stalk.implica.ru` join'ится во все три при первом логине, чтобы Reviewer сразу видел контент без ожидания инвайтов.

Создание комнат и заливка контента — на стороне Molly (см. STALK-276). Этот файл — источник правды по контенту.

---

## 1) #stalk-welcome:stalk.implica.ru

**Topic:** Добро пожаловать в sTalk! Корпоративный мессенджер на Matrix с E2EE
**history_visibility:** world_readable
**Закреп (pinned):** см. сообщение #1 ниже.

### Сообщения (от @bot-stalk, интервал 5–10 сек)

1. (pinned) 👋 Добро пожаловать в sTalk!

   Что попробовать:
   • Открыть чат — вкладка «Чаты»
   • Позвонить — вкладка «Звонки», нажать «+»
   • Сменить язык — Настройки → Язык интерфейса
   • Поиск по сообщениям — иконка лупы

   Все сообщения и звонки зашифрованы end-to-end.
2. 🔒 Сквозное шифрование (Olm/Megolm) — ни сервер, ни администратор не видят содержимое.
3. 📞 1:1 и групповые звонки с записью, шумоподавлением и виртуальным фоном.
4. 🌍 iOS / Android / Web — один аккаунт, везде sync.
5. ❓ Вопросы — #stalk-support или support@stalk.implica.ru.

---

## 2) #stalk-demo:stalk.implica.ru

**Topic:** Демонстрация возможностей sTalk
**history_visibility:** world_readable
**Permissions:** `users_default = 0`, `events_default = 0` — Reviewer может писать.

### Сценарий (8–12 сообщений; смешать авторов: @bot-stalk, @molly, @penny)

1. **@bot-stalk** — текст:
   `Привет! Здесь живые примеры возможностей sTalk.`
2. **@molly** — markdown:
   `**Жирный**, *курсив*, ~~зачёркнутый~~, ` + "`код`" + `, цитата, списки — всё работает.`
3. **@penny** — текст:
   `Ставьте реакции на сообщения 👍 ❤️ 🚀 — попробуйте сами на любом из этих.`
4. реакция 👍 от **@bot-stalk** на #3
5. реакция ❤️ от **@molly** на #3
6. **@penny** — reply на #2:
   `Ещё работают цитирования — это reply к сообщению #2.`
7. **@bot-stalk** — текст (стартует тред):
   `🧵 Треды — обсуждение деталей без шума в основной комнате.`
8. **@molly** — thread reply на #7:
   `Например, разобрать конкретный пункт повестки.`
9. **@penny** — thread reply на #7:
   `И при этом основной таймлайн остаётся чистым.`
10. **@bot-stalk** — image (`assets/demo-screenshot.png`):
    скрин главного экрана sTalk
11. **@molly** — voice (~3 сек, `assets/demo-voice.ogg`):
    «Это голосовое сообщение, длительностью три секунды»
12. **@penny** — текст со ссылкой (с URL-preview):
    `Подробнее о проекте: https://stalk.implica.ru`

### Ассеты (Penny подготовит отдельно перед заливкой)

- `demo-assets/demo-screenshot.png` — 1170×2532 PNG, главный экран iOS
- `demo-assets/demo-voice.ogg` — 3 сек, Opus, mono 48k

Если ассетов нет к моменту заливки — Molly заливает текст, картинку/voice добавим вторым проходом.

---

## 3) #stalk-support:stalk.implica.ru

**Topic:** Вопросы по приложению
**history_visibility:** world_readable
**Закреп:** см. сообщение #1.

### Сообщения (от @bot-stalk)

1. (pinned) 💬 Поддержка sTalk

   • Email: support@stalk.implica.ru
   • Ответим в течение 24 часов в рабочие дни.
2. 👋 Опишите вопрос — мы ответим тут или на почту.

---

## Порядок заливки (для Molly)

1. createRoom × 3 (curl из STALK-276).
2. `/_synapse/admin/v1/join` @apple-review во все три (нужен admin-token от @rusty).
3. Залить текст через `mcp__stalk__stalk_send_message` (паузы 5–10 сек между сообщениями).
4. Реакции через `mcp__stalk__stalk_react` на event_id шага 3 (для #stalk-demo сообщения 4–5).
5. Треды — отправка с `m.relates_to.rel_type = m.thread` и `event_id` корневого (#7).
6. Картинка/voice — `POST /_matrix/media/v3/upload` → MXC → `m.room.message` с `msgtype: m.image` / `m.audio`.
7. Pin — `PUT /_matrix/client/v3/rooms/{roomId}/state/m.room.pinned_events`.

## Definition of Done

- Файл закоммичен в element-x-fork develop, sha записан.
- Penny пинганула Molly в #ops с пометкой `@sandy`.
- Molly выполнила STALK-276 шаги 1–5 (см. там DoD).
