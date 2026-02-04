# Recording API v2 — Инструкция для iOS

**Дата:** 04.02.2026
**Статус:** Задеплоен на production
**URL:** `https://livekit.market.implica.ru/recording-api`

---

## Что изменилось

Recording API теперь поддерживает **метаданные участников**. Это позволяет показывать имена участников в истории звонков вместо зашифрованного `roomName`.

---

## Изменения в POST /start

### Было (v1)
```json
{
  "roomName": "NXGOiUAU8n..."
}
```

### Стало (v2) — добавьте эти поля
```json
{
  "roomName": "NXGOiUAU8n...",
  "matrixRoomId": "!abc123:matrix.market.implica.ru",
  "participants": [
    {"userId": "@user1:market.implica.ru", "displayName": "Иван Петров"},
    {"userId": "@user2:market.implica.ru", "displayName": "Мария Сидорова"}
  ],
  "initiatedBy": "@user1:market.implica.ru"
}
```

**Все новые поля опциональны** — старый код продолжит работать.

---

## Изменения в GET /list

### Response теперь содержит
```json
{
  "success": true,
  "recordings": [
    {
      "egressId": "EG_xxx",
      "roomName": "NXGOiUAU8n...",
      "matrixRoomId": "!abc123:server",
      "participants": [
        {"userId": "@ivan:server", "displayName": "Иван Петров"},
        {"userId": "@maria:server", "displayName": "Мария Сидорова"}
      ],
      "initiatedBy": "@ivan:server",
      "status": 3,
      "startedAt": "2026-02-02T14:50:07.188Z",
      "endedAt": "2026-02-02T14:51:33.984Z",
      "duration": 86,
      "fileSize": 15209801
    }
  ],
  "total": 42,
  "limit": 50,
  "offset": 0
}
```

### Новые поля в ответе
| Поле | Тип | Описание |
|------|-----|----------|
| `matrixRoomId` | string? | Matrix room ID |
| `participants` | array? | Массив участников с userId и displayName |
| `initiatedBy` | string? | Кто начал запись |
| `duration` | int? | Длительность в секундах |
| `fileSize` | int? | Размер файла в байтах |
| `total` | int | Общее количество записей (для пагинации) |

---

## Новая фильтрация

```
GET /api/recording/list?userId=@ivan:server
GET /api/recording/list?matrixRoomId=!room:server
GET /api/recording/list?from=2026-02-01&to=2026-02-03
GET /api/recording/list?limit=20&offset=40
```

---

## Что нужно сделать в iOS

### 1. Обновить `RecordingService.swift`

При вызове `/start` добавить метаданные:

```swift
struct RecordingStartRequest: Encodable {
    let roomName: String
    let matrixRoomId: String?      // NEW
    let participants: [Participant]? // NEW
    let initiatedBy: String?        // NEW

    struct Participant: Encodable {
        let userId: String
        let displayName: String
    }
}

func startRecording(
    roomName: String,
    matrixRoomId: String,
    participants: [(userId: String, displayName: String)],
    initiatedBy: String
) async throws -> String {
    let request = RecordingStartRequest(
        roomName: roomName,
        matrixRoomId: matrixRoomId,
        participants: participants.map {
            .init(userId: $0.userId, displayName: $0.displayName)
        },
        initiatedBy: initiatedBy
    )
    // ... rest of the code
}
```

### 2. Обновить модель `RecordingInfo`

```swift
struct RecordingInfo: Decodable {
    let egressId: String
    let roomName: String
    let matrixRoomId: String?       // NEW
    let participants: [Participant]? // NEW
    let initiatedBy: String?         // NEW
    let status: Int
    let startedAt: Date?
    let endedAt: Date?
    let duration: Int?               // NEW
    let fileSize: Int?               // NEW

    struct Participant: Decodable {
        let userId: String
        let displayName: String
    }
}
```

### 3. Обновить UI истории звонков

Вместо `roomName` показывать имена из `participants`:

```swift
// Было
Text(recording.roomName)

// Стало
if let participants = recording.participants, !participants.isEmpty {
    Text(participants.map { $0.displayName }.joined(separator: ", "))
} else {
    Text("Звонок") // fallback для старых записей
}
```

---

## Тестирование

```bash
# Проверить что API работает
curl https://livekit.market.implica.ru/recording-api/api/recording/list

# Начать запись с метаданными
curl -X POST https://livekit.market.implica.ru/recording-api/api/recording/start \
  -H "Content-Type: application/json" \
  -d '{
    "roomName": "test",
    "matrixRoomId": "!test:server",
    "participants": [{"userId": "@test:server", "displayName": "Test User"}],
    "initiatedBy": "@test:server"
  }'
```

---

## Вопросы?

Документация: `backend/recording-api/README.md`
WORKLOG: `sync/WORKLOG.md`
