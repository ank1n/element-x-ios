# Техническое задание: Оптимизация качества WebRTC звонков

**Версия:** 1.0
**Дата:** 02 февраля 2026
**Для:** Web-разработчик (@web-dev)
**Приоритет:** Высокий

**Важно:** Element X iOS использует Element Call через WebView, поэтому эти оптимизации применяются как для Web версии, так и для iOS автоматически!

---

## 1. Проблема

### 1.1 Текущие симптомы
При тестировании звонков между Element X iOS и Web выявлены проблемы:

- ❌ **Хрипы при старте звонка** — audio crackling в первые секунды
- ❌ **Лаги аудио** — задержки и прерывания во время разговора
- ❌ **Лаги видео при движении** — видео теряет качество при резких движениях камеры

### 1.2 Технические причины
1. **Высокое разрешение видео** (1280x720) без adaptive bitrate
2. **Нет оптимизации audio jitter buffer** — вызывает хрипы и прерывания
3. **Нет simulcast** — видео не адаптируется к условиям сети
4. **Агрессивный audio processing** — echo cancellation может давать артефакты
5. **Медленная ICE negotiation** — долгое установление соединения

---

## 2. Задача

Оптимизировать WebRTC настройки в Element X Web для стабильных звонков без артефактов.

**Критерии успеха:**
- ✅ Нет хрипов при старте звонка
- ✅ Аудио без лагов и прерываний
- ✅ Видео плавное даже при движении
- ✅ Соединение устанавливается < 5 секунд

---

## 3. Технические решения

### 3.1 Оптимизация видео

#### 3.1.1 Снизить начальное разрешение

**Где:** Код инициализации LiveKit Room / создание VideoTrack

**Было:**
```javascript
const videoTrack = await createLocalVideoTrack({
  resolution: VideoPresets.h720  // 1280x720
});
```

**Стало:**
```javascript
const videoTrack = await createLocalVideoTrack({
  resolution: {
    width: 960,
    height: 540,
    frameRate: 24,
    aspectRatio: 16/9
  }
});
```

**Обоснование:** 960x540 (qHD) — оптимальный баланс качества и пропускной способности для мобильных сетей.

#### 3.1.2 Включить Simulcast

**Где:** LiveKit Room options

**Код:**
```javascript
const room = new Room({
  adaptiveStream: true,  // Адаптивная подстройка качества
  dynacast: true,        // Динамическое управление слоями
  videoCaptureDefaults: {
    resolution: VideoPresets.h540,
    facingMode: 'user'
  },
  publishDefaults: {
    simulcast: true,      // 🔑 Ключевая настройка
    videoSimulcastLayers: [
      { width: 960, height: 540, bitrate: 1500000 },  // High
      { width: 480, height: 270, bitrate: 500000 },   // Medium
      { width: 240, height: 135, bitrate: 150000 }    // Low
    ],
    videoCodec: 'VP8'     // VP8 лучше работает с simulcast
  }
});
```

#### 3.1.3 Динамическая адаптация битрейта

**Где:** Обработчик событий качества соединения

**Код:**
```javascript
room.on(RoomEvent.ConnectionQualityChanged, (quality, participant) => {
  if (participant.isLocal) {
    const videoTrack = Array.from(participant.videoTracks.values())[0];

    switch(quality) {
      case ConnectionQuality.Excellent:
        videoTrack?.setVideoQuality(VideoQuality.HIGH);
        break;
      case ConnectionQuality.Good:
        videoTrack?.setVideoQuality(VideoQuality.MEDIUM);
        break;
      case ConnectionQuality.Poor:
        videoTrack?.setVideoQuality(VideoQuality.LOW);
        break;
    }
  }
});
```

---

### 3.2 Оптимизация аудио

#### 3.2.1 Настроить audio constraints

**Где:** Создание audio track

**КРИТИЧНО ДЛЯ УСТРАНЕНИЯ ХРИПОВ!** ⚠️

**Проблема найдена в production логах:**
- `disableRed: true` — Element Call отключает RED encoding
- Отсутствует FEC в Opus
- Это вызывает хрипы при старте звонка

