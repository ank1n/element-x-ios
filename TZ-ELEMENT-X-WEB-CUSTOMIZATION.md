# Техническое задание: Кастомизация Element X Web

**Версия:** 1.1
**Дата:** 03 февраля 2026
**Основано на:** iOS реализации Element X Fork
**Обновлено:** Добавлены критические задачи по Recording API

---

## 1. Обзор

### 1.1 Цель
Реализовать кастомную версию Element X Web с расширенным функционалом: новая структура навигации с 4 вкладками, встраиваемые приложения, история звонков с записями.

### 1.2 Ключевые изменения
- **Новая навигация**: 4 вкладки вместо стандартной структуры
- **Контакты**: отдельная вкладка со списком контактов
- **Звонки**: история звонков с воспроизведением записей
- **Приложения**: каталог встраиваемых веб-приложений (виджетов)
- **Запись звонков**: интеграция с LiveKit Egress API

---

## 🔴 КРИТИЧНО: Доработка Recording API

### Проблема
iOS приложение уже использует Recording API, но **не может показать имена участников** звонков.
`roomName` в API зашифрован LiveKit и не содержит информации о пользователях.

### Текущий ответ API
```json
{
  "recordings": [
    {"egressId": "EG_xxx", "roomName": "NXGOiUAU8n...", "status": 3}
  ]
}
```

### Требуемые изменения

#### 1. Расширить POST /api/recording/start

Добавить параметры (опциональные для совместимости):
```json
{
  "roomName": "encrypted_livekit_room_name",
  "matrixRoomId": "!abc123:matrix.market.implica.ru",
  "participants": [
    {"userId": "@user1:server", "displayName": "Иван Петров"},
    {"userId": "@user2:server", "displayName": "Мария Сидорова"}
  ],
  "initiatedBy": "@user1:server"
}
```

#### 2. Добавить базу данных для метаданных

```sql
CREATE TABLE recording_metadata (
  egress_id TEXT PRIMARY KEY,
  room_name TEXT NOT NULL,
  matrix_room_id TEXT,
  participants TEXT,  -- JSON array
  initiated_by TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### 3. Расширить GET /api/recording/list

```json
{
  "recordings": [
    {
      "egressId": "EG_xxx",
      "roomName": "encrypted",
      "matrixRoomId": "!abc:server",
      "participants": [
        {"userId": "@ivan:server", "displayName": "Иван Петров"},
        {"userId": "@maria:server", "displayName": "Мария Сидорова"}
      ],
      "status": 3,
      "startedAt": "2026-02-02T14:50:07.188Z",
      "endedAt": "2026-02-02T14:51:33.984Z",
      "duration": 86,
      "fileSize": 15209801
    }
  ]
}
```

#### 4. Добавить фильтрацию

- `?userId=@user:server` - записи где участвовал пользователь
- `?matrixRoomId=!room:server` - записи из конкретной комнаты
- `?from=2026-02-01&to=2026-02-03` - по дате

### Код Recording API

**Путь:** `backend/recording-api/index.js`
**URL:** https://livekit.market.implica.ru/recording-api

---

## 2. Структура навигации

### 2.1 Главный TabBar

```
┌─────────┬─────────┬─────────┬─────────┐
│Контакты │ Звонки  │  Чаты   │Приложен.│
│  👥     │   📞    │   💬    │   📱    │
└─────────┴─────────┴─────────┴─────────┘
```

### 2.2 Иерархия экранов

```
Element X Web
├── Контакты (ContactsTab)
│   ├── Список контактов
│   │   ├── Поиск
│   │   ├── Фильтры (Все / В сети / Избранные)
│   │   └── Карточки контактов
│   └── → Открытие чата с контактом
│
├── Звонки (CallsTab)
│   ├── История звонков
│   │   ├── Поиск
│   │   ├── Фильтры (Все / Пропущенные / Входящие / Исходящие)
│   │   ├── Карточки звонков
│   │   └── Кнопка воспроизведения записи
│   └── → Начать звонок / Прослушать запись
│
├── Чаты (ChatsTab) — существующий функционал
│   └── Список комнат и чатов
│
└── Приложения (AppsTab)
    ├── Каталог приложений
    │   ├── Поиск
    │   ├── Категории (Все / Продуктивность / Связь / Инструменты)
    │   └── Карточки приложений
    └── Экран приложения (iframe)
