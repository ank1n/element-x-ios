# Механизм синхронизации функций и API между командами

## 1. Обзор

### Проблема
Три команды (iOS, Web, Backend) разрабатывают один продукт. Нужно обеспечить:
- Единый API контракт
- Одинаковые модели данных
- Согласованный функционал
- Синхронные релизы

### Решение
Централизованный репозиторий спецификаций + автоматическая генерация кода.

---

## 2. Архитектура синхронизации

```
┌─────────────────────────────────────────────────────────────┐
│                    contracts-repo                            │
│  (Центральный репозиторий спецификаций)                     │
├─────────────────────────────────────────────────────────────┤
│  ├── api/                                                   │
│  │   ├── openapi.yaml          # OpenAPI 3.0 спецификация   │
│  │   ├── recording-api.yaml    # Recording API              │
│  │   └── apps-api.yaml         # Apps API                   │
│  ├── models/                                                │
│  │   ├── contact.schema.json   # JSON Schema моделей        │
│  │   ├── call-history.schema.json                           │
│  │   ├── app-item.schema.json                               │
│  │   └── recording.schema.json                              │
│  ├── features/                                              │
│  │   ├── contacts.feature      # Gherkin сценарии           │
│  │   ├── calls.feature                                      │
│  │   ├── apps.feature                                       │
│  │   └── recording.feature                                  │
│  └── docs/                                                  │
│      ├── CHANGELOG.md          # История изменений          │
│      └── MIGRATION.md          # Гайды по миграции          │
└─────────────────────────────────────────────────────────────┘
           │
           │  CI/CD генерация
           ▼
┌──────────┬──────────┬──────────┐
│   iOS    │   Web    │ Backend  │
│ (Swift)  │  (TS)    │ (Node)   │
└──────────┴──────────┴──────────┘
```

---

## 3. OpenAPI спецификация (contracts-repo/api/recording-api.yaml)

