# Element X Fork - Widgets + Recording

Форк Element X (iOS/Android) с поддержкой виджетов и записи звонков.

## Репозитории оригиналов

| Платформа | GitHub |
|-----------|--------|
| iOS | https://github.com/element-hq/element-x-ios |
| Android | https://github.com/element-hq/element-x-android |

## Добавляемые функции

### 1. Виджеты (Widgets)
- Парсинг `m.widget` и `im.vector.modular.widgets` из room state
- Отображение виджетов в WebView
- Widget API v2 для двусторонней коммуникации

### 2. Запись звонков (Call Recording)
- Кнопка записи в UI звонка
- Интеграция с LiveKit Egress через backend API
- Индикатор записи для всех участников
- Consent диалог (правовое требование)

## Серверная инфраструктура

| Сервис | URL |
|--------|-----|
| Matrix Homeserver | https://market.implica.ru |
| LiveKit | https://livekit.market.implica.ru |
| Recording API | https://api.market.implica.ru |
| Widget Example | https://stats.market.implica.ru |

## Структура проекта

```
element-x-fork/
├── README.md                    # Этот файл
├── IMPLEMENTATION-PLAN.md       # Детальный план реализации
├── SERVER-CONFIG.md             # Конфигурация серверов
├── backend/
│   └── recording-api/           # Node.js Recording API
│       ├── package.json
│       ├── index.js
│       └── k8s/
│           └── deployment.yaml
├── ios/                         # Fork element-x-ios (git submodule)
└── android/                     # Fork element-x-android (git submodule)
```

## Быстрый старт

### 1. Клонировать форки
```bash
# iOS
git clone https://github.com/YOUR_USERNAME/element-x-ios.git ios
cd ios && xcodegen && open ElementX.xcworkspace

# Android
git clone https://github.com/YOUR_USERNAME/element-x-android.git android
cd android && ./gradlew assembleDebug
```

### 2. Деплой Recording API
```bash
cd backend/recording-api
npm install
kubectl apply -f k8s/
```

### 3. Тестирование
```bash
# Проверить Recording API
curl -X POST https://api.market.implica.ru/api/recording/start \
  -H "Content-Type: application/json" \
  -d '{"roomName": "test-room"}'
```

## LiveKit Credentials

```
URL: wss://livekit.market.implica.ru
API Key: devkey
API Secret: secret123456789012345678901234567890
```

## MinIO Storage

```
Endpoint: http://minio.minio.svc.cluster.local:9000
Access Key: minioadmin
Secret: MinioAdmin2026!
Bucket: livekit-recordings
```