```

---

## 3. Модели данных

### 3.1 ContactItem (Контакт)

```typescript
interface ContactItem {
  id: string;              // Matrix User ID (@user:server.com)
  displayName: string;     // Отображаемое имя
  avatarURL?: string;      // URL аватара (mxc://)
  isOnline: boolean;       // Статус присутствия
}
```

### 3.2 CallHistoryItem (Запись в истории звонков)

```typescript
interface CallHistoryItem {
  id: string;
  contactName: string;
  contactId: string;       // Matrix User ID
  callType: CallType;
  timestamp: Date;
  duration?: number;       // Длительность в секундах
  isMissed: boolean;
  recordingURL?: string;   // URL записи (если есть)
}

enum CallType {
  INCOMING = "incoming",
  OUTGOING = "outgoing",
  VIDEO = "video"
}
```

### 3.3 AppItem (Приложение/Виджет)

```typescript
interface AppItem {
  id: string;
  name: string;
  description: string;
  icon: string;            // Имя иконки (Material Icons)
  url: string;             // URL приложения
  category: AppCategory;
}

enum AppCategory {
  ALL = "all",
  PRODUCTIVITY = "productivity",
  COMMUNICATION = "communication",
  TOOLS = "tools"
}
```

### 3.4 RecordingState (Состояние записи звонка)

```typescript
type RecordingState =
  | { type: "idle" }
  | { type: "starting" }
  | { type: "recording"; egressId: string }
  | { type: "stopping" }
  | { type: "error"; message: string };
