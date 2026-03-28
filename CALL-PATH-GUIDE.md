# Путь до звонка в sTalk Mobile (iOS)

## Предусловия
- Симулятор: iPhone 17 Pro (D1E80A03-46B0-414D-8CAD-48E0C442BCF9)
- Приложение: ru.implica.stalk (версия 26.01.1)
- Сервер: stalk.implica.ru

---

## Шаг 1: Запуск приложения
- Экран приветствия: "Чувствуйте себя как дома с Element"
- Кнопки: "Войти QR-кодом", **"Войти"**, "Создать учетную запись"
- **Действие:** Тап → "Войти"

## Шаг 2: Экран "Вход" — добавление сервера
- "Нет сохраненных аккаунтов"
- **Действие:** Тап → "Добавить сервер"

## Шаг 3: Ввод адреса сервера
- Поле: "URL-адрес домашнего сервера"
- **Действие:** Ввести `stalk.implica.ru` → "Продолжить"

## Шаг 4: OIDC логин (Keycloak WebView)
- Открывается `auth.trackit.implica.ru` в WKWebView (ASWebAuthenticationSession)
- Форма Keycloak с логотипом sTalk
- **Credentials:** `penny` / `Penny2026`
- **ВАЖНО:** Maestro НЕ МОЖЕТ автоматизировать ввод в WebView — оба inputText идут в первое поле
- **Действие:** Вручную ввести логин → пароль → "Войти"

### Возможные ошибки:
- `user_not_found` — пользователь `ankin` НЕ существует в Keycloak, используй `penny`
- `User exists` — upstream link не привязан в MAS БД (см. раздел Troubleshooting)

## Шаг 5: Главный экран (после логина)
- Вкладка "Контакты" (по умолчанию)
- 5 табов внизу: Контакты, Звонки, **Чаты**, Приложения, Настройки
- **Действие:** Тап → "Чаты" (координаты: `50%,93%` или id `message`)

## Шаг 6: Список чатов
- Фильтры: Непрочитанные, Пользователи, Комнаты, Избранные
- Чаты: "Rusty Bot" (1:1), "Ops" (группа)
- **Действие:** Тап → строка "Rusty Bot" (координаты: `50%,24%` — первая строка)
- **НЕ** тапать по тексту "Rusty Bot" — Maestro найдёт его внутри Ops

## Шаг 7: Экран чата 1:1
- Заголовок: "Rusty Bot"
- Справа вверху: 📞 (аудиозвонок) и 📹 (видеозвонок)
- **Действие (видеозвонок):** Тап → камера (координаты: `92%,10%`)
- **Действие (аудиозвонок):** Тап → телефон (координаты: `78%,10%`)

## Шаг 8: Экран звонка (CallScreen)
- Заголовок: "Rusty Bot" + таймер
- Статус: "Подключение к звонку..."
- Кнопки внизу: камера, микрофон, динамик, завершить (красная)
- Кнопка "Назад" (свернуть) слева
- Кнопка записи (⊙) справа

### Текущее состояние (2026-02-15):
- MatrixRTC signaling работает (event "Звонок начат" отправляется)
- **LiveKit нативное подключение НЕ устанавливается** — висит на "Подключение к звонку..."
- На вебе (Element Call) соединение проходит

---

## Maestro координаты (справочник)

| Элемент | Координаты | Метод |
|---------|-----------|-------|
| Таб "Контакты" | `10%,93%` | point |
| Таб "Звонки" | `30%,93%` | point |
| Таб "Чаты" | `50%,93%` | point |
| Таб "Приложения" | `70%,93%` | point |
| Таб "Настройки" | `90%,93%` | point |
| Кнопка "Назад" (навбар) | `7%,10%` | point |
| Аудиозвонок (в чате) | `78%,10%` | point |
| Видеозвонок (в чате) | `92%,10%` | point |
| Первый чат в списке | `50%,24%` | point |
| Второй чат в списке | `50%,34%` | point |

---

## Troubleshooting

### "User exists" при логине penny
MAS user `penny` не привязан к Keycloak upstream аккаунту.

**Решение через SSH:**
```bash
ssh root@195.58.34.43

# Проверить линк
kubectl exec -n matrix mas-postgres-9b5bdb844-xbf7j -- psql -U mas -d mas -c "
SELECT l.upstream_oauth_link_id, l.subject, l.user_id, u.username
FROM upstream_oauth_links l LEFT JOIN users u ON l.user_id = u.user_id;"

# Привязать (penny user_id = 019c3f1b-c342-b1a4-d579-45d128e20487)
kubectl exec -n matrix mas-postgres-9b5bdb844-xbf7j -- psql -U mas -d mas -c "
UPDATE upstream_oauth_links
SET user_id = '019c3f1b-c342-b1a4-d579-45d128e20487'
WHERE upstream_oauth_link_id = '019c60c7-16cb-0e17-8382-a2f6911695c8';"
```

### Сброс пароля Keycloak
```bash
ssh root@195.58.34.43

# Получить admin token
TOKEN=$(curl -s -X POST 'http://10.43.195.107:8080/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password&client_id=admin-cli&username=admin&password=admin_password_change_me' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# Сбросить пароль (penny id = 650dcc75-b45f-46de-a7f0-fa89f266e442)
curl -s -X PUT 'http://10.43.195.107:8080/admin/realms/matrix/users/650dcc75-b45f-46de-a7f0-fa89f266e442/reset-password' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"type":"password","value":"Penny2026","temporary":false}'
```

### Keycloak users (realm: matrix)
| Username | Keycloak ID |
|----------|------------|
| admin | (master realm) |
| dp.bondar | c1bf98a5-5f56-4140-9171-e4e0856ba42c |
| holly | d09b8f8d-6104-4947-ba37-7fc5af3359a7 |
| molly | 0cdb451c-c0a5-4d41-9701-c7820004e0e3 |
| ms.implica | eb2e1a8b-eb2e-49dc-82c1-5eb8c38b68d1 |
| penny | 650dcc75-b45f-46de-a7f0-fa89f266e442 |
| rusty | 8617f5e2-68ca-4926-8acf-d36a21d9d81b |
| sandy | c3d7c89b-1f65-47ea-a30a-bf165ef9f836 |
| tracy | 4403a177-f284-404e-ab00-3aa99fb972ef |
| tymbay | 2ec398ae-f4b2-4d5f-aebb-d9f09768df98 |
