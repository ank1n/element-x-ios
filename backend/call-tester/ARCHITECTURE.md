# Архитектура тестирования звонков

## Схема компонентов

```
┌─────────────────────────────────────────────────────────────┐
│                    ЛОКАЛЬНАЯ МАШИНА (macOS)                  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Call Quality Tester (Node.js)                         │ │
│  │  backend/call-tester/test-call-quality.js              │ │
│  │                                                         │ │
│  │  Функции:                                              │ │
│  │  • Создание комнат через LiveKit API                  │ │
│  │  • Генерация токенов для участников                   │ │
│  │  • Запуск участников через lk CLI                     │ │
│  │  • Мониторинг комнаты (статистика)                    │ │
│  │  • Сбор метрик и логирование                          │ │
│  └───────┬──────────────────────────────────┬─────────────┘ │
│          │                                  │                │
│          │ HTTP API                         │ spawn         │
│          │ (создание комнат,                │ процессы      │
│          │  получение статистики)           │                │
│          ▼                                  ▼                │
│  ┌──────────────────┐           ┌────────────────────────┐  │
│  │  LiveKit Server  │           │  lk CLI процессы       │  │
│  │  localhost:7880  │◄──────────│  (участники)           │  │
│  │                  │  WebRTC   │                        │  │
│  │  Роль:           │           │  Participant 1:        │  │
│  │  • SFU сервер    │           │  - WebRTC connect      │  │
│  │  • Routing медиа │           │  - Publish demo video  │  │
│  │  • Room управл.  │           │  - Subscribe to tracks │  │
│  │                  │           │                        │  │
│  │  Порты:          │           │  Participant 2:        │  │
│  │  • 7880 (HTTP)   │           │  - WebRTC connect      │  │
│  │  • 50000-60000   │           │  - Publish demo video  │  │
│  │    (RTC)         │           │  - Subscribe to tracks │  │
│  └──────────────────┘           └────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Последовательность событий при тесте

```
1. Старт теста
   │
   ├─► test-call-quality.js запускается
   │
   ├─► Создание комнаты через LiveKit API
   │   POST http://localhost:7880/twirp/livekit.RoomService/CreateRoom
   │   {
   │     name: "test-quality-1234567890",
   │     emptyTimeout: 60,
   │     maxParticipants: 20
   │   }
   │
   ├─► Генерация JWT токенов для участников
   │   (через livekit-server-sdk)
   │
   ├─► Запуск участника #1
   │   │
   │   └─► spawn("lk", [
   │         "room", "join",
   │         "--url", "ws://localhost:7880",
   │         "--api-key", "devkey",
   │         "--api-secret", "secret",
   │         "--identity", "test-participant-1",
   │         "--publish-demo",
   │         "--auto-subscribe",
   │         "test-quality-1234567890"
   │       ])
   │       │
   │       ├─► WebRTC соединение с LiveKit
   │       ├─► ICE negotiation (STUN/TURN)
   │       ├─► DTLS handshake
   │       ├─► Connected to room
   │       └─► Publish demo video track (simulcast)
   │
   ├─► Запуск участника #2 (через 1 секунду)
   │   │
   │   └─► spawn("lk", [...])
   │       │
   │       ├─► WebRTC соединение с LiveKit
   │       ├─► Connected to room
   │       ├─► Publish demo video track
   │       └─► Subscribe to participant #1 tracks
   │
   ├─► Мониторинг комнаты (каждые 5 секунд)
   │   │
   │   └─► GET ListParticipants API
   │       {
   │         participantCount: 2,
   │         participants: [
   │           { identity: "test-participant-1", tracks: 1 },
   │           { identity: "test-participant-2", tracks: 1 }
   │         ]
   │       }
   │
   ├─► Завершение теста (через 20 секунд)
   │   │
   │   ├─► SIGTERM → participant #1 процесс
   │   ├─► SIGTERM → participant #2 процесс
   │   └─► Disconnect from room
   │
   └─► Генерация отчета
       │
       ├─► Консольный вывод (метрики)
       └─► JSON файл (детальные логи)