```

---

## 4. Компоненты UI

### 4.1 Общие компоненты

#### FilterChipView (Чип фильтра)
```typescript
interface FilterChipProps {
  title: string;
  isSelected: boolean;
  onClick: () => void;
}
```

**Стили:**
- Выбран: белый текст, основной цвет фона
- Не выбран: основной текст, серый фон
- Скругление: 16px
- Padding: 6px 12px

#### LoadingSkeletonCell (Скелетон загрузки)
- Анимация shimmer
- Серые плейсхолдеры для аватара и текста

#### EmptyStateView (Пустое состояние)
- Иконка (64px)
- Заголовок
- Описание
- Центрирование по вертикали

---

### 4.2 Вкладка "Контакты"

#### ContactsListScreen

**Структура:**
```
┌─────────────────────────────────────┐
│ [Avatar]  Контакты              [+] │  ← Toolbar
├─────────────────────────────────────┤
│ 🔍 Поиск контактов                  │  ← SearchBar
├─────────────────────────────────────┤
│ [Все] [В сети] [Избранные]          │  ← Фильтры
├─────────────────────────────────────┤
│ [Ava] Имя Контакта                  │
│       🟢 В сети                     │
├─────────────────────────────────────┤
│ [Ava] Имя Контакта                  │
│       ⚫ Не в сети                   │
└─────────────────────────────────────┘
```

**Фильтры:**
- Все — показать всех
- В сети — только онлайн (isOnline: true)
- Избранные — помеченные контакты (future)

**Действия:**
- Клик на контакт → открыть чат
- Кнопка "+" → добавить контакт (invite)

---

### 4.3 Вкладка "Звонки"

#### CallsListScreen

**Структура:**
```
┌─────────────────────────────────────────┐
│ [Avatar]  Звонки                        │  ← Toolbar
├─────────────────────────────────────────┤
│ 🔍 Поиск                                │  ← SearchBar
├─────────────────────────────────────────┤
│ [Все] [Пропущенные] [Входящие] [Исход.] │  ← Фильтры
├─────────────────────────────────────────┤
│ [Ava] Алексей Петров       1 ч. назад  │
│       ↙ Входящий • 2:05  ~~~    [▶]   │
├─────────────────────────────────────────┤
│ [Ava] Мария Иванова       вчера        │
│       ↗ Исходящий • 5:40  ~~~   [▶]   │
├─────────────────────────────────────────┤
│ [Ava] Дмитрий Сидоров     2 дн. назад  │
│       📹 Пропущенный видеозвонок       │  ← красный цвет
└─────────────────────────────────────────┘
```

**Иконки типов звонков:**
- `↙` (phone.arrow.down.left) — входящий
- `↗` (phone.arrow.up.right) — исходящий
- `📹` (video) — видеозвонок

**Индикатор записи:**
- `~~~` (waveform) — показывается если есть recordingURL
- `[▶]` — кнопка воспроизведения (только если есть запись)

**Состояния кнопки воспроизведения:**
- Idle: серый фон, иконка play
- Loading: spinner
- Playing: синий фон, иконка pause

**Фильтры:**
- Все — показать все
- Пропущенные — isMissed: true
- Входящие — callType: incoming
- Исходящие — callType: outgoing

---

### 4.4 Вкладка "Приложения"

#### AppsListScreen

**Структура:**
```
┌─────────────────────────────────────┐
│ [Avatar]  Приложения            [+] │  ← Toolbar
├─────────────────────────────────────┤
│ 🔍 Поиск приложений                 │  ← SearchBar
├─────────────────────────────────────┤
│ [Все] [Продуктивность] [Связь] ...  │  ← Категории
├─────────────────────────────────────┤
│ [📊] Статистика                     │
│      Аналитика и отчеты             │
├─────────────────────────────────────┤
│ [📋] Задачи                         │
│      Управление задачами            │
├─────────────────────────────────────┤
│ [🔧] Настройки сервера              │
│      Администрирование              │
└─────────────────────────────────────┘
```

**Карточка приложения:**
- Иконка 52x52 со скругленными углами (12px)
- Цвет иконки — генерируется из названия (hash)
- Название (bodyLGSemibold)
- Описание до 2 строк (bodySM, secondary)

#### AppWebViewScreen

**Структура:**
```
┌─────────────────────────────────────┐
│ ←  Название приложения              │  ← Inline title
├─────────────────────────────────────┤
│                                     │
│         [Loading Spinner]           │
│            Загрузка...              │
│         [━━━━━━━━━━━━━] 75%        │
│                                     │
│    или после загрузки:              │
│                                     │
│         [ iframe content ]          │
│                                     │
└─────────────────────────────────────┘
```

**Параметры iframe:**
```html
<iframe
  src="https://app.example.com"
  sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
  allow="camera; microphone; fullscreen"
  style="width: 100%; height: 100%; border: none;"
/>
```

---

### 4.5 Экран звонка (Call Screen)

#### Кнопка записи

**Расположение:** в toolbar экрана звонка

**Состояния:**
```
┌─────┐
│  ⏺  │  Idle — серый фон, можно начать запись
└─────┘

┌─────┐
│  ◉  │  Starting/Stopping — spinner
└─────┘

┌─────┐
│  ⏹  │  Recording — красный фон + индикатор [🔴 REC]
└─────┘

┌─────┐
│  ⚠  │  Error — оранжевый фон
└─────┘
```

#### Диалог согласия на запись

```
┌─────────────────────────────────────┐
│                                     │
│              ⏺                      │
│                                     │
│       Начать запись?                │
│                                     │
│  Этот звонок будет записан.         │
│  Все участники будут уведомлены.    │
│                                     │
│  ┌─────────────────────────────┐    │
│  │      Начать запись          │    │  ← красная кнопка
│  └─────────────────────────────┘    │
│  ┌─────────────────────────────┐    │
│  │         Отмена              │    │  ← серая кнопка
│  └─────────────────────────────┘    │
│                                     │
└─────────────────────────────────────┘
```

---

## 5. API

### 5.1 Recording API

**Base URL:** `https://api.{domain}/api/recording`

