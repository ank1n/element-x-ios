# Рабочий журнал Element X

## Текущая работа

### iOS (@ios-dev)
| Задача | Срок | Статус |
|--------|------|--------|
| Тестирование записи звонков | 31.01 | в работе |
| Тест звонков после TURN/TLS настройки | 31.01 | ожидает |

### Web (@web-dev)
| Задача | Срок | Статус |
|--------|------|--------|
| **Оптимизация WebRTC (Element Call)** | 03.02 | **ожидает** |
| Ознакомиться с ТЗ и репозиторием | — | ожидает |
| Боковая панель с 4 секциями | — | ожидает |
| Раздел "Звонки" с историей | — | ожидает |
| Раздел "Приложения" | — | ожидает |

### Backend (общая зона)
| Зона | Задача | Кто | Срок | Статус |
|------|--------|-----|------|--------|
| recording-api | — | — | — | свободно |
| apps-api | реализовать endpoints | — | — | свободно |

### DevOps / K8s (общая зона)
| Зона | Задача | Кто | Срок | Статус |
|------|--------|-----|------|--------|
| matrix namespace | — | — | — | свободно |
| livekit namespace | — | — | — | свободно |
| nginx configs | — | — | — | свободно |
| SSL/DNS | настроить dev.market.implica.ru | @devops | — | ожидает DNS |

### API Docs (общая зона)
| Зона | Задача | Кто | Срок | Статус |
|------|--------|-----|------|--------|
| openapi.yaml | — | — | — | свободно |
| swagger UI | ждёт DNS dev.market.implica.ru | — | — | ожидает |

---

## Ожидает решения

- [ ] **DNS**: нужна A-запись `dev.market.implica.ru → 194.87.190.230`
- [x] **Звонки**: настроен TURN/TLS для symmetric NAT (см. выполнено)

---

## Выполнено

### iOS приложение
- [x] 4-tab навигация: Контакты, Звонки, Чаты, Приложения
- [x] Экран истории звонков (CallsListScreen)
- [x] Воспроизведение записей в истории звонков
- [x] Интеграция Recording API в CallScreen
- [x] Вкладка "Приложения" с iframe виджетами

### Backend
- [x] Recording API: start, stop, status, list endpoints
- [x] K8s deployment recording-api в namespace livekit
- [x] Recording API внешний доступ: `https://livekit.market.implica.ru/recording-api/*`
- [x] Swagger UI: openapi.yaml с полной спецификацией API

### DevOps
- [x] K8s: api-docs deployment для Swagger UI
- [x] Ingress для dev.market.implica.ru (ждёт DNS)
- [x] LiveKit TURN/TLS: UDP 3478, TLS 5349 с Let's Encrypt сертификатом
- [x] LiveKit deployment strategy: Recreate (для hostNetwork)
- [x] LiveKit качество звонков: congestion control, увеличенные буферы, оптимизированный PLI

### Документация
- [x] TZ-ELEMENT-X-WEB-CUSTOMIZATION.md — ТЗ для Web
- [x] SYNC-RULES.md — правила синхронизации
- [x] GETTING-STARTED.md — инструкция для разработчика
- [x] openapi.yaml — Swagger спецификация

---

## История изменений

### 2026-02-02
- [x] k8s: LiveKit оптимизация качества звонков — @claude
  - Congestion control (allow_pause: false)
  - Увеличены буферы (video: 1000, audio: 400)
  - Агрессивный PLI (250ms/500ms/500ms)
  - Оптимизирован playout delay (50-500ms)
- [x] docs: TZ-WEBRTC-QUALITY-OPTIMIZATION.md — ТЗ по оптимизации WebRTC для Web — @claude
- [x] docs: backend/livekit/OPTIMIZATIONS.md — документация применённых оптимизаций — @claude
- [x] ios: исправлен URL Recording API (eddb774) — @claude

### 2026-01-30
- [x] k8s: api-docs deployment — @ios-dev
- [x] swagger: openapi.yaml — @ios-dev
- [x] docs: sync-rules, getting-started — @ios-dev
- [x] git: запушено в github.com/ank1n/element-x-ios — @ios-dev
- [x] fix: Recording API внешний доступ (добавлен prefix /recording-api, удалён дублирующий ingress) — @ios-dev
- [x] k8s: LiveKit TURN/TLS настройка (cert_file, key_file, tls_port: 5349, udp_port: 3478) — @ios-dev
- [x] k8s: TLS secret volume mount для LiveKit deployment — @ios-dev
- [x] k8s: LiveKit deployment strategy изменён на Recreate — @ios-dev

### 2026-01-29
- [x] ios: 4-tab навигация — @ios-dev
- [x] ios: Recording API интеграция — @ios-dev
- [x] ios: воспроизведение записей — @ios-dev