**Код:**
```javascript
const audioTrack = await createLocalAudioTrack({
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,

  // 🔑 Критически важные параметры для устранения хрипов
  channelCount: 1,              // Моно для экономии bandwidth
  sampleRate: 48000,            // Opus оптимален на 48kHz
  latency: 0.01,                // 10ms латентность (минимальная)

  // Дополнительные Opus параметры
  opus: {
    maxaveragebitrate: 40000,   // 40kbps для качественного голоса
    stereo: false,
    useinbandfec: true,         // 🔥 Forward Error Correction — КРИТИЧНО!
    usedtx: false,              // Не использовать DTX (может давать артефакты)
    maxplaybackrate: 48000,
    sprop_maxcapturerate: 48000
  }
});
```

**ВАЖНО:** Включить RED encoding в LiveKit publishDefaults:
```javascript
const room = new Room({
  // ...
  publishDefaults: {
    red: true,  // 🔥 КРИТИЧНО! Включить RED для защиты от потери пакетов
    // ...
  }
});
```

#### 3.2.2 Увеличить jitter buffer

**Где:** RTCPeerConnection configuration

**Проблема:** Хрипы часто вызваны малым jitter buffer — пакеты не успевают прийти вовремя.

**Решение:**
```javascript
// При создании RTCPeerConnection (если есть прямой доступ)
const pc = new RTCPeerConnection({
  iceServers: [...],

  // Увеличиваем буферы
  sdpSemantics: 'unified-plan',
  rtcpMuxPolicy: 'require',

  // Jitter buffer конфигурация (Chrome/Edge)
  encodedInsertableStreams: true
});

// Или через SDP манипуляцию
room.on(RoomEvent.SignalConnected, () => {
  const pc = room.engine.publisher?.pc;

  if (pc) {
    const originalSetLocalDescription = pc.setLocalDescription.bind(pc);
    pc.setLocalDescription = async (description) => {
      if (description?.sdp) {
        // Увеличиваем минимальный jitter buffer до 50ms
        description.sdp = description.sdp.replace(
          /(a=fmtp:\d+ .*)/g,
          '$1;minptime=10;maxptime=60'
        );
      }
      return originalSetLocalDescription(description);
    };
  }
});
```

#### 3.2.3 Плавная инициализация аудио

**Проблема:** Хрипы при старте из-за резкого включения аудио.

**Решение:**
```javascript
async function startCallWithFadeIn() {
  const audioTrack = await createLocalAudioTrack({...});

  // Начинаем с низкой громкости
  const audioElement = audioTrack.attach();
  audioElement.volume = 0.1;

  // Плавно увеличиваем за 500ms
  let volume = 0.1;
  const fadeInterval = setInterval(() => {
    volume += 0.1;
    audioElement.volume = Math.min(volume, 1.0);

    if (volume >= 1.0) {
      clearInterval(fadeInterval);
    }
  }, 50);

  await room.localParticipant.publishTrack(audioTrack);
}
```

---

### 3.3 Оптимизация ICE negotiation

#### 3.3.1 Настроить TURN с правильными параметрами

**Где:** LiveKit connection config

**Код:**
```javascript
const room = new Room({
  // ... другие настройки

  rtcConfig: {
    iceServers: [
      {
        urls: [
          'stun:livekit.market.implica.ru:3478',
          'turn:livekit.market.implica.ru:3478',
          'turns:livekit.market.implica.ru:5349'
        ],
        username: 'будет автоматически от LiveKit',
        credential: 'будет автоматически от LiveKit'
      }
    ],
    iceTransportPolicy: 'all',        // Пробовать все типы candidates
    iceCandidatePoolSize: 10,         // 🔑 Предзагрузка candidates
    bundlePolicy: 'max-bundle',       // Один UDP поток для всех media
    rtcpMuxPolicy: 'require'          // RTCP через тот же порт что RTP
  }
});
```

#### 3.3.2 Ускорить gathering candidates

**Код:**
```javascript
// Начинаем собирать candidates ДО начала звонка
let cachedCandidates = [];

async function precacheIceCandidates() {
  const pc = new RTCPeerConnection({
    iceServers: [
      { urls: 'stun:livekit.market.implica.ru:3478' }
    ],
    iceCandidatePoolSize: 10
  });

  pc.onicecandidate = (event) => {
    if (event.candidate) {
      cachedCandidates.push(event.candidate);
    }
  };

  // Создаем dummy offer для запуска gathering
  const dc = pc.createDataChannel('dummy');
  await pc.createOffer();
}

// Вызывать при загрузке приложения
precacheIceCandidates();
```