```yaml
openapi: 3.0.3
info:
  title: Element X Custom API
  version: 1.0.0
  description: API для кастомизированной версии Element X

servers:
  - url: https://api.{domain}
    variables:
      domain:
        default: market.implica.ru

paths:
  /api/recording/start:
    post:
      operationId: startRecording
      summary: Начать запись звонка
      tags: [Recording]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/StartRecordingRequest'
      responses:
        '200':
          description: Запись начата
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/StartRecordingResponse'
        '400':
          $ref: '#/components/responses/BadRequest'
        '500':
          $ref: '#/components/responses/ServerError'

  /api/recording/stop:
    post:
      operationId: stopRecording
      summary: Остановить запись
      tags: [Recording]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/StopRecordingRequest'
      responses:
        '200':
          description: Запись остановлена
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/StopRecordingResponse'

  /api/recording/status/{egressId}:
    get:
      operationId: getRecordingStatus
      summary: Получить статус записи
      tags: [Recording]
      parameters:
        - name: egressId
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Статус записи
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/RecordingStatusResponse'

  /api/recording/list:
    get:
      operationId: listRecordings
      summary: Список записей
      tags: [Recording]
      parameters:
        - name: roomName
          in: query
          required: false
          schema:
            type: string
      responses:
        '200':
          description: Список записей
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/RecordingListResponse'

components:
  schemas:
    # === Recording Models ===
    StartRecordingRequest:
      type: object
      required: [roomName]
      properties:
        roomName:
          type: string
          description: Matrix room ID или имя комнаты
          example: "!roomId:server.com"
        layout:
          type: string
          enum: [grid-dark, grid-light, speaker]
          default: grid-dark

    StartRecordingResponse:
      type: object
      properties:
        success:
          type: boolean
        egressId:
          type: string
          example: "EG_xxxxx"
        status:
          type: integer
          description: "0=unknown, 1=active, 2=ended"
        roomName:
          type: string
        filepath:
          type: string
        error:
          type: string

    StopRecordingRequest:
      type: object
      required: [egressId]
      properties:
        egressId:
          type: string

    StopRecordingResponse:
      type: object
      properties:
        success:
          type: boolean
        egressId:
          type: string
        status:
          type: integer
        error:
          type: string

    RecordingStatusResponse:
      type: object
      properties:
        success:
          type: boolean
        egress:
          $ref: '#/components/schemas/EgressInfo'
        error:
          type: string

    RecordingListResponse:
      type: object
      properties:
        success:
          type: boolean
        recordings:
          type: array
          items:
            $ref: '#/components/schemas/RecordingInfo'

    EgressInfo:
      type: object
      properties:
        egressId:
          type: string
        roomName:
          type: string
        status:
          type: integer
        startedAt:
          type: string
          format: date-time
        endedAt:
          type: string
          format: date-time
          nullable: true

    RecordingInfo:
      allOf:
        - $ref: '#/components/schemas/EgressInfo'
        - type: object
          properties:
            downloadUrl:
              type: string
              format: uri

    # === Contact Models ===
    ContactItem:
      type: object
      required: [id, displayName, isOnline]
      properties:
        id:
          type: string
          description: Matrix User ID
          example: "@user:server.com"
        displayName:
          type: string
        avatarURL:
          type: string
          format: uri
          nullable: true
        isOnline:
          type: boolean

    # === Call History Models ===
    CallHistoryItem:
      type: object
      required: [id, contactName, contactId, callType, timestamp, isMissed]
      properties:
        id:
          type: string
        contactName:
          type: string
        contactId:
          type: string
        callType:
          $ref: '#/components/schemas/CallType'
        timestamp:
          type: string
          format: date-time
        duration:
          type: integer
          description: Duration in seconds
          nullable: true
        isMissed:
          type: boolean
        recordingURL:
          type: string
          format: uri
          nullable: true

    CallType:
      type: string
      enum: [incoming, outgoing, video]

    # === App Models ===
    AppItem:
      type: object
      required: [id, name, description, icon, url, category]
      properties:
        id:
          type: string
        name:
          type: string
        description:
          type: string
        icon:
          type: string
          description: Icon name (SF Symbols / Material Icons)
        url:
          type: string
          format: uri
        category:
          $ref: '#/components/schemas/AppCategory'

    AppCategory:
      type: string
      enum: [all, productivity, communication, tools, analytics]

  responses:
    BadRequest:
      description: Bad Request
      content:
        application/json:
          schema:
            type: object
            properties:
              success:
                type: boolean
                example: false
              error:
                type: string

    ServerError:
      description: Server Error
      content:
        application/json:
          schema:
            type: object
            properties:
              success:
                type: boolean
                example: false
              error:
                type: string
```

---

## 4. JSON Schema для моделей (contracts-repo/models/)

### contact.schema.json
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://element-x.example.com/schemas/contact.json",
  "title": "ContactItem",
  "type": "object",
  "required": ["id", "displayName", "isOnline"],
  "properties": {
    "id": {
      "type": "string",
      "description": "Matrix User ID",
      "pattern": "^@[a-z0-9._=\\-\\/]+:[a-z0-9.\\-]+$"
    },
    "displayName": {
      "type": "string",
      "minLength": 1
    },
    "avatarURL": {
      "type": ["string", "null"],
      "format": "uri"
    },
    "isOnline": {
      "type": "boolean"
    }
  }
}
```

### recording-state.schema.json
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://element-x.example.com/schemas/recording-state.json",
  "title": "RecordingState",
  "oneOf": [
    {
      "type": "object",
      "properties": { "type": { "const": "idle" } },
      "required": ["type"]
    },
    {
      "type": "object",
      "properties": { "type": { "const": "starting" } },
      "required": ["type"]
    },
    {
      "type": "object",
      "properties": {
        "type": { "const": "recording" },
        "egressId": { "type": "string" }
      },
      "required": ["type", "egressId"]
    },
    {
      "type": "object",
      "properties": { "type": { "const": "stopping" } },
      "required": ["type"]
    },
    {
      "type": "object",
      "properties": {
        "type": { "const": "error" },
        "message": { "type": "string" }
      },
      "required": ["type", "message"]
    }
  ]
}
```

---

## 5. Gherkin сценарии (contracts-repo/features/)

