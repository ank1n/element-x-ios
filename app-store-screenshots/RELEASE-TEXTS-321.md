# App Store — тексты релиза (sTalk, build 321)

Копипастить в App Store Connect → App Store → версия. Лимиты Apple в скобках.
Покрывает накопленное с версии, которая сейчас живёт в сторе (**26.20.07**, выложена 27.07.2026)
до build 321 от 04.08.2026 — 174 коммита.

---

## ⚠️ СНАЧАЛА РЕШИ: какой номер версии

В сторе сейчас **26.20.07**. В нашем IPA (build 321) стоит `CFBundleShortVersionString = 26.04.11`.
Строки не совпадают, и «26.04.11» **меньше** «26.20.07» — как номер публичной версии он не пройдёт.

Проверила: значений `26.20.07` и `26.12.07` в проекте не было никогда, ни в одной ветке.
То есть номер, который видно в сторе, ставится отдельно от того, что лежит в сборке.

**Нужно от тебя:** сказать номер новой версии (например `26.20.08`). Если App Store Connect
потребует, чтобы он совпадал с номером в сборке, — бампну `MARKETING_VERSION` и пересоберу
как 322, это десять минут.

---

## ⭐ ОБЯЗАТЕЛЬНОЕ для этой версии

### What's New in This Version / Что нового (≤4000)

**RU:**
```
sTalk стал умнее и удобнее: в нём появились ИИ-помощник и собственное хранилище файлов.

Айлок — ИИ-помощник
Новый раздел во вкладке «Приложения». Задаёте вопрос — ответ печатается на глазах и сразу с оформлением: заголовки, списки, цитаты, блоки кода; генерацию можно остановить кнопкой. История бесед с поиском и разбивкой по датам — легко вернуться к старому разговору. К вопросу можно приложить фото из галереи или файл с «Диска», а сам вопрос продиктовать голосом и поправить перед отправкой. Ответ помощника долгим нажатием копируется или сохраняется на «Диск».

Диск — все файлы в одном месте
Файлы из ваших чатов собраны в один список: разделы по типам, счётчики, поиск по названию, вид списком или карточками с превью. Есть режим «по папкам», где чаты видны как папки, и раздел «Доступно мне» — файлы, которыми с вами поделились, с владельцем и правом доступа. Файл открывается одним тапом, долгим нажатием — «найти в чате», «переслать», «поделиться». Теперь на Диск попадают и файлы, отправленные с айфона.

Файлы и встречи прямо в переписке
Сообщение «поделился файлом» приходит карточкой с именем, размером и уровнем доступа — файл открывается по нажатию. Ссылка на встречу превращается в карточку с названием, временем, организатором и кнопкой «Присоединиться».

Звонки — как обычный телефон
Свернули приложение во время видеозвонка — разговор продолжается в маленьком плавающем окне, и вас по-прежнему видно собеседнику. Звонком можно управлять с экрана блокировки и из «Динамического острова»; в «Недавних» видны имя собеседника, тип и длительность, и оттуда можно перезвонить, в том числе в групповой звонок. История звонков без дублей, разговор восстанавливается за секунды при переходе с Wi-Fi на мобильную сеть, а видео доходит надёжнее — включая тех, кто звонит из браузера или зашёл в звонок раньше вас.

Уведомления
О групповом звонке приходит понятное «Иван начал звонок» с названием чата. Уведомления о сообщениях больше не пустые: видно, кто и в каком чате написал, нажатие открывает нужный чат. Работают и сразу после перезагрузки телефона.

А ещё: у приложений — настоящие цветные логотипы, а плитка «Календарь» показывает сегодняшнюю дату.
```

**EN:**
```
sTalk is smarter and more useful: it now has an AI assistant and file storage of its own.

Ailock — your AI assistant
A new section on the Apps tab. Ask a question and the answer types out in front of you, already formatted: headings, lists, quotes, code blocks — and you can stop it at any moment. Past conversations are kept in a searchable history grouped by date, so you can pick up where you left off. Attach a photo from your library or a file from Drive, or dictate a question by voice and edit it before sending. Long-press an answer to copy it or save it to Drive.

Drive — every file in one place
Files from your chats gathered into a single list: sections by type, counters, search by name, list or card view with image previews. There is a folder mode where chats appear as folders, and a "Shared with me" section showing the owner and your access level. Tap a file to open it; long-press for "find in chat", "forward" or "share". Files sent from your iPhone now land on Drive too.

Files and meetings right in the conversation
A "shared a file" message now arrives as a card with the name, size and access level, and opens with a tap. A meeting link turns into a card with the title, time, organiser and a Join button.

Calls that behave like phone calls
Minimise the app during a video call and the conversation continues in a small floating window — and the other side still sees you. Control the call from the Lock Screen and Dynamic Island; Recents shows the person's name, the call type and the duration, and you can call back from there, group calls included. No duplicate entries in call history, calls recover within seconds when you switch from Wi-Fi to mobile data, and video arrives more reliably — including from people calling from the browser or who joined before you.

Notifications
Group calls now announce themselves clearly: "Ivan started a call" with the chat name. Message notifications are no longer empty — you can see who wrote and in which chat, and tapping opens that chat. They also work right after the phone restarts.

Also: apps now show their real colour logos, and the Calendar tile shows today's date.
```

