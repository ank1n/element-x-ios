# App Store Submission Checklist (STMOB-124)

Target: публикация **sTalk** в App Store (App ID `ru.implica.stalk`).
Текущий build для submission: **182** (`f0855fa3b`, cross-signing fix STMOB-180/181, в TestFlight 2026-05-28).

> ⚠️ Public release **только на build 182** — он содержит критичный fix `autoEnableCrossSigning=false`.
> Build 181 безопасен для Apple review (fresh reviewer), но для wide release несёт cross-signing rotation bug.

## Готовность артефактов (2026-05-29)

| Артефакт | Статус |
|----------|--------|
| Build 182 `.ipa` | ✅ `ios/build-archive/export/sTalk.ipa`, в TestFlight |
| Иконка 1024×1024 | ✅ `app-store-screenshots/AppIcon-1024.png` (no alpha) |
| Скриншоты 6.9" (1290×2796) | ✅ `app-store-screenshots/asc-final/69/` — 5 шт |
| Скриншоты 6.7" (1284×2778) | ✅ `app-store-screenshots/asc-final/67/` — 5 шт |
| Описание RU + EN, Keywords, Promo | ✅ разделы 6–7 ниже |
| Privacy / Terms / Support | ✅ `legal-pages/{privacy,terms,support}.html` → `https://stalk.implica.ru/{privacy,terms,support}` |
| Encryption compliance | ✅ `ITSAppUsesNonExemptEncryption=false` (раздел 5) |
| Review Notes + demo account | ✅ раздел 9 (проверить что demo account жив) |

**Остаток — только ручные действия в App Store Connect UI (раздел 10), плюс проверка demo-аккаунта.**

---

## 1. App Information (App Store Connect → App Information)

- **Bundle ID**: `ru.implica.stalk`
- **Primary Category**: Social Networking
- **Secondary Category**: Business
- **Age Rating**: **12+**
  - Infrequent/Mild Profanity or Crude Humor: No
  - Infrequent/Mild Mature/Suggestive Themes: No
  - Unrestricted Web Access: **Yes** (медиа-ссылки в сообщениях)
  - Gambling: No
  - User-Generated Content: **Yes** (сообщения, фото, видео)

---

## 2. Pricing & Availability

- **Price**: Free
- **Availability**: Россия (RU), потом возможно Беларусь, Казахстан
  - **НЕ** включать США/EU без юр-проверки (GDPR/COPPA implications)

---

## 3. Privacy Policy

- **Privacy Policy URL** (обязательно): `https://stalk.implica.ru/privacy`
- **Terms of Service URL** (рекомендуется): `https://stalk.implica.ru/terms`
- **Support URL**: `https://stalk.implica.ru/support`
- **Marketing URL** (необязательно): `https://stalk.implica.ru`

> Если страниц нет — создать минимальные через docs/stalk-mobile деплой.

---

## 4. App Privacy (Nutrition Labels)

Подавать в App Store Connect → App Privacy:

| Категория | Linked to User | Used for Tracking | Purpose |
|-----------|---------------|-------------------|---------|
| **Email Address** | Yes | No | App Functionality (OIDC login) |
| **Name** | Yes | No | App Functionality (display name) |
| **Photos or Videos** | Yes | No | App Functionality (media sharing, E2EE) |
| **Audio Data** | Yes | No | App Functionality (voice messages, calls) |
| **Other User Content** | Yes | No | App Functionality (text messages) |
| **User ID** | Yes | No | App Functionality (Matrix ID) |
| **Device ID** | Yes | No | App Functionality (Matrix device_id, push) |
| **Crash Data** | No | No | Analytics (Sentry) |
| **Performance Data** | No | No | Analytics |
| **Other Diagnostic Data** | No | No | Analytics (DiagLog, MXLog) |
| **Contacts** | No | No | (только если юзер импортирует — не используем сейчас) |
| **Coarse Location** | Yes | No | App Functionality (location sharing в сообщениях) |
| **Precise Location** | Yes | No | App Functionality (location pin в сообщениях) |

