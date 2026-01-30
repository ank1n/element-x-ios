# Правила синхронизации через Git

## Разработчики

| Кто | Проект | Префикс веток |
|-----|--------|---------------|
| **iOS Dev** | element-x-ios | `ios/` |
| **Web Dev** | element-x-web | `web/` |

---

## Файл синхронизации: WORKLOG.md

Перед работой с **общими зонами** — запиши себя в `WORKLOG.md`:

```markdown
## Текущая работа

### Backend
- [ ] recording-api: добавить list endpoint — @ios-dev (до 31.01)

### DevOps
- [x] nginx: настроить dev.market.implica.ru — @ios-dev (готово 30.01)

### API Docs
- [ ] swagger: добавить Apps API — @web-dev (до 01.02)
```

---

## Процесс работы с общими зонами

### 1. Проверь WORKLOG.md

```bash
git pull origin main
cat WORKLOG.md
```

Если зона свободна — переходи к шагу 2.
Если занята — подожди или договорись через коммит.

### 2. Займи зону

```bash
# Отредактируй WORKLOG.md, добавь свою задачу
git add WORKLOG.md
git commit -m "[SYNC] занял: backend/recording-api — @ios-dev"
git push origin main
```

### 3. Работай

Делай изменения в своей ветке:
```bash
git checkout -b ios/recording-api-list
# ... работа ...
git commit -m "[iOS] feat: recording list endpoint"
```

### 4. Освободи зону

```bash
# Обнови WORKLOG.md — отметь задачу как готовую
git checkout main
git pull
# Отметь [x] в WORKLOG.md
git add WORKLOG.md
git commit -m "[SYNC] готово: backend/recording-api — @ios-dev"
git push origin main
```

---

## Структура WORKLOG.md

```markdown
# Рабочий журнал Element X

## Текущая работа

### Backend
| Зона | Задача | Кто | Срок | Статус |
|------|--------|-----|------|--------|
| recording-api | list endpoint | @ios-dev | 31.01 | в работе |
| apps-api | — | — | — | свободно |

### DevOps / K8s
| Зона | Задача | Кто | Срок | Статус |
|------|--------|-----|------|--------|
| matrix namespace | — | — | — | свободно |
| livekit namespace | — | — | — | свободно |
| nginx configs | — | — | — | свободно |

### API Docs
| Зона | Задача | Кто | Срок | Статус |
|------|--------|-----|------|--------|
| openapi.yaml | Apps API | @web-dev | 01.02 | в работе |

---

## История

### 2026-01-30
- [x] nginx: dev.market.implica.ru — @ios-dev
- [x] k8s: api-docs deployment — @ios-dev

### 2026-01-29
- [x] recording-api: start/stop endpoints — @ios-dev
```

---

## Общие зоны (требуют записи в WORKLOG)

```
backend/
├── recording-api/     # API записи звонков
├── apps-api/          # API приложений
└── api-docs/          # Swagger UI

K8s namespaces:
├── matrix             # Synapse, Element Web, Recording
└── livekit            # LiveKit, JWT service

Сервер:
├── nginx configs      # /etc/nginx/sites-available/
└── SSL/DNS            # сертификаты, DNS записи
```

---

## Свободные зоны (без записи в WORKLOG)

| iOS Dev | Web Dev |
|---------|---------|
| `ios/ElementX/` | `web/src/` |
| iOS UI, логика | Web UI, логика |
| Xcode проект | package.json, configs |

---

## Конфликты в WORKLOG.md

Если git конфликт при push:

```bash
git pull --rebase origin main
# Разреши конфликт в WORKLOG.md
# Если оба хотят одну зону — кто раньше закоммитил, тот работает
git add WORKLOG.md
git rebase --continue
git push origin main
```

---

## Коммиты для синхронизации

```
[SYNC] занял: <зона> — @<кто>
[SYNC] готово: <зона> — @<кто>
[SYNC] передаю: <зона> @<от-кого> → @<кому>
```

---

## Срочные изменения

Если нужно срочно в занятую зону:

1. Добавь коммит:
```
[SYNC] СРОЧНО нужен доступ: <зона> — @<кто>
Причина: <описание>
```

2. Коллега увидит при следующем `git pull`

3. Договоритесь через коммиты или созвонитесь

---

## Ежедневный ритуал

### Начало работы
```bash
cd element-x-fork
git pull origin main
cat WORKLOG.md          # Смотрим кто что делает
```

### Конец работы
```bash
git pull origin main
# Обнови статус своих задач в WORKLOG.md
git add WORKLOG.md
git commit -m "[SYNC] обновил статус — @ios-dev"
git push origin main
```