### App Review Information (для ревьюера Apple) — КРИТИЧНО
Приложение требует вход — без демо-аккаунта ревьюер не зайдёт и реджектнет.
- **Sign-in required:** Yes
- **Demo account — User name:** `penny`
- **Demo account — Password:** `Penny2026`
- ⚠️ **Проверить руками перед сабмитом**, что этот вход ещё работает.
- **Notes (Review Notes):**
```
Sign in with the demo account above. On the login screen the server
"stalk.implica.ru" is preselected — just tap Sign In and enter the
credentials. The app is a secure team messenger (chats, calls, meetings,
file storage and an AI assistant on the Apps tab).
```

---

## Метаданные листинга

Подзаголовок можно оставить прежним. Промо-текст, ключевые слова и описание
стоит обновить — в приложении появились два больших раздела, которых в них нет.

### Subtitle / Подзаголовок (≤30) — БЕЗ ИЗМЕНЕНИЙ
- RU: `Защищённые чаты и звонки`
- EN: `Secure chats & calls`

### Promotional Text / Промо-текст (≤170, меняется без ревью) — ОБНОВИТЬ
- RU: `Корпоративный мессенджер с E2EE-шифрованием: чаты, звонки и встречи. Теперь ещё ИИ-помощник и Диск — все файлы команды в одном месте.`
- EN: `Secure team messenger with end-to-end encryption: chats, calls and meetings. Now with an AI assistant and Drive — all your team's files in one place.`

### Keywords / Ключевые слова (≤100, через запятую без пробелов) — ОБНОВИТЬ
- RU: `мессенджер,чаты,звонки,шифрование,e2ee,встречи,календарь,ии,помощник,файлы,диск,команда`
- EN: `messenger,chat,calls,encryption,e2ee,meetings,calendar,ai,assistant,files,drive,team,privacy`

### Description / Описание (≤4000) — ОБНОВИТЬ

**RU:**
```
sTalk — защищённый мессенджер для команд и компаний со сквозным (E2EE) шифрованием.

ВОЗМОЖНОСТИ
• Личные и групповые чаты со сквозным шифрованием
• Аудио- и видеозвонки, групповые звонки
• Встречи и календарь — планируйте и присоединяйтесь в один тап
• Диск — все файлы команды в одном месте, с поиском и превью
• ИИ-помощник Айлок — ответы, работа с файлами и голосовой ввод
• История звонков с удобными фильтрами
• Контакты и присутствие в сети
• Приложения и виджеты внутри мессенджера

БЕЗОПАСНОСТЬ
• Сквозное шифрование переписки и звонков
• Резервная копия ключей шифрования
• Ваши сообщения видите только вы и собеседник

sTalk построен на открытом протоколе Matrix.
```

**EN:**
```
sTalk is a secure messenger for teams and companies with end-to-end (E2EE) encryption.

FEATURES
• Direct and group chats with end-to-end encryption
• Audio and video calls, group calls
• Meetings and calendar — schedule and join in one tap
• Drive — all your team's files in one place, with search and previews
• Ailock, the AI assistant — answers, file handling and voice input
• Call history with handy filters
• Contacts and online presence
• Apps and widgets inside the messenger

SECURITY
• End-to-end encryption for messages and calls
• Encryption key backup
• Only you and your contact can read your messages

sTalk is built on the open Matrix protocol.
```

---

## Скриншоты

Текущий набор в сторе — из `asc-final/PUBLISH-206/` (июнь, build 206), по 5 штук на
6.5" и 6.9". Айлока и Диска на них нет: обоих разделов тогда не существовало.

Формально менять не обязательно — Apple примет и старые. Но релиз продаёт именно
эти два раздела, и на витрине их не видно. Если решишь обновить, я сниму на симуляторе
два новых кадра (Айлок с ответом и Диск с превью) и вставлю в набор тем же оформлением.

---

## Прочее (проверить, обычно уже заполнено)
- **Support URL:** https://stalk.implica.ru
- **Marketing URL:** https://stalk.implica.ru
- **Privacy Policy URL:** как в прошлом сабмите
- **Category:** Business / Social Networking
- **Age Rating:** как было
- **Version Release:** Manual — сам нажмёшь Release после одобрения

## Чеклист перед отправкой
- [ ] Решён номер версии (см. блок в начале)
- [ ] Демо-вход `penny` / `Penny2026` проверен руками
- [ ] Build 321 доставлен через Transporter и обработан в ASC
- [ ] «Что нового» вставлено в RU и EN локали
- [ ] Промо-текст, ключевые слова и описание обновлены
- [ ] Решено, обновляем ли скриншоты