```

## Поток данных WebRTC

```
Participant 1                LiveKit Server              Participant 2
    │                             │                            │
    │ ┌─────────────────────┐     │                            │
    │ │ SDP Offer           │────►│                            │
    │ └─────────────────────┘     │                            │
    │                             │ ┌─────────────────────┐    │
    │                             │ │ SDP Answer          │───►│
    │                             │ └─────────────────────┘    │
    │                             │                            │
    │ ┌─────────────────────┐     │                            │
    │ │ ICE Candidates      │────►│                            │
    │ └─────────────────────┘     │ ┌─────────────────────┐    │
    │                             │ │ ICE Candidates      │───►│
    │                             │ └─────────────────────┘    │
    │                             │                            │
    │═══════════════════════════════════════════════════════════│
    │         DTLS Handshake + SRTP Key Exchange               │
    │═══════════════════════════════════════════════════════════│
    │                             │                            │
    │ ┌─────────────────────┐     │                            │
    │ │ RTP Video Stream    │────►│──────────────────────────► │
    │ └─────────────────────┘     │                            │
    │                             │ ┌─────────────────────┐    │
    │ ◄──────────────────────────│ │ RTP Video Stream    │────│
    │                             │ └─────────────────────┘    │
    │                             │                            │
```

## Конфигурация LiveKit Server

Файл: `backend/livekit-config.yaml`

```yaml
port: 7880                    # HTTP/WebSocket API
rtc:
  port_range_start: 50000     # RTC медиа порты
  port_range_end: 60000
  use_external_ip: false      # Локальные IP (127.0.0.1)

keys:
  devkey: secret              # API ключи для аутентификации

logging:
  level: info

room:
  empty_timeout: 300          # Авто-удаление пустых комнат
  auto_create: true           # Авто-создание комнат

turn:
  enabled: false              # TURN не нужен для localhost
```

## Метрики которые собираются

### 1. Connection Metrics
- **Connection Attempts** - количество попыток подключения
- **Successful Connections** - успешные подключения
- **Failed Connections** - неудачные подключения
- **Success Rate** - процент успеха

### 2. Participant Metrics (из lk CLI логов)
- **Connection Time** - время установки соединения
- **ICE State Changes** - изменения ICE состояния
  - `Checking` → `Connected`
- **Peer Connection State** - состояние peer connection
  - `connecting` → `connected`
- **Track Events**
  - Published tracks (video/audio)
  - Subscribed tracks
- **Errors/Warnings** - любые проблемы

### 3. Room Statistics (из LiveKit API)
- **Participant Count** - количество участников в комнате
- **Active Tracks** - количество активных медиа-треков
- **Track Types** - типы треков (video/audio)

### 4. Timeline Events
- Timestamp каждого события
- Тип события (INFO, SUCCESS, ERROR, WARNING, METRIC)
- Детали события

## Примеры использования

### 1. Базовый тест (проверка работоспособности)
```bash
node test-call-quality.js
# 2 участника, 20 секунд
```

### 2. Стресс-тест (много участников)
```bash
PARTICIPANTS=10 TEST_DURATION=60 node test-call-quality.js
# 10 участников, 60 секунд
# Проверка как LiveKit справляется с нагрузкой
```

### 3. Тест стабильности (долгий звонок)
```bash
PARTICIPANTS=3 TEST_DURATION=600 node test-call-quality.js
# 3 участника, 10 минут
# Проверка стабильности долгих соединений
```

### 4. Тест переподключений
```bash
# Запустить тест, во время работы:
# 1. Убить процесс участника
# 2. Наблюдать как LiveKit обрабатывает disconnect
# 3. Проверить метрики в отчете
```

## Анализ результатов

### Success Rate = 100%
✅ Все хорошо, LiveKit работает стабильно

### Success Rate < 100%
⚠️ Проблемы с подключением:
- Проверить firewall
- Проверить порты (50000-60000)
- Проверить логи LiveKit
- Проверить детальные логи в JSON

### Errors в логах участников
- `Failed to ping` - проблемы с ICE
- `Connection timeout` - сетевые проблемы
- `DTLS handshake failed` - проблемы с шифрованием

## Логи

### Консольный вывод
Видишь в реальном времени:
- Создание комнаты
- Подключение участников
- Публикация треков
- Статистику каждые 5 секунд
- Финальный отчет

### JSON файлы
`backend/call-tester/logs/test-{room}-{timestamp}.json`

Содержит:
- Полные логи stdout/stderr от каждого участника
- Timeline всех событий
- Детальные метрики
- PID процессов
- Время старта/стопа каждого участника

## Дальнейшие улучшения

1. **Метрики качества**
   - Парсить статистику WebRTC (jitter, packet loss, bitrate)
   - Требует доступ к pion stats API

2. **Автоматические сценарии**
   - Тест с отключением участников
   - Тест с сетевыми задержками (tc netem)
   - Тест с ограничением bandwidth

3. **Интеграция с recording-api**
   - Запись тестовых звонков
   - Проверка качества записи

4. **Dashboard**
   - Веб-интерфейс для просмотра метрик
   - Графики в реальном времени
   - История тестов