#### POST /start
Начать запись звонка.

```json
// Request
{
  "roomName": "!roomId:server.com"
}

// Response
{
  "success": true,
  "egressId": "EG_xxxxx",
  "status": 1,
  "roomName": "!roomId:server.com",
  "filepath": "recordings/room_1706612400.mp4"
}
```

#### POST /stop
Остановить запись.

```json
// Request
{
  "egressId": "EG_xxxxx"
}

// Response
{
  "success": true,
  "egressId": "EG_xxxxx",
  "status": 2
}
```

#### GET /status/:egressId
Получить статус записи.

```json
// Response
{
  "success": true,
  "egress": {
    "egressId": "EG_xxxxx",
    "roomName": "!roomId:server.com",
    "status": 1,
    "startedAt": "2026-01-30T10:00:00Z",
    "endedAt": null
  }
}
```

#### GET /list
Список записей.

```json
// Query: ?roomName=!roomId:server.com (optional)

// Response
{
  "success": true,
  "recordings": [
    {
      "egressId": "EG_xxxxx",
      "roomName": "!roomId:server.com",
      "status": 2,
      "startedAt": "2026-01-30T10:00:00Z",
      "endedAt": "2026-01-30T10:30:00Z",
      "downloadUrl": "https://storage.../recording.mp4"
    }
  ]
}
```

### 5.2 Apps API (опционально)

Если список приложений хранится на сервере:

#### GET /api/apps/list

```json
// Response
{
  "success": true,
  "apps": [
    {
      "id": "stats",
      "name": "Статистика",
      "description": "Аналитика и отчеты",
      "icon": "chart-bar",
      "url": "https://stats.example.com",
      "category": "analytics"
    }
  ]
}
```

---

## 6. Сервисы

### 6.1 ContactsService

```typescript
class ContactsService {
  // Получить список контактов из Matrix (direct rooms)
  async getContacts(): Promise<ContactItem[]>;

  // Получить статус присутствия
  async getPresence(userId: string): Promise<boolean>;

  // Подписка на изменения присутствия
  subscribeToPresence(callback: (userId: string, isOnline: boolean) => void): void;
}
```

### 6.2 CallHistoryService

```typescript
class CallHistoryService {
  // Получить историю звонков
  async getCallHistory(): Promise<CallHistoryItem[]>;

  // Получить записи для комнаты
  async getRecordingsForRoom(roomId: string): Promise<RecordingInfo[]>;
}
```

### 6.3 RecordingService

```typescript
class RecordingService {
  private state: RecordingState = { type: "idle" };

  // Observable состояния
  get state$(): Observable<RecordingState>;

  // Начать запись
  async startRecording(roomName: string): Promise<string>;

  // Остановить запись
  async stopRecording(): Promise<void>;

  // Получить статус
  async getStatus(egressId: string): Promise<EgressInfo>;
}
```

### 6.4 AppsService

```typescript
class AppsService {
  // Получить список приложений (из конфига или API)
  async getApps(): Promise<AppItem[]>;

  // Фильтрация по категории
  async getAppsByCategory(category: AppCategory): Promise<AppItem[]>;
}
```

---

## 7. Конфигурация

### 7.1 Настройки приложения

```typescript
interface AppConfig {
  // API URLs
  recordingApiBaseURL: string;  // https://api.example.com
  appsApiBaseURL?: string;      // опционально

  // Feature flags
  enableContactsTab: boolean;   // true
  enableCallsTab: boolean;      // true
  enableAppsTab: boolean;       // true
  enableCallRecording: boolean; // true

  // Список приложений (если не через API)
  apps?: AppItem[];
}
```

### 7.2 Пример конфигурации

