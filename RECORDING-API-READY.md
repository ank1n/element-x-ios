# Recording API - Готово к использованию! ✅

## Статус

- ✅ **Recording API развернут** в namespace `livekit`
- ✅ **Egress** работает и готов к записи
- ✅ **MinIO** настроен для хранения записей
- ✅ **LiveKit CLI** установлен на сервере
- ⏳ **SSL сертификат** генерируется (cert-manager)

## API Endpoints

**Base URL**: `https://api.market.implica.ru` (или `http://recording-api.livekit.svc.cluster.local:3000` внутри кластера)

### 1. Health Check
```bash
GET /health

Response:
{
  "status": "ok"
}
```

### 2. Начать запись
```bash
POST /api/recording/start

Body:
{
  "roomName": "!abc123:market.implica.ru",
  "layout": "grid-dark"  // optional: grid-dark, grid-light, speaker-dark, speaker-light
}

Response:
{
  "success": true,
  "egressId": "EG_abc123xyz",
  "status": "EGRESS_STARTING",
  "roomName": "!abc123:market.implica.ru",
  "startedAt": "1706356800000"
}
```

### 3. Остановить запись
```bash
POST /api/recording/stop

Body:
{
  "egressId": "EG_abc123xyz"
}

Response:
{
  "success": true,
  "egressId": "EG_abc123xyz",
  "status": "EGRESS_COMPLETE",
  "endedAt": "1706357400000"
}
```

### 4. Статус записи
```bash
GET /api/recording/status/{egressId}

Response:
{
  "success": true,
  "egress": {
    "egressId": "EG_abc123xyz",
    "roomName": "!abc123:market.implica.ru",
    "status": "EGRESS_ACTIVE",
    "startedAt": "1706356800000",
    "endedAt": null,
    "error": null
  }
}
```

### 5. Список всех записей
```bash
GET /api/recording/list

Response:
{
  "success": true,
  "recordings": [
    {
      "egressId": "EG_abc123xyz",
      "roomName": "!abc123:market.implica.ru",
      "status": "EGRESS_ACTIVE",
      "startedAt": "1706356800000",
      "endedAt": null
    }
  ]
}
```

## Layouts (Композиции)

| Layout | Описание |
|--------|----------|
| `grid-dark` | Сетка участников (темная тема) |
| `grid-light` | Сетка участников (светлая тема) |
| `speaker-dark` | Активный спикер (темная тема) |
| `speaker-light` | Активный спикер (светлая тема) |

## Тестирование через CLI

### На сервере
```bash
ssh root@ozzy.implica.ru

# Список активных комнат
/root/room-recording.sh list

# Начать запись (auto-detect room)
/root/room-recording.sh start

# Начать запись конкретной комнаты
/root/room-recording.sh start "!abc123:market.implica.ru" grid-dark

# Остановить запись
/root/room-recording.sh stop

# Посмотреть записи
/root/room-recording.sh download
```

### Через API (curl)
```bash
# Start recording
curl -X POST https://api.market.implica.ru/api/recording/start \
  -H "Content-Type: application/json" \
  -d '{"roomName": "!test:market.implica.ru", "layout": "grid-dark"}'

# Stop recording
curl -X POST https://api.market.implica.ru/api/recording/stop \
  -H "Content-Type: application/json" \
  -d '{"egressId": "EG_xxxxx"}'

# List recordings
curl https://api.market.implica.ru/api/recording/list
```

## Доступ к записям

Записи сохраняются в MinIO:
- **Bucket**: `livekit-recordings`
- **Путь**: `recordings/{room_name}_{timestamp}.mp4`

### Скачать запись с сервера:
```bash
# Список файлов
kubectl exec -n minio deploy/minio -- ls -la /data/livekit-recordings/recordings/

# Скачать файл
kubectl cp minio/POD_NAME:/data/livekit-recordings/recordings/FILE.mp4 ./recording.mp4
```

## Интеграция в iOS приложение

### RecordingService.swift
```swift
class RecordingService {
    private let baseURL = "https://api.market.implica.ru"

    func startRecording(roomName: String) async throws -> String {
        let request = RecordingStartRequest(roomName: roomName)
        let response: RecordingStartResponse = try await post("\(baseURL)/api/recording/start", body: request)
        return response.egressId
    }

    func stopRecording(egressId: String) async throws {
        try await post("\(baseURL)/api/recording/stop", body: RecordingStopRequest(egressId: egressId))
    }
}
```

## Мониторинг

### Проверка статуса
```bash
# Pod status
kubectl get pods -n livekit -l app=recording-api

# Logs
kubectl logs -n livekit -l app=recording-api -f

# Events
kubectl get events -n livekit --sort-by='.lastTimestamp'
```

### Метрики Egress
```bash
# Активные egress
kubectl exec -n livekit svc/recording-api -- wget -q -O- http://localhost:3000/api/recording/list

# LiveKit CLI
export LIVEKIT_URL="wss://livekit.market.implica.ru"
export LIVEKIT_API_KEY="devkey"
export LIVEKIT_API_SECRET="secret123456789012345678901234567890"

lk egress list
lk room list
```

## Troubleshooting

### Проблема: Pod в CrashLoopBackOff
```bash
kubectl logs -n livekit -l app=recording-api --tail=50
kubectl describe pod -n livekit -l app=recording-api
```

### Проблема: Запись не начинается
```bash
# Проверить что комната активна
lk room list

# Проверить egress logs
kubectl logs -n livekit -l app=egress --tail=50

# Проверить MinIO доступ
kubectl exec -n livekit deploy/recording-api -- wget -q -O- http://minio.minio.svc.cluster.local:9000
```

### Проблема: SSL сертификат не работает
```bash
# Проверить cert-manager
kubectl get certificate -n livekit

# Проверить ingress
kubectl describe ingress recording-api-ingress -n livekit

# Вручную создать сертификат
kubectl get secret recording-api-tls -n livekit
```

## Следующие шаги

1. ✅ Recording API готов
2. ⬜ Реализовать RecordingService в iOS
3. ⬜ Добавить кнопку записи в Call Screen
4. ⬜ Добавить consent диалог
5. ⬜ Тестирование записи звонка

---

**Дата**: 2026-01-27
**Статус**: ✅ Ready for iOS integration
