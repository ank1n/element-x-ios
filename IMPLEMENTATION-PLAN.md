# План: Форк Element X с виджетами и записью звонков

## Обзор

Создание форков Element X iOS и Android с двумя новыми функциями:
1. **Виджеты** - отображение Matrix виджетов из room state
2. **Запись звонков** - кнопка записи с интеграцией LiveKit Egress

## Архитектура

```
┌─────────────────────────────────────────────────────────────────┐
│                    Element X Fork (iOS/Android)                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Widget View │  │ Call Screen │  │ Recording Service       │  │
│  │ (WebView)   │  │ + Record    │  │ (HTTP client)           │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘  │
│         │                │                      │                │
│         ▼                ▼                      ▼                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │              Matrix Rust SDK (room state, calls)            ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Backend Recording API                         │
│  POST /api/recording/start  { roomName }  → egress_id           │
│  POST /api/recording/stop   { egressId }  → success             │
│  GET  /api/recording/status { egressId }  → status              │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│              LiveKit Egress (уже развёрнут)                      │
│  livekit.market.implica.ru + MinIO storage                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Часть 1: iOS Implementation

### 1.1 Новые файлы для виджетов

```
ElementX/Sources/
├── Screens/
│   └── RoomScreen/
│       └── Widgets/
│           ├── WidgetListView.swift           # Список виджетов в комнате
│           ├── WidgetListViewModel.swift      # ViewModel для списка
│           ├── WidgetWebView.swift            # WKWebView для виджета
│           ├── WidgetWebViewModel.swift       # ViewModel + Widget API
│           └── WidgetCoordinator.swift        # Навигация виджетов
├── Services/
│   └── Widget/
│       ├── WidgetService.swift               # Парсинг m.widget events
│       ├── WidgetAPIBridge.swift             # JS ↔ Swift bridge
│       └── WidgetModels.swift                # Widget data models
```

### 1.2 Модели данных (WidgetModels.swift)

```swift
struct MatrixWidget: Identifiable, Codable {
    let id: String              // state_key
    let type: String            // widget type
    let name: String
    let url: String
    let creatorUserId: String
    let waitForIframeLoad: Bool?
    let data: [String: AnyCodable]?
}

enum WidgetStateEventType: String {
    case mWidget = "m.widget"
    case imVectorWidget = "im.vector.modular.widgets"
}
```

### 1.3 WidgetService (парсинг room state)

```swift
class WidgetService {
    private let roomProxy: RoomProxyProtocol

    func getWidgets() async -> [MatrixWidget] {
        // Читаем state events типа m.widget и im.vector.modular.widgets
        let stateEvents = await roomProxy.getStateEvents(
            types: ["m.widget", "im.vector.modular.widgets"]
        )
        return stateEvents.compactMap { parseWidget($0) }
    }

    func subscribeToWidgetChanges() -> AnyPublisher<[MatrixWidget], Never> {
        // Подписка на изменения через Timeline
    }
}
```

### 1.4 WidgetWebView (WKWebView + Widget API)

```swift
struct WidgetWebView: UIViewRepresentable {
    let widget: MatrixWidget
    let roomId: String
    let userId: String
    @ObservedObject var viewModel: WidgetWebViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(
            viewModel.messageHandler,
            name: "matrixWidget"  // Widget API bridge
        )

        let webView = WKWebView(frame: .zero, configuration: config)

        // Подставляем параметры в URL виджета
        let url = processWidgetURL(widget.url, roomId: roomId, userId: userId)
        webView.load(URLRequest(url: url))

        return webView
    }
}
```

### 1.5 Интеграция в RoomScreen

Модифицировать: `ElementX/Sources/Screens/RoomScreen/RoomScreenCoordinator.swift`

```swift
// Добавить в navigation
case .showWidgets:
    let coordinator = WidgetListCoordinator(roomProxy: roomProxy)
    navigationStack.push(coordinator)

case .openWidget(let widget):
    let coordinator = WidgetCoordinator(widget: widget, roomProxy: roomProxy)
    present(coordinator)
```

### 1.6 Запись звонков - RecordingService

```swift
// ElementX/Sources/Services/Recording/RecordingService.swift

class RecordingService: ObservableObject {
    @Published var isRecording = false
    @Published var currentEgressId: String?

    private let baseURL = "https://api.market.implica.ru"  // Ваш backend