```json
{
  "recordingApiBaseURL": "https://api.market.implica.ru",
  "enableContactsTab": true,
  "enableCallsTab": true,
  "enableAppsTab": true,
  "enableCallRecording": true,
  "apps": [
    {
      "id": "stats",
      "name": "Статистика",
      "description": "Аналитика звонков и сообщений",
      "icon": "chart-bar",
      "url": "https://stats.market.implica.ru",
      "category": "analytics"
    },
    {
      "id": "tasks",
      "name": "Задачи",
      "description": "Управление задачами команды",
      "icon": "clipboard-list",
      "url": "https://tasks.market.implica.ru",
      "category": "productivity"
    }
  ]
}
```

### 7.3 Matrix Well-Known (опционально)

```json
// .well-known/matrix/client
{
  "m.homeserver": {
    "base_url": "https://matrix.example.com"
  },
  "io.element.custom": {
    "recording_api": "https://api.example.com/api/recording",
    "apps_api": "https://api.example.com/api/apps"
  }
}
```

---

## 8. Локализация

```json
{
  "tabs.contacts": "Контакты",
  "tabs.calls": "Звонки",
  "tabs.chats": "Чаты",
  "tabs.apps": "Приложения",

  "contacts.title": "Контакты",
  "contacts.search": "Поиск контактов",
  "contacts.filter.all": "Все",
  "contacts.filter.online": "В сети",
  "contacts.filter.favorites": "Избранные",
  "contacts.empty.title": "Нет контактов",
  "contacts.empty.description": "Начните чат с кем-нибудь, чтобы добавить контакт",
  "contacts.status.online": "В сети",
  "contacts.status.offline": "Не в сети",

  "calls.title": "Звонки",
  "calls.search": "Поиск",
  "calls.filter.all": "Все",
  "calls.filter.missed": "Пропущенные",
  "calls.filter.incoming": "Входящие",
  "calls.filter.outgoing": "Исходящие",
  "calls.type.incoming": "Входящий",
  "calls.type.outgoing": "Исходящий",
  "calls.type.video": "Видеозвонок",
  "calls.type.missed": "Пропущенный",
  "calls.empty.title": "Нет звонков",
  "calls.empty.description": "История звонков будет отображаться здесь",

  "apps.title": "Приложения",
  "apps.search": "Поиск приложений",
  "apps.category.all": "Все",
  "apps.category.productivity": "Продуктивность",
  "apps.category.communication": "Связь",
  "apps.category.tools": "Инструменты",
  "apps.empty.title": "Нет приложений",
  "apps.empty.description": "Приложения будут отображаться здесь",
  "apps.loading": "Загрузка...",

  "recording.button.start": "Начать запись",
  "recording.button.stop": "Остановить запись",
  "recording.consent.title": "Начать запись?",
  "recording.consent.message": "Этот звонок будет записан. Все участники будут уведомлены.",
  "recording.consent.confirm": "Начать запись",
  "recording.consent.cancel": "Отмена",
  "recording.indicator": "REC",
  "recording.error": "Ошибка записи"
}
```

---

## 9. Безопасность

### 9.1 Content Security Policy

```
Content-Security-Policy:
  default-src 'self';
  frame-src 'self' https://*.implica.ru;
  connect-src 'self' https://*.implica.ru wss://*.implica.ru;
  media-src 'self' https://*.implica.ru blob:;
```

### 9.2 Sandbox для iframe

```html
<iframe
  sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals"
  allow="camera; microphone; fullscreen; display-capture"
/>
```

### 9.3 Валидация URL приложений

- Whitelist доменов
- Только HTTPS в production
- Запрет data: и javascript: схем

---

## 10. Структура файлов

