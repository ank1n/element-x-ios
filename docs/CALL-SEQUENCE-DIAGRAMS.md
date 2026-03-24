# Диаграммы последовательности звонков sTalk

## 1. Текущая схема: WebView (работает)

```
┌──────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐
│  iOS App │  │  WebView  │  │ Matrix  │  │ LiveKit  │  │ Web User │
│ (SwiftUI)│  │(Elem Call)│  │ Synapse │  │   SFU    │  │ (Browser)│
└────┬─────┘  └────┬─────┘  └────┬────┘  └────┬─────┘  └────┬─────┘
     │             │              │             │              │
     │  1. Нажал "Позвонить"     │             │              │
     │─────────────>│             │             │              │
     │             │  2. Widget API: start call │              │
     │             │──────────────>│            │              │
     │             │              │  3. m.call.member state   │
     │             │              │  (MatrixRTC join)          │
     │             │              │─────────────────────────────>│
     │             │              │             │              │
     │             │              │  4. JWT token для LiveKit  │
     │             │              │<────────────│              │
     │             │  5. Получает JWT           │              │
     │             │<─────────────│             │              │
     │             │              │             │              │
     │  JS перехват│              │             │              │
     │<────────────│ 6. onLiveKitCredentials    │              │
     │  (room name │    (url + token)           │              │
     │   для записи)              │             │              │
     │             │              │             │              │
     │             │  7. WebSocket connect       │              │
     │             │──────────────────────────────>│            │
     │             │              │             │              │
     │             │              │  8. E2EE key exchange     │
     │             │              │  (to-device events)        │
     │             │<─────────────│─────────────────────────────>│
     │             │              │             │              │
     │             │  9. SFrame encrypt          │              │
     │             │  Камера → зашифровано ──────>│             │
     │             │              │             │──────────────>│
     │             │              │             │  10. Расшифровка
     │             │              │             │              │
     │             │              │             │<──────────────│
     │             │  11. Получает зашифрованное │              │
     │             │<─────────────────────────────│             │
     │             │  SFrame decrypt             │              │
     │             │  → видео + аудио            │              │
     │             │              │             │              │
     │  12. CSS injection скрывает UI EC        │              │
     │  13. Наши кнопки поверх WebView          │              │
     │             │              │             │              │
     │  Завершение │              │             │              │
     │─────────────>│             │             │              │
     │             │  14. Widget API: hangup     │              │
     │             │──────────────>│            │              │
     │             │              │  15. m.call.member = {}    │
     │             │  16. WS close│             │              │
     │             │──────────────────────────────>│            │
     │             │              │             │              │
```

### Компоненты:
- **iOS App (SwiftUI)** — наши кнопки, навигация, CSS injection
- **WebView (Element Call)** — ВСЁ медиа: камера, микрофон, E2EE, видео рендеринг
- **Matrix Synapse** — signaling, to-device events, call state
- **LiveKit SFU** — пересылка зашифрованных медиапотоков
- **Web User** — Element Call в браузере

### Где E2EE:
```
Отправитель                    SFU                     Получатель
┌──────────┐              ┌──────────┐              ┌──────────┐
│ Камера   │              │          │              │          │
│    ↓     │   encrypted  │ forwards │  encrypted   │    ↓     │
│ SFrame   │─────────────>│ as-is    │─────────────>│ SFrame   │
│ encrypt  │              │ (не может│              │ decrypt  │
│ (AES-GCM)│              │  читать) │              │ (AES-GCM)│
│    ↓     │              │          │              │    ↓     │
│ WebRTC   │              │          │              │ Видео    │
└──────────┘              └──────────┘              └──────────┘

Ключи обмениваются через Matrix (to-device), НЕ через SFU
```

---

## 2. Целевая схема: Native SDK Observer (план)

```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐
│  iOS App │  │  WebView  │  │ Observer │  │ Matrix  │  │ LiveKit  │  │ Web User │
│ (SwiftUI)│  │(Elem Call)│  │(Native   │  │ Synapse │  │   SFU    │  │ (Browser)│
│          │  │          │  │ LK SDK)  │  │         │  │          │  │          │
└────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬────┘  └────┬─────┘  └────┬─────┘
     │             │              │             │             │              │
     │  1. Нажал "Позвонить"     │             │             │              │
     │─────────────>│             │             │             │              │
     │             │  2. Widget API: start      │             │              │
     │             │──────────────────────────────>│          │              │
     │             │              │             │  3. m.call.member         │
     │             │              │             │─────────────────────────────>│
     │             │              │             │             │              │
     │             │  4. WS connect (identity=user)           │              │
     │             │──────────────────────────────────────────>│             │
     │             │              │             │             │              │
     │  JS перехват│              │             │             │              │
     │<────────────│ 5. credentials              │             │              │
     │             │              │             │             │              │
     │  6. Генерация observer JWT │             │             │              │
     │  (identity=user_observer)  │             │             │              │
     │────────────────────────────>│             │             │              │
     │             │              │  7. WS connect (observer) │              │
     │             │              │────────────────────────────>│             │
     │             │              │  subscribe video only      │              │
     │             │              │  canPublish: false          │              │
     │             │              │             │             │              │
     │             │  8. E2EE key exchange       │             │              │
     │             │  (to-device events)          │             │              │
     │             │<────────────────────────────│─────────────────────────────>│
     │             │              │             │             │              │
     │  Widget driver             │             │             │              │
     │  9. Перехват encryption_keys              │             │              │
     │<────────────│              │             │             │              │
     │             │              │             │             │              │
     │  10. keyProvider.setKey()  │             │             │              │
     │────────────────────────────>│             │             │              │
     │             │              │             │             │              │
     │             │  Камера → SFrame encrypt    │             │              │
     │             │──────────────────────────────────────────>│             │
     │             │              │             │             │──────────────>│
     │             │              │             │             │              │
     │             │              │             │             │<──────────────│
     │             │              │  11. SFU → encrypted video│              │
     │             │              │<───────────────────────────│              │
     │             │              │  SFrame decrypt (с ключом)│              │
     │             │              │  → чистое видео           │              │
     │             │              │             │             │              │
     │  12. NativeCallGridView    │             │             │              │
     │  рендерит видео с blur     │             │             │              │
     │<───────────────────────────│             │             │              │
     │             │              │             │             │              │
     │  WebView: аудио            │             │             │              │
     │<────────────│ (E2EE decrypt)│             │             │              │
     │             │              │             │             │              │
```

