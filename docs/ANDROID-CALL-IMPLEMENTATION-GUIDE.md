# Руководство для Android: Реализация звонков в sTalk

> **Автор**: iOS-команда sTalk
> **Дата**: 2026-02-16
> **Версия iOS**: коммит `713dc67c` (develop)
> **Цель**: Описание архитектуры звонков iOS для переноса на Android

---

## 1. Общая архитектура

Звонки в sTalk реализованы **гибридной архитектурой**: WebView (Element Call) + нативный LiveKit SDK.

```
┌───────────────────────────────────────────────────────┐
│ Нативный UI (SwiftUI / Jetpack Compose)               │
│ - Кнопки: камера, микрофон, динамик, завершить        │
│ - Таймер звонка, имя контакта, аватар                 │
│ - Индикатор записи (локальной и удалённой)            │
├───────────────────────────────────────────────────────┤
│ Нативный LiveKit SDK                                   │
│ - Подключение к SFU (аудио + видео)                   │
│ - Публикация/подписка на треки                        │
│ - Управление камерой и микрофоном                     │
├───────────────────────────────────────────────────────┤
│ WebView (1×1 пиксель, невидимый)                      │
│ - Element Call (React SPA)                             │
│ - Widget API (MatrixRTC signaling через Rust SDK)     │
│ - JS хуки: перехват WebSocket, CSS скрытие UI         │
└───────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   Matrix Homeserver    LiveKit SFU         Recording API
   (signaling)          (медиа)            (запись звонков)
```

### Почему гибрид, а не чистый WebRTC?

| Подход | Проблема |
|--------|----------|
| Только WebView | Плохой контроль аудио, IOSurface перекрывает нативный UI |
| Только нативный WebRTC | Нет готовой MatrixRTC интеграции, огромный объём работы |
| **Гибрид (текущий)** | WebView для signaling, нативный SDK для медиа — баланс |

---

## 2. Жизненный цикл звонка

### 2.1 Инициализация

```
1. Пользователь нажимает "Позвонить"
2. ViewModel создаётся с параметрами комнаты
3. Rust SDK создаёт Widget Driver (для Widget API)
4. WebView загружает Element Call URL с параметрами:
   - userId, roomId, widgetId, displayName, lang, theme
   - clientId, deviceId, baseUrl, parentUrl
   - perParticipantE2EE, intent (start_call_dm / start_call)
```

### 2.2 Загрузка WebView и JS инъекции

**КРИТИЧЕСКИ ВАЖНО**: Скрипты инжектятся в **два этапа**:

#### Этап 1: `atDocumentStart` (ДО загрузки Element Call)

Инжектируется **до** любого HTML/JS Element Call. Содержит:

**a) CSS скрытие UI Element Call:**
```javascript
var s = document.createElement('style');
s.textContent = [
    'html, body { background:#000!important; margin:0!important; padding:0!important; overflow:hidden!important }',
    'body * { color:transparent!important; background:transparent!important; border-color:transparent!important; box-shadow:none!important; outline:none!important; text-shadow:none!important; caret-color:transparent!important }',
    'svg, img { opacity:0!important }',
    'video { background:#000!important }',
].join('\\n');
(document.documentElement || document).appendChild(s);
```

**Принцип**: Все цвета/фоны/тени → transparent. `<video>` элементы рендерят пиксели из стрима независимо от CSS. Весь текст, кнопки, аватарки — невидимы. Layout (grid/flex) сохраняется.

**b) Перехват WebSocket (LiveKit credentials):**
```javascript
var OrigWS = window.WebSocket;
var _intercepted = false;
window.WebSocket = function(url, protocols) {
    var u = String(url);
    // LiveKit WebSocket содержит /rtc и access_token=
    if (u.indexOf('/rtc') !== -1 && u.indexOf('access_token=') !== -1) {
        if (!_intercepted) {
            _intercepted = true;
            var token = (u.match(/access_token=([^&]+)/) || [])[1] || '';
            // Отправляем credentials в нативный код
            window.webkit.messageHandlers.onLiveKitCredentials.postMessage(
                JSON.stringify({ url: u, token: token })
            );
        }
    }
    // PASS-THROUGH: EC продолжает работать с WebSocket
    return protocols !== undefined ? new OrigWS(url, protocols) : new OrigWS(url);
};
window.WebSocket.prototype = OrigWS.prototype;
window.WebSocket.CONNECTING = 0;
window.WebSocket.OPEN = 1;
window.WebSocket.CLOSING = 2;
window.WebSocket.CLOSED = 3;
```