- Tracking: **No**
- Data Linked to User: см. выше
- ATT-разрешение **не запрашивается** (не отслеживаем для рекламы)

---

## 5. Encryption Export Compliance

- В `Info.plist` сейчас: `ITSAppUsesNonExemptEncryption = NO`
- **Это корректно** для нашего случая:
  - Используем стандартные алгоритмы (HTTPS/TLS, Megolm/Olm — based on Curve25519, AES-256, HMAC-SHA-256)
  - Все криптоалгоритмы — exempt по 5D002 (open source publicly available)
  - Matrix protocol — Open Source
- ERN/CCATS **не требуется**

> Если Apple потребует подтверждения: ссылка на Matrix spec + Element X open source (GPL).

---

## 6. App Description (RU)

### Promo Text (170 chars)
```
Корпоративный мессенджер с E2EE-шифрованием, видеозвонками и голосовыми сообщениями. Безопасное общение для команд на базе Matrix-протокола.
```
(*156 chars*)

### Description (full, до 4000 chars)
```
sTalk — корпоративный мессенджер на базе открытого протокола Matrix с end-to-end шифрованием всех сообщений и звонков.

ВОЗМОЖНОСТИ

Мгновенные сообщения
• Текстовые сообщения с форматированием (жирный, курсив, цитаты, код)
• Эмодзи-реакции на сообщения
• Ответы на конкретные сообщения с цитированием
• Редактирование и удаление отправленного
• Индикатор «печатает», статусы прочтения
• Поиск по истории чатов

Группы и комнаты
• Личные чаты и групповые комнаты
• Темы (топики) для структурирования обсуждений
• Управление участниками и правами
• Закреплённые сообщения

Видео и аудио звонки
• Групповые звонки до 30 участников
• Поделиться экраном
• Шумоподавление, размытие фона
• Запись звонков (по разрешению владельца комнаты)
• Поднятие руки, активный спикер
• AirPods и Bluetooth-устройства

Файлы и медиа
• Фото, видео, аудио, документы
• Голосовые сообщения с визуализацией
• Карты и геопозиция
• Опросы

Безопасность
• Сквозное шифрование (E2EE) для всех чатов и звонков (Megolm/Olm)
• Корпоративная авторизация через OIDC (Keycloak)
• Проверка устройств собеседника (cross-signing)
• Локальное хранение ключей в Apple Keychain

Уведомления
• VoIP push-уведомления для звонков с CallKit
• Push-уведомления о новых сообщениях
• Тонкая настройка по комнатам (mute, mentions only)
• Live Activities для активных звонков

ТРЕБОВАНИЯ

• Корпоративная учётная запись в вашей организации
• iOS 18.5+
• Подключение к интернету
• Доступ к камере и микрофону для звонков

ОТКРЫТЫЕ ИСТОЧНИКИ

sTalk построен на открытых протоколах:
• Matrix protocol (matrix.org)
• Element X iOS (element-hq/element-x-ios)
• LiveKit (livekit.io)

ПРИВАТНОСТЬ

• Никакого отслеживания пользователей
• Никакой передачи данных третьим сторонам
• Сервер размещён в вашей корпоративной инфраструктуре
• Полный контроль над вашими данными
```

### Keywords (100 chars, comma-separated, no spaces)
```
мессенджер,звонки,видеосвязь,e2ee,шифрование,matrix,корпоративный,чат,созвон,конференция
```
(*99 chars*)

### What's New (release notes для каждой версии)
```
Версия 26.04.05 — новый дизайн вкладок звонков, улучшения видео-конференций, поддержка iOS 26.
```

---

## 7. App Description (en-US)

### Promo Text (170 chars)
```
Corporate messenger with end-to-end encryption, video calls and voice messages. Secure team communication built on the Matrix protocol.
```
(*135 chars*)