### recording.feature
```gherkin
Feature: Call Recording
  As a user
  I want to record calls
  So that I can review them later

  Background:
    Given I am logged in as "@user:server.com"
    And I am in an active call in room "!room:server.com"

  Scenario: Start recording
    Given recording is not active
    When I tap the recording button
    Then I should see the consent dialog
    When I confirm recording
    Then recording should start
    And I should see the REC indicator
    And all participants should be notified

  Scenario: Stop recording
    Given recording is active with egressId "EG_123"
    When I tap the stop recording button
    Then recording should stop
    And the REC indicator should disappear
    And the recording should be saved to storage

  Scenario: View recording in call history
    Given I have a recorded call with "@contact:server.com"
    When I open the Calls tab
    Then I should see the call in history
    And I should see the recording indicator
    And I should see the play button

  Scenario: Play recording
    Given I am viewing call history
    And there is a call with recording
    When I tap the play button
    Then the recording should start playing
    And the button should show pause icon
```

### contacts.feature
```gherkin
Feature: Contacts
  As a user
  I want to see my contacts
  So that I can quickly start conversations

  Scenario: View contacts list
    Given I have contacts "@alice:server.com" and "@bob:server.com"
    When I open the Contacts tab
    Then I should see "Контакты" as the title
    And I should see Alice and Bob in the list

  Scenario: Filter online contacts
    Given "@alice:server.com" is online
    And "@bob:server.com" is offline
    When I select the "В сети" filter
    Then I should only see Alice

  Scenario: Search contacts
    Given I have contacts "Alice" and "Bob"
    When I search for "Ali"
    Then I should only see Alice
```

---

## 6. Автогенерация кода

### 6.1 CI/CD Pipeline (GitHub Actions)

```yaml
# .github/workflows/generate-clients.yml
name: Generate API Clients

on:
  push:
    branches: [main]
    paths:
      - 'api/**'
      - 'models/**'

jobs:
  generate-swift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Generate Swift models
        run: |
          npx openapi-generator-cli generate \
            -i api/openapi.yaml \
            -g swift5 \
            -o generated/swift \
            --additional-properties=responseAs=AsyncAwait

      - name: Create PR to iOS repo
        uses: peter-evans/create-pull-request@v5
        with:
          token: ${{ secrets.IOS_REPO_TOKEN }}
          repository: org/element-x-ios
          branch: auto/api-update
          title: "Auto: Update API models"
          body: "Generated from contracts-repo"

  generate-typescript:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Generate TypeScript models
        run: |
          npx openapi-generator-cli generate \
            -i api/openapi.yaml \
            -g typescript-fetch \
            -o generated/typescript

      - name: Create PR to Web repo
        uses: peter-evans/create-pull-request@v5
        with:
          token: ${{ secrets.WEB_REPO_TOKEN }}
          repository: org/element-x-web
          branch: auto/api-update
          title: "Auto: Update API models"

  validate-backend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate OpenAPI spec
        run: npx @openapitools/openapi-generator-cli validate -i api/openapi.yaml

      - name: Generate backend types
        run: |
          npx openapi-generator-cli generate \
            -i api/openapi.yaml \
            -g typescript-node \
            -o generated/backend
```

### 6.2 Сгенерированный Swift код

```swift
// Auto-generated from openapi.yaml
// DO NOT EDIT MANUALLY

import Foundation

// MARK: - ContactItem
public struct ContactItem: Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let avatarURL: URL?
    public let isOnline: Bool
}

// MARK: - CallHistoryItem
public struct CallHistoryItem: Codable, Equatable, Identifiable {
    public let id: String
    public let contactName: String
    public let contactId: String
    public let callType: CallType
    public let timestamp: Date
    public let duration: Int?
    public let isMissed: Bool
    public let recordingURL: URL?

    public enum CallType: String, Codable {
        case incoming
        case outgoing
        case video
    }
}

// MARK: - RecordingState
public enum RecordingState: Equatable {
    case idle
    case starting
    case recording(egressId: String)
    case stopping
    case error(message: String)
}

// MARK: - Recording API
public protocol RecordingAPIProtocol {
    func startRecording(roomName: String) async throws -> StartRecordingResponse
    func stopRecording(egressId: String) async throws -> StopRecordingResponse
    func getStatus(egressId: String) async throws -> RecordingStatusResponse
    func listRecordings(roomName: String?) async throws -> RecordingListResponse
}
```