    func startRecording(roomName: String) async throws -> String {
        let request = RecordingStartRequest(roomName: roomName)
        let response: RecordingStartResponse = try await apiClient.post(
            "\(baseURL)/api/recording/start",
            body: request
        )

        DispatchQueue.main.async {
            self.isRecording = true
            self.currentEgressId = response.egressId
        }

        return response.egressId
    }

    func stopRecording() async throws {
        guard let egressId = currentEgressId else { return }

        try await apiClient.post(
            "\(baseURL)/api/recording/stop",
            body: RecordingStopRequest(egressId: egressId)
        )

        DispatchQueue.main.async {
            self.isRecording = false
            self.currentEgressId = nil
        }
    }
}
```

### 1.7 Кнопка записи в Element Call

Модифицировать UI звонка (Element Call embedded widget):

```swift
// В ElementCallService или Call UI
struct CallControlsView: View {
    @ObservedObject var recordingService: RecordingService
    let roomName: String

    var body: some View {
        HStack {
            // Existing controls...

            Button(action: toggleRecording) {
                Image(systemName: recordingService.isRecording
                    ? "record.circle.fill"
                    : "record.circle")
                .foregroundColor(recordingService.isRecording ? .red : .white)
            }
        }
    }

    func toggleRecording() {
        Task {
            if recordingService.isRecording {
                try await recordingService.stopRecording()
            } else {
                // Показать consent диалог
                showRecordingConsent { approved in
                    if approved {
                        try await recordingService.startRecording(roomName: roomName)
                    }
                }
            }
        }
    }
}
```

---

## Часть 2: Android Implementation

### 2.1 Новые файлы для виджетов

```
features/
├── widgets/
│   ├── api/
│   │   └── WidgetService.kt              # Room state parsing
│   ├── impl/
│   │   ├── WidgetListScreen.kt           # Compose UI
│   │   ├── WidgetListState.kt
│   │   ├── WidgetListPresenter.kt
│   │   ├── WidgetWebViewScreen.kt        # WebView container
│   │   └── WidgetApiJsBridge.kt          # JS interface
│   └── model/
│       └── MatrixWidget.kt               # Data class
```

### 2.2 WidgetWebViewScreen (Jetpack Compose + WebView)

```kotlin
@Composable
fun WidgetWebViewScreen(
    widget: MatrixWidget,
    roomId: String,
    userId: String,
    onClose: () -> Unit
) {
    val context = LocalContext.current

    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true

                // Widget API bridge
                addJavascriptInterface(
                    WidgetApiJsBridge(roomId, userId),
                    "matrixWidget"
                )

                val url = processWidgetUrl(widget.url, roomId, userId)
                loadUrl(url)
            }
        }
    )
}
```

### 2.3 RecordingService для Android

```kotlin
// features/call/impl/RecordingService.kt