---

### 3.4 Мониторинг качества

#### 3.4.1 Добавить отслеживание метрик

**Где:** Создать отдельный модуль `callQualityMonitor.ts`

**Код:**
```javascript
export class CallQualityMonitor {
  private statsInterval: NodeJS.Timer | null = null;

  startMonitoring(room: Room) {
    this.statsInterval = setInterval(async () => {
      const stats = await this.getConnectionStats(room);

      // Логируем проблемы
      if (stats.audioPacketLoss > 5) {
        console.warn('🔴 High audio packet loss:', stats.audioPacketLoss + '%');
      }

      if (stats.videoPacketLoss > 5) {
        console.warn('🔴 High video packet loss:', stats.videoPacketLoss + '%');
      }

      if (stats.rtt > 200) {
        console.warn('🔴 High RTT:', stats.rtt + 'ms');
      }

      // Можно отправлять в аналитику
      this.sendToAnalytics(stats);
    }, 2000);
  }

  private async getConnectionStats(room: Room): Promise<any> {
    const pc = room.engine.publisher?.pc;
    if (!pc) return null;

    const stats = await pc.getStats();
    let audioPacketLoss = 0;
    let videoPacketLoss = 0;
    let rtt = 0;

    stats.forEach((report) => {
      if (report.type === 'inbound-rtp') {
        const packetsLost = report.packetsLost || 0;
        const packetsReceived = report.packetsReceived || 1;
        const lossPercent = (packetsLost / (packetsLost + packetsReceived)) * 100;

        if (report.mediaType === 'audio') {
          audioPacketLoss = lossPercent;
        } else if (report.mediaType === 'video') {
          videoPacketLoss = lossPercent;
        }
      }

      if (report.type === 'candidate-pair' && report.state === 'succeeded') {
        rtt = report.currentRoundTripTime * 1000;
      }
    });

    return { audioPacketLoss, videoPacketLoss, rtt };
  }

  stopMonitoring() {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
    }
  }
}
```

**Использование:**
```javascript
const monitor = new CallQualityMonitor();

room.on(RoomEvent.Connected, () => {
  monitor.startMonitoring(room);
});

room.on(RoomEvent.Disconnected, () => {
  monitor.stopMonitoring();
});
```

---

## 4. Тестирование

### 4.1 Чек-лист проверки

После внедрения изменений проверить:

- [ ] **Звонок Web → Web**
  - [ ] Нет хрипов при старте
  - [ ] Аудио чистое без лагов
  - [ ] Видео плавное при движении

- [ ] **Звонок Web → iOS**
  - [ ] Совместимость кодеков
  - [ ] Качество аудио/видео
  - [ ] Время установления соединения < 5 сек

- [ ] **Звонок iOS → Web**
  - [ ] Прием видео без артефактов
  - [ ] Синхронизация аудио/видео

### 4.2 Инструменты для тестирования

**Локально:**
```bash
cd /Users/ankin/Documents/element-x-fork/backend/call-tester
node analyze-call-quality.js  # Мониторинг активных звонков
node benchmark-before-after.js  # Тест скорости соединения
```

**В браузере:**
```javascript
// В DevTools console во время звонка
chrome://webrtc-internals/  # Детальная статистика WebRTC
```

---

## 5. Референсы

### 5.1 Код для справки

**iOS реализация (уже оптимизирована):**
```
/Users/ankin/Documents/element-x-fork/ios/ElementX/Sources/Services/Call/CallService.swift
```

**Backend (LiveKit будет обновлен):**
```
Сервер: market.implica.ru
Namespace: livekit
Config: будет включен simulcast, codec settings
```

### 5.2 Документация