### 6.3 Сгенерированный TypeScript код

```typescript
// Auto-generated from openapi.yaml
// DO NOT EDIT MANUALLY

// MARK: - ContactItem
export interface ContactItem {
  id: string;
  displayName: string;
  avatarURL?: string | null;
  isOnline: boolean;
}

// MARK: - CallHistoryItem
export interface CallHistoryItem {
  id: string;
  contactName: string;
  contactId: string;
  callType: CallType;
  timestamp: string; // ISO 8601
  duration?: number | null;
  isMissed: boolean;
  recordingURL?: string | null;
}

export type CallType = 'incoming' | 'outgoing' | 'video';

// MARK: - RecordingState
export type RecordingState =
  | { type: 'idle' }
  | { type: 'starting' }
  | { type: 'recording'; egressId: string }
  | { type: 'stopping' }
  | { type: 'error'; message: string };

// MARK: - Recording API Client
export class RecordingAPI {
  constructor(private baseURL: string) {}

  async startRecording(roomName: string): Promise<StartRecordingResponse> {
    const response = await fetch(`${this.baseURL}/api/recording/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ roomName }),
    });
    return response.json();
  }

  async stopRecording(egressId: string): Promise<StopRecordingResponse> {
    const response = await fetch(`${this.baseURL}/api/recording/stop`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ egressId }),
    });
    return response.json();
  }

  async getStatus(egressId: string): Promise<RecordingStatusResponse> {
    const response = await fetch(`${this.baseURL}/api/recording/status/${egressId}`);
    return response.json();
  }

  async listRecordings(roomName?: string): Promise<RecordingListResponse> {
    const url = new URL(`${this.baseURL}/api/recording/list`);
    if (roomName) url.searchParams.set('roomName', roomName);
    const response = await fetch(url.toString());
    return response.json();
  }
}
```

---

## 7. Contract Testing

### 7.1 Pact для Consumer-Driven Contracts

```typescript
// iOS/Web тестируют свои ожидания от API
// pact/recording.pact.spec.ts

import { PactV3, MatchersV3 } from '@pact-foundation/pact';

const provider = new PactV3({
  consumer: 'ElementX-Web',
  provider: 'RecordingAPI',
});

describe('Recording API Contract', () => {
  it('starts recording', async () => {
    await provider
      .given('room exists')
      .uponReceiving('a request to start recording')
      .withRequest({
        method: 'POST',
        path: '/api/recording/start',
        headers: { 'Content-Type': 'application/json' },
        body: { roomName: '!room:server.com' },
      })
      .willRespondWith({
        status: 200,
        body: {
          success: true,
          egressId: MatchersV3.string('EG_xxxxx'),
          status: 1,
          roomName: '!room:server.com',
        },
      });

    await provider.executeTest(async (mockServer) => {
      const api = new RecordingAPI(mockServer.url);
      const result = await api.startRecording('!room:server.com');
      expect(result.success).toBe(true);
      expect(result.egressId).toBeDefined();
    });
  });
});
```

### 7.2 Backend верификация контрактов

```typescript
// backend/tests/pact.verify.ts
import { Verifier } from '@pact-foundation/pact';

describe('Pact Verification', () => {
  it('validates contracts from all consumers', async () => {
    const verifier = new Verifier({
      providerBaseUrl: 'http://localhost:3000',
      pactUrls: [
        'pacts/elementx-web-recordingapi.json',
        'pacts/elementx-ios-recordingapi.json',
      ],
      stateHandlers: {
        'room exists': async () => {
          // Setup test room
        },
      },
    });

    await verifier.verifyProvider();
  });
});
```

---

## 8. Версионирование

### 8.1 Semantic Versioning для API

```
MAJOR.MINOR.PATCH