```
src/
├── components/
│   ├── tabs/
│   │   ├── ContactsTab/
│   │   │   ├── ContactsListScreen.tsx
│   │   │   ├── ContactCard.tsx
│   │   │   └── ContactsFilters.tsx
│   │   ├── CallsTab/
│   │   │   ├── CallsListScreen.tsx
│   │   │   ├── CallHistoryCard.tsx
│   │   │   ├── CallsFilters.tsx
│   │   │   └── RecordingPlayButton.tsx
│   │   ├── ChatsTab/
│   │   │   └── (existing)
│   │   └── AppsTab/
│   │       ├── AppsListScreen.tsx
│   │       ├── AppCard.tsx
│   │       ├── AppsCategories.tsx
│   │       └── AppWebView.tsx
│   ├── call/
│   │   ├── RecordingButton.tsx
│   │   ├── RecordingIndicator.tsx
│   │   └── RecordingConsentDialog.tsx
│   └── common/
│       ├── FilterChip.tsx
│       ├── LoadingSkeleton.tsx
│       ├── EmptyState.tsx
│       └── SearchBar.tsx
├── services/
│   ├── ContactsService.ts
│   ├── CallHistoryService.ts
│   ├── RecordingService.ts
│   └── AppsService.ts
├── models/
│   ├── ContactItem.ts
│   ├── CallHistoryItem.ts
│   ├── AppItem.ts
│   └── RecordingState.ts
├── stores/
│   ├── contactsStore.ts
│   ├── callsStore.ts
│   ├── recordingStore.ts
│   └── appsStore.ts
└── config/
    └── appConfig.ts
```

---

## 11. Reference: iOS реализация

| Функционал | iOS файлы |
|------------|-----------|
| Контакты | `ContactsListScreen.swift`, `ContactsListScreenModels.swift`, `ContactsListScreenViewModel.swift` |
| Звонки | `CallsListScreen.swift`, `CallsListScreenModels.swift`, `CallsListScreenViewModel.swift` |
| Приложения | `WidgetsListScreen.swift`, `WidgetsListScreenModels.swift`, `WidgetWebViewScreen.swift` |
| Запись | `RecordingService.swift`, `RecordingModels.swift`, `RecordingButton.swift` |
| Координаторы | `ContactsTabFlowCoordinator.swift`, `CallsTabFlowCoordinator.swift`, `WidgetsTabFlowCoordinator.swift` |
| TabBar | `UserSessionFlowCoordinator.swift` (HomeTab enum) |

---

## 12. План реализации

### 🔴 Приоритет: Критические задачи (блокируют iOS)

| Задача | Оценка | Статус |
|--------|--------|--------|
| Recording API: метаданные участников | 1-2 дня | ✅ готово |
| Recording API: расширить GET /list | 0.5 дня | ✅ готово |
| Recording API: фильтрация | 0.5 дня | ✅ готово |
| WebRTC: устранить хрипы (audio RED/FEC) | 0.5 дня | ✅ готово |
| WebRTC: simulcast для видео | 0.5 дня | ✅ готово |
| **Итого критичное** | **3-4 дня** | |

> 📄 **Детали WebRTC оптимизации:** см. `TZ-WEBRTC-QUALITY-OPTIMIZATION.md`

### 🟡 Приоритет: Веб-интерфейс

| Задача | Оценка | Статус |
|--------|--------|--------|
| 4-tab навигация | 1 день | 🔄 частично (2 кнопки) |
| Вкладка Контакты | 2 дня | ⏳ |
| Вкладка Звонки + плеер | 2-3 дня | ⏳ |
| Вкладка Приложения | 2 дня | ⏳ |
| **Итого веб** | **7-8 дней** | |

### Фаза 0: Recording API (КРИТИЧНО) ✅
- [x] Добавить SQLite для метаданных
- [x] Расширить POST /api/recording/start
- [x] Расширить GET /api/recording/list
- [x] Добавить фильтрацию
- [ ] Тестирование с iOS

### Фаза 1: Структура навигации
- [ ] Создать 4-tab layout
- [ ] Базовые экраны для каждой вкладки
- [ ] Общие компоненты (FilterChip, EmptyState, SearchBar)

### Фаза 2: Контакты
- [ ] ContactsService (интеграция с Matrix SDK)
- [ ] ContactsListScreen
- [ ] Фильтрация и поиск
- [ ] Статус присутствия

