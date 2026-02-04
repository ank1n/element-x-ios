# Recording API

API для управления записью звонков LiveKit с поддержкой метаданных участников.

## Возможности

- Запуск/остановка записи звонков через LiveKit Egress
- Хранение метаданных о записях (участники, Matrix room ID)
- Фильтрация записей по пользователю, комнате, дате
- Потоковое воспроизведение записей из MinIO
- Поддержка Range requests для видео

## API Endpoints

### POST /api/recording/start

Начать запись звонка.

**Request:**
```json
{
  "roomName": "encrypted_livekit_room_name",
  "matrixRoomId": "!abc123:matrix.market.implica.ru",
  "participants": [
    {"userId": "@user1:server", "displayName": "Иван Петров"},
    {"userId": "@user2:server", "displayName": "Мария Сидорова"}
  ],
  "initiatedBy": "@user1:server",
  "layout": "grid-dark"
}
```

**Response:**
```json
{
  "success": true,
  "egressId": "EG_xxxxx",
  "status": 1,
  "roomName": "actual_livekit_room",
  "matrixRoomId": "!abc123:server",
  "participants": [...],
  "filepath": "recordings/room_1706612400.mp4"
}
```

### POST /api/recording/stop

Остановить запись.

**Request:**
```json
{
  "egressId": "EG_xxxxx"
}
```

**Response:**
```json
{
  "success": true,
  "egressId": "EG_xxxxx",
  "status": 2,
  "duration": 86,
  "fileSize": 15209801
}
```

### GET /api/recording/list

Получить список записей с фильтрацией.

**Query Parameters:**
- `matrixRoomId` - фильтр по Matrix room ID
- `userId` - фильтр по участнику (ищет в JSON массиве participants)
- `from` - начальная дата (ISO 8601)
- `to` - конечная дата (ISO 8601)
- `limit` - количество записей (default: 50)
- `offset` - смещение для пагинации (default: 0)

**Response:**
```json
{
  "success": true,
  "recordings": [
    {
      "egressId": "EG_xxx",
      "roomName": "encrypted",
      "matrixRoomId": "!abc:server",
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

### GET /api/recording/status/:egressId

Получить статус конкретной записи.

### GET /api/recording/play/:egressId

Потоковое воспроизведение записи. Поддерживает Range requests.

### GET /health

Health check endpoint.

## Переменные окружения

| Variable | Default | Description |
|----------|---------|-------------|
| PORT | 3001 | Порт сервера |
| DB_PATH | /data/recordings.db | Путь к SQLite базе |
| LIVEKIT_URL | wss://livekit.market.implica.ru | LiveKit WebSocket URL |
| LIVEKIT_API_KEY | devkey | LiveKit API Key |
| LIVEKIT_API_SECRET | - | LiveKit API Secret |
| S3_ENDPOINT | http://minio:9000 | MinIO endpoint |
| S3_ACCESS_KEY | minioadmin | MinIO access key |
| S3_SECRET_KEY | - | MinIO secret key |
| S3_BUCKET | livekit-recordings | Bucket для записей |

## База данных

SQLite база создается автоматически при запуске.

**Таблица recording_metadata:**
```sql
CREATE TABLE recording_metadata (
  egress_id TEXT PRIMARY KEY,
  room_name TEXT NOT NULL,
  matrix_room_id TEXT,
  participants TEXT,  -- JSON array
  initiated_by TEXT,
  filepath TEXT,
  created_at DATETIME,
  ended_at DATETIME,
  duration INTEGER,
  file_size INTEGER
);
```

## Развертывание

### Docker

```bash
docker build -t recording-api .
docker run -p 3001:3001 -v /path/to/data:/data recording-api
```

### Kubernetes

```bash
cd k8s
kubectl apply -k .
```

## Примеры использования

### Curl

```bash
# Начать запись
curl -X POST https://api.market.implica.ru/api/recording/start \
  -H "Content-Type: application/json" \
  -d '{
    "roomName": "test-room",
    "matrixRoomId": "!room:server",
    "participants": [{"userId": "@user:server", "displayName": "User"}],
    "initiatedBy": "@user:server"
  }'

# Получить записи пользователя
curl "https://api.market.implica.ru/api/recording/list?userId=@user:server"

# Получить записи за период
curl "https://api.market.implica.ru/api/recording/list?from=2026-02-01&to=2026-02-03"

# Скачать запись
curl -o recording.mp4 https://api.market.implica.ru/api/recording/play/EG_xxxxx
```

## Совместимость

API поддерживает короткие пути для совместимости с iOS:
- `/start` → `/api/recording/start`
- `/stop` → `/api/recording/stop`
- `/status/:id` → `/api/recording/status/:id`
- `/list` → `/api/recording/list`
- `/play/:id` → `/api/recording/play/:id`

## Изменения

### v2.0.0 (2026-02-03)
- Добавлена SQLite база для метаданных
- Расширен POST /start с поддержкой participants, matrixRoomId, initiatedBy
- Расширен GET /list с фильтрацией и метаданными
- Добавлен duration и fileSize в ответы
- Поддержка Range requests в /play