MAJOR - breaking changes (удаление полей, изменение типов)
MINOR - новые эндпоинты, новые опциональные поля
PATCH - исправления багов, улучшения документации
```

### 8.2 Changelog (contracts-repo/docs/CHANGELOG.md)

```markdown
# Changelog

## [1.2.0] - 2026-02-01
### Added
- `GET /api/recording/download/:egressId` - прямое скачивание записи
- Поле `fileSize` в `RecordingInfo`

### Changed
- `recordingURL` теперь nullable (было required)

## [1.1.0] - 2026-01-30
### Added
- `GET /api/apps/list` - список приложений
- Модель `AppItem`

## [1.0.0] - 2026-01-25
### Added
- Initial release
- Recording API (start, stop, status, list)
- Models: ContactItem, CallHistoryItem, RecordingState
```

### 8.3 API Versioning в URL (опционально)

```
/api/v1/recording/start
/api/v2/recording/start  # breaking changes
```

---

## 9. Процесс синхронизации

### 9.1 Workflow изменений

```
1. Создать Issue в contracts-repo
   └── Описать изменение API/модели

2. Создать PR с изменениями
   ├── Обновить openapi.yaml
   ├── Обновить JSON Schema
   ├── Обновить Gherkin сценарии
   └── Обновить CHANGELOG.md

3. Review от всех команд
   ├── iOS team ✓
   ├── Web team ✓
   └── Backend team ✓

4. Merge в main
   └── CI автоматически генерирует код

5. Команды получают PR с обновлениями
   ├── iOS: auto/api-update branch
   ├── Web: auto/api-update branch
   └── Backend: валидация + типы

6. Имплементация
   └── Каждая команда реализует изменения

7. E2E тестирование
   └── Contract tests проверяют совместимость
```

### 9.2 Коммуникация

```
Slack channels:
  #api-changes     - уведомления об изменениях
  #api-discussion  - обсуждение новых фич

Weekly sync:
  - API Review Meeting (30 min)
  - Участники: Tech Lead от каждой команды
```

---

## 10. Инструменты

| Инструмент | Назначение |
|------------|------------|
| OpenAPI Generator | Генерация клиентов из спецификации |
| Pact | Contract testing |
| Spectral | Линтинг OpenAPI |
| Redoc / Swagger UI | Документация API |
| JSON Schema | Валидация моделей |
| Cucumber | Запуск Gherkin сценариев |

### Установка

```bash
# OpenAPI Generator
npm install @openapitools/openapi-generator-cli -g

# Pact
npm install @pact-foundation/pact --save-dev

# Spectral (linter)
npm install @stoplight/spectral-cli -g

# Validate spec
spectral lint api/openapi.yaml
```

---

## 11. Структура contracts-repo

```
contracts-repo/
├── api/
│   ├── openapi.yaml           # Главная спецификация
│   ├── components/
│   │   ├── schemas.yaml       # Модели
│   │   ├── parameters.yaml    # Общие параметры
│   │   └── responses.yaml     # Общие ответы
│   └── paths/
│       ├── recording.yaml     # Recording endpoints
│       └── apps.yaml          # Apps endpoints
├── models/
│   ├── contact.schema.json
│   ├── call-history.schema.json
│   ├── app-item.schema.json
│   └── recording.schema.json
├── features/
│   ├── contacts.feature
│   ├── calls.feature
│   ├── apps.feature
│   └── recording.feature
├── generated/                 # Auto-generated (gitignored)
│   ├── swift/
│   ├── typescript/
│   └── backend/
├── docs/
│   ├── CHANGELOG.md
│   ├── MIGRATION.md
│   └── CONTRIBUTING.md
├── .github/
│   └── workflows/
│       └── generate-clients.yml
├── .spectral.yaml             # Linter config
├── package.json
└── README.md
```

---

## 12. Преимущества

| Аспект | Без синхронизации | С синхронизацией |
|--------|-------------------|------------------|
| Модели | Разные в каждом репо | Единый источник истины |
| API changes | Ручное обновление | Автогенерация |
| Баги | Обнаруживаются в runtime | Contract tests |
| Документация | Устаревает | Всегда актуальна |
| Onboarding | Долгий | Быстрый (всё в одном месте) |
