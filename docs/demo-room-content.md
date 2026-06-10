# Demo Room Content — Apple Reviewer (STMOB-124 / STALK-276)

3 публичные комнаты на stalk.implica.ru. Аккаунт `@apple-review:stalk.implica.ru` join'ится во все три при первом логине, чтобы Reviewer сразу видел контент без ожидания инвайтов.

Создание комнат и заливка контента — на стороне Molly (см. STALK-276). Этот файл — источник правды по контенту.

> **ВАЖНО (STMOB-222 / 2026-06-10):** весь контент демо-комнат — **на АНГЛИЙСКОМ** (ревьюер Apple). Засев должен быть СВЕЖИМ (актуальный timestamp), чтобы live-окно не было пустым на повторном входе (см. STMOB-222 — event-cache auto-shrink). При повторной заливке — **пересоздать комнаты заново** (старый русский контент = каша, history-visibility у old-join).

---

## 1) #stalk-welcome:stalk.implica.ru

**Topic:** Welcome to sTalk — a corporate messenger on Matrix with E2EE
**history_visibility:** world_readable
**Pinned:** message #1 below.

### Messages (from @bot-stalk, interval 5–10 sec, ENGLISH)

1. (pinned) 👋 Welcome to sTalk!

   What to try:
   • Open a chat — the “Chats” tab
   • Start a call — the “Calls” tab, tap “+”
   • Switch language — Settings → Interface language
   • Search messages — the magnifier icon

   All messages and calls are end-to-end encrypted.
2. 🔒 End-to-end encryption (Olm/Megolm) — neither the server nor an administrator can read your content.
3. 📞 1:1 and group calls with recording, noise suppression and virtual background.
4. 🌍 iOS / Android / Web — one account, synced everywhere.
5. ❓ Questions — #stalk-support or support@stalk.implica.ru.

---

## 2) #stalk-demo:stalk.implica.ru

**Topic:** sTalk feature showcase
**history_visibility:** world_readable
**Permissions:** `users_default = 0`, `events_default = 0` — Reviewer can post.

### Scenario (8–12 messages; mix authors: @bot-stalk, @molly, @penny — ENGLISH)

1. **@bot-stalk** — text:
   `Hi! Here are live examples of what sTalk can do.`
2. **@molly** — markdown:
   `**Bold**, *italic*, ~~strikethrough~~, ` + "`code`" + `, quotes, lists — all supported.`
3. **@penny** — text:
   `React to messages 👍 ❤️ 🚀 — try it on any of these.`
4. reaction 👍 from **@bot-stalk** on #3
5. reaction ❤️ from **@molly** on #3
6. **@penny** — reply to #2:
   `Quoting works too — this is a reply to message #2.`
7. **@bot-stalk** — text (starts a thread):
   `🧵 Threads — discuss details without cluttering the main room.`
8. **@molly** — thread reply to #7:
   `For example, to go over a specific agenda item.`
9. **@penny** — thread reply to #7:
   `…while the main timeline stays clean.`
10. **@bot-stalk** — image (`assets/demo-screenshot.png`):
    sTalk home screen screenshot
11. **@molly** — voice (~3 sec, `assets/demo-voice.ogg`):
    “This is a voice message, three seconds long.”
12. **@penny** — text with a link (URL preview):
    `More about the project: https://stalk.implica.ru`

### Ассеты (Penny подготовит отдельно перед заливкой)

- `demo-assets/demo-screenshot.png` — 1170×2532 PNG, главный экран iOS
- `demo-assets/demo-voice.ogg` — 3 сек, Opus, mono 48k

Если ассетов нет к моменту заливки — Molly заливает текст, картинку/voice добавим вторым проходом.

---

## 3) #stalk-support:stalk.implica.ru

**Topic:** App questions
**history_visibility:** world_readable
**Pinned:** message #1.

### Messages (from @bot-stalk, ENGLISH)

1. (pinned) 💬 sTalk support

   • Email: support@stalk.implica.ru
   • We reply within 24 hours on business days.
2. 👋 Describe your question — we’ll answer here or by email.

---

## Порядок заливки (для Molly)

1. createRoom × 3 (curl из STALK-276). **Пересоздать заново** (новые room_id) для чистого английского контента.
2. `/_synapse/admin/v1/join` @apple-review во все три (нужен admin-token от @rusty).
3. Залить текст через `mcp__stalk__stalk_send_message` (паузы 5–10 сек между сообщениями), **на английском**, свежим timestamp.
4. Реакции через `mcp__stalk__stalk_react` на event_id шага 3 (для #stalk-demo сообщения 4–5).
5. Треды — отправка с `m.relates_to.rel_type = m.thread` и `event_id` корневого (#7).
6. Картинка/voice — `POST /_matrix/media/v3/upload` → MXC → `m.room.message` с `msgtype: m.image` / `m.audio`.
7. Pin — `PUT /_matrix/client/v3/rooms/{roomId}/state/m.room.pinned_events`.

## Definition of Done

- Файл закоммичен в element-x-fork develop, sha записан.
- Penny пинганула Molly в #ops с пометкой `@molly`.
- Molly выполнила STALK-276 шаги 1–5 на английском (см. там DoD).
- Контент во всех трёх комнатах — английский, свежий (live-окно не пустое на re-entry).
