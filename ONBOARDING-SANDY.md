# Onboarding: Sandy — Android Developer

**Добро пожаловать в команду sTalk Mobile!** 👋

Ты будешь разрабатывать Android клиент sTalk на базе Element X Android.

---

## 🎯 Твоя задача

**Проект**: sTalk Mobile Android (форк Element X Android)
**Tracker**: Plane @ https://trackit.implica.ru
**Проект в Plane**: STAND (sTalk Android)
**Project ID**: `e1f00989-ffd2-4c87-a1fb-05bea83e4d16`

**Цель**: Реализовать 24 функции Element X iOS в Android версии + кастомный Telegram-style UI.

**ТЗ**: `/TZ-SANDY-ANDROID.md` (67KB, 2059 строк) — отправлено в #ops чат

---

## 🔑 Доступы

### 1. Plane (Tracker)

**URL**: https://trackit.implica.ru
**Workspace**: `implica`
**Твой проект**: STAND (sTalk Android)

**Credentials** (временные, смени пароль после первого входа):
- **Email**: sandy@implica.ru
- **Password**: `SandyDev2026!`

**Как работать**:
1. Заходи в Plane: https://trackit.implica.ru
2. Workspace: `implica` → Project: `STAND`
3. Задачи разбиты по фазам (Phase 1-4)
4. Бери задачи из **Phase 1** (Core UI) первыми
5. Статусы: Backlog → Todo → In Progress → Done
6. Коммент в задаче при старте/завершении

**API Token** (если нужен для скриптов):
```
plane_api_202c911565d24089b96fdbd06e289780
```

---

### 2. Matrix #ops (Чат команды)

**Обязательно**: Все важные уведомления идут в Matrix чат #ops.

**Room**: `!CwWGwdwgnXGNIzElHm:stalk.implica.ru`
**Server**: https://stalk.implica.ru

**Credentials**:
- **Username**: sandy
- **Password**: `SandyPass2026!`
- **Server**: `stalk.implica.ru`

**Как войти**:
1. Открой Element Web/Mobile/Desktop
2. "Войти" → "Сервер домашней страницы": `stalk.implica.ru`
3. Логин: `sandy` / `SandyPass2026!`
4. Найди комнату #ops

**Правила работы в #ops**:
1. **При старте задачи** → `[Sandy] Task/INFO: Начинаю STAND-XX <url>`
2. **При завершении** → `[Sandy] Done/INFO: Закрыла STAND-XX <url>`
3. **Вопросы** → `[Sandy] Question/INFO: @penny/@tracy описание вопроса`
4. **Проблемы** → `[Sandy] Alert/HIGH: описание проблемы`
5. **Перед сообщением** — прочитай последние 20 сообщений (контекст, не дублируй)

**Формат**: `[Sandy] Type/Level: текст`
- **Type**: Task | Done | Alert | Info | Question
- **Level**: CRIT | HIGH | INFO

---

### 3. Git Repository

**Upstream** (оригинал):
```bash
https://github.com/element-hq/element-x-android.git
```

**Fork** (наш):
```bash
https://github.com/ank1n/element-x-android.git
```

**Клонирование**:
```bash
git clone https://github.com/ank1n/element-x-android.git
cd element-x-android
git remote add upstream https://github.com/element-hq/element-x-android.git
```

**Branch strategy**:
- `main` — стабильная ветка (как upstream/main)
- `develop` — разработка (твоя основная ветка)
- `android/<feature>` — фича-ветки

**Workflow**:
```bash
# Начало работы
git checkout develop
git pull origin develop

# Создай фича-ветку
git checkout -b android/stalk-tab-bar

# Работай, коммить
git add .
git commit -m "[Android] feat: Stalk Tab Bar with Material Icons"

# Push
git push origin android/stalk-tab-bar

# Создай PR: android/stalk-tab-bar → develop
```

---

### 4. Серверы

#### Production сервер
**URL**: https://stalk.implica.ru
**Homeserver**: `stalk.implica.ru`
**Auth**: Keycloak @ https://auth.trackit.implica.ru (realm: `matrix`)

**Тестовый аккаунт**:
- **Username**: ankin
- **Password**: `AnkinPass2026!`

#### SSH доступ к Misty (опционально, если нужен доступ к K8s)
**Host**: 195.58.34.43
**User**: ankin
**Password**: (запроси у @penny если понадобится)

**Зачем**: Прямой доступ к Synapse API, K8s, логам.

---

## 🤝 Правила работы в команде

### SYNC Rules (Общие зоны)

Мы работаем в **моно-репо** (iOS + Android + Backend в одном форке).

**Общие зоны** (требуют записи в `sync/WORKLOG.md`):
- `backend/recording-api/` — API записи звонков
- `backend/apps-api/` — API приложений
- `backend/api-docs/` — Swagger документация
- K8s namespaces: `matrix`, `livekit`
- nginx configs, SSL/DNS

**Твоя свободная зона** (без записи в WORKLOG):
- `android/` — весь Android код
- Работай свободно, не нужно записываться