### Разделение ролей:

| Компонент | Роль |
|-----------|------|
| **WebView** | Камера, микрофон, аудио (приём/передача), E2EE encrypt/decrypt, MatrixRTC signaling |
| **Observer (Native SDK)** | Только приём видео, E2EE decrypt с ключами от Widget API, рендеринг с blur |
| **iOS App** | Кнопки, навигация, передача ключей WebView → Observer |

### Два участника на SFU:

```
LiveKit SFU Room
┌─────────────────────────────────────────┐
│                                         │
│  Participant: @user:server:device       │
│  (WebView)                              │
│  ├─ publishes: camera + microphone      │
│  ├─ subscribes: remote video + audio    │
│  └─ E2EE: SFrame (JS crypto worker)    │
│                                         │
│  Participant: @user:server:device_obs   │
│  (Native SDK Observer)                  │
│  ├─ publishes: nothing                  │
│  ├─ subscribes: remote video only       │
│  └─ E2EE: LKRTCFrameCryptor (native)   │
│                                         │
│  Participant: @remote:server:device     │
│  (Web browser)                          │
│  ├─ publishes: camera + microphone      │
│  ├─ subscribes: remote video + audio    │
│  └─ E2EE: SFrame (JS crypto worker)    │
│                                         │
└─────────────────────────────────────────┘
```

---

## 3. Поток E2EE ключей (детально)

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ Web User │     │  Synapse  │     │  WebView  │     │ Observer │
│ (Browser)│     │  (Matrix) │     │(Elem Call)│     │(Native)  │
└────┬─────┘     └────┬─────┘     └────┬─────┘     └────┬─────┘
     │                │                │                 │
     │ 1. Генерирует  │                │                 │
     │ encryption key │                │                 │
     │ (base64)       │                │                 │
     │                │                │                 │
     │ 2. sendToDevice│                │                 │
     │ (io.element.call.encryption_keys)                 │
     │ зашифрован Olm │                │                 │
     │───────────────>│                │                 │
     │                │                │                 │
     │                │ 3. to-device   │                 │
     │                │ event в sync   │                 │
     │                │───────────────>│                 │
     │                │                │                 │
     │                │  Rust SDK расшифровывает Olm     │
     │                │                │                 │
     │                │  4. Widget driver получает       │
     │                │  "io.element.call.encryption_keys"
     │                │                │                 │
     │                │  5. extractEncryptionKeysIfNeeded │
     │                │  парсит: {key: "E++CV...", index: 0}
     │                │  sender: @remote:server           │
     │                │  device: ABCDEF                   │
     │                │                │                 │
     │                │                │ 6. actionsSubject│
     │                │                │ .encryptionKeys  │
     │                │                │ Received         │
     │                │                │────────────────>│
     │                │                │                 │
     │                │                │ 7. keyProvider   │
     │                │                │ .setKey(         │
     │                │                │   key, pid,      │
     │                │                │   index)         │
     │                │                │                 │
     │                │                │ 8. LKRTCFrame   │
     │                │                │ Cryptor теперь  │
     │                │                │ может расшифро- │
     │                │                │ вать видео      │
     │                │                │                 │
```

---

## 4. Блокеры и решения

```
Блокер 1: EncryptionOptions блокирует подписку
─────────────────────────────────────────────────

  С EncryptionOptions:
    connect() → autoSubscribe → ❌ нет ключей → не подписывается

  Без EncryptionOptions:
    connect() → autoSubscribe → ✅ подписан → видео с артефактами E2EE

  Решение A: Подключиться БЕЗ EncryptionOptions,
             получить ключи,
             вызвать E2EEManager.enableE2EE() ← нужно проверить API

  Решение B: autoSubscribe: false,
             получить ключи,
             вручную subscribe с EncryptionOptions


Блокер 2: Audio session конфликт
─────────────────────────────────

  Observer подключается к LiveKit → SDK активирует AVAudioSession
  → WebView теряет аудио

  Решение A: customConfigureAudioSessionFunc = no-op
             (пробовали, частично помогает)

  Решение B: Отдельный процесс (App Extension) для observer
             (сложно, но изолирует audio session)

  Решение C: Два Room() объекта с разными audio settings
             (нужно проверить LiveKit SDK)
```

---

## 5. Что уже сделано (в git history)

| Компонент | Коммит | Статус |
|-----------|--------|--------|
| Observer JWT генерация | `231ea519` | ✅ работает |
| Observer подключение | `231ea519` | ✅ работает |
| E2EE key extraction из Widget API | `e88517ee` | ✅ парсит ключи |
| keyProvider.setKey() | `e88517ee` | ✅ устанавливает |
| NativeCallGridView (fallback tracks) | `341e9214` | ✅ любой video source |
| Audio session no-op | `c20abb8a` | ⚠️ частично |
| Video-only subscribe | `c80748c2` | ✅ работает |

Весь код сохранён в git history веток develop.
Текущая стабильная сборка: тег `v0.9-stable-webview` (коммит `4620a756`).