### Фаза 3: Звонки
- [ ] CallHistoryService
- [ ] CallsListScreen
- [ ] Интеграция с Recording API
- [ ] Плеер для воспроизведения записей

### Фаза 4: Приложения
- [ ] AppsService
- [ ] AppsListScreen
- [ ] AppWebView (iframe контейнер)
- [ ] Категоризация и поиск

### Фаза 5: Запись звонков
- [ ] RecordingService
- [ ] RecordingButton на экране звонка
- [ ] Диалог согласия
- [ ] Индикатор записи

### Фаза 6: Тестирование и деплой
- [ ] Unit тесты
- [ ] Integration тесты
- [ ] E2E тесты
- [ ] Документация
- [ ] Деплой

---

## 13. Зависимости

### Backend
- LiveKit Server с Egress
- Recording API (Node.js)
- S3-совместимое хранилище (MinIO)
- Matrix Synapse

### Frontend
- React 18+
- Matrix JS SDK
- Zustand / Redux для state management
- React Query для API calls

---

## Приложение A: Демо данные

### Контакты
```typescript
const demoContacts: ContactItem[] = [
  { id: "@alice:server.com", displayName: "Алиса Иванова", avatarURL: null, isOnline: true },
  { id: "@bob:server.com", displayName: "Борис Петров", avatarURL: null, isOnline: false },
  { id: "@carol:server.com", displayName: "Кристина Сидорова", avatarURL: null, isOnline: true },
];
```

### История звонков
```typescript
const demoCallHistory: CallHistoryItem[] = [
  { id: "1", contactName: "Алексей Петров", contactId: "@alexey:server.com", callType: "incoming", timestamp: new Date(Date.now() - 3600000), duration: 125, isMissed: false, recordingURL: "https://..." },
  { id: "2", contactName: "Мария Иванова", contactId: "@maria:server.com", callType: "outgoing", timestamp: new Date(Date.now() - 7200000), duration: 340, isMissed: false, recordingURL: "https://..." },
  { id: "3", contactName: "Дмитрий Сидоров", contactId: "@dmitry:server.com", callType: "video", timestamp: new Date(Date.now() - 86400000), duration: null, isMissed: true, recordingURL: null },
];
```

### Приложения
```typescript
const demoApps: AppItem[] = [
  { id: "stats", name: "Статистика", description: "Аналитика и отчеты", icon: "chart-bar", url: "https://stats.market.implica.ru", category: "analytics" },
  { id: "tasks", name: "Задачи", description: "Управление задачами", icon: "clipboard-list", url: "https://tasks.market.implica.ru", category: "productivity" },
  { id: "files", name: "Файлы", description: "Файловое хранилище", icon: "folder", url: "https://files.market.implica.ru", category: "tools" },
];
```

---

## Приложение B: Связанные документы

| Документ | Описание | Приоритет |
|----------|----------|-----------|
| `TZ-WEBRTC-QUALITY-OPTIMIZATION.md` | Оптимизация качества звонков (хрипы, лаги) | 🔴 Высокий |
| `IMPLEMENTATION-PLAN.md` | Общий план реализации проекта | Справочник |
| `backend/recording-api/` | Исходный код Recording API | Код |

---

## Приложение C: Контакты и доступы

### Git репозиторий
```
Форк: https://github.com/ank1n/element-x-ios
Backend: backend/recording-api/
```

### API Endpoints
```
Recording API: https://livekit.market.implica.ru/recording-api
LiveKit: wss://livekit.market.implica.ru
Matrix: https://matrix.market.implica.ru
```

### Тестирование
```bash
# Проверить Recording API
curl https://livekit.market.implica.ru/recording-api/api/recording/list

# Скачать запись
curl -o test.mp4 https://livekit.market.implica.ru/recording-api/api/recording/play/EG_y58fKCUEjYY9
```

---

**Дата обновления:** 03.02.2026
**Автор:** @claude + @ankin