### Description
```
sTalk is a corporate messenger built on the open Matrix protocol with end-to-end encryption for all messages and calls.

FEATURES

Instant Messaging
• Rich text formatting (bold, italic, quotes, code)
• Emoji reactions
• Threaded replies with quoting
• Edit and delete sent messages
• Typing indicators, read receipts
• Full-text chat history search

Groups & Rooms
• Direct messages and group rooms
• Threads for structured discussions
• Member management and permissions
• Pinned messages

Video & Audio Calls
• Group calls up to 30 participants
• Screen sharing
• Noise suppression, background blur
• Call recording (with room owner permission)
• Hand raise, active speaker
• AirPods and Bluetooth support

Files & Media
• Photos, videos, audio, documents
• Voice messages with waveform visualization
• Location sharing with maps
• Polls

Security
• End-to-end encryption (E2EE) for all chats and calls (Megolm/Olm)
• Corporate authentication via OIDC (Keycloak)
• Device verification with cross-signing
• Local key storage in Apple Keychain

Notifications
• VoIP push notifications for calls with CallKit
• Push notifications for new messages
• Per-room mute and mentions-only settings
• Live Activities for active calls

REQUIREMENTS

• Corporate account at your organization
• iOS 18.5+
• Internet connection
• Camera and microphone access for calls

OPEN SOURCE

sTalk is built on open protocols:
• Matrix protocol (matrix.org)
• Element X iOS (element-hq/element-x-ios)
• LiveKit (livekit.io)

PRIVACY

• No user tracking
• No data shared with third parties
• Server hosted in your corporate infrastructure
• Full control over your data
```

### Keywords (en-US)
```
messenger,calls,video,e2ee,encryption,matrix,corporate,chat,meeting,conference
```
(*88 chars*)

---

## 8. Screenshots

✅ **Готово** — 5 шт, ASC-ready размеры, без альфа-канала. Загружать из:
- 6.9" (1290×2796): `app-store-screenshots/asc-final/69/`
- 6.7" (1284×2778): `app-store-screenshots/asc-final/67/`

Набор (одинаковый в обеих папках):
- `01-chats-list.png` — список чатов
- `02-room-message.png` — переписка в комнате
- `03-call-active.png` — активный групповой звонок
- `05-contacts-list.png` — список контактов с presence dots
- `06-call-details.png` — детали звонка с транскрипцией + tabs

> Сырые исходники (1320×2868, нативный iPhone 17 Pro Max) — в корне `app-store-screenshots/`.
> Resized-варианты сделаны через `sips`; повторить при пересъёмке.

### Размеры (iPhone)
- **6.9"** (iPhone 17 Pro Max, 1290×2796) — обязательно для submission
- **6.7"** (iPhone 14/15/16 Pro Max, 1290×2796) — same as 6.9
- **6.5"** (iPhone 11 Pro Max, 1242×2688) — необязательно, можно скипнуть

### Снятие
В симуляторе **iPhone 17 Pro Max** (`46C27CF1-096B-4D7B-A5B1-C33B74B92FE9`):
```bash
xcrun simctl io 46C27CF1-096B-4D7B-A5B1-C33B74B92FE9 screenshot \
  ~/Documents/element-x-fork/app-store-screenshots/03-call-active.png
```

---

## 9. Demo Account for Apple Reviewer

Создать в **Keycloak** (realm `matrix`) аккаунт:
- **Email**: `apple-review@stalk.implica.ru`
- **Password**: сгенерировать (16 chars, передать в App Store Connect → Review Info)
- **Display Name**: `Apple Reviewer`
- **Готовый профиль**: добавить в 2-3 тестовых комнаты с реальной перепиской

