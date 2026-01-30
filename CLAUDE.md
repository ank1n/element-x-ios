делай план изменений что мы провели
записывай изменения в функционале как новые ппункты плана изменений и добаляй ссылку на коммит в коде который нужно применять для того чтобы изменения функциональные применять для новой версии исходников element x в случаи их обновления

## Правила совместной работы

**ВАЖНО: Перед изменением общих зон — записывайся в sync/WORKLOG.md**

### Общие зоны (требуют записи в WORKLOG):
- `backend/recording-api/` — API записи звонков
- `backend/apps-api/` — API приложений
- `backend/api-docs/` — Swagger документация
- K8s namespaces: matrix, livekit
- nginx configs, SSL/DNS

### Процесс:
1. `git pull` — проверить кто что делает
2. Записать себя в `sync/WORKLOG.md`
3. `git commit -m "[SYNC] занял: <зона> — @ios-dev"`
4. Работать
5. `git commit -m "[SYNC] готово: <зона> — @ios-dev"`

### Свободные зоны (без записи):
- iOS: `ios/ElementX/` — весь iOS код
- Web: `web/src/` — весь Web код

Подробнее: `sync/SYNC-RULES.md`

## Git репозиторий

Форк проекта: https://github.com/ank1n/element-x-ios

При выполнении минорных и мажорных изменений — пушить в репозиторий:
```bash
cd /Users/ankin/Documents/element-x-fork/ios
git add -A
git commit --no-verify -m "описание изменений"
git push origin develop
```

Remotes:
- origin: https://github.com/ank1n/element-x-ios.git (форк)
- upstream: https://github.com/element-hq/element-x-ios.git (оригинал)
