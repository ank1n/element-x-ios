# Инструкция для Web-разработчика Element X

## Быстрый старт

### 1. Клонируй репозиторий

```bash
git clone https://github.com/ank1n/element-x-ios.git element-x-fork
cd element-x-fork
```

### 2. Изучи структуру

```
element-x-fork/
├── ios/                    # iOS приложение (submodule)
├── backend/
│   ├── recording-api/      # API записи звонков
│   └── api-docs/           # Swagger UI документация
├── WORKLOG.md              # << ГЛАВНЫЙ ФАЙЛ — журнал задач
├── SYNC-RULES.md           # Правила синхронизации
├── TZ-ELEMENT-X-WEB-CUSTOMIZATION.md  # ТЗ для Web версии
└── docs/                   # Документация
```

### 3. Прочитай ключевые файлы

```bash
cat SYNC-RULES.md           # Как синхронизироваться
cat WORKLOG.md              # Кто что делает сейчас
cat TZ-ELEMENT-X-WEB-CUSTOMIZATION.md  # ТЗ для Web
```

---

## Правила работы

### Перед началом работы — ВСЕГДА

```bash
git pull origin main
cat WORKLOG.md              # Смотри кто что делает
```

### Работа со своей зоной (Web код)

Работай свободно, не нужно записывать в WORKLOG:
```bash
git checkout -b web/feature-name
# ... работа ...
git commit -m "[WEB] feat: описание"
git push origin web/feature-name
# Создай PR в main
```

### Работа с общими зонами (Backend, DevOps, API Docs)

**Обязательно** запиши себя в WORKLOG.md:

```bash
# 1. Проверь что зона свободна
cat WORKLOG.md

# 2. Займи зону — отредактируй WORKLOG.md
# Например, добавь строку:
# | apps-api | новый endpoint | @web-dev | 05.02 | в работе |

git add WORKLOG.md
git commit -m "[SYNC] занял: apps-api — @web-dev"
git push origin main

# 3. Работай в своей ветке
git checkout -b web/apps-api-feature
# ... работа ...

# 4. Когда закончил — освободи зону
git checkout main
git pull
# Отметь задачу как готовую в WORKLOG.md
git add WORKLOG.md
git commit -m "[SYNC] готово: apps-api — @web-dev"
git push origin main
```

---

## Общие зоны (требуют записи в WORKLOG)

| Зона | Путь | Описание |
|------|------|----------|
| recording-api | `backend/recording-api/` | API записи звонков |
| apps-api | `backend/apps-api/` | API приложений |
| api-docs | `backend/api-docs/` | Swagger документация |
| matrix namespace | K8s | Synapse, Element, Recording |
| livekit namespace | K8s | LiveKit, JWT service |
| nginx configs | ozzy.implica.ru | Конфиги nginx |

---

## Сервера и доступы

### Продакшн
- **Matrix/Element**: https://market.implica.ru
- **LiveKit**: wss://livekit.market.implica.ru

### Документация API
- **Swagger UI**: https://dev.market.implica.ru (когда настроят DNS)

### Сервер
- **SSH**: `ssh root@ozzy.implica.ru`
- **K8s**: `kubectl` доступен на сервере

---

## Что уже сделано (iOS)

1. **4 вкладки навигации**: Контакты, Звонки, Чаты, Приложения
2. **Запись звонков**: интеграция с LiveKit Egress
3. **История звонков**: с воспроизведением записей
4. **Встраиваемые приложения**: вкладка "Приложения"

Твоя задача — реализовать то же самое для Web.

---

## ТЗ для Web

Подробное техническое задание: `TZ-ELEMENT-X-WEB-CUSTOMIZATION.md`

### Кратко — что нужно сделать:

1. **Боковая панель** с 4 секциями (как вкладки в iOS)
2. **Раздел "Звонки"** — история с воспроизведением записей
3. **Раздел "Приложения"** — iframe виджеты
4. **Интеграция Recording API** — старт/стоп записи в звонках

---

## API Endpoints

### Recording API (уже работает)

```
POST /recording-api/start
POST /recording-api/stop
GET  /recording-api/status/:egressId
GET  /recording-api/list/:roomId
```

### Apps API (нужно реализовать)

```
GET  /apps
GET  /apps/:id
```

Полная спецификация: `backend/api-docs/openapi.yaml`

---

## Контакты

- **iOS Dev**: @ankin (Telegram)
- **Сервер**: ozzy.implica.ru

---

## Чек-лист первого дня

- [ ] Склонировал репозиторий
- [ ] Прочитал SYNC-RULES.md
- [ ] Прочитал TZ-ELEMENT-X-WEB-CUSTOMIZATION.md
- [ ] Получил доступ к серверу (SSH)
- [ ] Проверил что market.implica.ru работает
- [ ] Написал план работ в WORKLOG.md