**ВАЖНО для Android**: На iOS `window.webkit.messageHandlers` работает только в main frame, НЕ в iframe. Element Call может создавать WebSocket из iframe. Решение — postMessage relay:
```javascript
// В iframe: нет messageHandlers → шлём через parent
function _stalkPostCreds(data) {
    try { window.webkit.messageHandlers.onLiveKitCredentials.postMessage(JSON.stringify(data)); return; } catch(e) {}
    try { window.top.postMessage({_stalkLiveKitCreds: data}, '*'); } catch(e2) {}
}

// В main frame: слушаем relay от iframe
if (window === window.top) {
    window.addEventListener('message', function(event) {
        if (event.data && event.data._stalkLiveKitCreds) {
            window.webkit.messageHandlers.onLiveKitCredentials.postMessage(
                JSON.stringify(event.data._stalkLiveKitCreds)
            );
        }
    });
}
```

**На Android** используй `@JavascriptInterface` — он доступен во всех фреймах через `addJavascriptInterface`.

#### Этап 2: `atDocumentEnd` (ПОСЛЕ загрузки EC)

- **Widget API listener**: перехват `window.postMessage` для Widget API сообщений
- **Lobby detection**: определение завершения звонка удалённой стороной (3 метода)
- **Hand raise observer**: отслеживание поднятия руки через DOM

### 2.3 Перехват credentials и подключение LiveKit

```
Element Call загружается
    → EC создаёт WebSocket к LiveKit SFU
    → JS хук перехватывает URL: wss://sfu.host/rtc?access_token=JWT_TOKEN
    → Token и URL отправляются в нативный код
    → Нативный код декодирует JWT (base64 payload):
        {
          "video": {
            "room": "Ln7Vag8yq-ZnDzrLQ4DTdsubT+09ECbcx-...",
            "canPublish": true,
            "canSubscribe": true
          },
          "exp": 1234567890
        }
    → Извлекается room name (для recording-api)
    → Нативный LiveKit SDK подключается с теми же credentials
    → Публикуются аудио и видео треки
```

**Декодирование JWT (критично для записи):**
```
JWT = header.payload.signature (разделены точками)
payload = base64decode(parts[1])  // Добавить padding "=" до кратности 4
room_name = payload["video"]["room"] || payload["room"]
```

### 2.4 Подключение нативного LiveKit SDK

```
1. Извлечь base URL: "wss://sfu.host/rtc?access_token=..." → "wss://sfu.host"
2. Настроить аудио сессию (VoIP mode)
3. Подключиться: room.connect(url, token, options)
4. Включить микрофон: room.localParticipant.setMicrophone(enabled: true)
5. Включить камеру: room.localParticipant.setCamera(enabled: true)
6. Подписаться на события: participantDidConnect, participantDidDisconnect, etc.
```

**Параметры подключения (iOS):**
```
Video: 720p 16:9, max 1.5 Mbps, max 30 FPS
Audio: платформенные defaults, DTX включён (экономия трафика на тишине)
AutoSubscribe: true (получать все треки автоматически)
```

**Аудио сессия (iOS → Android аналог):**
```
iOS: AVAudioSession.setCategory(.playAndRecord, mode: .voiceChat,
     options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])

Android: AudioManager.setMode(MODE_IN_COMMUNICATION)
         AudioManager.setSpeakerphoneOn(true)
         // + Bluetooth через BluetoothProfile.HEADSET
```

### 2.5 Определение подключения звонка

Звонок считается "подключённым" когда:

**Для 1:1 звонков:**
- MatrixRTC показывает >= 2 участников в комнате

**Для групповых:**
- MatrixRTC показывает текущего пользователя в списке участников

После подключения запускается:
- Таймер звонка (каждую секунду)
- Polling recording-api (каждые 5 секунд)

### 2.6 Завершение звонка

**Последовательность (критична!):**
```
1. Остановить запись (если активна)                    — POST /recording-api/stop
2. Кликнуть кнопку hangup в Element Call (JS DOM click) — JS: querySelector('[data-testid="hangup_button"]').click()
3. Отправить .hangup в Widget API (fallback)           — postMessage({api:"fromWidget", action:"im.vector.hangup"})
4. Подождать 2 секунды                                 — EC обрабатывает hangup
5. Отправить .close в Widget API                       — postMessage({api:"fromWidget", action:"io.element.close"})
6. Подождать 1 секунду                                 — Rust SDK чистит MatrixRTC state
7. Отключить LiveKit SDK                               — room.disconnect()
8. Завершить CallKit сессию                            — tearDownCallSession()
9. Закрыть экран звонка                                — dismiss
```

