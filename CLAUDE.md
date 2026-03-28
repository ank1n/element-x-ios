делай план изменений что мы провели
записывай изменения в функционале как новые ппункты плана изменений и добаляй ссылку на коммит в коде который нужно применять для того чтобы изменения функциональные применять для новой версии исходников element x в случаи их обновления

## Правила совместной работы

**ВАЖНО: Перед изменением общих зон — записывайся в sync/WORKLOG.md**

### Общие зоны (требуют записи в WORKLOG):
- `backend/recording-api/` — API записи звонков
- `backend/apps-api/` — API приложений
- `backend/api-docs/` — Swagger документация
- K8s namespaces: matrix, livekit
- nginx configs, SSL/DNS

### Процесс:
1. `git pull` — проверить кто что делает
2. Записать себя в `sync/WORKLOG.md`
3. `git commit -m "[SYNC] занял: <зона> — @ios-dev"`
4. Работать
5. `git commit -m "[SYNC] готово: <зона> — @ios-dev"`

### Свободные зоны (без записи):
- iOS: `ios/ElementX/` — весь iOS код
- Web: `web/src/` — весь Web код

Подробнее: `sync/SYNC-RULES.md`

## Git репозиторий

Форк проекта: https://github.com/ank1n/element-x-ios

При выполнении минорных и мажорных изменений — пушить в репозиторий:
```bash
cd /Users/ankin/Documents/element-x-fork/ios
git add -A
git commit --no-verify -m "описание изменений"
git push origin develop
```

Remotes:
- origin: https://github.com/ank1n/element-x-ios.git (форк)
- upstream: https://github.com/element-hq/element-x-ios.git (оригинал)

## Ежедневное обновление документации (Pages)

**При каждом запуске сессии** проверяй актуальность Pages проекта sTalk Mobile (STMOB).

### Алгоритм:
1. Получить список Pages проекта: `GET /api/v1/workspaces/implica/projects/a0b9904b-b856-422f-9540-3b975e54f42e/pages/`
2. Для каждой страницы проверить `updated_at`
3. Если (сейчас - updated_at) > 24 часов И были релевантные изменения → обновить
4. Обновить: `PATCH /api/v1/workspaces/implica/projects/{id}/pages/{page_id}/`

### Какие страницы проверять:
| Страница | Обновлять когда |
|----------|----------------|
| Статистика проекта | Новые задачи/коммиты |
| Среды (Production & Dev) | Менялась инфра |
| Архитектура | Менялась архитектура |
| Код | Менялся код |
| Документация | Менялись API |

### ВАЖНО:
- Pages API работает **только через session cookie**, не через API key
- Pages API доступен только **изнутри K8s кластера** (OAuth2 Proxy блокирует внешние запросы)
- Не обновлять если нет реальных изменений (не менять ради даты)
- Не трогать страницы других ботов/проектов
- Подробнее: `docs/BOT_DEVELOPER_GUIDE.md` раздел 10

## Память сессий (iOS)

### Последняя успешная сборка
- **Коммит**: `713dc67c` — `feat(Recording): fix room name from JWT + remote recording indicator + remove chat message`
- **Дата**: 2026-02-16 ~02:30 MSK
- **Что работает**: видео (LiveKit native + симулятор BufferCapturer), звук, звонки, hangup, MatrixRTC cleanup, история звонков, запись с iOS (JWT room name fix), индикатор удалённой записи (веб→iOS), без сообщений в чат при записи
- **Симулятор**: iPhone 17 Pro Max (A50D4EE6-BCA4-4E20-A3CF-A855F9498FAF)
- **Bundle ID**: ru.implica.stalk

### Важные правила сборки
- **ВСЕГДА собирать и тестировать на симуляторе** (НЕ на физическом устройстве)
- **Симулятор**: iPhone 17 Pro Max (A50D4EE6-BCA4-4E20-A3CF-A855F9498FAF) — единственный, других нет
- **Fake video для симулятора**: LiveKit SDK `BufferCapturer` с `CVPixelBuffer` color-cycling (15fps) — файл `LiveKitRoomManager.swift`
- **os_log**: использовать subsystem `ru.implica.stalk` для видимости в `log stream`
- **MXLog**: НЕ виден через `log show` / `log stream`, пишет только в файлы в AppGroup

### Git stash
- `"endCall fixes + os_log + fake camera + iframe credentials"` — содержит:
  - os_log debugging (3 файла)
  - `.callEnded` isEndingCall guard fix
  - `sendCloseDirectlyToWidgetDriver()` метод
  - `stop()` reverted to upstream
  - iframe→parent postMessage relay для LiveKit credentials (НЕ ТЕСТИРОВАНО)
  - `connectNativeLiveKit` вызов из credentials handler

## Plane (TrackIt) — Управление задачами

- **URL**: https://trackit.implica.ru
- **Workspace**: `implica`
- **Проект**: sTalk Mobile (STMOB)
- **Project ID**: `a0b9904b-b856-422f-9540-3b975e54f42e`
- **API Key (Penny)**: `plane_api_c380b83adf714ffa0a4fefa20d7193ae`
- **API Base**: `https://trackit.implica.ru/api/v1`

### States (STMOB):
| State | ID |
|-------|----|
| Backlog | (default) |
| Todo | `e864041b` |
| In Progress | `060f9624` |
| Review | `b2a57531` |
| Done | `39423651` |
| Cancelled | `f3672c81` |

### Создание задачи:
```bash
curl -s -X POST "https://trackit.implica.ru/api/v1/workspaces/implica/projects/a0b9904b-b856-422f-9540-3b975e54f42e/issues/" \
  -H "X-Api-Key: plane_api_c380b83adf714ffa0a4fefa20d7193ae" \
  -H "Content-Type: application/json" \
  -d '{"name": "Title", "description_html": "<p>Description</p>", "state": "e864041b"}'
```

### Связанные задачи:
- **STMOB-47**: Android — Реализация звонков (CallScreen) по образцу iOS
  - ID: `b96b2319-676b-42c6-850f-30a90c63f186`
  - Документация: `docs/ANDROID-CALL-IMPLEMENTATION-GUIDE.md`
  - GitHub issue: https://github.com/ank1n/element-x-android/issues/2
