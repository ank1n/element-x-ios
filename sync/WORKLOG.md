# Рабочий журнал Element X

## Текущая работа

### iOS (@ios-dev)
| Задача | Срок | Статус |
|--------|------|--------|
| Тестирование записи звонков | 31.01 | в работе |
| Исправить передачу видео/аудио в звонках | 31.01 | в работе |

### Web (@web-dev)
| Задача | Срок | Статус |
|--------|------|--------|
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
- [ ] **Звонки**: разобраться почему не передаётся видео/аудио (NAT/TURN?)

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
- [x] K8s deployment recording-api в namespace matrix
- [x] Swagger UI: openapi.yaml с полной спецификацией API

### DevOps
- [x] K8s: api-docs deployment для Swagger UI
- [x] Ingress для dev.market.implica.ru (ждёт DNS)

### Документация
- [x] TZ-ELEMENT-X-WEB-CUSTOMIZATION.md — ТЗ для Web
- [x] SYNC-RULES.md — правила синхронизации
- [x] GETTING-STARTED.md — инструкция для разработчика
- [x] openapi.yaml — Swagger спецификация

---

## История изменений

### 2026-01-30
- [x] k8s: api-docs deployment — @ios-dev
- [x] swagger: openapi.yaml — @ios-dev
- [x] docs: sync-rules, getting-started — @ios-dev
- [x] git: запушено в github.com/ank1n/element-x-ios — @ios-dev

### 2026-01-29
- [x] ios: 4-tab навигация — @ios-dev
- [x] ios: Recording API интеграция — @ios-dev
- [x] ios: воспроизведение записей — @ios-dev