**ВАЖНО**: `.close` сообщение обязательно для очистки MatrixRTC state events на сервере. Без него — "призрачная" сессия висит, и комната показывает активный звонок.

---

## 3. Widget API (MatrixRTC signaling)

### 3.1 Формат сообщений

```json
// iOS → Element Call (toWidget)
{
    "api": "toWidget",
    "action": "io.element.device_mute",
    "data": {"audio_enabled": false, "video_enabled": true},
    "widgetId": "uuid",
    "requestId": "widgetapi-uuid"
}

// Element Call → iOS (fromWidget)
{
    "api": "fromWidget",
    "action": "im.vector.hangup",
    "data": {},
    "widgetId": "uuid",
    "requestId": "widgetapi-timestamp"
}
```

### 3.2 Действия

| Action | Direction | Описание |
|--------|-----------|----------|
| `content_loaded` | fromWidget | EC загружен и готов |
| `im.vector.hangup` | fromWidget | EC хочет завершить звонок |
| `io.element.close` | fromWidget | EC закрывается (cleanup) |
| `io.element.device_mute` | обе | Изменение состояния микрофона/камеры |

### 3.3 Поток сообщений

```
JS (WebView) → WKScriptMessageHandler → ViewModel → Rust SDK Widget Driver
                                                            ↓
                                                     MatrixRTC state sync
                                                     (Matrix homeserver)
```

На Android:
```
JS (WebView) → @JavascriptInterface → ViewModel → Rust SDK (JNI)
```

### 3.4 Отправка сообщений в WebView

```javascript
// iOS: evaluateJavaScript
postMessage(JSON.stringify(message), '*')

// Android: evaluateJavascript
webView.evaluateJavascript("postMessage(JSON.stringify(${jsonMessage}), '*')", null)
```

---

## 4. Определение завершения звонка удалённой стороной

### 4.1 Три метода (JS lobby detection)

```javascript
// Метод 1: Кнопка "Join" в лобби EC
// EC показывает эту кнопку ТОЛЬКО когда в лобби
var joinBtn = document.querySelector('[data-testid="lobby_joinCall"]');
if (joinBtn && hasLeftLobby) {
    // Мы ушли из лобби (звонили) → кнопка появилась = собеседник повесил
    notifyCallEnded("lobby");
}

// Метод 2: MediaStream стал неактивным
var videos = document.querySelectorAll('video');
videos.forEach(function(v) {
    if (v.srcObject && v.srcObject.active) activeStreamCount++;
});
if (hadActiveMedia && activeStreamCount === 0) {
    notifyCallEnded("mediaEnded");
}

// Метод 3: video элементы удалены из DOM
if (hadVideoElements && videos.length === 0) {
    notifyCallEnded("videoRemoved");
}
```

**Проверка**: MutationObserver + setInterval(1500ms)

### 4.2 Автозавершение 1:1 звонков (нативная проверка)

```
Условия для автозавершения:
- Звонок 1:1 (isDirect = true)
- Статус: connected
- Прошло > 30 секунд (grace period)
- MatrixRTC: 0 или только мы в списке участников
- LiveKit: 0 remote participants
→ endCall()
```

Grace period 30 секунд нужен потому что:
- MatrixRTC state sync через homeserver — задержка
- Участник может кратковременно пропасть при переподключении
- Предотвращает ложные срабатывания

---

## 5. Запись звонков

### 5.1 Архитектура

```
Recording API (backend)
├─ POST /recording-api/start  — начать запись
├─ POST /recording-api/stop   — остановить запись
├─ GET  /recording-api/api/recording/list   — список записей
├─ GET  /recording-api/api/recording/status/:egressId — статус
└─ GET  /recording-api/api/recording/play/:egressId   — воспроизведение
```

Recording API использует **LiveKit Egress** — встроенный механизм записи LiveKit SFU. API принимает **LiveKit room name** (НЕ Matrix room ID).

### 5.2 Начало записи

```
POST /recording-api/start
{
    "roomName": "Ln7Vag8yq-ZnDzrLQ4DTdsubT+09ECbcx-...",  // LiveKit room name из JWT
    "layout": "grid-dark",
    "matrixRoomId": "!abc:stalk.implica.ru",  // Для метаданных
    "participants": [
        {"userId": "@user1:stalk.implica.ru", "displayName": "Иван"},
        {"userId": "@user2:stalk.implica.ru", "displayName": "Мария"}
    ],
    "initiatedBy": "@user1:stalk.implica.ru"
}

→ Response:
{
    "success": true,
    "egressId": "EG_xxx",
    "status": 1,
    "roomName": "Ln7Vag8yq-..."
}
```