### Notes for Reviewer (в App Store Connect)
```
sTalk is a corporate messenger for our company's internal use, built on the open Matrix protocol with end-to-end encryption.

REVIEW NOTES:
1. The app requires corporate authentication via OIDC (Keycloak). Use the provided demo account to test all features.

2. Login flow:
   - Tap "Sign In" on the welcome screen
   - The app opens a WebView with OIDC login at https://auth.trackit.implica.ru
   - Enter the demo credentials below
   - You'll be redirected back to the app

3. Demo account:
   - Email: apple-review@stalk.implica.ru
   - Password: [generated 16-char password]

4. Pre-populated content:
   - The account has 2-3 demo chats with sample messages
   - Test messaging, voice messages, sending photos
   - Voice/video calls can be initiated if there's another user (please contact us if testing in-call features required)

5. E2EE: All messages and calls are end-to-end encrypted using the Matrix Megolm/Olm protocol (publicly documented at matrix.org/specs/).

6. The server is hosted at stalk.implica.ru (corporate infrastructure).

7. App uses standard cryptographic algorithms (Curve25519, AES-256, HMAC-SHA-256) — exempt from ERN per 5D002.

Contact: dp.bondar@gmail.com
```

---

## 10. Submission Checklist

### Pre-submit (юзер в App Store Connect UI)
- [ ] Иконку 1024×1024 ASC берёт из бандла build 182 автоматически (запасной файл: `app-store-screenshots/AppIcon-1024.png`, no alpha)
- [ ] Загрузить screenshots: `asc-final/69/` (6.9") + `asc-final/67/` (6.7"), по 5 шт
- [ ] Заполнить Description / Keywords / Promo (RU + en-US) — copy-paste из разделов 6–7
- [ ] Privacy Policy URL: `https://stalk.implica.ru/privacy`
- [ ] App Privacy questionnaire заполнен (раздел 4)
- [ ] Age Rating: 12+ (раздел 1)
- [ ] Sign-in Required: Yes
- [ ] Demo account credentials в Review Information (раздел 9 — проверить что аккаунт жив)
- [ ] Review Notes из раздела 9 выше
- [ ] **Build 182** выбран в "Build" секции

### Submit
- [ ] "Submit for Review"
- [ ] Manual Release выбран (контроль таймингов)

### Post-submit
- [ ] Через 1-3 дня — Apple response (Approved / Rejected / Metadata)
- [ ] При Reject — фикс + resubmit
- [ ] При Approval → manual release → public

---

## Possible Apple Rejection Triggers

| Guideline | Что | Митигация |
|-----------|-----|-----------|
| **4.2** Minimum Functionality | "App too simple" | В описании подчеркнуть features (звонки, E2EE, файлы) |
| **5.1.1** Data Collection | Privacy Policy неясен | Прописать что и зачем собираем |
| **5.1.2** Data Use & Sharing | Передача 3rd parties | Указать **No** sharing |
| **2.3** Performance | Crash при review | Build 162+ стабильный, тестировать на демо-аккаунте |
| **4.3** Spam (если есть аналог в Store) | Похож на Element/Matrix | Объяснить что это fork с корп-функциями |
| **2.5.4** Multitasking Apps | VoIP background mode misuse | У нас правильное использование — CallKit + PushKit |

---

## Файлы артефактов

- `ElementX/SupportingFiles/Info.plist` — Info.plist с usage descriptions
- `ElementX/SupportingFiles/PrivacyInfo.xcprivacy` — privacy manifest
- `NSE/SupportingFiles/PrivacyInfo.xcprivacy` — для extension
- `ElementX/Resources/AppIcon.icon/Assets/AppIcon.png` — иконка 1024×1024 (RGBA — нужно конвертировать в RGB без альфы для submission)
- `app-store-screenshots/asc-final/{69,67}/` — screenshots ready (5 шт каждая папка)
- `ios/build-archive/sTalk.xcarchive` + `export/sTalk.ipa` — archive/ipa build 182
- `ios/ExportOptions.plist` — для re-export если нужно

---

## Estimate

- **Phase 1 (Privacy & Compliance)**: 1-2 часа (большая часть уже есть)
- **Phase 2 (Screenshots + Content)**: 2-3 часа (4-6 screenshots + переводы)
- **Phase 3 (Demo Account in Keycloak)**: 30 мин
- **Phase 4 (ASC submission)**: 30 мин ручной работы юзера в UI
- **Phase 5 (Apple review)**: 1-3 дня (не зависит от нас)

Total: **4-6 часов работы** до submit.