- [LiveKit Web SDK](https://docs.livekit.io/client-sdk-js/)
- [WebRTC Best Practices](https://webrtc.org/getting-started/media-devices)
- [Opus Audio Codec](https://opus-codec.org/docs/)

---

## 6. Приоритеты

### 6.1 Критичные (сделать первым делом)
1. ✅ **Audio jitter buffer** — устранит хрипы
2. ✅ **Simulcast** — устранит лаги видео
3. ✅ **Снизить разрешение** — улучшит стабильность

### 6.2 Важные (после критичных)
4. ⚠️ ICE candidates pooling
5. ⚠️ Мониторинг качества

### 6.3 Желательные (когда будет время)
6. 💡 Fade-in аудио при старте
7. 💡 Автоматическая адаптация при плохом качестве

---

## 7. Координация

### 7.1 Зависимости

**Блокирует:**
- Обновление LiveKit на сервере (делает @claude)
- Оптимизация iOS клиента (делает @ios-dev)

**Блокируется:**
- Нет блокеров, можно начинать параллельно

### 7.2 Синхронизация

После завершения:
1. Обновить `sync/WORKLOG.md`
2. Сделать коммит: `git commit -m "[SYNC] готово: webrtc optimization — @web-dev"`
3. Протестировать совместно с iOS

---

## 8. Recording API: Мультиканальная запись звонков

### 8.1 Требования к записи

**Формат выходного файла:**
- Один файл на звонок
- Мультиканальная аудиозапись (каждый участник в отдельном канале)
- Контейнер: MP4/M4A
- Аудио кодек: AAC (для совместимости с iOS AVPlayer)

### 8.2 Проблема с текущей реализацией

**Track Composite Egress** (быстрый старт ~1 сек):
- ❌ Поддерживает только OPUS
- ❌ iOS AVPlayer не воспроизводит OPUS
- ✅ Быстрый старт записи

**Room Composite Egress** (медленный старт ~5 сек):
- ✅ Поддерживает AAC
- ❌ Медленный старт (headless браузер)
- ❌ Микширует все в один канал

### 8.3 Решение: Транскодирование на сервере

**Архитектура:**
```
1. Запись в OPUS (Track Composite) — быстро
2. После завершения → ffmpeg транскодирование в AAC
3. Хранение AAC версии в MinIO
4. iOS получает AAC файл
```

**Команда транскодирования:**
```bash
ffmpeg -i input.ogg -c:a aac -b:a 128k -ar 48000 output.m4a
```

### 8.4 API: Информация о каналах и участниках

**Новый endpoint:** `GET /api/recording/channels/:egressId`

**Response:**
```json
{
  "success": true,
  "egressId": "EG_xxx",
  "channels": [
    {
      "channelIndex": 0,
      "userId": "@ankin:market.implica.ru",
      "displayName": "ankin",
      "startTime": "00:00:00",
      "endTime": "00:05:23"
    },
    {
      "channelIndex": 1,
      "userId": "@dbondar:market.implica.ru",
      "displayName": "dbondar",
      "startTime": "00:00:02",
      "endTime": "00:05:20"
    }
  ],
  "totalChannels": 2,
  "duration": 323
}
```

### 8.5 Расширение метаданных записи

**Обновить таблицу `recording_metadata`:**
```sql
ALTER TABLE recording_metadata ADD COLUMN channels_info TEXT;
-- JSON с информацией о каналах
```

**При старте записи сохранять:**
- ID каждого участника
- Какой трек (канал) соответствует какому участнику
- Время подключения/отключения участника

### 8.6 Задачи для реализации

| # | Задача | Приоритет |
|---|--------|-----------|
| 1 | Добавить ffmpeg в Docker образ recording-api | Высокий |
| 2 | Реализовать автотранскодирование после записи | Высокий |
| 3 | Сохранять маппинг каналов-участников | Высокий |
| 4 | Создать endpoint `/api/recording/channels/:id` | Средний |
| 5 | Мультиканальная запись (отдельный трек на участника) | Средний |

### 8.7 Пример использования (iOS)

```swift
// 1. Получить список каналов
let channelsURL = URL(string: "https://api/recording/channels/\(egressId)")!
let (data, _) = try await URLSession.shared.data(from: channelsURL)
let channels = try JSONDecoder().decode(ChannelsResponse.self, from: data)

// 2. Показать UI с возможностью выбора канала
for channel in channels.channels {
    print("Канал \(channel.channelIndex): \(channel.displayName)")
}

// 3. Воспроизвести конкретный канал или все вместе
audioPlayer.play(recordingURL, channel: selectedChannel)
```

---

## 9. Вопросы?

Если что-то непонятно или нужна помощь:
- Пиши в общий чат
- Проверяй `sync/WORKLOG.md` кто чем занят
- Смотри recording-api как референс для работы с LiveKit

**Удачи! 🚀**