**КРИТИЧНО**: `roomName` — это LiveKit room name, извлечённый из JWT токена (см. раздел 2.3). Если передать Matrix room ID — ошибка "Room not found".

### 5.3 Остановка записи

```
POST /recording-api/stop
{
    "egressId": "EG_xxx"
}

→ Response:
{
    "success": true,
    "egressId": "EG_xxx",
    "status": 3
}
```

### 5.4 Обнаружение удалённой записи (polling)

Каждые 5 секунд во время звонка:

```
GET /recording-api/api/recording/list

→ Response:
{
    "success": true,
    "recordings": [
        {
            "egressId": "EG_xxx",
            "roomName": "Ln7Vag8yq-...",
            "status": 1,           // 1 = ACTIVE
            "initiatedBy": "@user2:stalk.implica.ru"
        }
    ]
}
```

Если есть запись с `status == 1` и `roomName == наша комната` → показать индикатор записи (красная кнопка, disabled).

**Статусы записи:**
| Код | Статус | Описание |
|-----|--------|----------|
| 0 | STARTING | Инициализация |
| 1 | ACTIVE | Идёт запись |
| 2 | ENDING | Завершается |
| 3 | COMPLETE | Готова к воспроизведению |
| 4 | FAILED | Ошибка |
| 5 | ABORTED | Прервана |

---

## 6. Управление медиа

### 6.1 Mute/Unmute

```
1. Нативный LiveKit SDK: room.localParticipant.setMicrophone(enabled: !muted)
2. Widget API уведомление (для синхронизации MatrixRTC state):
   postMessage({
       api: "toWidget",
       action: "io.element.device_mute",
       data: { audio_enabled: !muted }
   })
```

Оба шага обязательны: нативный SDK реально контролирует аудио, Widget API синхронизирует состояние.

### 6.2 Camera toggle

```
1. Нативный LiveKit SDK: room.localParticipant.setCamera(enabled: on)
2. Widget API уведомление:
   postMessage({
       api: "toWidget",
       action: "io.element.device_mute",
       data: { video_enabled: on }
   })
```

### 6.3 Hand raise (групповые звонки)

```javascript
// Toggle через DOM click в EC:
window.stalkToggleHandRaise = function() {
    var btn = document.querySelector('[class*="_raiseHand"] button');
    if (!btn) btn = document.querySelector('[class*="_raiseHand"]');
    if (btn) btn.click();
    return !!btn;
};

// Наблюдение за состоянием:
// MutationObserver + setInterval(1000ms)
// Проверяем aria-pressed на кнопке раисе
```

### 6.4 Динамик / аудио маршрутизация

iOS: `AVRoutePickerView` показывает системный picker.
Android: `AudioManager` + `BluetoothProfile.HEADSET`.

---

## 7. Проблемы и решения (из опыта iOS)

### 7.1 Проблема: "Room not found" при записи

**Причина**: Recording API ожидает LiveKit room name, а не Matrix room ID.
**Решение**: Декодировать JWT из перехваченных credentials, извлечь `video.room`.

### 7.2 Проблема: Экран звонка закрывается при подключении

**Причина**: `.close` сообщение отправленное через WebView возвращается обратно как `fromWidget` → обработчик видит `.close` → `.callEnded` → dismiss.
**Решение**: Добавить guard `isEndingCall` — если мы уже завершаем звонок, игнорировать `.callEnded`.

### 7.3 Проблема: MatrixRTC сессия не очищается при hangup

**Причина**: `stop()` (вызывается координатором при удалении экрана) отправлял `.close` через WebView, что вызывало bounce-back.
**Решение**: В `stop()` отправлять только `.hangup`. `.close` отправлять напрямую в Rust SDK (минуя WebView).

### 7.4 Проблема: Ложное срабатывание lobby detection на симуляторе

**Причина**: На симуляторе нет реальных медиа-стримов → `mediaEnded` срабатывает через ~10 секунд.
**Решение**: Проверять `callElapsedTime > 5` перед обработкой lobby detection.

### 7.5 Проблема: onLiveKitCredentials не приходит (iframe)

**Причина**: Element Call создаёт WebSocket из iframe, где `window.webkit.messageHandlers` недоступен.
**Решение**: Relay через `window.top.postMessage()` + слушатель в main frame. На Android `@JavascriptInterface` доступен во всех фреймах — эта проблема может не возникнуть.

---

## 8. Android-специфичные заметки

### 8.1 WebView setup