class RecordingService @Inject constructor(
    private val httpClient: HttpClient
) {
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording

    private var currentEgressId: String? = null

    suspend fun startRecording(roomName: String): Result<String> {
        return try {
            val response = httpClient.post<RecordingStartResponse>(
                "$BASE_URL/api/recording/start",
                RecordingStartRequest(roomName)
            )
            currentEgressId = response.egressId
            _isRecording.value = true
            Result.success(response.egressId)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun stopRecording(): Result<Unit> {
        val egressId = currentEgressId ?: return Result.failure(
            IllegalStateException("No active recording")
        )

        return try {
            httpClient.post<Unit>(
                "$BASE_URL/api/recording/stop",
                RecordingStopRequest(egressId)
            )
            _isRecording.value = false
            currentEgressId = null
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
```

---

## Часть 3: Backend Recording API

### 3.1 Простой Node.js сервис

```javascript
// recording-api/index.js
const express = require('express');
const { EgressClient, EncodedFileOutput, S3Upload } = require('livekit-server-sdk');

const app = express();
app.use(express.json());

const egressClient = new EgressClient(
    'wss://livekit.market.implica.ru',
    'devkey',
    'secret123456789012345678901234567890'
);

// Start recording
app.post('/api/recording/start', async (req, res) => {
    const { roomName, layout = 'grid-dark' } = req.body;

    try {
        const fileOutput = new EncodedFileOutput({
            filepath: `recordings/${roomName}_{time}.mp4`,
            output: {
                case: 's3',
                value: new S3Upload({
                    accessKey: 'minioadmin',
                    secret: 'MinioAdmin2026!',
                    endpoint: 'http://minio.minio.svc.cluster.local:9000',
                    bucket: 'livekit-recordings',
                    forcePathStyle: true
                })
            }
        });

        const info = await egressClient.startRoomCompositeEgress(roomName, {
            file: fileOutput,
            layout: layout
        });

        res.json({
            success: true,
            egressId: info.egressId,
            status: info.status
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// Stop recording
app.post('/api/recording/stop', async (req, res) => {
    const { egressId } = req.body;

    try {
        await egressClient.stopEgress(egressId);
        res.json({ success: true });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// Get status
app.get('/api/recording/status/:egressId', async (req, res) => {
    try {
        const list = await egressClient.listEgress();
        const egress = list.find(e => e.egressId === req.params.egressId);
        res.json({ egress });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.listen(3000, () => console.log('Recording API on :3000'));
```

### 3.2 Деплой в Kubernetes

```yaml
# recording-api-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recording-api
  namespace: livekit
spec:
  replicas: 1
  selector:
    matchLabels:
      app: recording-api
  template:
    metadata:
      labels:
        app: recording-api
    spec:
      containers:
      - name: recording-api
        image: node:20-alpine
        command: ["node", "/app/index.js"]
        ports:
        - containerPort: 3000
        volumeMounts:
        - name: app-code
          mountPath: /app
---
apiVersion: v1
kind: Service
metadata:
  name: recording-api
  namespace: livekit
spec:
  selector:
    app: recording-api
  ports:
  - port: 3000
```

---

## Часть 4: Этапы реализации

### Этап 1: Backend Recording API (1-2 дня)
- [ ] Создать Node.js сервис
- [ ] Задеплоить в Kubernetes
- [ ] Настроить Ingress (api.market.implica.ru)
- [ ] Протестировать через curl

### Этап 2: iOS Fork - Запись (2-3 дня)
- [ ] Форкнуть element-x-ios
- [ ] Добавить RecordingService
- [ ] Добавить кнопку записи в Call UI
- [ ] Добавить consent диалог
- [ ] Тестирование на устройстве

### Этап 3: iOS Fork - Виджеты (3-5 дней)
- [ ] Создать WidgetService для парсинга state
- [ ] Создать WidgetWebView с WKWebView
- [ ] Реализовать Widget API bridge
- [ ] Интегрировать в RoomScreen
- [ ] Тестирование с stats.market.implica.ru

### Этап 4: Android Fork (3-5 дней)
- [ ] Форкнуть element-x-android
- [ ] Портировать RecordingService
- [ ] Портировать Widget компоненты
- [ ] Тестирование

### Этап 5: Публикация
- [ ] Настроить CI/CD (Fastlane/GitHub Actions)
- [ ] Подписать приложения
- [ ] TestFlight / Google Play Internal

---

## Часть 5: Ключевые файлы для модификации

### iOS (element-x-ios)
| Файл | Изменение |
|------|-----------|
| `app.yml` | Изменить bundle ID, app name |
| `AppSettings.swift` | Добавить feature flags для widgets/recording |
| `RoomScreenCoordinator.swift` | Добавить навигацию к виджетам |
| `RoomScreenViewModel.swift` | Добавить widgets state |

### Android (element-x-android)
| Файл | Изменение |
|------|-----------|
| `build.gradle` | Изменить applicationId |
| `AppNavGraph.kt` | Добавить widget routes |
| `RoomDetailsNode.kt` | Добавить widgets section |

---

## Часть 6: Верификация

### Тест виджетов
1. Открыть комнату с виджетом (stats.market.implica.ru)
2. Убедиться что виджет отображается в WebView
3. Проверить Widget API (если виджет использует)

### Тест записи
1. Начать звонок между двумя устройствами
2. Нажать кнопку записи
3. Проверить что запись началась (индикатор)
4. Остановить запись
5. Скачать файл из MinIO
6. Проверить качество видео/аудио

---

## Оценка трудозатрат

| Компонент | iOS | Android | Backend |
|-----------|-----|---------|---------|
| Recording API | - | - | 1-2 дня |
| Кнопка записи | 2 дня | 2 дня | - |
| Виджеты | 4 дня | 4 дня | - |
| Тестирование | 2 дня | 2 дня | - |
| **Итого** | **8 дней** | **8 дней** | **2 дня** |

**Общая оценка: 2-3 недели** при работе одного разработчика над обеими платформами параллельно.
