# Call Quality Tester

Автоматический тестер качества и стабильности звонков LiveKit.

## Возможности

- ✅ Создание тестовых комнат
- ✅ Подключение нескольких участников
- ✅ Эмуляция аудио/видео стримов
- ✅ Сбор метрик качества
- ✅ Анализ стабильности соединения
- ✅ Детальное логирование

## Требования

1. LiveKit сервер (запущен локально или удаленно)
2. livekit-cli установлен в `~/bin/lk`
3. Node.js 18+

## Установка

```bash
npm install
```

## Использование

### Базовый тест (2 участника, 30 секунд)

```bash
node test-call-quality.js
```

### Кастомные параметры

```bash
# Больше участников
PARTICIPANTS=5 node test-call-quality.js

# Длительность теста 60 секунд
TEST_DURATION=60 node test-call-quality.js

# Удаленный LiveKit
LIVEKIT_URL=wss://your-server.com \
LIVEKIT_API_KEY=your-key \
LIVEKIT_API_SECRET=your-secret \
node test-call-quality.js

# Кастомный путь к lk CLI
LK_CLI_PATH=/usr/local/bin/lk node test-call-quality.js
```

### Комбо

```bash
PARTICIPANTS=3 TEST_DURATION=45 node test-call-quality.js
```

## Метрики

Тестер собирает следующие метрики:

- **Connection Success Rate** - процент успешных подключений
- **Participant Count** - количество участников в комнате
- **Active Tracks** - количество активных медиа треков
- **Connection Stability** - стабильность соединений
- **Errors** - список ошибок

## Логи

Детальные логи сохраняются в `logs/test-{room}-{timestamp}.json`:

```json
{
  "startTime": 1234567890,
  "endTime": 1234567920,
  "roomName": "test-quality-1234567890",
  "participants": [...],
  "events": [...],
  "metrics": {...}
}
```

## Анализ результатов

После каждого теста выводится отчет:

```
📊 ТЕСТ КАЧЕСТВА ЗВОНКОВ - ОТЧЕТ
=====================================

🕐 Длительность теста: 30.5s
🏠 Комната: test-quality-1234567890
👥 Участников: 2

📈 Метрики подключений:
  Попыток подключения: 2
  Успешных: 2
  Неудачных: 0
  Success Rate: 100.0%

👤 Участники:
  1. test-participant-1 ✅ (30.2s)
  2. test-participant-2 ✅ (30.1s)

💡 Рекомендации:
  ✅ Все подключения успешны
```

## Примеры сценариев

### 1. Стресс-тест (много участников)

```bash
PARTICIPANTS=10 TEST_DURATION=60 node test-call-quality.js
```

### 2. Долгий тест (стабильность)

```bash
PARTICIPANTS=3 TEST_DURATION=300 node test-call-quality.js
```

### 3. Быстрый тест (smoke test)

```bash
PARTICIPANTS=2 TEST_DURATION=10 node test-call-quality.js
```

## Troubleshooting

### lk CLI не найден

```bash
# Проверить установку
which lk
ls -la ~/bin/lk

# Если не установлен, см. основной README
```

### LiveKit сервер недоступен

```bash
# Проверить что сервер запущен
curl http://localhost:7880

# Проверить логи
ps aux | grep livekit-server
```

### Ошибки подключения участников

- Проверьте firewall правила
- Проверьте настройки RTC портов в livekit-config.yaml
- Проверьте логи участников в детальном JSON отчете

## Следующие шаги

На основе результатов тестов можно:

1. Настроить параметры LiveKit (битрейт, кодеки, TURN)
2. Оптимизировать сетевые настройки
3. Выявить проблемы с конкретными типами подключений
4. Измерить impact изменений конфигурации
