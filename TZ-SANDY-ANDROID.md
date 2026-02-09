# 📱 Техническое задание: sTalk Android

**Дата**: 2026-02-10
**Заказчик**: Implica
**Разработчик**: Sandy
**Проект**: sTalk Mobile — корпоративный мессенджер на базе Matrix

---

## 🎯 Цель проекта

Разработать Android версию мобильного приложения **sTalk**, которая будет максимально соответствовать по функциональности iOS версии. Приложение должно быть основано на **Element X Android** (fork) с кастомизацией под требования sTalk.

---

## 📊 Обзор проекта

### Что такое sTalk?

**sTalk** — корпоративный мессенджер на базе протокола Matrix с расширенным функционалом:
- 5-tab навигация (Контакты, Звонки, Чаты, Приложения, Настройки)
- Telegram-style UI/UX
- Интеграция с корпоративными системами через виджеты
- Запись звонков с сохранением на сервере
- OIDC авторизация через Keycloak

### Upstream проект

**Element X Android**: https://github.com/element-hq/element-x-android
- Официальный Matrix клиент от Element (новое поколение)
- Kotlin + Jetpack Compose
- Matrix Rust SDK

### Референсная iOS версия

**Репозиторий**: https://github.com/ank1n/element-x-ios (fork)
- Все изменения задокументированы в CHANGELOG-ELEMENTX.md
- 24 функциональных изменения (#1-#24)
- SwiftUI + Matrix Rust SDK

---

## 🖥️ Серверная инфраструктура

### Production сервер

**Домен**: `stalk.implica.ru`

**Компоненты**:
- **Matrix Homeserver**: Synapse 1.x
  - Internal URL: `http://10.43.249.30:8008` (ClusterIP внутри K8s)
  - Public URL: `https://stalk.implica.ru`
- **Auth**: `auth.trackit.implica.ru`
  - Keycloak OIDC provider
  - Realm: `matrix`
  - Delegated authentication
- **Recording API**: `https://stalk.implica.ru/recording-api/*`
  - API для записи звонков (LiveKit)
  - Swagger: https://stalk.implica.ru/api-docs/recording
- **Apps/Widgets API**: `https://stalk.implica.ru/apps-api/*`
  - API для списка приложений и виджетов
  - Swagger: https://stalk.implica.ru/api-docs/apps

**Credentials**:
- **Test user**: `ankin` / `AnkinPass2026!`

### .well-known URLs

```
https://stalk.implica.ru/.well-known/matrix/client
{
  "m.homeserver": {
    "base_url": "https://stalk.implica.ru"
  },
  "m.identity_server": {
    "base_url": "https://vector.im"
  },
  "org.matrix.msc3575.proxy": {
    "url": "https://stalk.implica.ru"
  }
}
```

---

## 🎨 Дизайн и UI требования

### Общий стиль: Telegram-like

Приложение должно максимально походить на Telegram по UI/UX:

#### Tab Bar (нижняя панель)
- **5 вкладок** (слева направо):
  1. **Контакты** (Contacts) — `person` icon (SF Symbols на iOS, Material Icons на Android)
  2. **Звонки** (Calls) — `phone` icon
  3. **Чаты** (Chats) — `message` icon
  4. **Приложения** (Apps) — `square.grid.2x2` / `apps` icon
  5. **Настройки** (Settings) — `gearshape` / `settings` icon

- **Иконки**:
  - Filled (selected state) / Outline (unselected state)
  - Размер: 24dp
  - Цвет активной: `colorPrimary`
  - Цвет неактивной: `colorOnSurfaceVariant`

- **Бейджи**:
  - 🟢 **Зелёный** — непрочитанные сообщения
  - ⚫ **Серый** — muted чаты
  - 🔴 **Красный** — @mention или важные
  - Адаптивные цвета для Dark Mode

#### Navigation

- **Inline titles**: все экраны используют inline toolbar (не large titles)
- **Underline filters**: фильтры подчёркиванием (как в Telegram), не кнопками
- **Анимация**: плавные переходы между вкладками и экранами

#### Цветовая схема

- **Light Mode**:
  - Primary: `#0088CC` (Telegram blue)
  - Background: `#FFFFFF`
  - Surface: `#F5F5F5`
  - Message bubble (outgoing): `#DCF8C6` (зелёный как в Telegram/WhatsApp)

- **Dark Mode**:
  - Primary: `#8AB4F8` (lighter blue)
  - Background: `#0E0E0E`
  - Surface: `#1C1C1C`
  - Message bubble (outgoing): `#005C4B` (тёмно-зелёный)

**ВАЖНО**: Все цвета должны быть adaptive (меняться в Dark Mode). Никаких hardcoded RGB значений!

---

## 📦 Функциональные требования

Ниже приведён полный список функций из iOS версии (CHANGELOG #1-#24). Все они должны быть реализованы в Android версии.

### #1-#2: Вкладка Widgets (Приложения)

**Описание**: Третья вкладка "Приложения" показывает список виджетов/приложений комнат.

**Экраны**:
1. **WidgetsListScreen** — список комнат с виджетами
   - Отображение: аватар комнаты + название + описание
   - Источник данных: Apps API (`GET /apps-api/widgets`)
   - Тап → открывает WidgetWebView

2. **WidgetWebViewScreen** — WebView для отображения виджета
   - Полноэкранный WebView
   - URL из `widget.url`
   - Toolbar с кнопкой "Закрыть"

**API**:
```
GET https://stalk.implica.ru/apps-api/widgets
Authorization: Bearer {access_token}

Response:
{
  "widgets": [
    {
      "room_id": "!xyz:stalk.implica.ru",
      "room_name": "Проект Alpha",
      "widget_id": "widget_123",
      "name": "Трекер задач",
      "url": "https://stalk.implica.ru/widgets/tracker?room=xyz",
      "type": "m.custom"
    }
  ]
}
```

**Архитектура**:
- Используйте стандартный `NavHost` + `NavController`
- WebView: используйте `WebViewScreen` с `rememberWebViewState()`
- Не требуется split-view (список + детали), только стек экранов

---

### #3: 5-tab навигация (Контакты, Звонки, Чаты, Приложения, Настройки)

**Описание**: Переработка TabBar с 3 вкладок (Chats, Spaces, Profile) на 5 вкладок.

**Изменения**:
- **Было**: Chats, Spaces, Profile
- **Стало**: Contacts, Calls, Chats, Apps, Settings

**Mapping экранов**:
- **Contacts** → DM комнаты (isDirect = true), список контактов
- **Calls** → История звонков (CallHistory)
- **Chats** → Все комнаты (rooms)
- **Apps** → Виджеты (#1-#2)
- **Settings** → Профиль + настройки

**Технические детали**:
```kotlin
// MainActivity.kt или RootNavHost
sealed class HomeTab(val route: String, val icon: ImageVector) {
    object Contacts : HomeTab("contacts", Icons.Default.Person)
    object Calls : HomeTab("calls", Icons.Default.Phone)
    object Chats : HomeTab("chats", Icons.Default.Message)
    object Apps : HomeTab("apps", Icons.Default.Apps)
    object Settings : HomeTab("settings", Icons.Default.Settings)
}

@Composable
fun BottomNavigationBar(
    tabs: List<HomeTab>,
    currentTab: HomeTab,
    onTabSelected: (HomeTab) -> Unit
) {
    NavigationBar {
        tabs.forEach { tab ->
            NavigationBarItem(
                selected = currentTab == tab,
                onClick = { onTabSelected(tab) },
                icon = { Icon(tab.icon, contentDescription = tab.route) },
                label = { Text(stringResource(tab.titleRes)) }
            )
        }
    }
}
```

---

### #4: Запись звонков + Recording API

**Описание**: Интеграция с Recording API для записи LiveKit звонков.

**Функциональность**:
1. **Кнопка "Записать"** в call screen
2. **Старт записи**: `POST /recording-api/start`
3. **Стоп записи**: `POST /recording-api/stop`
4. **Список записей**: `GET /recording-api/recordings?room_id={room_id}`
5. **Воспроизведение**: AudioPlayer с плейлистом

**API Endpoints**:

```
POST https://stalk.implica.ru/recording-api/start
Authorization: Bearer {access_token}
Content-Type: application/json

{
  "room_id": "!xyz:stalk.implica.ru",
  "livekit_room_name": "livekit_room_123"
}

Response:
{
  "recording_id": "rec_456",
  "status": "started"
}

---

POST https://stalk.implica.ru/recording-api/stop/{recording_id}
Authorization: Bearer {access_token}

Response:
{
  "recording_id": "rec_456",
  "status": "stopped",
  "duration_seconds": 120
}

---

GET https://stalk.implica.ru/recording-api/recordings?room_id={room_id}
Authorization: Bearer {access_token}

Response:
{
  "recordings": [
    {
      "id": "rec_456",
      "room_id": "!xyz:stalk.implica.ru",
      "started_at": "2026-02-10T10:00:00Z",
      "duration_seconds": 120,
      "file_url": "https://stalk.implica.ru/recordings/rec_456.mp4"
    }
  ]
}
```

**UI компоненты**:
- **RecordButton** (красная кнопка в call screen)
- **RecordingIndicator** (пульсирующий индикатор во время записи)
- **RecordingsListScreen** (список записей комнаты)
- **AudioPlayerScreen** (плеер с интерактивным slider)

---

### #5: Унифицированные фильтры

**Описание**: Единый стиль фильтров на всех экранах (Contacts, Calls, Chats, Apps).

**Стиль**: Underline filters (как в Telegram)
- Не используйте `Chip` или `Button`
- Текст + анимированная линия снизу при выборе
- Анимация: `animateColorAsState`, `animateDpAsState`

**Пример** (Contacts):
```kotlin
@Composable
fun ContactsFilterRow(
    selectedFilter: ContactsFilter,
    onFilterSelected: (ContactsFilter) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.SpaceEvenly
    ) {
        ContactsFilter.values().forEach { filter ->
            FilterItem(
                text = stringResource(filter.titleRes),
                selected = selectedFilter == filter,
                onClick = { onFilterSelected(filter) }
            )
        }
    }
}

@Composable
fun FilterItem(
    text: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    val underlineColor by animateColorAsState(
        targetValue = if (selected) MaterialTheme.colorScheme.primary else Color.Transparent
    )

    Column(
        modifier = Modifier
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyLarge,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
        )

        Box(
            modifier = Modifier
                .width(40.dp)
                .height(2.dp)
                .background(underlineColor)
        )
    }
}
```

**Фильтры по экранам**:
- **Contacts**: Все / Только онлайн
- **Calls**: Все / Пропущенные / Исходящие / Входящие
- **Chats**: Все / Непрочитанные / Важные
- **Apps**: Все / По категориям (Tools, Fun, Productivity, etc.)

---

### #6: Stalk Tab Bar (с Lottie анимацией) — DEPRECATED

**Статус**: DEPRECATED, заменено на #20

Изначально использовались Lottie анимации для иконок табов. В #20 заменено на SF Symbols (iOS) / Material Icons (Android) filled/outline.

**Для Android**: пропустите #6, сразу реализуйте #20.

---

### #7: Telegram-style: SF Symbols, underline фильтры, зелёные бейджи

**Описание**: Первая волна Telegram-style изменений.

**Изменения**:
1. **Иконки**: Material Icons вместо кастомных drawable
2. **Фильтры**: underline стиль (#5)
3. **Бейджи**: зелёные (unread), серые (muted), красные (mention)

**Бейджи** (детали):
```kotlin
@Composable
fun ChatBadge(
    count: Int,
    isMuted: Boolean = false,
    isMention: Boolean = false
) {
    val backgroundColor = when {
        isMention -> MaterialTheme.colorScheme.error // Красный
        isMuted -> Color.Gray // Серый
        else -> Color(0xFF4CAF50) // Зелёный
    }

    Badge(
        containerColor = backgroundColor,
        contentColor = Color.White
    ) {
        Text(count.toString())
    }
}
```

---

### #8: Telegram-style: шапки и навигация

**Описание**: Переработка navigation headers и toolbars.

**Изменения**:
1. **Segmented Control** для выбора между разделами (вместо tabs)
2. **Compose FAB** (Floating Action Button) для создания нового чата
3. **Edit mode** в списках для массового выбора (swipe влево → "Изменить")

**Пример Segmented Control**:
```kotlin
@Composable
fun SegmentedControl(
    items: List<String>,
    selectedIndex: Int,
    onItemSelected: (Int) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
    ) {
        items.forEachIndexed { index, item ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clickable { onItemSelected(index) }
                    .background(
                        if (selectedIndex == index) MaterialTheme.colorScheme.primary else Color.Transparent,
                        RoundedCornerShape(8.dp)
                    )
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = item,
                    color = if (selectedIndex == index) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
```

---

### #9: Telegram-style: двойной bubble, dot-бейджи, cleanup

**Описание**: Доработки UI деталей.

**Изменения**:
1. **Двойная иконка bubble** для сообщений (отправленные / доставленные / прочитанные)
2. **Dot-бейджи** вместо чисел когда count > 99
3. **Cleanup**: удаление неиспользуемого кода

**Bubble states**:
```kotlin
enum class MessageStatus {
    SENDING,      // Одна галочка (серая)
    SENT,         // Две галочки (серые)
    DELIVERED,    // Две галочки (синие)
    READ          // Две галочки (зелёные)
}

@Composable
fun MessageStatusIcon(status: MessageStatus) {
    when (status) {
        MessageStatus.SENDING -> Icon(Icons.Default.Check, tint = Color.Gray)
        MessageStatus.SENT -> Icon(Icons.Default.DoneAll, tint = Color.Gray)
        MessageStatus.DELIVERED -> Icon(Icons.Default.DoneAll, tint = Color.Blue)
        MessageStatus.READ -> Icon(Icons.Default.DoneAll, tint = Color.Green)
    }
}
```

**Dot-бейдж**:
```kotlin
@Composable
fun DotBadge() {
    Box(
        modifier = Modifier
            .size(8.dp)
            .background(MaterialTheme.colorScheme.error, CircleShape)
    )
}
```

---

### #10: Telegram-style: алфавитный индекс, секции дат, профиль

**Описание**: Улучшения навигации и UI.

**Изменения**:
1. **Алфавитный скруббер** на экране Contacts (правый край, A-Z)
2. **Секции дат** в Calls и Chats ("Сегодня", "Вчера", "2 фев")
3. **Профиль**: chevron иконки, секции

**Алфавитный скруббер** (Contacts):
```kotlin
@Composable
fun AlphabetScrollbar(
    letters: List<Char>,
    onLetterSelected: (Char) -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .width(24.dp)
            .padding(end = 4.dp),
        verticalArrangement = Arrangement.SpaceEvenly
    ) {
        letters.forEach { letter ->
            Text(
                text = letter.toString(),
                modifier = Modifier.clickable { onLetterSelected(letter) },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary
            )
        }
    }
}
```

**Секции дат**:
```kotlin
@Composable
fun LazyColumnWithHeaders(
    items: List<ChatItem>,
    groupByDate: (ChatItem) -> String
) {
    LazyColumn {
        items
            .groupBy { groupByDate(it) }
            .forEach { (date, itemsForDate) ->
                stickyHeader {
                    Text(
                        text = date,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.surface)
                            .padding(8.dp),
                        style = MaterialTheme.typography.labelMedium
                    )
                }
                items(itemsForDate) { item ->
                    ChatItemRow(item)
                }
            }
    }
}
```

---

### #11: Swipe actions на ячейках чатов

**Описание**: Swipe влево/вправо на ячейках списка чатов.

**Actions**:
- **Swipe влево** (от правого края):
  - 🔕 **Mute** (если не muted)
  - 🔔 **Unmute** (если muted)
  - 📌 **Pin** (если не pinned)
  - 📍 **Unpin** (если pinned)
  - 🗑️ **Delete** (красная кнопка)

- **Swipe вправо** (от левого края):
  - ✅ **Mark as read** (если есть непрочитанные)

**Библиотека**: Используйте `me.saket.swipe` или встроенный `SwipeToDismiss` Compose.

**Пример**:
```kotlin
@Composable
fun SwipeableChatItem(
    chat: ChatSummary,
    onMute: () -> Unit,
    onPin: () -> Unit,
    onDelete: () -> Unit,
    onMarkRead: () -> Unit
) {
    val swipeState = rememberSwipeableActionsState()

    SwipeableActionsBox(
        state = swipeState,
        startActions = listOf(
            SwipeAction(
                icon = { Icon(Icons.Default.DoneAll, contentDescription = null) },
                background = Color.Green,
                onSwipe = onMarkRead
            )
        ),
        endActions = listOf(
            SwipeAction(
                icon = { Icon(if (chat.isMuted) Icons.Default.Notifications else Icons.Default.NotificationsOff, null) },
                background = Color.Gray,
                onSwipe = onMute
            ),
            SwipeAction(
                icon = { Icon(if (chat.isPinned) Icons.Default.PushPin else Icons.Default.PushPinOutlined, null) },
                background = Color.Blue,
                onSwipe = onPin
            ),
            SwipeAction(
                icon = { Icon(Icons.Default.Delete, null) },
                background = Color.Red,
                isDestructive = true,
                onSwipe = onDelete
            )
        )
    ) {
        ChatListItem(chat)
    }
}
```

---

### #12: Badge непрочитанных на вкладке Чаты

**Описание**: Красный бейдж с числом непрочитанных на иконке вкладки "Чаты".

**Требования**:
- Показывать только если есть непрочитанные
- Максимум 2 цифры (99+)
- Красный цвет (`MaterialTheme.colorScheme.error`)

**Код**:
```kotlin
NavigationBarItem(
    selected = currentTab == HomeTab.Chats,
    onClick = { onTabSelected(HomeTab.Chats) },
    icon = {
        BadgedBox(
            badge = {
                if (unreadCount > 0) {
                    Badge {
                        Text(if (unreadCount > 99) "99+" else unreadCount.toString())
                    }
                }
            }
        ) {
            Icon(Icons.Default.Message, contentDescription = null)
        }
    },
    label = { Text("Чаты") }
)
```

---

### #13: Недавние поисковые запросы + фикс навбара

**Описание**: История поиска + фикс видимости navigation bar.

**Функциональность**:
1. **История поиска**: Сохранение последних 10 запросов в SharedPreferences
2. **Быстрый доступ**: Показ истории при открытии поиска (до ввода текста)
3. **Удаление**: Крестик для очистки отдельного запроса

**Хранение**:
```kotlin
class SearchHistoryRepository(context: Context) {
    private val prefs = context.getSharedPreferences("search_history", Context.MODE_PRIVATE)

    fun addQuery(query: String) {
        val history = getHistory().toMutableList()
        history.remove(query) // Удалить дубликат
        history.add(0, query) // Добавить в начало
        if (history.size > 10) history.removeLast()

        prefs.edit().putStringSet("queries", history.toSet()).apply()
    }

    fun getHistory(): List<String> {
        return prefs.getStringSet("queries", emptySet())?.toList() ?: emptyList()
    }

    fun removeQuery(query: String) {
        val history = getHistory().toMutableList()
        history.remove(query)
        prefs.edit().putStringSet("queries", history.toSet()).apply()
    }

    fun clearAll() {
        prefs.edit().remove("queries").apply()
    }
}
```

**UI**:
```kotlin
@Composable
fun SearchHistoryList(
    queries: List<String>,
    onQueryClick: (String) -> Unit,
    onRemoveClick: (String) -> Unit
) {
    LazyColumn {
        items(queries) { query ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onQueryClick(query) }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.History, contentDescription = null)
                    Spacer(Modifier.width(12.dp))
                    Text(query)
                }

                IconButton(onClick = { onRemoveClick(query) }) {
                    Icon(Icons.Default.Close, contentDescription = "Удалить")
                }
            }
        }
    }
}
```

---

### #14: Интерактивный slider для плеера записей

**Описание**: Audio player с seek bar для воспроизведения записей звонков.

**Требования**:
- Перемотка перетаскиванием slider
- Отображение текущего времени / общей длительности
- Pause/Play кнопка
- Скорость воспроизведения (1.0x, 1.5x, 2.0x)

**UI**:
```kotlin
@Composable
fun RecordingPlayer(
    recording: Recording,
    playerState: PlayerState
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
    ) {
        // Название и дата
        Text(recording.title, style = MaterialTheme.typography.titleMedium)
        Text(recording.date, style = MaterialTheme.typography.bodySmall)

        Spacer(Modifier.height(16.dp))

        // Slider
        Slider(
            value = playerState.currentPosition.toFloat(),
            onValueChange = { playerState.seekTo(it.toLong()) },
            valueRange = 0f..playerState.duration.toFloat(),
            modifier = Modifier.fillMaxWidth()
        )

        // Время
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(formatTime(playerState.currentPosition))
            Text(formatTime(playerState.duration))
        }

        Spacer(Modifier.height(16.dp))

        // Контроллы
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly
        ) {
            // Назад 15 сек
            IconButton(onClick = { playerState.seekBackward(15000) }) {
                Icon(Icons.Default.Replay15, null)
            }

            // Play/Pause
            IconButton(onClick = { playerState.togglePlayPause() }) {
                Icon(
                    if (playerState.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                    null
                )
            }

            // Вперёд 15 сек
            IconButton(onClick = { playerState.seekForward(15000) }) {
                Icon(Icons.Default.Forward15, null)
            }

            // Скорость
            TextButton(onClick = { playerState.cyclePlaybackSpeed() }) {
                Text("${playerState.playbackSpeed}x")
            }
        }
    }
}

fun formatTime(millis: Long): String {
    val seconds = millis / 1000
    return String.format("%02d:%02d", seconds / 60, seconds % 60)
}
```

**Media Player**: Используйте `ExoPlayer` или `MediaPlayer`.

---

### #15: Алфавитный скруббер на экране Контакты

**Описание**: См. #10. Вертикальный скруббер A-Z на правом краю экрана Contacts.

**Детали**:
- Отображать только если контактов > 20
- При тапе на букву → скролл к первому контакту с этой буквой
- Визуальный feedback: увеличение буквы + haptic vibration

**Haptic feedback**:
```kotlin
val haptic = LocalHapticFeedback.current

fun onLetterTap(letter: Char) {
    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    scrollToLetter(letter)
}
```

---

### #16: Кнопки редактирования профиля, секции настроек, анимация фильтров

**Описание**: Улучшения экрана Settings (Profile).

**Изменения**:
1. **Кнопки в профиле**:
   - "Изменить фото" (над аватаркой)
   - "Изменить имя" (рядом с именем)

2. **Секции настроек** с заголовками:
   - **Аккаунт**: имя, email, телефон
   - **Приватность**: шифрование, резервные копии
   - **Уведомления**: звук, vibration, preview
   - **Внешний вид**: тема (Light/Dark/Auto), размер шрифта
   - **Чаты**: архив, блокировка

3. **Анимация фильтров**: плавная анимация подчёркивания при переключении (#5)

**UI секций**:
```kotlin
@Composable
fun SettingsSection(
    title: String,
    content: @Composable () -> Unit
) {
    Column {
        Text(
            text = title,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary
        )

        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp)
        ) {
            content()
        }
    }
}

// Использование:
SettingsSection("Аккаунт") {
    SettingsItem("Имя", value = "John Doe", onClick = { /* Edit */ })
    SettingsItem("Email", value = "john@example.com", onClick = { /* Edit */ })
}
```

---

### #17: Фильтрация приложений по категориям

**Описание**: На экране Apps (Widgets) добавить фильтры по категориям.

**Категории**:
- Все
- Инструменты (Tools)
- Развлечения (Fun)
- Продуктивность (Productivity)
- Другое (Other)

**API**:
```
GET /apps-api/widgets?category=tools
```

**UI**: Используйте underline filters (#5) горизонтально scrollable:
```kotlin
LazyRow {
    items(categories) { category ->
        FilterItem(
            text = category.name,
            selected = selectedCategory == category,
            onClick = { onCategorySelected(category) }
        )
    }
}
```

---

### #18: Dark Mode аудит — adaptive цвета

**Описание**: Убрать все hardcoded RGB цвета, заменить на `MaterialTheme.colorScheme.*`.

**Запрещено**:
```kotlin
// ❌ ПЛОХО
val background = Color(0xFFFFFFFF)
val text = Color.Black
```

**Правильно**:
```kotlin
// ✅ ХОРОШО
val background = MaterialTheme.colorScheme.background
val text = MaterialTheme.colorScheme.onBackground
```

**Проверка**: Переключение Dark/Light mode не должно ломать UI или делать элементы невидимыми.

---

### #19: Миграция на stalk.implica.ru — динамические URL

**Описание**: Все URL (Recording API, Widgets API) должны браться из `clientProxy.homeserver`, а не быть hardcoded.

**Было**:
```kotlin
const val RECORDING_API_URL = "https://market.implica.ru/recording-api"
```

**Стало**:
```kotlin
class ApiConfig(clientProxy: ClientProxy) {
    val recordingApiUrl = "${clientProxy.homeserver}/recording-api"
    val appsApiUrl = "${clientProxy.homeserver}/apps-api"
}
```

**Почему**: Сервер может измениться (market.implica.ru → stalk.implica.ru), приложение должно работать без пересборки.

---

### #20: Telegram-style Tab Bar — Material Icons filled/outline, зелёные бабблы

**Описание**: Финальная версия Tab Bar с Material Icons и зелёными пузырями сообщений.

**Изменения**:
1. **Иконки вкладок**:
   - **Filled** (selected): `Icons.Filled.*`
   - **Outline** (unselected): `Icons.Outlined.*`

2. **Зелёные пузыри** для исходящих сообщений:
   - Light mode: `#DCF8C6`
   - Dark mode: `#005C4B`

**Код иконок**:
```kotlin
sealed class HomeTab(
    val route: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
    val label: String
) {
    object Contacts : HomeTab(
        "contacts",
        Icons.Filled.Person,
        Icons.Outlined.Person,
        "Контакты"
    )

    object Calls : HomeTab(
        "calls",
        Icons.Filled.Phone,
        Icons.Outlined.Phone,
        "Звонки"
    )

    // и т.д.
}
```

**Message bubble**:
```kotlin
@Composable
fun MessageBubble(
    message: String,
    isOutgoing: Boolean
) {
    val backgroundColor = if (isOutgoing) {
        if (isSystemInDarkTheme()) Color(0xFF005C4B) else Color(0xFFDCF8C6)
    } else {
        MaterialTheme.colorScheme.surfaceVariant
    }

    Box(
        modifier = Modifier
            .background(backgroundColor, RoundedCornerShape(12.dp))
            .padding(12.dp)
    ) {
        Text(message)
    }
}
```

---

### #21: Inline titles на всех экранах (убраны large titles)

**Описание**: Все экраны используют `TopAppBar` с inline title, без `LargeTopAppBar`.

**Было**:
```kotlin
LargeTopAppBar(title = { Text("Чаты") })
```

**Стало**:
```kotlin
TopAppBar(
    title = { Text("Чаты") },
    colors = TopAppBarDefaults.topAppBarColors(
        containerColor = MaterialTheme.colorScheme.surface
    )
)
```

**Причина**: Telegram не использует large titles, все заголовки inline.

---

### #22: Навигация контакт → чат (как в Telegram)

**Описание**: При тапе на контакт → открывается чат с этим контактом. Кнопка "Назад" возвращает в список контактов (не в список чатов).

**Навигация**:
```
ContactsScreen -> ContactDetailsScreen -> ChatScreen
                                              ↑
                                         (Back button)
                                              ↓
                                       ContactsScreen
```

**Реализация**:
```kotlin
// ContactsScreen
LazyColumn {
    items(contacts) { contact ->
        ContactItem(
            contact = contact,
            onClick = {
                navController.navigate("chat/${contact.roomId}") {
                    // Важно: не использовать popUpTo, чтобы сохранить стек
                }
            }
        )
    }
}

// ChatScreen
BackHandler {
    navController.popBackStack() // Вернёт в Contacts, не в Chats
}
```

---

### #23: Фильтр пустых комнат в контактах — только реальные люди

**Описание**: В списке Contacts показывать только реальных людей (DM комнаты с 2+ участниками), исключить пустые комнаты.

**Фильтры**:
```kotlin
fun filterRealContacts(rooms: List<RoomSummary>): List<RoomSummary> {
    return rooms.filter { room ->
        room.isDirect && // Только DM
        room.activeMembersCount >= 2 && // 2+ участника (я + собеседник)
        !room.name.startsWith("Empty Room") // Не пустая комната
    }
}
```

**Дополнительно**: Отображать аватар контакта из `room.avatarURL`.

---

### #24: Поиск сообщений внутри чата (как в Telegram)

**Описание**: Inline search bar внутри экрана чата для поиска сообщений.

**Функциональность**:
1. ~~**Кнопка поиска** 🔍 в toolbar~~ **НЕТ** (как в Telegram - только через Room Details)
2. **Inline search bar** появляется сверху при активации из Room Details
3. **TextField** для ввода запроса
4. **Счётчик результатов**: "X/Y"
5. **Кнопки навигации**: ↑↓ для перемещения между результатами
6. **Кнопка закрытия**: ✖️

**UI**:
```kotlin
@Composable
fun ChatScreen(
    roomId: String,
    viewModel: ChatViewModel
) {
    val searchActive by viewModel.searchActive.collectAsState()
    val searchQuery by viewModel.searchQuery.collectAsState()
    val searchResults by viewModel.searchResults.collectAsState()

    Scaffold(
        topBar = {
            Column {
                TopAppBar(
                    title = { Text(viewModel.roomName) },
                    actions = {
                        // Только кнопка звонка
                        // Поиск доступен через Room Details (как в Telegram)
                        IconButton(onClick = { viewModel.startCall() }) {
                            Icon(Icons.Default.VideoCall, contentDescription = "Звонок")
                        }
                    }
                )

                // Search bar (появляется при searchActive = true)
                AnimatedVisibility(visible = searchActive) {
                    SearchBar(
                        query = searchQuery,
                        onQueryChange = { viewModel.updateSearchQuery(it) },
                        resultCount = searchResults.size,
                        currentIndex = viewModel.currentSearchIndex,
                        onPrevious = { viewModel.searchPrevious() },
                        onNext = { viewModel.searchNext() },
                        onDismiss = { viewModel.toggleSearch() }
                    )
                }
            }
        }
    ) { padding ->
        // Timeline/Messages list
        MessagesList(
            messages = viewModel.messages,
            highlightedMessageId = searchResults.getOrNull(viewModel.currentSearchIndex),
            modifier = Modifier.padding(padding)
        )
    }
}

@Composable
fun SearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    resultCount: Int,
    currentIndex: Int,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onDismiss: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(Icons.Default.Search, contentDescription = null)

        Spacer(Modifier.width(8.dp))

        TextField(
            value = query,
            onValueChange = onQueryChange,
            modifier = Modifier.weight(1f),
            placeholder = { Text("Поиск") },
            singleLine = true
        )

        if (query.isNotEmpty()) {
            Text(
                text = if (resultCount > 0) "${currentIndex + 1}/$resultCount" else "0/0",
                style = MaterialTheme.typography.bodySmall
            )

            IconButton(
                onClick = onPrevious,
                enabled = resultCount > 0
            ) {
                Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Предыдущий")
            }

            IconButton(
                onClick = onNext,
                enabled = resultCount > 0
            ) {
                Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Следующий")
            }
        }

        IconButton(onClick = onDismiss) {
            Icon(Icons.Default.Close, contentDescription = "Закрыть")
        }
    }
}
```

**ViewModel**:
```kotlin
class ChatViewModel : ViewModel() {
    private val _searchActive = MutableStateFlow(false)
    val searchActive = _searchActive.asStateFlow()

    private val _searchQuery = MutableStateFlow("")
    val searchQuery = _searchQuery.asStateFlow()

    private val _searchResults = MutableStateFlow<List<String>>(emptyList())
    val searchResults = _searchResults.asStateFlow()

    var currentSearchIndex = 0
        private set

    fun toggleSearch() {
        _searchActive.value = !_searchActive.value
        if (!_searchActive.value) {
            _searchQuery.value = ""
            _searchResults.value = emptyList()
            currentSearchIndex = 0
        }
    }

    fun updateSearchQuery(query: String) {
        _searchQuery.value = query
        performSearch(query)
    }

    private fun performSearch(query: String) {
        if (query.isEmpty()) {
            _searchResults.value = emptyList()
            return
        }

        viewModelScope.launch {
            // Поиск по загруженным сообщениям
            val results = timelineItems
                .filter { it.body.contains(query, ignoreCase = true) }
                .map { it.eventId }

            _searchResults.value = results
            currentSearchIndex = if (results.isNotEmpty()) results.size - 1 else 0

            // Скролл к последнему найденному (самый новый)
            results.lastOrNull()?.let { focusOnEvent(it) }
        }
    }

    fun searchPrevious() {
        if (searchResults.value.isEmpty()) return
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.value.size) % searchResults.value.size
        focusOnEvent(searchResults.value[currentSearchIndex])
    }

    fun searchNext() {
        if (searchResults.value.isEmpty()) return
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.value.size
        focusOnEvent(searchResults.value[currentSearchIndex])
    }

    private fun focusOnEvent(eventId: String) {
        // Скролл к сообщению + highlight
        // Используйте LazyListState.scrollToItem()
    }
}
```

**Детали**:
- **Debounce 300ms**: добавьте `.debounce(300)` к `_searchQuery` flow
- **Highlight**: найденное сообщение подсвечивается (background color change)
- **Клиентский поиск**: только по уже загруженным сообщениям в timeline

**Дополнительно** (опционально, если есть время):
- Кнопка "Поиск" в Room Details shortcuts (открывает чат с активным поиском)

---

## 🔐 Авторизация

### OIDC через Keycloak

**Поток**:
1. Пользователь вводит homeserver: `stalk.implica.ru`
2. Приложение делает `GET /.well-known/matrix/client`
3. Получает OIDC issuer из delegated authentication
4. Открывает WebView с Keycloak auth URL
5. Пользователь логинится (username/password)
6. Keycloak редиректит обратно с `code`
7. Приложение обменивает `code` на `access_token`
8. Сохраняет сессию

**Библиотеки**:
- AppAuth for Android: https://github.com/openid/AppAuth-Android
- Matrix Auth SDK (если поддерживает OIDC)

**Важно**:
- **НЕ** используйте hardcoded homeserver URL
- Пользователь должен иметь возможность ввести любой Matrix homeserver
- Но по умолчанию показывайте `stalk.implica.ru`

---

## 📐 Архитектура приложения

### Общая структура

```
app/
├── src/main/kotlin/
│   ├── features/
│   │   ├── contacts/
│   │   │   ├── ContactsScreen.kt
│   │   │   ├── ContactsViewModel.kt
│   │   │   └── ContactsRepository.kt
│   │   ├── calls/
│   │   │   ├── CallsScreen.kt
│   │   │   ├── CallsViewModel.kt
│   │   │   └── CallHistoryRepository.kt
│   │   ├── chats/
│   │   │   ├── ChatsScreen.kt
│   │   │   ├── ChatScreen.kt (Timeline)
│   │   │   ├── ChatsViewModel.kt
│   │   │   └── ChatViewModel.kt
│   │   ├── apps/
│   │   │   ├── AppsScreen.kt (WidgetsList)
│   │   │   ├── WidgetWebViewScreen.kt
│   │   │   └── AppsViewModel.kt
│   │   ├── settings/
│   │   │   ├── SettingsScreen.kt
│   │   │   ├── ProfileScreen.kt
│   │   │   └── SettingsViewModel.kt
│   │   └── recordings/
│   │       ├── RecordingsListScreen.kt
│   │       ├── RecordingPlayerScreen.kt
│   │       └── RecordingsViewModel.kt
│   ├── core/
│   │   ├── network/
│   │   │   ├── RecordingApiService.kt
│   │   │   ├── AppsApiService.kt
│   │   │   └── MatrixClientProvider.kt
│   │   ├── auth/
│   │   │   ├── OIDCAuthManager.kt
│   │   │   └── SessionManager.kt
│   │   └── ui/
│   │       ├── components/
│   │       │   ├── FilterRow.kt
│   │       │   ├── SearchBar.kt
│   │       │   ├── MessageBubble.kt
│   │       │   └── SwipeableChatItem.kt
│   │       └── theme/
│   │           ├── Color.kt
│   │           ├── Theme.kt
│   │           └── Type.kt
│   └── MainActivity.kt
```

### Паттерны

- **MVVM**: ViewModel + StateFlow для reactive UI
- **Clean Architecture**: Repository pattern для data layer
- **Single Activity**: Navigation Compose
- **Dependency Injection**: Hilt или Koin

---

## 🛠️ Технологический стек

### Обязательные библиотеки

- **UI**: Jetpack Compose
- **Navigation**: Navigation Compose
- **DI**: Hilt (рекомендуется) или Koin
- **Networking**: Retrofit + OkHttp
- **Matrix SDK**: Matrix Rust SDK for Android (или Element Android SDK)
- **Auth**: AppAuth for Android
- **Image loading**: Coil
- **WebView**: WebView Compose
- **Audio**: ExoPlayer
- **Swipe actions**: me.saket.swipe или встроенный SwipeToDismiss
- **Persistence**: Room (для локального кэша) + DataStore (для настроек)

### Рекомендуемые

- **JSON**: kotlinx.serialization или Moshi
- **Date/Time**: java.time (API 26+) или ThreeTenABP
- **Logging**: Timber
- **Testing**: JUnit, Mockk, Compose UI Test

---

## 📋 Приоритеты разработки

### Фаза 1: MVP (Core функциональность)
**Срок**: 2-3 недели

1. ✅ 5-tab навигация (#3)
2. ✅ OIDC авторизация
3. ✅ Список чатов (Chats tab)
4. ✅ Timeline/Chat screen
5. ✅ Telegram-style UI (#20, #21)
   - Inline titles
   - Material Icons filled/outline
   - Зелёные message bubbles
6. ✅ Базовый профиль (Settings tab)

### Фаза 2: Контакты и звонки
**Срок**: 1-2 недели

7. ✅ Contacts screen (#22, #23)
   - Фильтр реальных контактов
   - Навигация контакт → чат
8. ✅ Calls screen (история звонков)
9. ✅ Recording API integration (#4)
10. ✅ Audio player с интерактивным slider (#14)

### Фаза 3: Виджеты и улучшения UI
**Срок**: 1-2 недели

11. ✅ Apps tab (Widgets) (#1-#2)
12. ✅ Фильтры по категориям (#17)
13. ✅ Underline filters на всех экранах (#5, #7)
14. ✅ Swipe actions (#11)
15. ✅ Алфавитный скруббер (#15)

### Фаза 4: Полировка и advanced функции
**Срок**: 1-2 недели

16. ✅ Поиск внутри чата (#24)
17. ✅ История поиска (#13)
18. ✅ Badge на вкладке Чаты (#12)
19. ✅ Dark Mode аудит (#18)
20. ✅ Секции дат (#10)
21. ✅ Настройки с секциями (#16)

---

## ✅ Чеклист перед релизом

### Функциональность
- [ ] Все 5 вкладок работают
- [ ] OIDC авторизация успешна
- [ ] Отправка/получение сообщений
- [ ] Звонки через LiveKit
- [ ] Запись звонков (Recording API)
- [ ] Виджеты открываются в WebView
- [ ] Поиск внутри чата работает
- [ ] Swipe actions на чатах
- [ ] Фильтры на всех экранах

### UI/UX
- [ ] Dark Mode работает корректно (adaptive цвета)
- [ ] Иконки вкладок меняются (filled/outline)
- [ ] Зелёные пузыри сообщений (исходящие)
- [ ] Underline фильтры с анимацией
- [ ] Inline titles на всех экранах
- [ ] Бейджи (зелёные/серые/красные) отображаются
- [ ] Алфавитный скруббер на Contacts

### Производительность
- [ ] Нет лагов при скролле списков
- [ ] Изображения загружаются асинхронно (Coil)
- [ ] Debounce на поиске (300ms)
- [ ] LazyColumn для всех списков

### Безопасность
- [ ] End-to-end шифрование работает
- [ ] Access token хранится в EncryptedSharedPreferences
- [ ] WebView не выполняет произвольный JavaScript

### Совместимость
- [ ] Минимальная API 26 (Android 8.0)
- [ ] Целевая API 34 (Android 14)
- [ ] Поддержка планшетов (адаптивный layout)

---

## 📚 Ресурсы и документация

### Официальная документация

- **Element X Android**: https://github.com/element-hq/element-x-android
- **Matrix Client-Server API**: https://spec.matrix.org/latest/client-server-api/
- **Matrix Rust SDK**: https://github.com/matrix-org/matrix-rust-sdk
- **Jetpack Compose**: https://developer.android.com/jetpack/compose
- **Material 3**: https://m3.material.io/

### sTalk документация

- **iOS CHANGELOG**: `/Users/ankin/Documents/element-x-fork/CHANGELOG-ELEMENTX.md`
- **Swagger Recording API**: https://stalk.implica.ru/api-docs/recording
- **Swagger Apps API**: https://stalk.implica.ru/api-docs/apps
- **Penny Memory**: `/Users/ankin/.claude/projects/-Users-ankin-Documents-element-x-fork/memory/`

### Референсы

- **Telegram Android**: https://github.com/DrKLO/Telegram (для UI вдохновения)
- **WhatsApp**: Для референса зелёных пузырей и UX

---

## 🤝 Координация с iOS разработкой

### Синхронизация

- **iOS версия**: Penny (@Penny)
- **Репозиторий iOS**: https://github.com/ank1n/element-x-ios
- **Ветка iOS**: `develop`

### Правила

1. **Паритет функций**: Android должен иметь те же функции что и iOS
2. **Согласование API**: Любые изменения в Recording API или Apps API обсуждать заранее
3. **Дизайн**: Следовать iOS дизайну (Telegram-style), но адаптировать под Material Design
4. **Релизы**: Синхронизировать версии iOS и Android

### Коммуникация

- **Matrix #ops chat**: `!CwWGwdwgnXGNIzElHm:stalk.implica.ru`
- **Формат сообщений**: `[Sandy] Type/Level: текст`
  - Type: Task, Done, Alert, Info, Question
  - Level: CRIT, HIGH, INFO

**Пример**:
```
[Sandy] Task/INFO: Начинаю работу над #3 (5-tab navigation)
[Sandy] Done/INFO: Завершила #3, создала PR https://github.com/.../pull/1
[Sandy] Question/HIGH: Какой endpoint использовать для списка виджетов?
```

---

## 📞 Контакты

**Заказчик**: Implica
**PM**: Ankin (ankin@implica.ru)
**iOS Dev**: Penny (bot)
**Android Dev**: Sandy (вы!)

**Вопросы по API**: Задавать в #ops chat или напрямую Ankin
**Вопросы по дизайну**: Сверяться с iOS версией (скриншоты можно запросить у Penny)

---

## 🎯 Цель

Создать Android версию sTalk, которая будет **максимально идентична** iOS версии по функциональности и дизайну, но адаптирована под платформу Android (Material Design, Android UX паттерны).

**Успех проекта** = Feature parity с iOS + Качественная реализация Material Design + Стабильная работа на всех Android устройствах.

---

**Удачи, Sandy! 🚀**

Если возникнут вопросы — пиши в #ops chat. Penny и Ankin помогут!