**Если тебе нужна общая зона**:
1. Открой `sync/WORKLOG.md`
2. Проверь, что зона свободна
3. Добавь строку:
   ```markdown
   | recording-api | GET /recordings | @sandy | 15.02 | в работе |
   ```
4. Коммит:
   ```bash
   git add sync/WORKLOG.md
   git commit -m "[SYNC] занял: backend/recording-api — @sandy"
   git push origin main
   ```
5. Работай
6. Когда готово — обнови статус:
   ```bash
   git add sync/WORKLOG.md
   git commit -m "[SYNC] готово: backend/recording-api — @sandy"
   git push origin main
   ```

**Подробнее**: читай `/sync/SYNC-RULES.md`

---

## 👥 Команда

| Кто | Роль | Ответственность | Упоминание |
|-----|------|-----------------|------------|
| **Penny** | iOS Dev (бот) | iOS клиент, Recording API, координация | `@penny` |
| **Tracy** | Backend Dev (бот) | Backend APIs, K8s, DevOps | `@tracy` |
| **Sandy** | Android Dev (ты!) | Android клиент | `@sandy` |

**Как общаться**:
- **Matrix #ops** — главный канал (обязательно!)
- **Plane комментарии** — вопросы по конкретной задаче
- **Git коммиты** — синхронизация общих зон

---

## 📋 План работы (Phases)

### Phase 1: Core UI (2 недели)
- STAND-2: Stalk Tab Bar (Material Icons)
- STAND-3: Unified Filters (Underline style)
- STAND-4: Green Bubbles (sent messages)
- STAND-5: Inline Titles (Calls, Chats)
- STAND-6: Empty Room List Filter

### Phase 2: Features (3 недели)
- STAND-7: Contact Profiles
- STAND-8: Call History
- STAND-9: Recording API Integration
- STAND-10: Contact → Chat Navigation
- STAND-11: In-Room Search
- ... (см. Plane)

### Phase 3: Apps & API (2 недели)
- Apps API, widgets

### Phase 4: Production (1 неделя)
- Testing, polish, deploy

**Всего**: 8-10 недель

---

## 🛠 Tech Stack

**Базовый стек Element X Android**:
- Kotlin 2.x
- Jetpack Compose
- Matrix Rust SDK (через FFI)
- Coroutines + Flow
- Hilt (DI)
- Coil (images)

**Наши дополнения**:
- Material Design 3 (Material You)
- Ktor Client (Recording API, Apps API)
- ExoPlayer (audio playback)
- Lottie (animations, опционально)

**Не используй**:
- XML layouts (только Compose!)
- RxJava (только Coroutines)
- Gson (используй kotlinx.serialization)

---

## 📚 Ключевые документы

| Документ | Описание |
|----------|----------|
| `TZ-SANDY-ANDROID.md` | Главное ТЗ (2059 строк) |
| `sync/SYNC-RULES.md` | Правила работы с общими зонами |
| `sync/WORKLOG.md` | Журнал занятости зон |
| `CHANGELOG-ELEMENTX.md` | История изменений iOS (для ориентира) |
| `CLAUDE.md` | Правила работы проекта |

---

## ✅ Чеклист первого дня

- [ ] Зарегистрироваться в Plane (https://trackit.implica.ru)
- [ ] Войти в Matrix #ops чат (stalk.implica.ru)
- [ ] Клонировать репозиторий (https://github.com/ank1n/element-x-android.git)
- [ ] Прочитать `TZ-SANDY-ANDROID.md` полностью
- [ ] Прочитать `sync/SYNC-RULES.md`
- [ ] Написать в #ops: `[Sandy] Info/INFO: Привет! Готова к работе над sTalk Android 🚀`
- [ ] Взять первую задачу из Phase 1 (рекомендую STAND-2: Stalk Tab Bar)
- [ ] Написать в #ops: `[Sandy] Task/INFO: Начинаю STAND-2 https://trackit.implica.ru/implica/projects/e1f00989-ffd2-4c87-a1fb-05bea83e4d16/issues/STAND-2`

---

## 🆘 Помощь

**Вопросы по коду**:
- iOS reference: спроси `@penny` в #ops
- Backend API: спроси `@tracy` в #ops
- Plane: https://docs.plane.so

**Срочные проблемы**:
```
[Sandy] Alert/HIGH: <описание проблемы>
```

**Документация**:
- Element X Android: https://github.com/element-hq/element-x-android
- Matrix Rust SDK: https://github.com/matrix-org/matrix-rust-sdk
- Matrix Spec: https://spec.matrix.org/latest/

---

## 🎉 Добро пожаловать в команду!

Мы рады что ты с нами. Penny и Tracy — боты, но мы работаем как обычная команда: коммуникация в #ops, задачи в Plane, код в Git.

**Главное правило**: Всегда пиши в #ops когда начинаешь/заканчиваешь задачу. Так мы все в курсе прогресса.

Удачи! 🚀

---

**Контакт для вопросов**: @penny в Matrix #ops
