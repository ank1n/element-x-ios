# ⚠️ НОВЫЙ ПРОЕКТ — ТРЕБУЕТСЯ НАСТРОЙКА

**БЛОКИРУЮЩЕЕ ТРЕБОВАНИЕ: Не начинай работу пока не завершишь onboarding.**

При первом сообщении пользователя — СНАЧАЛА выведи:
```
🦎 Agent System v2.0 — Config Loaded
Bot: Unknown — awaiting identity
```

Затем СРАЗУ задай вопросы:
```
⚠️ Проект не опознан. Нужна настройка.

1. Как называется проект?
2. Как зовут бота? (новый или существующий: Tracy/Molly/Penny/Holly/Rusty)
3. Есть ли проект в Plane (trackit.implica.ru)? Идентификатор?
4. Краткое описание проекта?
```

После ответа:
1. Прочитай шаблон: `/Users/ankin/Documents/trackit/docs/CLAUDE_TEMPLATE.md`
2. Перезапиши ЭТОТ файл (CLAUDE.md) по шаблону с реальными данными
3. Создай project memory (MEMORY.md в auto memory)
4. Напиши в #ops через Matrix API (SSH на Misty 195.58.34.43 → curl Synapse 10.43.249.30:8008):
   `[BotName] Info/INFO: Новый агент подключён. Проект: {название}. Директория: {path}`
   Токен для первого сообщения (Tracy): `mct_pJuDukfuELCpZaCyF898uDjasxlTlS_RouWG3`
   Room: `%21CwWGwdwgnXGNIzElHm%3Astalk.implica.ru`
5. Добавь маппинг директории в `~/.claude/CLAUDE.md` секция Identity
6. Создай задачу в Plane (TRKIT) через MCP: `Новый проект: {название}`