```kotlin
val webView = WebView(context).apply {
    layoutParams = FrameLayout.LayoutParams(1, 1) // 1×1 пиксель
    settings.apply {
        javaScriptEnabled = true
        domStorageEnabled = true
        mediaPlaybackRequiresUserGesture = false
        allowFileAccess = true
    }
    webChromeClient = object : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) {
            // Разрешить getUserMedia для камеры и микрофона
            request.grant(request.resources)
        }
    }
    addJavascriptInterface(jsBridge, "stalkBridge")
}
```

### 8.2 JS Bridge (Android)

```kotlin
class StalkJsBridge(private val viewModel: CallScreenViewModel) {
    @JavascriptInterface
    fun onWidgetAction(message: String) {
        viewModel.handleWidgetAction(message)
    }

    @JavascriptInterface
    fun onLiveKitCredentials(json: String) {
        val obj = JSONObject(json)
        viewModel.onCredentialsIntercepted(obj.getString("url"), obj.getString("token"))
    }

    @JavascriptInterface
    fun onLobbyDetected(reason: String) {
        viewModel.onLobbyDetected(reason)
    }

    @JavascriptInterface
    fun onHandRaiseStateChanged(state: String) {
        viewModel.onHandRaiseChanged(state == "raised")
    }
}
```

**ВАЖНО**: В JS скриптах заменить `window.webkit.messageHandlers.XXX.postMessage(msg)` на `stalkBridge.XXX(msg)`.

### 8.3 LiveKit Android SDK

```kotlin
// build.gradle
implementation("io.livekit:livekit-android:2.12.0")

// Подключение
val room = LiveKit.create(context)
room.connect(url, token, ConnectOptions(autoSubscribe = true))

// Публикация треков
room.localParticipant.setMicrophoneEnabled(true)
room.localParticipant.setCameraEnabled(true)

// Подписка на события
room.events.collect { event ->
    when (event) {
        is RoomEvent.ParticipantConnected -> { ... }
        is RoomEvent.ParticipantDisconnected -> { ... }
        is RoomEvent.TrackSubscribed -> { ... }
    }
}
```

### 8.4 Аудио на Android

```kotlin
val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
audioManager.isSpeakerphoneOn = true
// Bluetooth: AudioManager.startBluetoothSco()
```

---

## 9. Файловая структура (iOS → Android маппинг)

| iOS файл | Роль | Android аналог |
|----------|------|----------------|
| `CallScreenViewModel.swift` | Главная логика звонка | `CallScreenViewModel.kt` |
| `CallScreen.swift` | UI + WebView coordinator | `CallScreenFragment.kt` + `CallScreen.kt` (Compose) |
| `CallScreenModels.swift` | JS скрипты, модели | `CallScreenModels.kt` + `js/` ресурсы |
| `ElementCallWidgetDriver.swift` | Widget API bridge | `ElementCallWidgetDriver.kt` (Rust SDK JNI) |
| `LiveKitRoomManager.swift` | Нативный LiveKit | `LiveKitRoomManager.kt` |
| `RecordingService.swift` | HTTP клиент recording-api | `RecordingRepository.kt` (OkHttp/Retrofit) |
| `RecordingModels.swift` | Модели данных | `RecordingModels.kt` |
| `ElementCallService.swift` | CallKit интеграция | `CallService.kt` (ConnectionService) |
| `RecordingButton.swift` | UI кнопка записи | `RecordingButton.kt` (Compose) |

---

## 10. Контрольный чеклист

- [ ] WebView 1×1 загружает Element Call
- [ ] CSS injection скрывает UI Element Call
- [ ] JS перехват WebSocket → credentials приходят в нативный код
- [ ] JWT декодирование → LiveKit room name извлечён
- [ ] Нативный LiveKit SDK подключается с credentials
- [ ] Аудио работает (микрофон + динамик)
- [ ] Видео работает (камера + рендеринг удалённого видео)
- [ ] Mute/unmute через нативный SDK + Widget API sync
- [ ] Camera toggle через нативный SDK + Widget API sync
- [ ] Widget API сообщения проходят (fromWidget ↔ toWidget)
- [ ] Hangup работает (JS click + Widget API + LiveKit disconnect)
- [ ] `.close` отправляется для MatrixRTC cleanup
- [ ] Lobby detection определяет завершение удалённой стороной
- [ ] Автозавершение 1:1 при уходе собеседника (30s grace)
- [ ] Запись: start/stop через recording-api
- [ ] Запись: room name из JWT (не Matrix room ID!)
- [ ] Запись: индикатор удалённой записи (polling /list каждые 5с)
- [ ] Таймер звонка
- [ ] Hand raise (групповые звонки)
- [ ] Динамик / Bluetooth routing
