# 📋 Element X - План изменений и коммиты

Этот файл содержит все функциональные изменения, внесённые в Element X iOS, с ссылками на коммиты для применения изменений при обновлении исходников Element X.

---

## 🎯 Общая информация

**Проект**: Element X iOS
**Репозиторий**: /Users/ankin/Documents/element-x-fork/ios
**Ветка**: develop

---

## 📦 Изменения функционала

### 1. ✅ Добавлена вкладка Widgets в TabBar

**Дата**: 2026-01-28
**Коммиты**: `21dd96e`, `68a68b4`, `1deb412`

#### Описание:
Добавлена новая вкладка "Виджеты" (Widgets) в нижний TabBar приложения. Вкладка показывает список комнат с виджетами и позволяет открывать виджеты в WebView.

#### Функциональность:
- 🧩 Третья вкладка в TabBar между Spaces и Profile
- 📱 Список комнат с виджетами
- 🌐 WebView для отображения виджетов
- ✨ Иконки: extensions / extensionsSolid
- 🔧 NavigationStackCoordinator (не требует split-view)

#### Созданные файлы (9 новых файлов):

1. **ElementX/Sources/FlowCoordinators/WidgetsTabFlowCoordinator.swift**
   - Главный координатор для вкладки Widgets
   - Управляет навигацией и потоком экранов

2. **ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenCoordinator.swift**
   - Координатор экрана списка виджетов
   - Обрабатывает навигацию к WebView

3. **ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenModels.swift**
   - Модели данных для списка виджетов
   - State, ViewState, ViewActions

4. **ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenViewModel.swift**
   - ViewModel для списка виджетов
   - Загрузка данных о комнатах и виджетах

5. **ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreen.swift**
   - SwiftUI View для списка виджетов
   - Отображение комнат с аватарами и названиями

6. **ElementX/Sources/Screens/WidgetWebViewScreen/WidgetWebViewScreenCoordinator.swift**
   - Координатор для WebView виджета

7. **ElementX/Sources/Screens/WidgetWebViewScreen/WidgetWebViewScreenModels.swift**
   - Модели данных для WebView экрана

8. **ElementX/Sources/Screens/WidgetWebViewScreen/WidgetWebViewScreenViewModel.swift**
   - ViewModel для WebView
   - Управление URL и загрузкой

9. **ElementX/Sources/Screens/WidgetWebViewScreen/WidgetWebViewScreen.swift**
   - SwiftUI View с WKWebView
   - Отображение виджета в браузере

#### Изменённые файлы:

**ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift**:
```swift
// Строка 23 - Добавлен widgets в enum
enum HomeTab: Hashable { case chats, spaces, widgets }

// Строки 95-99 - Инициализация Widgets координатора
let widgetsStackCoordinator = NavigationStackCoordinator()
widgetsTabFlowCoordinator = WidgetsTabFlowCoordinator(
    navigationStackCoordinator: widgetsStackCoordinator,
    flowParameters: flowParameters
)
widgetsTabDetails = .init(tag: HomeTab.widgets,
                          title: "Виджеты",
                          icon: \.extensions,
                          selectedIcon: \.extensionsSolid)
widgetsTabDetails.barVisibilityOverride = .visible

// Строка 109 - Добавлен widgets в setTabs
navigationTabCoordinator.setTabs([
    .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
    .init(coordinator: spacesSplitCoordinator, details: spacesTabDetails),
    .init(coordinator: widgetsStackCoordinator, details: widgetsTabDetails)  // ← NEW
])
```

#### Коммиты для применения:

```bash
# Коммит 1: Создание файлов Widgets UI
git cherry-pick 21dd96e

# Коммит 2: Интеграция в UserSessionFlowCoordinator
git cherry-pick 68a68b4

# Коммит 3: Фикс видимости TabBar
git cherry-pick 1deb412
```

#### Применение изменений на новой версии Element X:

1. Скопируйте 9 новых файлов в соответствующие директории
2. Добавьте файлы в Xcode проект (можно использовать `add_widgets_files.rb`)
3. Примените изменения в `UserSessionFlowCoordinator.swift`
4. Убедитесь что есть иконки `extensions` и `extensionsSolid` в Compound

---

### 2. ✅ TabBar всегда виден на вкладке Widgets

**Дата**: 2026-01-28
**Коммит**: `1deb412`

#### Описание:
Добавлен `barVisibilityOverride = .visible` для вкладки Widgets чтобы TabBar всегда оставался видимым.

#### Причина:
- Chats и Spaces используют NavigationSplitCoordinator с автоматическим скрытием TabBar при открытии чата
- Widgets использует NavigationStackCoordinator и открывает виджеты в модальном WebView
- TabBar должен оставаться видимым для быстрого переключения между вкладками

#### Изменённые файлы:

**ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift**:
```swift
widgetsTabDetails = .init(tag: HomeTab.widgets,
                          title: "Виджеты",
                          icon: \.extensions,
                          selectedIcon: \.extensionsSolid)
widgetsTabDetails.barVisibilityOverride = .visible  // ← ДОБАВЛЕНО
```

#### Коммит для применения:
```bash
git cherry-pick 1deb412
```

---

## 🛠️ Вспомогательные скрипты

### add_widgets_files.rb

**Назначение**: Автоматическое добавление файлов Widgets в Xcode проект

**Использование**:
```bash
cd /Users/ankin/Documents/element-x-fork/ios
ruby add_widgets_files.rb
```

**Что делает**:
- Находит ElementX.xcodeproj/project.pbxproj
- Создаёт UUID для каждого файла
- Добавляет файлы в PBXBuildFile, PBXFileReference, PBXGroup, PBXSourcesBuildPhase
- Сохраняет резервную копию перед изменениями

**Файлы которые добавляет**:
1. WidgetsTabFlowCoordinator.swift
2. WidgetsListScreenCoordinator.swift
3. WidgetsListScreenModels.swift
4. WidgetsListScreenViewModel.swift
5. WidgetsListScreen.swift
6. WidgetWebViewScreenCoordinator.swift
7. WidgetWebViewScreenModels.swift
8. WidgetWebViewScreenViewModel.swift
9. WidgetWebViewScreen.swift

---

## 📚 Архитектурные решения

### Почему NavigationStackCoordinator а не NavigationSplitCoordinator?

**NavigationSplitCoordinator** (Chats, Spaces):
- ✅ Нужен для split-view на iPad (список слева, детали справа)
- ✅ На iPhone сворачивается в NavigationStack
- ❌ Более сложный (sidebar + detail coordinators)

**NavigationStackCoordinator** (Widgets):
- ✅ Простой линейный навигационный стек
- ✅ Виджеты открываются в WebView (не требуется split-view)
- ✅ Легче в обслуживании
- ✅ Меньше кода

### Почему barVisibilityOverride = .visible?

**Без override** (Chats, Spaces):
```swift
func barVisibility(in horizontalSizeClass: UserInterfaceSizeClass?) -> Visibility {
    if horizontalSizeClass == .compact, navigationSplitCoordinator?.detailCoordinator != nil {
        .hidden  // Скрыть TabBar когда открыт чат на iPhone
    } else {
        .automatic
    }
}
```

**С override** (Widgets):
```swift
if let barVisibilityOverride {
    barVisibilityOverride  // .visible - всегда показывать
}
```

**Преимущества**:
- TabBar всегда доступен для переключения вкладок
- Виджет открывается модально (не влияет на TabBar)
- Улучшенная навигация между вкладками

---

## 🔄 Процесс обновления Element X

При выходе новой версии Element X:

### Шаг 1: Бэкап текущих изменений
```bash
cd /Users/ankin/Documents/element-x-fork

# Создать бранч с изменениями
git checkout -b widgets-changes
git add -A
git commit -m "Backup: Widgets tab implementation"
```

### Шаг 2: Обновление upstream
```bash
# Добавить upstream если ещё нет
git remote add upstream https://github.com/element-hq/element-x-ios.git

# Получить изменения
git fetch upstream

# Слить новую версию
git checkout develop
git merge upstream/develop
```

### Шаг 3: Применить изменения Widgets
```bash
# Cherry-pick коммитов
git cherry-pick 21dd96e  # Widgets files
git cherry-pick 68a68b4  # Integration
git cherry-pick 1deb412  # TabBar fix

# Или rebase ветки
git checkout widgets-changes
git rebase develop
```

### Шаг 4: Разрешить конфликты

Возможные конфликты:

**UserSessionFlowCoordinator.swift**:
- HomeTab enum: убедитесь что есть `widgets`
- setTabs: убедитесь что widgets добавлен в массив

**project.pbxproj**:
- Если конфликты в файле проекта → используйте `add_widgets_files.rb`

### Шаг 5: Проверка

```bash
# Очистить кеш
rm -rf ~/Library/Developer/Xcode/DerivedData/ElementX-*

# Собрать проект
xcodebuild -project ElementX.xcodeproj -scheme ElementX -destination 'id=...' build

# Проверить что:
# ✅ Компиляция успешна
# ✅ 9 файлов Widgets существуют
# ✅ TabBar показывает 4 вкладки
# ✅ Widgets вкладка работает
```

---

## 📝 Чеклист при обновлении

- [ ] Бэкап текущей версии в отдельный бранч
- [ ] Получены изменения upstream
- [ ] Применены коммиты 21dd96e, 68a68b4, 1deb412
- [ ] Разрешены конфликты в UserSessionFlowCoordinator.swift
- [ ] 9 файлов Widgets существуют и добавлены в проект
- [ ] Проверено наличие иконок extensions/extensionsSolid
- [ ] Проект собирается без ошибок
- [ ] TabBar показывает 4 вкладки
- [ ] Вкладка Widgets открывается и работает
- [ ] WebView виджетов загружается корректно

---

### 3. Кастомная 4-tab навигация (Контакты, Звонки, Чаты, Приложения)

**Дата**: 2026-01-29
**Коммиты**: `4978145`, `a91a56f`

#### Описание:
Полная замена навигации Element X. Вместо стандартных 2 вкладок (Chats, Spaces) — 4 вкладки в стиле Stalk: Контакты, Звонки, Чаты, Приложения. TabBar всегда виден.

#### Созданные файлы:
```
ElementX/Sources/Screens/ContactsListScreen/
├── ContactsListScreenCoordinator.swift
├── ContactsListScreenModels.swift
├── ContactsListScreenViewModel.swift
└── ContactsListScreen.swift

ElementX/Sources/Screens/CallsListScreen/
├── CallsListScreenCoordinator.swift
├── CallsListScreenModels.swift
├── CallsListScreenViewModel.swift
└── CallsListScreen.swift
```

#### Изменённые файлы:
- **UserSessionFlowCoordinator.swift** — полная переработка: HomeTab enum теперь `contacts, calls, chats, apps`; 4 таба вместо 2; Spaces убраны
- **NavigationTabCoordinator.swift** — поддержка `lottieIcon` в TabDetails

#### Коммиты для применения:
```bash
git cherry-pick 4978145  # 4-tab navigation
git cherry-pick a91a56f  # Force TabBar visibility
```

---

### 4. Интеграция записи звонков (Recording API)

**Дата**: 2026-01-30 — 2026-02-04
**Коммиты**: `a59b6bd` → `b05df5c` (серия из ~15 коммитов)

#### Описание:
Полная интеграция записи звонков через Recording API (livekit.market.implica.ru/recording-api). Локальная история звонков + серверные записи. Inline-плеер в ячейке звонка.

#### Функциональность:
- Автоматическая отправка startCall при начале звонка
- Получение списка записей с Recording API v2
- Merge локальной истории с серверными данными
- Inline аудиоплеер с progress bar
- Фильтры: Все / Пропущенные / Входящие / Исходящие
- Определение типа звонка (входящий/исходящий/пропущенный)
- Группировка по датам

#### Ключевые файлы:
```
ElementX/Sources/Screens/CallsListScreen/
├── CallsListScreenModels.swift  — модели CallRecord, CallType, RecordingInfo
├── CallsListScreenViewModel.swift — логика загрузки записей, merge, фильтрация
└── CallsListScreen.swift — UI с inline-плеером

ElementX/Sources/Services/CallHistory/  (УДАЛЕНЫ дубликаты)
```

#### Коммиты для применения (в порядке):
```bash
git cherry-pick a59b6bd  # feat: интеграция с Recording API
git cherry-pick 54e0c77  # fix: URL Recording API
git cherry-pick 8f25802  # feat: локальная история + Recording API v2
git cherry-pick c40241d  # fix: displayName через infoPublisher
git cherry-pick ce11ea1  # fix: вёрстка и отслеживание исходящих
git cherry-pick 45008dd  # fix: date parsing + dedup + merge
git cherry-pick d2726d4  # fix: верстка ячеек + направление из API
git cherry-pick b242fc4  # fix: две кнопки + определение входящих
git cherry-pick f056ccb  # fix: startCall для записи в историю
git cherry-pick 70aeeeb  # fix: таймаут Recording API 15с
git cherry-pick f100fc5  # fix: парсинг дат UTC + логика входящих
git cherry-pick 12584c9  # improve: оптимизация аудиоплеера
git cherry-pick bc68ab3  # fix: не показывать play для прерванных
git cherry-pick 88ee2d4  # fix: гонка при остановке записи
git cherry-pick 9baa5b4  # fix: воспроизведение со статусом ENDING
git cherry-pick 6bbc268  # fix: retry логика загрузки
git cherry-pick bdcd1d5  # fix: воспроизведение через стриминг
git cherry-pick 5452a24  # fix: data() вместо download()
git cherry-pick 54670a1  # fix: отключён HTTP/3 (QUIC)
git cherry-pick b05df5c  # fix: сброс состояния при новом звонке
```

---

### 5. Унифицированные фильтры на всех экранах

**Дата**: 2026-02-04
**Коммит**: `0d07b3d`

#### Описание:
Единообразные фильтры-табы (pill-style) на всех 4 экранах, используя стандартный GenericFilterView из Element X.

#### Экраны с фильтрами:
- **Чаты**: Все / Непрочитанные / Личные / Группы
- **Звонки**: Все / Пропущенные / Входящие / Исходящие
- **Контакты**: Все / В сети / Избранные
- **Приложения**: Все / Продуктивность / Общение / Инструменты

#### Коммит для применения:
```bash
git cherry-pick 0d07b3d
```

---

### 6. Stalk-style Tab Bar с Lottie-анимациями

**Дата**: 2026-02-05
**Коммит**: `636fee5`

#### Описание:
Кастомный Tab Bar с Lottie-анимациями иконок. При выборе вкладки — проигрывается анимация. Неактивные иконки серые, активная — синяя.

#### Новые файлы:
```
ElementX/Resources/StalkIcons/
├── TabContacts.json   — Lottie анимация "Контакты"
├── TabCalls.json      — Lottie анимация "Звонки"
├── TabChats.json      — Lottie анимация "Чаты"
└── TabSettings.json   — Lottie анимация "Приложения"

ElementX/Sources/Other/SwiftUI/Views/
├── LottieTabBarIcon.swift  — UIViewRepresentable wrapper для Lottie
└── StalkTabBar.swift       — кастомный Tab Bar с badge
```

#### Зависимости:
```yaml
# Добавлено в project.yml / Package.resolved
Lottie:
  url: https://github.com/airbnb/lottie-ios
  minorVersion: 4.6.0
```

#### Изменённые файлы:
- **NavigationTabCoordinator.swift** — переключение на StalkTabBar когда есть lottieIcon
- **UserSessionFlowCoordinator.swift** — lottieIcon: "TabContacts", "TabCalls", "TabChats", "TabSettings"

#### Коммит для применения:
```bash
git cherry-pick 636fee5
```

---

### 7. Telegram-style UI — SF Symbol иконки, underline фильтры, зелёные бейджи

**Дата**: 2026-02-06
**Коммит**: `3b4452e`

#### Описание:
Первая фаза приведения UI к стилю классического Telegram iOS (до Liquid Glass). Замена Lottie-анимаций на SF Symbols, переработка фильтров из pill в underline-табы, зелёные бейджи непрочитанных.

#### Изменения:

**1. Tab Bar иконки → SF Symbols (контурные/заполненные)**

| Вкладка | Было (Lottie) | Стало (SF Symbol) |
|---------|---------------|-------------------|
| Контакты | TabContacts.json | `person` / `person.fill` |
| Звонки | TabCalls.json | `phone` / `phone.fill` |
| Чаты | TabChats.json | `message` / `message.fill` |
| Приложения | square.grid.2x2 | без изменений |
| Настройки | TabSettings.json | `gearshape` / `gearshape.fill` |

**2. Фильтры: pill → underline**
- Убран RoundedRectangle background (pill-стиль)
- Добавлено подчёркивание (2pt линия) для активного фильтра
- Цвет подчёркивания: `.accentColor` (синий)
- Неактивный: `Color(.systemGray)`
- Шрифт: 15pt medium

**3. Бейджи непрочитанных → зелёные**
- Обычные непрочитанные: зелёный `Color(red: 0.33, green: 0.78, blue: 0.39)`
- Упоминания/важные: красный `Color.red`
- Числовой badge: Capsule с белым текстом

**4. Заголовки**
- HomeScreen: "Все чаты" → "Чаты"
- SettingsScreen: "Профиль" → "Настройки"

#### Изменённые файлы:
- **UserSessionFlowCoordinator.swift** — SF Symbol иконки вместо Lottie, заголовки вкладок
- **NavigationTabCoordinator.swift** — `useLottieTabBar` → `useCustomTabBar`, поддержка sfSymbol
- **StalkTabBar.swift** — размер иконок 22pt → 24pt
- **RoomListFilterView.swift** — полная переработка FilterToggleStyle (underline)
- **RoomListFiltersView.swift** — spacing 8→0, padding 12→8
- **HomeScreenRoomCell.swift** — зелёные бейджи непрочитанных
- **HomeScreen.swift** — заголовок "Чаты"
- **SettingsScreen.swift** — заголовок "Настройки"

#### Коммит для применения:
```bash
git cherry-pick 3b4452e
```

---

### 8. Telegram-style шапки и навигация

**Дата**: 2026-02-06
**Коммит**: `265fc03`

#### Описание:
Приведение шапок (navigation bars) всех экранов к стилю классического Telegram iOS: кнопки, segmented control, стиль заголовков.

#### Изменения:

**1. Чаты (HomeScreen)**
- Кнопка "+" → compose (pencil) `square.and.pencil`
- Добавлена кнопка "Изменить" слева (placement: .cancellationAction)

**2. Звонки (CallsListScreen)**
- Заголовок → segmented control "Все / Пропущенные" (как в Telegram)
- Фильтры сокращены до 2: `.all` и `.missed` (убраны .incoming/.outgoing)
- Кнопка "Изменить" слева
- Иконка `phone.badge.plus` справа
- Убрана секция фильтров из тела списка (перенесены в navigation)

**3. Контакты (ContactsListScreen)**
- Кнопка сортировки (Menu) слева: "По имени" / "По времени"
- Иконка `arrow.up.arrow.down`
- Кнопка "+" → `Image(systemName: "plus")`

**4. Настройки (SettingsScreen)**
- Large title display mode (`.navigationBarTitleDisplayMode(.large)`)
- Убрана неиспользуемая кнопка Done в toolbar

**5. Фильтры: активный текст → синий**
- Активный фильтр: `.accentColor` (синий) вместо `.compound.textPrimary`

**6. Бейджи: muted → серые**
- Muted чаты: badge `Color(.systemGray)` вместо зелёного

#### Изменённые файлы:
- **HomeScreen.swift** — compose icon, Edit button
- **CallsListScreen.swift** — segmented Picker, 2 фильтра, toolbar buttons
- **ContactsListScreen.swift** — sort Menu, + icon
- **SettingsScreen.swift** — large title, removed Done
- **RoomListFilterView.swift** — blue active text
- **HomeScreenRoomCell.swift** — gray badge for muted

#### Коммит для применения:
```bash
git cherry-pick 265fc03
```

---

### 9. Доработки Telegram-style UI — бейджи, иконка чатов, cleanup

**Дата**: 2026-02-06
**Коммит**: `ea581d3`

#### Описание:
Финальные доработки: иконка вкладки "Чаты" на двойной bubble (как в Telegram), исправление цветов dot-бейджей, удаление неиспользуемого кода.

#### Изменения:

**1. Иконка "Чаты" → двойной bubble**
- `message` / `message.fill` → `bubble.left.and.bubble.right` / `bubble.left.and.bubble.right.fill`
- Ближе к иконке Telegram (два пузырька)

**2. Dot-бейджи (без числа) → зелёные/серые**
- Обычные: `Color(red: 0.33, green: 0.78, blue: 0.39)` (зелёный)
- Muted: `Color(.systemGray)` (серый)
- Highlights: `Color.red` (красный)
- Размер dot: 12pt

**3. Settings cleanup**
- Убрана неиспользуемая computed property `toolbar` с кнопкой Done

#### Изменённые файлы:
- **UserSessionFlowCoordinator.swift** — sfSymbol: `bubble.left.and.bubble.right`
- **HomeScreenRoomCell.swift** — dot badge colors (green/gray/red)
- **SettingsScreen.swift** — removed unused toolbar code

#### Коммит для применения:
```bash
git cherry-pick ea581d3
```

---

### 10. Telegram-style доработки — алфавитный индекс, секции дат, профиль

**Дата**: 2026-02-06
**Коммит**: `859b3d6`

#### Описание:
Продолжение Telegram-style редизайна. Алфавитный индекс контактов, группировка звонков по датам, центрированный профиль в настройках.

#### Изменения:

**1. Контакты: алфавитный индекс**
- Sticky section headers (D, N, S, T...) с `pinnedViews: [.sectionHeaders]`
- Группировка по первой букве имени
- Аватар уменьшен с 52pt до 44pt (`.custom(44)`)
- Онлайн-индикатор 10pt перенесён вправо
- Relative time для оффлайн: "был(а) X мин./ч. назад"
- Добавлено поле `lastSeenDate` в `ContactItem`

**2. Звонки: группировка по датам**
- Section headers: "Сегодня", "Вчера", день недели, "d MMMM"
- `pinnedViews: [.sectionHeaders]` для sticky headers
- Автоматическая группировка через `Calendar.isDateInToday/Yesterday`

**3. Настройки: центрированный профиль**
- Аватар 80pt по центру (`.custom(80)`)
- Имя 22pt bold под аватаром
- Matrix ID под именем
- Убран chevron и горизонтальный layout

**4. Приложения: chevron**
- Добавлена иконка `chevron.right` справа в ячейках виджетов
- Separator перенесён с текстовой зоны на полную ширину (padding .leading: 84)

**5. Чаты: spacing**
- HStack spacing avatar-text: 16pt → 12pt (ближе к Telegram)

#### Изменённые файлы:
- **ContactsListScreen.swift** — alphabetical index, cell rework, relative time
- **ContactsListScreenModels.swift** — `lastSeenDate` в ContactItem
- **ContactsListScreenViewModel.swift** — lastSeenDate parameter
- **CallsListScreen.swift** — date grouping sections
- **SettingsScreen.swift** — centered profile header
- **WidgetsListScreen.swift** — chevron in cells
- **HomeScreenRoomCell.swift** — spacing 16→12

#### Коммит для применения:
```bash
git cherry-pick 859b3d6
```

### 11. Swipe actions на ячейках чатов

**Дата**: 2026-02-07
**Коммит**: `35bbc8e`

#### Описание:
Добавлены Telegram-style swipe actions на ячейках списка чатов. Кастомный SwipeActionView для работы в ScrollView+LazyVStack (нативный .swipeActions не работает вне List).

#### Изменения:
- Свайп влево: серая кнопка "Настройки" (ellipsis) + красная "Покинуть комнату" (trash)
- Свайп вправо: синяя "Прочитано/Непрочитано" (envelope) + оранжевая "Избранное" (pin)
- Кастомный DragGesture с highPriorityGesture для совместной работы с Button
- Rubber band эффект при перетягивании за границы
- Context menu сохранено как дополнение

#### Изменённые файлы:
- `ElementX/Sources/Screens/HomeScreen/View/HomeScreenRoomList.swift` — SwipeActionView + swipe actions

#### Коммит для применения:
```bash
git cherry-pick 35bbc8e
```

---

### 12. Badge непрочитанных на вкладке Чаты в Tab Bar

**Дата**: 2026-02-07
**Коммит**: `a5d8724`

#### Описание:
Красный бейдж с числом непрочитанных сообщений на иконке вкладки "Чаты" в Tab Bar. Обновляется в реальном времени.

#### Изменения:
- Подписка на alternateRoomSummaryProvider.roomListPublisher
- Агрегация unreadNotificationsCount по всем комнатам
- Обновление chatsTabDetails.badgeCount через Observable
- Бейдж: красный capsule, 99+ для >99

#### Изменённые файлы:
- `ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift` — подписка + обновление badgeCount

#### Коммит для применения:
```bash
git cherry-pick a5d8724
```

---

### 13. Недавние поисковые запросы + фикс навбара на вкладке Чаты

**Дата**: 2026-02-08
**Коммит**: `95323f8`

#### Описание:
Недавние поисковые запросы в стиле Telegram — при фокусе на пустом поисковом поле показываются последние 5 запросов с иконкой часов. Также исправлена проблема со скрытой навигационной панелью на вкладке Чаты.

#### Изменения:
- Сохранение запросов в UserDefaults при выборе комнаты из результатов поиска
- Overlay "Недавние" с кнопкой "Очистить" при пустом поле поиска в фокусе
- Каждый запрос с иконкой clock.arrow.circlepath, тап вставляет в поле поиска
- Очистка поискового запроса при переходе в комнату (как в Telegram)
- Фикс: отключён .ignoresSafeArea() на NavigationSplitCoordinator (скрывал навбар в StalkTabBar)
- Фикс: добавлен .navigationBarTitleDisplayMode(.large) + .toolbarVisibility(.visible) на HomeScreen

#### Изменённые файлы:
- `ElementX/Sources/Application/Settings/AppSettings.swift` — ключ recentSearchQueries + @UserPreference
- `ElementX/Sources/Screens/HomeScreen/HomeScreenModels.swift` — новые ViewActions + state
- `ElementX/Sources/Screens/HomeScreen/HomeScreenViewModel.swift` — сохранение/загрузка/очистка запросов
- `ElementX/Sources/Screens/HomeScreen/View/HomeScreenContent.swift` — UI overlay недавних поисков
- `ElementX/Sources/Screens/HomeScreen/View/HomeScreen.swift` — large title + visible toolbar
- `ElementX/Sources/Application/Navigation/NavigationCoordinators.swift` — отключён ignoresSafeArea

#### Коммит для применения:
```bash
git cherry-pick 95323f8
```

---

### 14. Интерактивный slider для плеера записей

**Дата**: 2026-02-08
**Коммит**: `c00a5b1`

#### Описание:
Замена статичного progress bar на интерактивный Slider для перемотки записей звонков.

#### Изменения:
- Slider(value:in:) вместо GeometryReader+Rectangle
- Новый action seekPlayback(progress:) для перемотки тапом/перетягиванием
- AudioPlayer.seek(to:) для позиционирования воспроизведения

#### Изменённые файлы:
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreen.swift` — Slider UI
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreenModels.swift` — seekPlayback action
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreenViewModel.swift` — обработка seek

#### Коммит для применения:
```bash
git cherry-pick c00a5b1
```

### 15. Алфавитный скруббер на экране Контакты

**Дата**: 2026-02-08
**Коммит**: `5b31df2`

#### Описание:
Добавлен алфавитный скруббер (A-Я) справа на экране контактов для быстрой навигации по секциям.

#### Изменения:
- ScrollViewReader для программной прокрутки к секциям
- Alphabet scrubber с DragGesture для быстрой навигации
- Скруббер скрывается при активном поиске
- Sticky section headers с id для scroll anchor

#### Изменённые файлы:
- `ElementX/Sources/Screens/ContactsListScreen/ContactsListScreen.swift` — ScrollViewReader + alphabetScrubber

#### Коммит для применения:
```bash
git cherry-pick 5b31df2
```

---

### 16. Кнопки редактирования профиля, секции настроек, анимация фильтров

**Дата**: 2026-02-08
**Коммит**: `32f5a0a`

#### Описание:
Комплексное обновление UI: кнопки редактирования в профиле, группировка настроек по секциям, анимация переключения фильтров, корректная разделительная линия Tab Bar.

#### Изменения:
- Профиль: кнопки "Изменить фото" и "Изменить имя" в capsule-стиле под аватаром
- Настройки: заголовки секций "Аккаунт", "Приватность", "Поддержка"
- Фильтры: анимация переключения 0.2s easeInOut (подчёркивание + цвет текста)
- Tab Bar: разделительная линия 0.5pt borderDisabled (по ТЗ §2.1.1)

#### Изменённые файлы:
- `ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift` — кнопки + секции
- `ElementX/Sources/Screens/HomeScreen/View/Filters/RoomListFilterView.swift` — анимация фильтров
- `ElementX/Sources/Other/SwiftUI/Views/StalkTabBar.swift` — разделитель Tab Bar

#### Коммит для применения:
```bash
git cherry-pick 32f5a0a
```

### 17. Фильтрация приложений по категориям

**Дата**: 2026-02-08
**Коммит**: `c2a16c4`

#### Описание:
Реализована фильтрация виджетов/приложений по категориям: Продуктивность, Связь, Инструменты.

#### Изменения:
- WidgetCategory enum: productivity, communication, tools
- Поле category в WidgetItem с дефолтным значением .tools
- Фильтрация по selectedCategory в filteredWidgets

#### Изменённые файлы:
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenModels.swift` — WidgetCategory enum
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreen.swift` — фильтрация по категории

#### Коммит для применения:
```bash
git cherry-pick c2a16c4
```

---

### 18. Dark Mode аудит — adaptive цвета

**Дата**: 2026-02-08
**Коммит**: `608e0d9`

#### Описание:
Аудит и замена hardcoded RGB цветов на adaptive/compound цвета для корректной работы в Dark Mode.

#### Изменения:
- Color.stalkBadgeGreen / stalkOnlineGreen с UITraitCollection (light/dark)
- HomeScreenRoomCell: badge .white → .textOnSolidPrimary, .red → .textCriticalPrimary
- CallsListScreen: пропущенные .red → .textCriticalPrimary/.iconCriticalPrimary
- ContactsListScreen: online .green → .stalkOnlineGreen
- WidgetsListScreen: icon .white → .textOnSolidPrimary
- StalkTabBar: badge цвета → compound equivalents

#### Изменённые файлы:
- `ElementX/Sources/Other/SwiftUI/Views/StalkTabBar.swift` — adaptive цвета + badge
- `ElementX/Sources/Screens/HomeScreen/View/HomeScreenRoomCell.swift` — badge цвета
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreen.swift` — missed call + play цвета
- `ElementX/Sources/Screens/ContactsListScreen/ContactsListScreen.swift` — online indicator
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreen.swift` — icon цвет

#### Коммит для применения:
```bash
git cherry-pick 608e0d9
```

### 19. Миграция на сервер stalk.implica.ru — динамические URL

**Дата**: 2026-02-08
**Коммит**: `8d9ef0f`

#### Описание:
Миграция с market.implica.ru на новый production-сервер stalk.implica.ru. Все URL сервисов (Recording API, виджеты) стали динамическими — определяются по домену homeserver, к которому подключён пользователь.

#### Изменения:

**1. Default сервер → stalk.implica.ru**
- accountProvider: `matrix.market.implica.ru` → `stalk.implica.ru`
- Recording API default: `livekit.market.implica.ru` → `livekit.stalk.implica.ru`

**2. Динамические URL сервисов**
- Recording API: домен извлекается из `clientProxy.homeserver` → `livekit.{domain}/recording-api`
- Виджеты: serverDomain computed property → `stats.{domain}`, `calendar.{domain}`, etc.
- Playback URL в CallHistoryItem принимает apiBaseURL параметр

**3. Удалены все hardcoded ссылки на market.implica.ru**

#### Изменённые файлы:
- `ElementX/Sources/Application/Settings/AppSettings.swift` — default server URLs
- `ElementX/Sources/FlowCoordinators/CallsTabFlowCoordinator.swift` — dynamic Recording API URL
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreenModels.swift` — apiBaseURL parameter
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreenViewModel.swift` — pass apiBaseURL
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenViewModel.swift` — serverDomain + dynamic widget URLs
- `ElementX/Sources/Screens/CallsListScreen/CallsListScreen.swift` — mock URL update

#### Коммит для применения:
```bash
git cherry-pick 8d9ef0f
```

### 20. Telegram-style Tab Bar — SF Symbols filled/outline, убран Lottie

**Дата**: 2026-02-09
**Коммит**: `c220ddc`

#### Описание:
Приведение Tab Bar к классическому стилю Telegram iOS. Убраны Lottie-анимации из Tab Bar, иконки полностью на SF Symbols (filled для активной вкладки, outline для неактивной). Иконка Чаты заменена на один пузырь `message` (как в Telegram).

#### Изменения:

**1. Удалён Lottie из Tab Bar**
- Убран `import Lottie` из StalkTabBar.swift
- Убрано поле `lottieIcon` из StalkTabItem и TabDetails
- Убрана Lottie-ветка из iconView() — теперь только SF Symbols
- NavigationTabCoordinator: убрана проверка `lottieIcon != nil`

**2. Иконка Чаты → один пузырь**
- `bubble.left.and.bubble.right` → `message` / `message.fill`
- Один пузырь — ближе к оригинальному Telegram

**3. Зелёные бабблы исходящих сообщений (Telegram-style)**
- Outgoing: #E1FEC6 (light) / #2B5F37 (dark) — зелёные
- Incoming: #FFFFFF (light) / #282829 (dark) — белые/тёмно-серые
- Добавлены `Color.stalkBubbleOutgoing` / `.stalkBubbleIncoming` в StalkTabBar.swift
- TimelineItemBubbledStylerView: `.compound._bgBubbleOutgoing` → `.stalkBubbleOutgoing`

**4. Зелёный "в сети" в контактах**
- Текст "в сети" теперь `.stalkOnlineGreen` вместо `.compound.textSecondary`

#### Изменённые файлы:
- `ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift` — иконка Чаты → message/message.fill
- `ElementX/Sources/Application/Navigation/NavigationTabCoordinator.swift` — убран lottieIcon из TabDetails
- `ElementX/Sources/Other/SwiftUI/Views/StalkTabBar.swift` — убран Lottie, добавлены bubble colors
- `ElementX/Sources/Screens/Timeline/View/Style/TimelineItemBubbledStylerView.swift` — зелёные бабблы
- `ElementX/Sources/Screens/ContactsListScreen/ContactsListScreen.swift` — зелёный "в сети"
- `ElementX/Sources/Screens/HomeScreen/View/HomeScreen.swift` — inline title
- `ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift` — inline title

#### Коммит для применения:
```bash
git cherry-pick c220ddc
```

---

### 21. Inline titles на всех экранах (убраны large titles)

**Дата**: 2026-02-09
**Коммит**: `c220ddc`, `71745dc`

#### Описание:
Замена всех large titles на inline centered — как в классическом Telegram iOS. Все 5 основных экранов теперь используют `.navigationBarTitleDisplayMode(.inline)`.

#### Изменения:

| Экран | Было | Стало |
|-------|------|-------|
| Чаты (HomeScreen) | `.large` | `.inline` |
| Настройки (SettingsScreen) | `.large` | `.inline` |
| Контакты (ContactsListScreen) | default (large) | `.inline` |
| Приложения (WidgetsListScreen) | default (large) | `.inline` |
| Звонки (CallsListScreen) | уже `.inline` | без изменений |

#### Изменённые файлы:
- `ElementX/Sources/Screens/HomeScreen/View/HomeScreen.swift` — `.large` → `.inline`
- `ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift` — `.large` → `.inline`
- `ElementX/Sources/Screens/ContactsListScreen/ContactsListScreen.swift` — добавлен `.inline`
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreen.swift` — добавлен `.inline`

#### Коммиты для применения:
```bash
git cherry-pick c220ddc  # Чаты, Настройки, Контакты + бабблы + иконки
git cherry-pick 71745dc  # Приложения (пропущен в первом коммите)
```

---

### 22. Навигация контакт → чат (как в Telegram)

**Дата**: 2026-02-09
**Коммиты**: `ec1cb80`, `e49ba44`

#### Описание:
Тап на контакт открывает чат с ним — как в Telegram. Чат открывается внутри навигационного стека Контактов (не переключается на вкладку Чаты). Кнопка "Назад" возвращает в список контактов.

#### Изменения:

**1. ContactsTabFlowCoordinator — открытие чата в своём стеке**
- Добавлен `RoomFlowCoordinator` с `isChildFlow: true` — пушит экран чата поверх списка контактов
- Обработка `.openChat(roomId:)` от ContactsListScreenViewModel
- Кнопка "Назад" корректно возвращает в список контактов (не в Чаты)
- Поддержка `.presentCallScreen` для звонков из контактов

**2. ContactsListScreen — полная область нажатия**
- Добавлен `.contentShape(Rectangle())` на HStack ячейки контакта
- Тап работает по всей строке, а не только по тексту имени

#### Изменённые файлы:
- `ElementX/Sources/FlowCoordinators/ContactsTabFlowCoordinator.swift` — RoomFlowCoordinator + openRoom()
- `ElementX/Sources/Screens/ContactsListScreen/ContactsListScreen.swift` — .contentShape(Rectangle())

#### Коммиты для применения:
```bash
git cherry-pick e49ba44  # финальная версия (включает фикс навигации + contentShape)
```

---

### 23. Фильтр пустых комнат в контактах — только реальные люди

**Дата**: 2026-02-09
**Коммит**: `7bbfa2b`

#### Описание:
В списке контактов теперь отображаются только реальные люди (DM-комнаты с 2+ участниками). Пустые и покинутые комнаты ("Empty Room") отфильтрованы. Также добавлены аватарки контактов из RoomSummary.

#### Изменения:
- Фильтр `activeMembersCount >= 2` — исключает покинутые/пустые DM
- Фильтр `!name.hasPrefix("Empty Room")` — исключает комнаты с дефолтным именем
- Передача `avatarURL` из `summary.avatarURL` в `ContactItem` (ранее был `nil`)

#### Изменённые файлы:
- `ElementX/Sources/Screens/ContactsListScreen/ContactsListScreenViewModel.swift` — фильтр в updateContacts()

#### Коммит для применения:
```bash
git cherry-pick 7bbfa2b
```

---

### 24. Поиск сообщений внутри чата (как в Telegram)

**Дата**: 2026-02-09
**Коммит**: `d8fb603`

#### Описание:
Добавлен поиск по сообщениям внутри комнаты (in-room search) с inline search bar, аналогично Telegram. Поиск работает по уже загруженным сообщениям таймлайна (клиентский поиск).

#### Функциональность:
- 🔍 ~~Кнопка поиска в toolbar комнаты~~ **УБРАНО** (слишком плотно, не как в Telegram)
- 📝 Inline search bar появляется сверху при активации поиска
- 🔢 Счётчик результатов (текущий / всего): "X/Y"
- ⬆️⬇️ Кнопки навигации вверх/вниз по результатам
- ✖️ Кнопка закрытия поиска
- 🎯 Автоматический скролл к найденным сообщениям
- 📱 Кнопка "Поиск" в Room Details shortcuts
- 🔄 Роутинг из Room Details → активация поиска в комнате

#### Технические детали:
- Поиск по тексту сообщений через `EventBasedTimelineItemProtocol.body.localizedCaseInsensitiveContains(query)`
- Debounce 300ms для оптимизации поиска при вводе
- Передача `timelineController` в `RoomScreenViewModel` для доступа к items
- Навигация через `focusOnEvent(eventID:)` для скролла к результатам
- Search bar использует `.safeAreaInset(edge: .top)` для overlay

#### Созданные файлы (1 новый):

1. **ElementX/Sources/Screens/RoomScreen/View/RoomSearchBar.swift**
   - SwiftUI компонент inline search bar
   - TextField + счётчик + кнопки ↑↓ + кнопка ✖️
   - Auto-focus при появлении

#### Изменённые файлы (12 файлов):

1. **ElementX/Sources/Screens/RoomScreen/RoomScreenModels.swift**
   ```swift
   // ViewActions
   case toggleSearch
   case searchNext
   case searchPrevious

   // ViewModelActions
   case focusSearchResult(eventID: String)

   // ViewState
   var isSearchActive = false
   var searchResultEventIDs: [String] = []
   var currentSearchResultIndex: Int = 0
   var searchResultCount: Int { searchResultEventIDs.count }

   // Bindings
   var searchQuery = ""
   ```

2. **ElementX/Sources/Screens/RoomScreen/View/RoomScreen.swift**
   ```swift
   // Кнопка в toolbar
   ToolbarItem(placement: .primaryAction) {
       HStack(spacing: 4) {
           Button { context.send(viewAction: .toggleSearch) }
           label: { CompoundIcon(\.search) }
           ...
       }
   }

   // Search bar overlay
   .safeAreaInset(edge: .top) {
       if context.viewState.isSearchActive {
           RoomSearchBar(
               searchQuery: $context.searchQuery,
               resultCount: context.viewState.searchResultCount,
               ...
           )
       }
   }
   ```

3. **ElementX/Sources/Screens/RoomScreen/RoomScreenViewModel.swift**
   - Свойство `timelineController` для доступа к timeline items
   - `setupSearchSubscription()` — debounce 300ms
   - `performSearch(query:)` — фильтрация по `body.localizedCaseInsensitiveContains`
   - `toggleSearch()` — переключение состояния
   - `navigateSearchResult(forward:)` — циклическая навигация ↑↓
   - `activateSearch()` — активация из Room Details

4. **ElementX/Sources/Screens/RoomScreen/RoomScreenViewModelProtocol.swift**
   ```swift
   func activateSearch()
   ```

5. **ElementX/Sources/Screens/RoomScreen/RoomScreenCoordinator.swift**
   - Передача `timelineController` в `RoomScreenViewModel.init`
   - Обработка `.focusSearchResult` → `timelineViewModel.focusOnEvent`
   - Публичный метод `activateSearch()` для роутинга

6. **ElementX/Sources/Screens/RoomDetailsScreen/RoomDetailsScreenModels.swift**
   ```swift
   // Shortcuts
   enum RoomDetailsScreenViewShortcut {
       case search  // NEW
   }

   var shortcuts: [RoomDetailsScreenViewShortcut] {
       shortcuts.append(.search)  // После .call
   }

   // ViewActions
   case processTapSearch

   // ViewModelActions
   case displayRoomSearch
   ```

7. **ElementX/Sources/Screens/RoomDetailsScreen/View/RoomDetailsScreen.swift**
   ```swift
   private func shortcutButton(for shortcut: ...) -> some View {
       switch shortcut {
       case .search:
           Button { context.send(viewAction: .processTapSearch) }
           label: { CompoundIcon(\.search) }
           .buttonStyle(FormActionButtonStyle(title: L10n.actionSearch))
       }
   }
   ```

8. **ElementX/Sources/Screens/RoomDetailsScreen/RoomDetailsScreenViewModel.swift**
   - Обработка `.processTapSearch` → `.displayRoomSearch`

9. **ElementX/Sources/Screens/RoomDetailsScreen/RoomDetailsScreenCoordinator.swift**
   ```swift
   enum RoomDetailsScreenCoordinatorAction {
       case presentRoomSearch  // NEW
   }
   ```

10. **ElementX/Sources/FlowCoordinators/RoomFlowCoordinator.swift**
    ```swift
    // В presentRoomDetails coordinator actions:
    case .presentRoomSearch:
        navigationStackCoordinator.pop()
        stateMachine.tryEvent(.dismissRoomDetails)
        roomScreenCoordinator?.activateSearch()
    ```

11. **ElementX/Sources/FlowCoordinators/SpaceSettingsFlowCoordinator.swift**
    - Добавлен `.presentRoomSearch` в fatalError (не применимо для Space)

12. **ElementX.xcodeproj/project.pbxproj**
    - Добавлен `RoomSearchBar.swift` в build phase

#### Коммит для применения:
```bash
git cherry-pick d8fb603
```

---

### 25. Telegram-style CallScreen UI (CSS Injection + Native Overlay)

**Дата**: 2026-02-10
**Коммиты**: `883a265` → `d0f38ce` → `f4a7ccf` → `7d6b575` (финальный)

#### Описание:
Экран звонков (CallScreen) стилизован под Telegram через CSS/JS инъекцию в Element Call WebView + нативные SwiftUI overlay. Полноэкранное видео, 5 кнопок управления (mic, camera, emoji, settings, end call + invite/raiseHand), gradient footer, имя собеседника, кнопка записи.

#### Функциональность:
- **Полноэкранное видео** — tiles/spotlights растянуты на весь экран, без рамок и скруглений
- **5 кнопок управления** — mic, camera, emoji, settings, end call (все видны, invite + raiseHand тоже)
- **Кнопки Telegram-style** — 48px круглые, rgba(255,255,255,0.15), backdrop blur 10px
- **End Call — красная** (#FF3B30) с повышенной CSS специфичностью
- **Gradient footer** — linear-gradient от transparent до rgba(0,0,0,0.75)
- **Скрыт header bar** Element Call (заменён нативным SwiftUI toolbar)
- **Имя собеседника** — нативный SwiftUI Text overlay с тенью
- **MutationObserver** — динамическая манипуляция DOM для React-рендеров
- **Recording** — Telegram-style кнопка записи (36px, transparent circle) + RecordingIndicator (красный капсула "REC")
- **Показаны имена участников** — displayName/nameTag видны с text-shadow
- **Nuclear border removal** — убраны все borders/outlines/scrollbars

#### Изменённые файлы (4):

1. **ElementX/Sources/Screens/CallScreen/CallScreenModels.swift**
   - `telegramStyleInjectionScript` — JavaScript IIFE: `<style>` + MutationObserver
   - CSS Module attribute selectors: `_buttons_110p2`, `_footer_110p2`, `_endCall_bwclo`, `_invite_110p2`, `_raiseHand_110p2`
   - JS `applyTelegramLayout()` — force-show invite/raiseHand, fullscreen spotlights, borderless tiles
   - Delayed execution (500ms, 1500ms, 3000ms, 5000ms) для React async renders
   - `roomDisplayName: String?` в `CallScreenViewState`

2. **ElementX/Sources/Screens/CallScreen/View/CallScreen.swift**
   - `.toolbarBackground(.hidden)` — прозрачный nav bar
   - `.preferredColorScheme(.dark)` — тёмная тема
   - `.ignoresSafeArea()` — WebView на весь экран
   - WebView: чёрный фон, `bounces = false`, без scroll indicators
   - Native overlay: имя собеседника вверху центра
   - RecordingIndicator: красный капсула справа вверху

3. **ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift**
   - Извлечение `roomDisplayName` из `roomProxy.infoPublisher.value.displayName`

4. **ElementX/Sources/Screens/CallScreen/View/RecordingButton.swift**
   - Telegram-style дизайн: 36px circle, rgba(255,255,255,0.15)
   - RecordingIndicator: красный капсула с "REC" + пульсация
   - RecordingConsentView: русский текст "Начать запись?"

#### CSS селекторы Element Call (v0.16.3):
```
_header_110p2 → скрыт (display: none)
_footer_110p2 → gradient overlay, absolute positioning
_buttons_110p2 → flex, gap 16px, centered, все кнопки видны
_endCall_bwclo → красный круг #FF3B30 (высокая специфичность)
_tile_31vx3 → без рамок/скруглений
_spotlight, _grid → полноэкранные (position absolute, inset 0)
_displayName, _nameTag → видны, белый текст с text-shadow
_invite_110p2, _raiseHand_110p2 → force display: flex
```

#### Коммиты для применения:
```bash
git cherry-pick d0f38ce f4a7ccf 7d6b575
```

#### Важно при обновлении:
CSS селекторы привязаны к хэшам CSS Modules Element Call v0.16.3. При обновлении Element Call пакета нужно проверить актуальность хэшей (например `_buttons_110p2_84` может измениться). Хэши можно найти в JS бандле Element Call (`index-*.js`).

### 26. CallScreen v4 — 5 нативных кнопок, рука, динамик, формат участников, CSS grid

**Дата**: 2026-02-11
**Коммит**: `53dd858`

#### Описание:
Четыре улучшения CallScreen: 5 нативных кнопок управления (рука, камера, микрофон, динамик, завершить), кнопка «Поднять руку» для групповых звонков через DOM click, кнопка «Динамик» через AVRoutePickerView, формат участников «0:50 · 3 из 5 участников», CSS grid для групповых звонков.

#### Функциональность:
- **5 кнопок** — рука (только группа), камера, микрофон, динамик, завершить (spacing 20)
- **Кнопка «Динамик»** — `showSpeakerPickerHandler` binding → `tapRoutePickerView()` в Coordinator
- **isSpeakerOn** — отслеживается через `AVAudioSession.routeChangeNotification`
- **Кнопка «Рука»** — DOM click через `window.stalkToggleHandRaise()` (JS injection)
- **_raiseHand off-screen** — CSS `position: fixed; left: -9999px` вместо `display: none` для clickability
- **MutationObserver руки** — наблюдает `aria-pressed` на кнопке _raiseHand, сообщает native через `onHandRaiseStateChanged`
- **Формат статуса** — 1:1: `"0:43"`, группа: `"0:43 · 3 из 5 участников"` (время первое)
- **Реактивные участники** — подписка на `roomProxy.infoPublisher` для `totalMembersCount` и `callParticipantsCount`
- **CSS v2 conditional** — `body.stalk-direct` (spotlight fullscreen) / `body.stalk-group` (CSS grid 2x2)
- **Grid плитки** — `border-radius: 12px`, `background: #1a1a1a`, имена участников с `text-shadow`
- **Body class injection** — JS `document.body.classList.add('stalk-direct'|'stalk-group')` при `mediaCapturePermissionGranted`

#### Изменённые файлы (3):

1. **ElementX/Sources/Screens/CallScreen/CallScreenModels.swift**
   - `isSpeakerOn`, `isHandRaised` в `CallScreenViewState`
   - `totalMembersCount`, `callParticipantsCount` вместо `participantCount`
   - `showSpeakerPickerHandler` в `Bindings`
   - `showSpeakerPicker`, `toggleHandRaise`, `handRaiseStateChanged` в `CallScreenViewAction`
   - `onHandRaiseStateChanged` в `CallScreenJavaScriptMessageName` + JS observer
   - CSS: `body.stalk-direct` / `body.stalk-group` conditional стили
   - CSS: `_raiseHand` off-screen вместо hidden
   - CSS: grid layout для группы, nameTag/displayName показаны в grid

2. **ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift**
   - `showSpeakerPicker` → `showSpeakerPickerHandler?()`
   - `toggleHandRaise()` → JS `window.stalkToggleHandRaise()`
   - `handRaiseStateChanged` → `state.isHandRaised`
   - `isSpeakerOn` обновляется при route change
   - `roomProxy.infoPublisher` подписка для live participant counts
   - Body class injection при `mediaCapturePermissionGranted`

3. **ElementX/Sources/Screens/CallScreen/View/CallScreen.swift**
   - 5 кнопок: рука (группа), камера, микрофон, динамик, завершить (spacing 20)
   - `showSpeakerPickerHandler = self.tapRoutePickerView` в Coordinator
   - `onHandRaiseStateChanged` handler → `handRaiseStateChanged` viewAction

#### Коммиты для применения:
```bash
git cherry-pick 53dd858
```

#### Важно при обновлении:
- CSS селекторы `_raiseHand`, `_scrollingGrid`, `_spotlight` зависят от версии Element Call
- JS `stalkToggleHandRaise` кликает по DOM-кнопке _raiseHand — проверить наличие при обновлении EC
- `activeRoomCallParticipants` может требовать rust SDK поддержки

---

### 27. Исправление конфликта LiveKit SDK + адаптация API

**Дата**: 2026-02-13
**Коммит**: `3cd7b9b`

#### Описание:
Исправлен конфликт SPM зависимостей `swift-collections` (корневой проект 1.3.0..<1.4.0 vs LiveKit SDK 1.1.0..<1.3.0). Адаптирован LiveKitRoomManager к обновлённому API. Удалены мёртвые ссылки на LottieTabBarIcon.

#### Изменения:
- `swift-collections`: `upToNextMinorVersion: 1.3.0` → `upToNextMajorVersion: 1.1.0` (1.1.0..<2.0.0)
- LiveKit API: `participantDidJoin` → `participantDidConnect`, `participantDidLeave` → `participantDidDisconnect`
- Убран `any` с конкретного типа `Participant`
- Удалены 4 ссылки на LottieTabBarIcon.swift из pbxproj, убран `import Lottie`

#### Изменённые файлы:
- `ElementX.xcodeproj/project.pbxproj` — swift-collections range + LottieTabBarIcon cleanup
- `ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — new LiveKit API
- `ElementX/Sources/Application/Navigation/NavigationTabCoordinator.swift` — removed import Lottie

#### Коммит для применения:
```bash
git cherry-pick 3cd7b9b
```

---

### 28. Виджеты — реальные URL с продакшена

**Дата**: 2026-02-13
**Коммит**: `333daf5`

#### Описание:
Виджеты в табе "Приложения" используют реальные URL с продакшен-сервера. Статистика доступна по `/stats/` path (ingress rewrite), а не поддомену.

#### Изменения:
- Статистика: `stats.stalk.implica.ru` → `stalk.implica.ru/stats/`
- Удалены 4 несуществующих виджета (Календарь, Задачи, Файлы, Заметки)
- Добавлен `serverBaseURL` helper для построения URL из homeserver

#### Изменённые файлы:
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenViewModel.swift`

#### Коммит для применения:
```bash
git cherry-pick 333daf5
```

---

### 29. Виджет статистики — персональная информация пользователя

**Дата**: 2026-02-13
**Коммит**: `c5bf455`

#### Описание:
Виджет статистики передаёт `userId` текущего пользователя через query-параметр. Stats widget на сервере показывает персональную карточку (имя, аватар, комнаты, диалоги, группы, дней с регистрации) — как в Element Web на проде.

#### Изменения:
- URL: `stalk.implica.ru/stats/` → `stalk.implica.ru/stats/?userId=@user:domain`
- userId из `userSession.clientProxy.userID`, URL-кодирован
- Сервер отдаёт данные через `/api/user-stats?userId=` endpoint (Synapse Admin API)

#### Изменённые файлы:
- `ElementX/Sources/Screens/WidgetsListScreen/WidgetsListScreenViewModel.swift`

#### Коммит для применения:
```bash
git cherry-pick c5bf455
```

---

### 30. CallScreen v5 — Native LiveKit Video + Phase 4 Cleanup

**Дата**: 2026-02-15
**Коммиты**: `0b7b947c` (Phase 4 cleanup), предыдущие фазы в серии коммитов develop

#### Описание:
Замена WKWebView Element Call на нативное LiveKit видео. WebView остаётся невидимым (0×0) только для Widget API signaling. Фаза 4 — удаление мёртвого кода WebView-эры.

#### Фазы:
1. **LiveKit SDK + WS-перехват** — добавлен LiveKit Swift SDK через SPM, JS хук перехватывает LiveKit credentials из WebSocket Element Call
2. **Нативное видео** — `LiveKitRoomManager` подключается к SFU, `NativeCallVideoView` рендерит видео через SwiftUI
3. **Переключение** — WebView скрыт (0×0), фейковый WebSocket блокирует LiveKit в WebView, нативный SDK управляет камерой/микрофоном
4. **Cleanup** — удалены: `clickElementCallHangup()`, `killWebViewMedia()`, `updateOutputsListOnWeb()`, `handleOutputDeviceSelected()`, JS handlers (`showNativeOutputDevicePicker`, `onOutputDeviceSelect`, `onBackButtonPressed`), WebView PiP код, `requestPictureInPictureHandler`

#### Добавлено:
- Proximity monitoring — автовключение proximity sensor при разговоре через ресивер (earpiece)
- `AVAudioSession.routeChangeNotification` handler для speaker/earpiece detection

#### Новые файлы:
- `ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift`
- `ElementX/Sources/Screens/CallScreen/View/NativeCallVideoView.swift`

#### Изменённые файлы:
- `CallScreenViewModel.swift` — нативные mute/camera, proximity, cleanup
- `CallScreenModels.swift` — WS hook JS, удалены мёртвые enum cases
- `CallScreen.swift` — WebView 0×0, нативное видео overlay, удалён PiP

#### Коммит для применения:
```bash
git cherry-pick 0b7b947c  # Phase 4 cleanup
# + предыдущие коммиты Phase 1-3 из ветки develop
```

---

### 31. OIDC Login Fix — AASA + HTTPS Redirect + Entitlements

**Дата**: 2026-02-15
**Коммит**: `1d312d9d`

#### Описание:
Фикс OIDC авторизации через ASWebAuthenticationSession. Основная проблема — `.https()` callback URL требует Apple App Site Association (AASA) файл на сервере, которого не было. MAS (Matrix Authentication Service) не принимает custom URL schemes — только HTTPS.

#### Изменения:
- Развёрнут AASA на `stalk.implica.ru/.well-known/apple-app-site-association` (K8s: ConfigMap → nginx → Ingress)
- `AppSettings.oidcRedirectURL` восстановлен на `https://stalk.implica.ru/oidc/login`
- Entitlements: добавлены `applinks:stalk.implica.ru` + `webcredentials:stalk.implica.ru`
- `AuthenticationFlowCoordinator`: обработка дублирующих переходов `savedAccountsScreen → savedAccountsScreen` (вместо fatalError)

#### K8s инфраструктура (на сервере):
- ConfigMap `apple-app-site-association` в namespace `matrix`
- Deployment `aasa-server` (nginx:alpine)
- Service `aasa-server:80`
- Ingress route `/.well-known/apple-app-site-association` в `stalk-ingress`

#### Изменённые файлы:
- `ElementX/Sources/Application/Settings/AppSettings.swift`
- `ElementX/Sources/FlowCoordinators/AuthenticationFlowCoordinator.swift`
- `ElementX/SupportingFiles/ElementX.entitlements`

#### Коммит для применения:
```bash
git cherry-pick 1d312d9d
```

---

### 32. Stale-While-Revalidate кеширование + управление кешем в настройках

**Дата**: 2026-02-18
**Коммит**: `160a6132`

#### Описание:
Кеширование данных для ускорения приложения. Паттерн Stale-While-Revalidate: данные мгновенно показываются из кеша, обновляются в фоне с сервера. Экран управления кешем в настройках.

#### Функциональность:
- **STalkCacheService** — actor-based кеш с двумя уровнями: in-memory + JSON-файлы на диске (Library/Caches/)
- **Виджеты (Apps)** — кеш на 1 час, мгновенный показ из кеша при открытии, обновление в фоне
- **Записи звонков (Calls)** — кеш на 5 минут, статус "прослушано" сохраняется между сессиями
- **Профили пользователей** — кеш на 30 минут, без спиннера при повторном открытии
- **Аватарки (Kingfisher)** — disk cache 100 МБ / 7 дней, не перезагружаются при background/foreground
- **Настройки → Хранилище → Кеш и данные** — отображение размера и очистка (API кеш, изображения, записи)
- **Очистка при logout** — все кеши (API + Kingfisher disk/memory) очищаются
- **Pull-to-refresh** — принудительное обновление с сервера, минуя кеш

#### Изменённые файлы:
- `Services/Cache/STalkCacheService.swift` **(NEW)** — actor-based кеш сервис
- `Application/ServiceLocator.swift` — регистрация cacheService
- `Application/AppCoordinator.swift` — инициализация + очистка при clearCache
- `WidgetsListScreen/WidgetsListScreenModels.swift` — +Codable к WidgetItem, WidgetCategory
- `WidgetsListScreen/WidgetsListScreenViewModel.swift` — SWR для виджетов
- `CallsListScreen/CallsListScreenModels.swift` — +Codable к CallHistoryItem, +isListened
- `CallsListScreen/CallsListScreenViewModel.swift` — SWR для записей, кеш listened status
- `UserProfileScreen/UserProfileScreenViewModel.swift` — SWR для профиля
- `Services/Users/UserProfileProxy.swift` — +Codable
- `Other/Extensions/ImageCache.swift` — disk cache 100MB/7 дней
- `Services/UserSession/UserSessionStore.swift` — очистка кешей при logout
- `Settings/SettingsScreen/` — добавлен пункт "Кеш и данные"
- `Settings/CacheAndStorageScreen/` **(NEW)** — экран управления кешем
- `FlowCoordinators/SettingsFlowCoordinator.swift` — routing на CacheAndStorageScreen

#### Коммит для применения:
```bash
git cherry-pick 160a6132
```

---

### 33. Telegram-style архив чатов

**Дата**: 2026-02-18
**Коммит**: `5a1ffdba`

#### Описание:
Архив чатов в стиле Telegram. Свайп "Архив" убирает чат из основного списка. Строка "Архив" появляется вверху списка чатов с превью и счётчиком. Тап на строку открывает экран с архивными чатами. Свайп "Разархив." возвращает чат обратно. Архивные чаты автоматически мьютятся (подавление уведомлений).

#### Функциональность:
- **Свайп "Архив"** (фиолетовый) на чате → убирает из основного списка (flagAsLowPriority + mute)
- **Строка "Архив"** вверху списка чатов — иконка, превью имён, счётчик, шеврон
- **Экран "Архив"** — отдельный список архивных комнат с кнопкой назад
- **Свайп "Разархив."** (зелёный) → возврат в основной список (unflag + unmute)
- **Пустое состояние** — "Архив пуст" с иконкой archivebox
- **Контекстное меню** в архиве — Разархивировать, Настройки, Покинуть
- **Подавление уведомлений** — автоматический mute при архивации, unmute при разархивации
- **lowPriorityFilterEnabled** = true по умолчанию (SDK фильтр .nonLowPriority)

#### Изменённые файлы:
- `Screens/ArchiveScreen/ArchiveScreen.swift` **(NEW)** — View с списком архивных чатов + swipe actions
- `Screens/ArchiveScreen/ArchiveScreenViewModel.swift` **(NEW)** — ViewModel с фильтром .lowPriority
- `Screens/ArchiveScreen/ArchiveScreenModels.swift` **(NEW)** — State/Action модели
- `Screens/ArchiveScreen/ArchiveScreenCoordinator.swift` **(NEW)** — Coordinator pattern
- `Application/Settings/AppSettings.swift` — lowPriorityFilterEnabled default → true
- `Screens/HomeScreen/HomeScreenModels.swift` — +archiveRoomCount, +archivePreviewText, +openArchive, +presentArchive
- `Screens/HomeScreen/HomeScreenViewModel.swift` — +setupArchiveSubscription, +mute при архивации
- `Screens/HomeScreen/View/HomeScreenContent.swift` — +archiveRow (строка "Архив")
- `Screens/HomeScreen/HomeScreenCoordinator.swift` — +presentArchive action
- `FlowCoordinators/ChatsTabFlowCoordinator.swift` — +presentArchiveScreen навигация

#### Коммит для применения:
```bash
git cherry-pick 5a1ffdba
```

---

### 34. Telegram-style архив v2 — trailing свайп + undo toast

**Дата**: 2026-02-18
**Коммит**: `bfcef467`

#### Описание:
Доработка архива до полного Telegram-стиля: архивация по свайпу ВЛЕВО (trailing), undo toast "Чат архивирован" с кнопкой "Отменить".

#### Функциональность:
- **Архив в trailing swipe** — кнопка "Архив" теперь при свайпе влево (как в Telegram), а не вправо
- **Undo toast** — после архивации показывается toast "Чат архивирован" с кнопкой "Отменить" (2.5 сек)
- **Кнопка "Отменить"** — разархивирует чат (flagAsLowPriority(false) + restoreDefaultNotificationMode)
- **UserIndicator с action** — расширен для поддержки интерактивных toast'ов (actionTitle + action closure)

#### Изменённые файлы:
- `Other/UserIndicator/UserIndicator.swift` — +actionTitle, +action, manual Equatable conformance
- `Other/UserIndicator/UserIndicatorToastView.swift` — рендеринг кнопки action в toast
- `Screens/HomeScreen/HomeScreenViewModel.swift` — undo toast при архивации + unarchiveRoom helper
- `Screens/HomeScreen/View/HomeScreenRoomList.swift` — "Архив" из leading → trailing actions

#### Коммит для применения:
```bash
git cherry-pick bfcef467
```

### 35. Telegram-style pull-to-reveal архив + fix unmute

**Дата**: 2026-02-19
**Коммит**: `bc872ec5`

#### Описание:
Переделка строки архива под стиль Telegram: голубая иконка, pull-to-reveal поведение, исправление unmute.

#### Изменения:
- 🔵 Строка "Архив": голубая иконка 52pt (вместо серой 40pt), убраны счётчик и шеврон
- 🫣 Архив скрыт по умолчанию — не рендерится пока пользователь не потянет список вниз (overscroll > 60pt)
- ↕️ При прокрутке вверх (offset > 80pt) архив автоматически скрывается с компенсацией сдвига контента
- 🎬 Анимация появления/скрытия `.easeOut(duration: 0.25)` с transition `.move(edge: .top)`
- 🔔 Fix unmute: `setNotificationMode(.allMessages)` вместо `restoreDefaultNotificationMode` — теперь unmute работает для архивных комнат

#### Изменённые файлы:
- `Screens/HomeScreen/View/HomeScreenContent.swift` — pull-to-reveal архив, overscroll detection, Telegram-style иконка
- `Screens/HomeScreen/HomeScreenViewModel.swift` — fix unmute через `.allMessages`

#### Коммит для применения:
```bash
git cherry-pick bc872ec5
```

---

### 36. Presence (онлайн-статус) контактов + отправка своего presence

**Дата**: 2026-02-19
**Коммиты**: `d3bd8a10`, `db9f5403`

#### Описание:
Реальный онлайн-статус контактов через Matrix Presence API. Зелёная точка и "в сети" для онлайн-пользователей, "был(а) X мин./ч. назад" для оффлайн. Приложение отправляет свой presence — другие видят нас "в сети". Polling каждые 30 сек.

#### Функциональность:
- **GET** `/_matrix/client/v3/presence/{userId}/status` — получение статуса собеседников
- **PUT** `/_matrix/client/v3/presence/{userId}/status` — отправка своего статуса (online/offline)
- **Polling** каждые 30 сек — обновление статусов всех контактов
- **Lifecycle** — foreground → online + restart polling, background → offline + stop polling
- **Фильтр "В сети"** — показывает только онлайн-контактов (реальные данные вместо захардкоженных)

#### Новые файлы:
- `ElementX/Sources/Services/Presence/PresenceService.swift` — HTTP-сервис presence (async/await, TaskGroup для параллельных запросов)

#### Изменённые файлы:
- `ContactsListScreenModels.swift` — `matrixUserID: String?` в ContactItem, `isOnline`/`lastSeenDate` → var
- `ContactsListScreenViewModel.swift` — setupPresenceService(), applyPresence(), lifecycle handlers
- `ContactsTabFlowCoordinator.swift` — передача PresenceService (не требуется, создаётся в VM)

#### Технические детали:
- Access token: `(clientProxy as? ClientProxy)?.matrixAccessToken()`
- Homeserver URL: strip trailing slash (избежание двойного `//`)
- UserID encoding: `@` и `:` percent-encoded в URL path
- Heroes: `summary.heroes.first?.userID` для определения собеседника в DM

#### Коммиты для применения:
```bash
git cherry-pick d3bd8a10  # feat: базовая реализация presence
git cherry-pick db9f5403  # fix: trailing slash, percent-encode, foreground restart
```

---

### 37. Избранные контакты — свайп влево + фильтр "Избранные"

**Дата**: 2026-02-19
**Коммиты**: `2e2d2f4d`, `a3e4b0b2`

#### Описание:
Избранные контакты в стиле Telegram. Свайп влево на контакте открывает оранжевую кнопку "Избранное" (как swipe actions в чатах). Фильтр "Избранные" показывает только отмеченных. Данные сохраняются в UserDefaults.

#### Функциональность:
- **Свайп влево** на контакте → оранжевая кнопка "Избранное" (звёздочка)
- **Повторный свайп** → "Убрать" (star.slash) — снимает из избранных
- **Фильтр "Избранные"** — показывает только отмеченные контакты
- **Персистентность** — UserDefaults (`ru.implica.stalk.favoriteContacts`)
- **SwipeActionView** — переиспользован кастомный компонент из чатов (сделан internal)

#### Изменённые файлы:
- `ContactsListScreenModels.swift` — `isFavorite: Bool` в ContactItem, `toggleFavorite(ContactItem)` action
- `ContactsListScreenViewModel.swift` — `favoriteRoomIDs: Set<String>`, toggleFavorite(), saveFavorites()
- `ContactsListScreen.swift` — SwipeActionView wrapper, фильтр .favorites, убраны кнопки-звёздочки
- `HomeScreenRoomList.swift` — `SwipeAction` и `SwipeActionView` из `private` → `internal`

#### Коммиты для применения:
```bash
git cherry-pick 2e2d2f4d  # feat: избранные контакты (модель + логика + UI)
git cherry-pick a3e4b0b2  # refactor: свайп влево вместо кнопки-звёздочки
```

### 38. VoIP Push — Sygnal push gateway + VoIP pusher registration

**Дата**: 2026-02-25
**Коммиты**: `fd61566c`

#### Описание:
Настройка VoIP Push уведомлений для мгновенных входящих звонков через PushKit + CallKit. Развёрнут Sygnal push gateway на K8s, обновлён push gateway URL, реализована отправка VoIP push token на сервер.

#### Функциональность:
- **Sygnal push gateway** развёрнут на K8s (namespace `matrix`, порт 5000)
- **Ingress** настроен: `/_matrix/push` → Sygnal (перед `/_matrix` → Synapse)
- **pushGatewayBaseURL** обновлён с `matrix.org` на `stalk.implica.ru`
- **VoIP pusher registration** — `didUpdate pushCredentials` теперь отправляет VoIP token на сервер
- **Well-known** обновлён с `org.matrix.msc3881.push_gateway`
- **Два app_id** в Sygnal: `ru.implica.stalk.ios.dev` (обычные push) и `ru.implica.stalk.voip` (VoIP)

#### Серверные изменения (K8s):
- ConfigMap `sygnal-config` — конфиг Sygnal с APNs apps
- Secret `sygnal-apns-key` — APNs `.p8` ключ (placeholder, требует реальный ключ)
- Deployment `sygnal` — matrixdotorg/sygnal:latest
- Service `sygnal` — ClusterIP:5000
- Ingress route `/_matrix/push` в stalk-ingress
- Well-known ConfigMap обновлён с push_gateway

#### Изменённые файлы (iOS):
- `AppSettings.swift:278` — `pushGatewayBaseURL` → `https://stalk.implica.ru`
- `ElementCallService.swift:36` — `voipDeviceToken: Data?` для хранения VoIP токена
- `ElementCallService.swift:46-48` — регистрация VoIP pusher при получении clientProxy
- `ElementCallService.swift:185-195` — `didUpdate pushCredentials` реализация
- `ElementCallService.swift:345-370` — `registerVoIPPusher()` метод

#### ⚠️ Требуется для завершения:
1. **APNs ключ (.p8)** — сгенерировать в Apple Developer Portal и загрузить в K8s Secret `sygnal-apns-key`
2. **KEY_ID** — обновить `PLACEHOLDER_KEY_ID` в ConfigMap `sygnal-config` на реальный Key ID
3. Перезапустить Sygnal pod после обновления ключа

#### Коммиты для применения:
```bash
git cherry-pick fd61566c  # feat(VoIP): push gateway URL + VoIP pusher registration
```

---

### 39. Org-profile — должность и отдел в контактах

**Дата**: 2026-03-05
**Коммит**: `ddb70669`
**Задача**: STMOB-51

#### Что сделано:
- Добавлены поля `jobTitle` и `department` в `ContactItem`
- Создан `OrgProfileService` — загрузка данных из `/api/org-profile/:userId`
- Проверка включённых полей через `/api/org-profile/settings`
- Subtitle "должность · отдел" отображается под именем контакта
- Одноразовая загрузка профилей (кеш в `CurrentValueSubject`)

#### Затронутые файлы:
- `ContactsListScreenModels.swift` — поля `jobTitle`, `department` в `ContactItem`
- `ContactsListScreenViewModel.swift` — `OrgProfileService` интеграция
- `ContactsListScreen.swift` — subtitle в ячейке контакта
- `Services/OrgProfile/OrgProfileService.swift` — **новый файл**

#### Коммиты для применения:
```bash
git cherry-pick ddb70669  # feat(Contacts): org-profile — должность и отдел
```

---

### 40. Meetings-api — расписание встреч на вкладке Звонки

**Дата**: 2026-03-05
**Коммит**: `0262289a`
**Задача**: STMOB-52

#### Что сделано:
- `MeetingsService` — загрузка встреч из `/api/meetings` + RSVP через `/api/meetings/:id/rsvp`
- Секция "Встречи" над историей звонков с календарной иконкой (день/число)
- RSVP кнопки (✓ принять / ✗ отклонить) для pending приглашений
- Кнопка "Присоединиться" (video) для принятых встреч с matrix room
- Время, место, количество участников, статус RSVP
- Фильтрация: только предстоящие (не cancelled, не прошедшие)

#### Затронутые файлы:
- `Services/Meetings/MeetingsService.swift` — **новый файл**
- `CallsListScreenModels.swift` — actions + state для meetings
- `CallsListScreenViewModel.swift` — MeetingsService интеграция
- `CallsListScreen.swift` — meetingCell + RSVP UI

#### Коммиты для применения:
```bash
git cherry-pick 0262289a  # feat(Calls): meetings-api — расписание встреч
```

---

### 41. Избранные сообщения (Bookmarks) — сохранение/удаление через контекстное меню

**Дата**: 2026-03-23

#### Что сделано:
- `BookmarkService` — локальное хранение избранных сообщений в UserDefaults (до 500 шт.)
- `BookmarkedMessage` модель — eventID, roomID, senderID, senderName, body preview (200 chars), timestamp
- Действие "В избранное" / "Из избранного" в контекстном меню сообщений (long press)
- Иконка `favourite` из Compound Design Tokens
- Регистрация `BookmarkService` в `ServiceLocator` (singleton)
- Строки уже были в `SL10n`: `bookmarkAdd`, `bookmarkRemove`, `bookmarkTitle`, `bookmarkEmpty`

#### Затронутые файлы:
- `Services/Bookmark/BookmarkService.swift` — **новый файл**
- `Application/ServiceLocator.swift` — регистрация BookmarkService
- `Application/AppCoordinator.swift` — setupBookmarkService() при запуске
- `Timeline/View/ItemMenu/TimelineItemMenuAction.swift` — `.bookmark` / `.removeBookmark` cases
- `Timeline/View/ItemMenu/TimelineItemMenuActionProvider.swift` — добавление bookmark action с проверкой isBookmarked
- `Timeline/TimelineInteractionHandler.swift` — обработка bookmark/removeBookmark действий

#### Коммиты для применения:
```bash
git cherry-pick <commit>  # feat(Bookmarks): bookmark/unbookmark messages via context menu
```

---

## 🎯 Текущий статус

**Версия Element X**: Форк на основе upstream develop
**Ветка**: develop
**Функционал**:
- ✅ Saved Accounts экран (CUSTOM-CHANGES.md #1-3)
- ✅ Widgets вкладка (#1-2 в этом файле)
- ✅ 4-tab навигация: Контакты, Звонки, Чаты, Приложения (#3)
- ✅ Запись звонков + Recording API (#4)
- ✅ Унифицированные фильтры (#5)
- ✅ Stalk Tab Bar с Lottie (#6)
- ✅ Telegram-style: SF Symbol иконки, underline фильтры, зелёные бейджи (#7)
- ✅ Telegram-style: шапки и навигация — segmented control, compose, Edit (#8)
- ✅ Telegram-style: двойной bubble иконка, dot-бейджи, cleanup (#9)
- ✅ Telegram-style: алфавитный индекс, секции дат, профиль, chevron (#10)
- ✅ Swipe actions на ячейках чатов (#11)
- ✅ Badge непрочитанных на вкладке Чаты (#12)
- ✅ Недавние поисковые запросы + фикс навбара (#13)
- ✅ Интерактивный slider для плеера записей (#14)
- ✅ Алфавитный скруббер на экране Контакты (#15)
- ✅ Кнопки редактирования профиля, секции настроек, анимация фильтров (#16)
- ✅ Фильтрация приложений по категориям (#17)
- ✅ Dark Mode аудит — adaptive цвета (#18)
- ✅ Миграция на stalk.implica.ru — динамические URL (#19)
- ✅ Telegram-style Tab Bar — SF Symbols filled/outline, зелёные бабблы (#20)
- ✅ Inline titles на всех экранах (#21)
- ✅ Навигация контакт → чат (как в Telegram) (#22)
- ✅ Фильтр пустых комнат в контактах (#23)
- ✅ Поиск сообщений внутри чата (как в Telegram) (#24)
- ✅ Telegram-style CallScreen UI — CSS injection в Element Call WebView (#25)
- ✅ CallScreen v4 — 5 нативных кнопок, рука, динамик, формат участников, CSS grid (#26)
- ✅ Исправление конфликта LiveKit SDK + адаптация API (#27)
- ✅ Виджеты — реальные URL с продакшена (#28)
- ✅ Виджет статистики — персональная информация пользователя (#29)
- ✅ CallScreen v5 — Native LiveKit Video + Phase 4 Cleanup (#30)
- ✅ OIDC Login Fix — AASA + HTTPS Redirect + Entitlements (#31)
- ✅ SWR кеширование данных + управление кешем в настройках (#32)
- ✅ Telegram-style архив чатов (#33)
- ✅ Telegram-style архив v2 — trailing свайп + undo toast (#34)
- ✅ Pull-to-reveal архив + fix unmute (#35)
- ✅ Presence (онлайн-статус) контактов + отправка своего presence (#36)
- ✅ Избранные контакты — свайп влево + фильтр "Избранные" (#37)
- ✅ VoIP Push — Sygnal push gateway + VoIP pusher registration (#38)
- ✅ Org-profile — должность и отдел в контактах (#39)
- ✅ Meetings-api — расписание встреч на вкладке Звонки (#40)

**Последний коммит**: `0262289a` - feat(Calls): meetings-api — расписание встреч

---

## 📝 Полный чеклист при обновлении Element X

- [ ] Бэкап текущей версии
- [ ] `git fetch upstream && git merge upstream/develop`
- [ ] Применить коммиты из CUSTOM-CHANGES.md (#1-3: Saved Accounts)
- [ ] Применить коммиты #1-2: Widgets (`21dd96e`, `68a68b4`, `1deb412`)
- [ ] Применить коммит #3: 4-tab navigation (`4978145`, `a91a56f`)
- [ ] Применить коммиты #4: Recording API (серия ~15 коммитов)
- [ ] Применить коммит #5: Фильтры (`0d07b3d`)
- [ ] Применить коммит #6: Stalk Tab Bar + Lottie (`636fee5`)
- [ ] Применить коммит #7: Telegram-style SF Symbols + underline + бейджи (`3b4452e`)
- [ ] Применить коммит #8: Telegram-style шапки (`265fc03`)
- [ ] Применить коммит #9: Telegram-style доработки (`ea581d3`)
- [ ] Применить коммит #10: Алфавит, секции дат, профиль (`859b3d6`)
- [ ] Применить коммит #11: Swipe actions (`35bbc8e`)
- [ ] Применить коммит #12: Badge непрочитанных (`a5d8724`)
- [ ] Применить коммит #13: Недавние поисковые запросы (`95323f8`)
- [ ] Применить коммит #14: Интерактивный slider записей (`c00a5b1`)
- [ ] Применить коммит #15: Алфавитный скруббер контактов (`5b31df2`)
- [ ] Применить коммит #16: Кнопки профиля, секции настроек, анимация (`32f5a0a`)
- [ ] Применить коммит #17: Фильтрация приложений по категориям (`c2a16c4`)
- [ ] Применить коммит #18: Dark Mode adaptive цвета (`608e0d9`)
- [ ] Применить коммит #19: Миграция stalk.implica.ru + динамические URL (`8d9ef0f`)
- [ ] Применить коммит #20: Telegram-style Tab Bar + зелёные бабблы (`c220ddc`)
- [ ] Применить коммиты #21: Inline titles на всех экранах (`c220ddc`, `71745dc`)
- [ ] Применить коммит #22: Навигация контакт → чат (`e49ba44`)
- [ ] Применить коммит #23: Фильтр пустых комнат в контактах (`7bbfa2b`)
- [ ] Применить коммит #24: Поиск сообщений внутри чата (`d8fb603`)
- [ ] Применить коммиты #25: Telegram-style CallScreen UI (`d0f38ce`, `f4a7ccf`, `7d6b575`)
- [ ] Применить коммит #26: CallScreen v4 — 5 кнопок, рука, динамик, grid (`53dd858`)
- [ ] Применить коммит #27: Исправление конфликта LiveKit SDK + API (`3cd7b9b`)
- [ ] Применить коммит #28: Виджеты — реальные URL (`333daf5`)
- [ ] Применить коммит #29: Виджет статистики — userId (`c5bf455`)
- [ ] Применить коммит #30: CallScreen v5 — Native LiveKit + cleanup (`0b7b947c` + серия)
- [ ] Применить коммит #31: OIDC Login Fix — AASA + entitlements (`1d312d9d`)
- [ ] Применить коммит #33: Telegram-style архив чатов (`5a1ffdba`)
- [ ] Применить коммит #34: Архив v2 — trailing свайп + undo toast (`bfcef467`)
- [ ] Применить коммит #35: Pull-to-reveal архив + fix unmute (`bc872ec5`)
- [ ] Применить коммиты #36: Presence контактов (`d3bd8a10`, `db9f5403`)
- [ ] Применить коммиты #37: Избранные контакты (`2e2d2f4d`, `a3e4b0b2`)
- [ ] Разрешить конфликты в UserSessionFlowCoordinator.swift
- [ ] Проект собирается без ошибок
- [ ] 5 вкладок с SF Symbol иконками работают
- [ ] Underline фильтры с анимацией отображаются на всех экранах
- [ ] Зелёные/серые/красные бейджи корректны (adaptive для dark mode)
- [ ] Записи звонков воспроизводятся с интерактивным slider
- [ ] Кнопки "Изменить фото" / "Изменить имя" в профиле работают
- [ ] Секции настроек с заголовками отображаются
- [ ] Фильтрация приложений по категориям работает
- [ ] Dark Mode: все цвета корректны, нет hardcoded RGB
- [ ] Навигация контакт → чат работает (назад → контакты)
- [ ] Только реальные люди в контактах (без Empty Room)
- [ ] Поиск внутри чата работает (inline bar, счётчик, навигация ↑↓)
- [ ] Виджет статистики показывает персональную карточку пользователя
- [ ] LiveKit SDK зависимости разрешаются без конфликтов

### 38. ✅ E2EE: безопасное восстановление ключей при reinstall

**Дата**: 2026-04-05 — 2026-04-16
**Коммиты**: `10d88e12`, `d2f2f3fe`, `779054a1`, `7e63395c`, `b37aaf5c`

#### Описание:
Исправлена критическая проблема: при переустановке приложения `selfVerifyDevice()` и `cleanupServerE2EEState()` уничтожали ключи бэкапа (m.megolm_backup.v1), делая невозможной расшифровку старых сообщений.

#### Изменения:
- `selfVerifyDevice` использует `tryRestoreFromServerKey` вместо деструктивного `forceEnableRecovery`
- `cleanupServerE2EEState` сохраняет `m.megolm_backup.v1` (не удаляет ключ бэкапа)
- Таймаут восстановления увеличен до 120с
- Удалено всё клиентское удаление бэкапов — сервер управляет lifecycle

#### Файлы:
- `ElementX/Sources/Services/Session/UserSession.swift`

---

### 39. ✅ CallScreen v6: адаптивный grid, аватары, screen share, PiP

**Дата**: 2026-04-14
**Коммит**: `683059ac`

#### Описание:
Полностью переработан UI экрана звонка: адаптивный grid для участников, аватары, индикатор screen share, mute indicator, PiP с активным спикером.

#### Файлы:
- `ElementX/Sources/Screens/CallScreen/`

---

### 40. ✅ Ring notification для входящих звонков (mobile → web)

**Дата**: 2026-04-15 — 2026-04-16
**Коммиты**: `95600ac8`, `510d11eb`, `b37aaf5c`

#### Описание:
NativeCallSession отправляет ring notification через Matrix API сразу после `sendJoinViaREST`. Уведомление содержит `user_ids` и `m.relates_to` для корректного отображения IncomingCallToast на веб-клиенте.

#### Файлы:
- `ElementX/Sources/Services/NativeCall/NativeCallSession.swift`
- `ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift`

---

### 41. ✅ Нативные звонки по умолчанию (убран toggle)

**Дата**: 2026-04-16
**Коммит**: `6c9aa40d`

#### Описание:
Нативные звонки (LiveKit) включены по умолчанию для всех типов звонков. Убран toggle "Нативные звонки" из настроек.

#### Файлы:
- `ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift`
- `ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift`

---

### 42. ✅ Push notifications: авто-запрос разрешений

**Дата**: 2026-04-17
**Коммиты**: `8cfd4dbe`, `eec12439`

#### Описание:
Исправлен баг: при установке на новое устройство (без прохождения onboarding) пушер не регистрировался, т.к. notification permission был `.notDetermined`. Теперь `NotificationManager.setUserSession()` автоматически запрашивает разрешение.

#### Изменения:
- `setUserSession()`: при `.notDetermined` → `requestAuthorization()` → регистрация пушера
- `Info.plist`: добавлен `remote-notification` в `UIBackgroundModes`
- os_log debug для всей цепочки push registration

#### Файлы:
- `ElementX/Sources/Services/Notification/Manager/NotificationManager.swift`
- `ElementX/Sources/Application/AppDelegate.swift`
- `ElementX/SupportingFiles/Info.plist`

---

### 43. ✅ Push: разделение call и text уведомлений

**Дата**: 2026-04-17 — 2026-04-18
**Коммиты**: `67f2ec82`, `29120b50`, `a5f80303`

#### Описание:
VoIP пушер в Synapse получал ВСЕ события (не только звонки), из-за чего каждое текстовое сообщение приходило как CallKit звонок.

#### Решение:
- VoIP pusher registration отключена (voip pushkin удалён из Sygnal)
- NSE: `rtcNotification` показывается с 📞 в заголовке и `defaultRingtone` (fallback если CallKit не сработал)
- Звонки идут через обычный APNs push → NSE → `CXProvider.reportNewIncomingVoIPPushPayload` → CallKit

#### Серверные изменения:
- Удалён `ru.implica.stalk.voip` из Sygnal ConfigMap
- Удалены VoIP пушеры из БД Synapse

#### Файлы:
- `ElementX/Sources/Services/ElementCall/ElementCallService.swift`
- `NSE/Sources/NotificationHandler.swift`
- `NSE/Sources/NotificationContentBuilder.swift`

---

### 44. ✅ Push: подавление badge-only уведомлений

**Дата**: 2026-04-18
**Коммиты**: `0d69843e`, `01ab94c1`

#### Описание:
Badge update пуши (`room:None, event:None`) проходили через NSE и показывали "Новое сообщение" без текста. Теперь при отсутствии `eventID` уведомление подавляется.

#### Файлы:
- `NSE/Sources/NotificationServiceExtension.swift`

---

### 45. ✅ CallKit из NSE: PushKit без VoIP пушера

**Дата**: 2026-04-18
**Коммит**: `45f36285`

#### Описание:
PushKit включён локально (нужен для `CXProvider.reportNewIncomingVoIPPushPayload` из NSE), но VoIP пушер НЕ регистрируется в Synapse. Sygnal без voip pushkin — даже при попытке регистрации, Sygnal отклонит.

#### Архитектура пушей (Build 34):
```
Сообщение → Synapse → Sygnal (ios.prod) → APNs → NSE → текстовое уведомление
Звонок    → Synapse → Sygnal (ios.prod) → APNs → NSE → CXProvider → CallKit
                                                         ↓ (fallback)
                                                         📞 push-уведомление
```

#### Файлы:
- `ElementX/Sources/Services/ElementCall/ElementCallService.swift`
- `NSE/Sources/NotificationHandler.swift`

---

### 46. ✅ E2EE hotfix: независимые call keys на каждом индексе

**Дата**: 2026-04-18
**Коммит**: `c4d59475`
**Plane**: STMOB-77

#### Проблема
После подключения нового участника (например, Бондарь зашёл к Самусенко) получатель слышал 1-2 секунды зашифрованного шума, потом тишина. Видео — чёрный экран.

#### Root cause
В `handleEncryptionKeys` при получении call key с `index=N` код записывал этот же ключ на все индексы `0...N` ("in case we missed earlier keys"). Но в Element Call ключи **ротируются** при каждом join/leave — каждый индекс хранит независимый random ключ. Workaround затирал валидные ключи на младших индексах → пакеты с `keyIndex < N` декодировались неправильным ключом → гарбл.

#### Фикс
Убран цикл `for idx in 0...Int32(keyInfo.index)` — пишем только в точный индекс, как это уже делается в timeline-path (`listenForEncryptionKeysFromTimeline`).

#### Файлы:
- `ElementX/Sources/Services/NativeCall/NativeCallSession.swift` (строки 781-786)

---

### 47. ✅ E2EE/WS reliability: retry ключей + auto-reconnect + background task + диагностика

**Дата**: 2026-04-18
**Коммит**: `17a1864b`
**Plane**: STMOB-73, STMOB-74, STMOB-75

#### Контекст
Продолжение расследования звонка 18.04 (Самусенко–Тымбай–Бондарь). Кроме hotfix #46 нужны:
- Надёжная доставка E2EE ключей (retry + reuse + resend on network change)
- Стабильность WebSocket на iOS (background task + auto-reconnect + AudioSession)
- Диагностические логи через os_log (subsystem `ru.implica.stalk`)

#### E2EE (STMOB-73)
1. **Reuse existing key** — `sendOurEncryptionKey` больше не регенерит ключ на каждый вызов. Периодические resend-ы и resend на новом участнике отправляют ТОТ ЖЕ ключ, а не ротируют.
2. **setRawKey consistency** — `sendOurEncryptionKey` теперь использует `setRawKeyInProvider` с `ourEncryptionKeyRaw` (как connectToLiveKit и handleEncryptionKeys), а не `keyProvider.setKey(string)`. Это важно для HKDF: UTF-8 байты base64-строки ≠ сырые 16 байт.
3. **Retry с backoff** — `send_to_device` и `send_event` теперь делают 3 попытки с задержкой 1s/2s/4s, парсят `Result<Bool, Error>` и явно логируют успех/fail.
4. **NWPathMonitor** — при смене wifi ↔ cellular ↔ none re-send E2EE ключа (покрывает сценарий Бондаря 18.04, когда он сменил сеть через 50 сек и пропустил to_device ключи).

#### WebSocket (STMOB-74)
1. **Background task** — `UIApplication.beginBackgroundTask` на `didEnterBackground`, держит WS живым при уходе iOS в background (причина cascade-выкида 18.04).
2. **AudioSession interruption** — наблюдатель `AVAudioSession.interruptionNotification`, re-activate session по окончании interruption (звонок/Siri).
3. **AudioSession route change** — логируется.
4. **Auto-reconnect** — на unexpected disconnect (old=`.connected`|`.reconnecting` → new=`.disconnected`): 3 попытки с задержкой 1s/3s/7s. Использует сохранённые `reconnectURL`/`reconnectToken`/`savedKeyProvider`.

#### Diagnostics (STMOB-75)
1. Новые OSLog категории: `Call` и `LiveKit` (subsystem `ru.implica.stalk`).
2. WS state transitions, network changes, send_to_device results, AudioSession events — всё через `os_log` для видимости в `log stream --predicate 'subsystem == "ru.implica.stalk"'`.

#### Отложено (не реализовано в этом коммите)
- **1.1 Key request mechanism** — когда клиент не может декодировать трек, активно послать to_device `io.element.call.encryption_keys.request`. Требует координации протокола с web-клиентом Element Call. Оставлено в STMOB-73 как follow-up.
- **4.1 Decrypt failure hook** — нужен hook в LiveKit SDK на неудачные decrypt-попытки. Требует исследования API.
- **2.2 Application keepalive ping** — у LiveKit уже есть свой WS keepalive; пока не добавляем.
- **3.1 Cascade disconnect в LiveKit SFU** — upstream-issue, не наш код.

#### Файлы:
- `ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — +NWPathMonitor, refactored sendOurEncryptionKey, sendWidgetMessageWithRetry helper
- `ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — +lifecycle observers, +attemptAutoReconnect, enhanced delegate logging

---

### 49. ✅ Camera reset после Quick reconnect — фикс чёрного видео на вебе (build 45)

**Дата**: 2026-04-21
**Коммит**: TBD (build 45)
**Plane**: STMOB-76

#### Контекст
Build 44 в TestFlight показал — при WiFi→cellular звонок не умирает (Quick reconnect работает), звук переключается, НО **веб перестаёт видеть видео с iOS** (чёрный экран). iOS при этом продолжает видеть веб нормально.

#### Диагноз
На симуляторе воспроизвести не удалось — BufferCapturer (генерирует frames в памяти) работает через iceRestart без проблем. На физ устройстве **`AVCaptureSession`** (реальная камера) продолжает получать frames локально, но они **не долетают до publisher track** после iceRestart. Симптом: `camera.localVideoTrack` существует, frames пишутся, но SFU не видит media. Специфика WebRTC iOS SDK.

#### Фикс
В `LiveKitRoomManager.attemptQuickReconnect(trigger:)` после `Quick reconnect SUCCESS` вызываем `resetCameraAfterReconnect()`:
1. Проверяем что camera publication была активна и не muted
2. `setCamera(false)` → unpublish track
3. `setCamera(true)` → publish fresh track с новой AVCaptureSession

Занимает ~1 сек на физ устройстве (чёрный экран на вебе в это время), но видео восстанавливается автоматически без hangup+redial.

#### Тестирование
- **Симулятор + debug timer**: через 20 сек после connect код сам триггерит fake `wifi → cellular`. Логи показывают чистую цепочку `Quick reconnect starting → SUCCESS → Resetting camera → Camera reset SUCCESS` за 340+1 мс. Веб видит видео с BufferCapturer continuously (мини-пробел).
- **Физ устройство**: собирается для TestFlight (build 45).

#### Файлы
- `ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — `attemptQuickReconnect` вызывает `resetCameraAfterReconnect` на SUCCESS
- `ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — debug timer 20s в `#if targetEnvironment(simulator)` для reproducibility на симе
- `sTalk.xcodeproj/project.pbxproj` — CURRENT_PROJECT_VERSION 44→45

---

### 48. 🧪 Quick reconnect (ICE restart) на смене сети — эксперимент build 44

**Дата**: 2026-04-20
**Коммит**: TBD (build 44)
**Plane**: STMOB-74, STMOB-76 (research)
**Статус**: эксперимент — фичефлаг `kEnableQuickReconnectOnNetworkChange = true`

#### Контекст
Build 41/42 пытался `room.disconnect()` + `connect()` на смене сети (WiFi↔cellular) — создавал infinite reconnect loop и убивал звонок. Build 43 откатился к чистому resend E2EE key. Остаётся known issue: mid-call смена сети морозит видео, workaround — повесить трубку и перезвонить.

#### Research (до этого коммита)
Изучили LiveKit Swift SDK (`build-device/SourcePackages/checkouts/client-sdk-swift`):
- **Public API**: `Room.debug_simulate(scenario: SimulateScenario)` — `Room+Debug.swift:32`
- Сценарии: `.quickReconnect` (ICE restart на живых transports), `.fullReconnect` (как build 41/42), `.nodeFailure`, `.migration`, `.serverLeave`
- **`quickReconnect` != build 41/42**: не делает teardown RTCPeerConnection, только ICE restart через `publisher.createAndSendOffer(iceRestart: true)` + `subscriber.setIsRestartingIce()` (Room+Engine.swift:307-353)
- SDK сам fallback на `.full` через retry logic если quick не получился (Room+Engine.swift:414)

#### Изменения
1. **LiveKitRoomManager.attemptQuickReconnect(trigger:)** — новый public метод. Проверяет `connectionState == .connected`, вызывает `room.debug_simulate(scenario: .quickReconnect)` с try/catch и os_log.
2. **NativeCallSession.handleNetworkPathChange** — после resend E2EE key, если `kEnableQuickReconnectOnNetworkChange == true`, вызывает `liveKitRoomManager.attemptQuickReconnect(trigger: "network:wifi→cellular")`.
3. **Фичефлаг** — `private static let kEnableQuickReconnectOnNetworkChange = true` в NativeCallSession. Если эксперимент сломает — поменять на `false` для возврата к build 43 поведению.

#### Что тестировать
- Mid-call WiFi→cellular: видео должно восстановиться без hangup. Логи: `Quick reconnect starting — trigger=network:wifi→cellular` → `Quick reconnect SUCCESS`.
- Если `.quickReconnect` зависнет — SDK сам должен fall back на `.full` (watch for `Reconnect mode: quick failed` в логах).
- Регресс: звонок не должен стать менее стабильным в обычных сценариях.

#### Файлы:
- `ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — +attemptQuickReconnect(trigger:)
- `ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — hook в handleNetworkPathChange + фичефлаг
- `sTalk.xcodeproj/project.pbxproj` — CURRENT_PROJECT_VERSION 43→44

---

- [ ] Применить коммиты #38: E2EE safe restore (`10d88e12`...`b37aaf5c`)
- [ ] Применить коммит #39: CallScreen v6 grid (`683059ac`)
- [ ] Применить коммиты #40: Ring notification (`95600ac8`, `510d11eb`)
- [ ] Применить коммит #41: Native calls default (`6c9aa40d`)
- [ ] Применить коммиты #42: Push auto-permission (`8cfd4dbe`, `eec12439`)
- [ ] Применить коммиты #43: Push call/text separation (`67f2ec82`, `29120b50`, `a5f80303`)
- [ ] Применить коммиты #44: Badge suppression (`0d69843e`, `01ab94c1`)
- [ ] Применить коммит #45: CallKit from NSE (`45f36285`)

---

### 49. ✅ NSE passive content — полное подавление baseline-баннеров от encryption_keys (build 98)

**Дата**: 2026-05-02
**Коммит**: TBD (build 98)
**Plane**: STMOB-94

#### Симптом
На входящий MatrixRTC звонок iPhone показывал 3 baseline-баннера ("1 уведомление" / "sTalk: Новое сообщение") за 1-2 сек до основного CallKit fullscreen UI. По логу build 97 (2026-05-02 11:26 MSK):
```
11:26:16.985  NSE event $z2UKNLt...  contentType=nil → unsupportedShouldDiscard
11:26:17.445  NSE event $pcboDSSX... contentType=nil → unsupportedShouldDiscard
11:26:17.744  NSE event $-iTrUWn...  contentType=nil → unsupportedShouldDiscard
11:26:18.954  VoIP push → CallKit shown за 66 ms
```

#### Корень
3 события — `m.room.encrypted` от инициатора звонка, после расшифровки — `io.element.call.encryption_keys` (Per-Participant E2EE keys для нового звонка). Серверный фикс невозможен без слома `.m.rule.encrypted` для обычных DM.

Build 97 уже ставил `interruptionLevel = .passive` в `discardNotification()`, но iOS 26.3 всё равно показывал baseline-баннер: при `mutable-content=1` + `alert` payload iOS использует `alert` из исходного APNS payload как fallback, если NSE-content не обнулил title/body/subtitle/sound/attachments/userInfo явно.

#### Изменения
1. **`NSE/Sources/NotificationHandler.swift`** — добавлен `static func makePassiveContent()`, который явно ставит `title=""`, `subtitle=""`, `body=""`, `sound=nil`, `attachments=[]`, `userInfo=[:]`, `interruptionLevel=.passive`, `relevanceScore=0`. `discardNotification()` теперь делегирует в этот helper.
2. **`NSE/Sources/NotificationServiceExtension.swift`** — badge-update path (eventID==nil) использует `NotificationHandler.makePassiveContent()` вместо просто `UNMutableNotificationContent()`.

#### Что НЕ трогается
Fallback-пути для locked device / no credentials / session-creation failure (`NotificationServiceExtension.swift:99-115, 155`) оставлены с "sTalk Новое сообщение" — для реальных недешифруемых сообщений это полезно. Encryption_keys на эти пути не попадают при нормальной работе (Molly уже почистила stale pushers, остались 2 валидных: 1 main + 1 VoIP).

#### Acceptance
- На заблокированном экране при входящем звонке: только CallKit fullscreen, никаких других баннеров до или после.
- Reinstall build 98 + первый звонок с новой пары устройств — лишних баннеров нет.
- NSE по-прежнему расшифровывает обычные сообщения и показывает message preview.

#### Файлы:
- `ios/NSE/Sources/NotificationHandler.swift` — +makePassiveContent (строки ~230-258)
- `ios/NSE/Sources/NotificationServiceExtension.swift` — badge-update path (~94)
- `ios/sTalk.xcodeproj/project.pbxproj` — CURRENT_PROJECT_VERSION 97→98

---

### 50. ✅ Pusher cleanup — удаление stale pushers того же app_id перед setPusher (build 99)

**Дата**: 2026-05-02
**Коммит**: `814ce6c2` (build 99)
**Plane**: STMOB-95

#### Контекст
На каждом reinstall iOS app генерится новый APNS device token → Element X iOS делает `POST /pushers/set` с новым `pushkey`. Старые pushers того же юзера остаются в Synapse. У `@dp.bondar` накопилось 11 stale main app pushers + 1 VoIP — Synapse fan-out на ВСЕ → 11x запросов в sygnal на каждый event. Sygnal встроенный auto-cleanup через `BadDeviceToken` от Apple срабатывает не всегда (zombie tokens возвращают success).

#### Архитектурное замечание
Matrix Rust SDK не отдаёт `GET /pushers` — нет API `listPushers()`. Поэтому полностью повторить процесс из спеки (GET → filter по app_id → DELETE) нельзя без прямого HTTP-запроса. Решение через **локальную историю pushkeys в UserDefaults** — клиент сам помнит все ранее зарегистрированные pushkeys для (userID, app_id) и DELETE'ит их перед новым setPusher.

#### Изменения
1. **`ClientProxyProtocol.swift` / `ClientProxy.swift`** — добавлен метод `deletePusher(pushkey:appId:)` обёрткой над SDK `client.deletePusher(identifiers:)` (внутри SDK — `POST /pushers/set` с `kind: null`).
2. **`NotificationManager.swift`** — добавлен `enum PusherHistoryStorage` с UserDefaults storage `stalk_pusher_history` (структура `[userID: [appId: [pushkey, ...]]]`). Методы `recordedPushkeys`, `recordPushkey`, `forgetPushkey`.
3. **`NotificationManager.setPusher` (APNS)** — перед `setPusher(new pushkey)` итерирует known prior pushkeys того же appId и вызывает `deletePusher` для каждого (best-effort). После успешного setPusher записывает новый pushkey в историю.
4. **`ElementCallService.registerVoIPPusher` (VoIP)** — тот же паттерн для VoIP app_id.
5. **`Mocks/Generated/GeneratedMocks.swift`** — добавлен mock `deletePusher` (manually — sourcery нужно перегенерить при следующем регуляр-апдейте).

#### Лимитации
- До build 99 у пользователей нет UserDefaults history → первый запуск build 99 знает только текущий pushkey, старые stale остаются. Для них нужен одноразовый серверный SQL DELETE (Molly уже сделала) или Apple BadDeviceToken eventually.
- Начиная с build 99 — на каждый reinstall история сохраняется (UserDefaults живёт через reinstall), cleanup отрабатывает.

#### Acceptance
- После reinstall в Synapse у юзера ≤1 pusher с каждым `app_id`
- Cleanup best-effort: если delete упал — регистрация нового всё равно выполняется
- Работает независимо от `BadDeviceToken` от Apple
- В DiagLog APNS/VoIP видны строки `cleanup deleted stale pushkey=...`

#### Файлы:
- `ios/ElementX/Sources/Services/Client/ClientProxyProtocol.swift` — +deletePusher in protocol
- `ios/ElementX/Sources/Services/Client/ClientProxy.swift` — +deletePusher impl
- `ios/ElementX/Sources/Services/Notification/Manager/NotificationManager.swift` — +PusherHistoryStorage enum, +cleanup loop в setPusher
- `ios/ElementX/Sources/Services/ElementCall/ElementCallService.swift` — +cleanup loop в registerVoIPPusher
- `ios/ElementX/Sources/Mocks/Generated/GeneratedMocks.swift` — +deletePusher mock

---

### 51. ✅ Continuous E2EE key rebroadcast — iOS прекращал слать keys через 2 мин (build 99)

**Дата**: 2026-05-02
**Коммит**: `57196c1e` (build 99)
**Plane**: STMOB-96

#### Симптом
В активном MatrixRTC звонке web-участники переставали слышать iPhone после reconnect (новый pID = peer connection с нуля). Bondar audio track продолжал публиковаться в LiveKit, но key rotation в room timeline останавливалась через ~2 минуты после JOIN.

Synapse timeline показал gap 7+ минут без `m.room.encrypted` от bondar (с 11:35:21 до 11:42:24 на боевом инциденте).

#### Корень
`ElementX/Sources/Services/NativeCall/NativeCallSession.swift:170-176` (build 98):
```swift
for _ in 0..<12 {
    try? await Task.sleep(for: .seconds(10))
    guard let self, self.sessionState == .connected else { return }
    await self.sendOurEncryptionKey()
}
```
12 × 10s = **ровно 2 минуты**. После цикл завершался, и iOS никогда больше не транслировал PP E2EE key до завершения сессии (только при membership change).

`sendOurEncryptionKey()` каждый вызов **регенерирует random key** и заменяет в LiveKit keyProvider — поэтому просто продолжать loop без изменений нельзя (создаст постоянную ротацию ключей).

#### Изменения
1. **`NativeCallSession setUp` loop**: первые 2 минуты остаются как было (`sendOurEncryptionKey()` каждые 10s — covers late joiners). Далее continuous `while !Task.isCancelled` с `rebroadcastCurrentEncryptionKey()` каждые 30s до конца сессии.
2. **Новый метод `rebroadcastCurrentEncryptionKey()`** — шлёт **текущий** `ourEncryptionKey` через те же два канала (send_to_device + send_event) **без перегенерации**. Не трогает keyProvider, не публикует на key-server повторно.
3. **Hook на `$remoteParticipants`**: при появлении нового LiveKit identity (reconnect = новый pID или newcomer) — сразу триггерим `rebroadcastCurrentEncryptionKey()`, не ждём 30-секундного тика.
4. **`knownRemoteIdentities: Set<String>`** — отслеживает виденные identity для diff-detection.

#### Acceptance
- В звонке >5 минут iPhone продолжает слать `m.room.encrypted` каждые 30s до конца сессии
- Reconnect web участника → его новый pID получает текущий ключ за <1 сек (через rebroadcast trigger)
- В Synapse: gap между `m.room.encrypted` от iPhone не превышает 30-40 секунд

#### Файлы:
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — replaced fixed 12-iter loop with continuous loop, +rebroadcastCurrentEncryptionKey method, +knownRemoteIdentities tracking, +rebroadcast trigger в $remoteParticipants observer

---

### 52. ✅ CallScreen UI fixes — counter / speaking indicator / names / mini-window active speaker (build 99)

**Дата**: 2026-05-02
**Коммит**: `28259ff9` (build 99)
**Plane**: внутренние QA-фиксы из тестового звонка Bondar (build 98)

#### Симптомы (из скриншота тестового звонка)
1. **Counter "1 из 5 участников"** при 3 реальных подключённых.
2. **Зелёная рамка "говорит"** у себя постоянно (даже при mic muted/тишине).
3. **Имена не показываются** под remote-тайлами (отображалась пустота).
4. **Mini-window (minimized call)** всегда показывает первого по JOIN participant'а независимо от того кто говорит ("Самусенко всегда").

#### Изменения

**`CallScreenViewModel.swift`** — counter `1 из 5`:
- `callParticipantsCount = max(matrixRTC.activeRoomCallParticipants.count, liveKitRoomManager.remoteParticipants.count + 1)` — берём максимум из двух источников. Matrix sync может отставать (особенно если участник не опубликовал `m.call.member` через виджет), а LiveKit реально знает кто в медиа-сессии.
- Добавлена вторая sink на `liveKitRoomManager.$remoteParticipants` — counter обновляется и при LiveKit-изменениях, не только при Matrix sync.

**`NativeCallVideoView.swift` (GroupCallLayout)** — speaking + names:
- Local participant: `isSpeaking = false` всегда (LiveKit voice activity срабатывал на echo/шум, рамка отвлекала; пользователь видит mic state по кнопке).
- Remote participant: `isSpeaking = participant.isSpeaking && !audioMuted` (рамка не зажигается у muted даже при false-positive).
- Новый helper `resolveDisplayName(for:identity:)`: priority — `participant.name` → fuzzy lookup в Matrix participants (по userID) → суффикс identity после `:` → полный identity. Гарантирует имя под каждым тайлом.

**`NativeCallVideoView.swift` (ActiveSpeakerMiniView)** — mini-window:
- Раньше: `remotes.first(where: { $0.isSpeaking }) ?? remotes.first` — при false-positive выбирался первый по JOIN. Теперь: filter по `isSpeaking && !muted`, sort по `audioLevel` (max). Loudest actually-speaking remote выбирается; fallback на `remotes.first` только если никто не активен.
- Новый helper `resolveSpeakerName(for:identity:)` — тот же fuzzy lookup для красивого имени.

#### Файлы:
- `ios/ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift` — dual-source counter + LiveKit subscription
- `ios/ElementX/Sources/Screens/CallScreen/View/NativeCallVideoView.swift` — speaking suppress for local, mute-gated for remote, +resolveDisplayName/resolveSpeakerName helpers, audioLevel-based active speaker

---

### 53. ✅ Call dedup state cleanup — incomingCallID не обнулялся в teardown (build 100, hotfix)

**Дата**: 2026-05-02
**Коммит**: `ae77dd31` (build 100 hotfix)
**Plane**: внутренний hotfix по обнаруженной регрессии в build 99

#### Симптом (build 99 на iPhone Bondar)
После endCall первого звонка следующий VoIP push в ту же комнату через 4+ минуты не показывал CallKit. Пользователь видел "не пришёл нормально звонок". Лог:
```
15:50:16.379  VoIP push (новый звонок)
15:50:16.381  VoIP duplicate ring for room=!Toy..., keeping callKitID=C3ECD42F
              ↑ это callKitID от звонка 15:45:26 который уже завершён 4 мин назад!
```

#### Корень
Dedup-логика добавленная в STMOB-96 (предотвращение duplicate CallKit при fan-out push'ей):
```swift
// ElementCallService.swift:283
if let pending = incomingCallID, pending.roomID == roomID {
    reportAndCancelFakeCall(...)
    return
}
```
Задумана для случая когда iOS получает 3-4 VoIP push'а на один логический звонок в 2 сек. Но `incomingCallID` очищался **только в `setupCallSession()`** (accept-flow). Если accept не прошёл (decline, race на NSE timeout, hang up до setup) — `incomingCallID` оставался stale до перезапуска приложения. На следующий звонок dedup находил stale callKitID → cancel.

#### Изменения
- **`ElementCallService.tearDownCallSession()`**: добавлено `incomingCallID = nil` — раньше обнулялся только `ongoingCallID`. Теперь любой teardown сбрасывает full state.
- **`endUnansweredCallTask?.cancel()`** + nil — иначе залипший таймаут от прошлого ring может выстрелить с `reportCall` на старый callKitID и зашорить новый ring.

Безопасно: `setupCallSession()` (accept-flow) уже делает `incomingCallID = nil`, повторное обнуление в teardown не ломает accept-path. Зато покрывает все остальные exit-пути из ring state.

#### Acceptance
- Decline звонка → новый звонок в ту же комнату через ≥1 сек: CallKit показывается, не cancel'ится как duplicate
- Accept + endCall → новый звонок в ту же комнату через ≥1 сек: CallKit показывается
- Реальный duplicate (3-4 push в 2 сек) — по-прежнему dedup'ится корректно (incomingCallID живёт пока ring активен)

#### Файлы:
- `ios/ElementX/Sources/Services/ElementCall/ElementCallService.swift` — `tearDownCallSession`: +`incomingCallID = nil`, +`endUnansweredCallTask` cancel
- `ios/sTalk.xcodeproj/project.pbxproj` — CURRENT_PROJECT_VERSION 99→100

---

### 54. ✅ Camera toggle fix + STMOB-96 v2 enhanced rebroadcast (build 101)

**Дата**: 2026-05-02
**Коммиты**: `ffb511b1` (camera toggle), `36298276` (STMOB-96 v2)
**Plane**: внутренний QA + STMOB-96

#### A. Camera toggle залипает (commit `ffb511b1`)

**Симптом (build 100):** user тапает toggle камеры — иконка остаётся включённой, self-view продолжает рендерить видео, повторный tap не реагирует, но видео реально перестало идти на web.

**Корень:** `LiveKitRoomManager.updateState()`:
```swift
localVideoTrack = room.localParticipant.videoTracks
    .compactMap { $0.track as? VideoTrack }
    .first
```
`setCamera(enabled: false)` в LiveKit SDK мьютит publication, но НЕ unpublish'ит. Track остаётся в `videoTracks`, `localVideoTrack` остаётся != nil. Observer в `CallScreenViewModel.$localVideoTrack` ставит `state.isVideoEnabled = true` → перетирает toggle обратно в ON.

**Подтверждение в логе 61** (22:52:13-30): 30 тапов за 17 сек, каждый раз `setCamera(false) ok, track=true` — race-loop.

**Фикс:** фильтр `!pub.isMuted` в `updateState()`:
```swift
localVideoTrack = room.localParticipant.videoTracks
    .compactMap { pub -> VideoTrack? in
        guard !pub.isMuted else { return nil }
        return pub.track as? VideoTrack
    }
    .first
```

#### B. STMOB-96 v2 enhanced rebroadcast (commit `36298276`)

**Симптом:** v1 fix (build 99/100, commit `57196c1e`) не работал. Molly увидела в Synapse только 3 `m.room.encrypted` в первые 30 сек звонка, потом 8+ минут тишины. Continuous rebroadcast не запустился.

**Гипотезы причин:**
1. `guard sessionState == .connected` strict guard выходит навсегда при reconnecting
2. Task cancelled родителем
3. iOS background throttle async Task.sleep
4. weak self стал nil при reconnect/recreate

**v2 changes:**
- **`keyRebroadcastTask: Task<Void, Never>?`** stored в private property — strong reference, не cancel'ится случайно. Cancel вручную в `stop()`.
- **`foregroundObserver`** на `UIApplication.didBecomeActiveNotification` — force-rebroadcast immediate когда app поднимается из background suspend.
- **`guard sessionState != .disconnected`** (вместо `== .connected`) — не выходим из цикла при reconnecting / waitingForCredentials, только при finalizing teardown.
- **DiagLog "E2EE"** в каждой итерации показывает phase/tick/state:
  - `rebroadcastLoop START` / `regenerate tick=N/12` / `entered continuous phase` / `continuous tick=N` / `EXIT — <reason>`
  - `rebroadcast START key=AbCd…`
  - `foreground entry — force rebroadcast`
- **Fix Swift 5.7+ shorthand:** named binding `let s = self` для повторных unwrap (после первого `guard let self` self становится non-optional, повторный shorthand ломается).
- **Cleanup в `stop()`:** cancel task + removeObserver.

#### Acceptance
- В Synapse длинного звонка: gap между `m.room.encrypted` от iPhone не превышает 30-40 секунд (после первых 2 мин regenerate)
- DiagLog покажет точку где цикл умирает (если ещё умирает) — диагностика для дальнейших итераций
- При foreground entry — немедленный rebroadcast event
- Camera toggle: тап → иконка обновляется в OFF, self-view гаснет, повторные тапы тогглят правильно

#### Файлы:
- `ios/ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — фильтр `!pub.isMuted` в `updateState()`
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — +`keyRebroadcastTask`, +`foregroundObserver`, less strict guard, DiagLog tracing, named binding fix
- `ios/sTalk.xcodeproj/project.pbxproj` — CURRENT_PROJECT_VERSION 100→101

---

### 55. ✅ Reuse Matrix device_id через Keychain (build 102 — STMOB-98)

**Дата**: 2026-05-02
**Коммит**: `6b866e01` (build 102)
**Plane**: STMOB-98 (high)

#### Симптом
В Synapse `devices` table у `@dp.bondar:stalk.implica.ru` накопилось **12+ Matrix device_id** на ОДИН физический iPhone (`idfv: 14F6FD77-...`) за 4 дня. Каждый logout/login через MAS создавал новый device_id вместо переиспользования. Эффекты:
- 11+ stale APNS pushers (Synapse fan-out на все)
- 12 megolm sessions у каждого собеседника
- 12 entries в "Sessions" UI у юзера

Web reuse device_id через `localStorage` корректно — iOS-side регрессия.

#### Корень
`AuthenticationService.urlForOIDCLogin()` передавал `deviceId: nil` в `client.urlForOidc()`. MAS видит nil → Synapse генерирует свежий device_id для каждой OIDC сессии. Element X iOS не сохранял device_id между сессиями.

#### Изменения
1. **`MatrixDeviceIDKeychain` enum** (file-private в AuthenticationService.swift):
   - `savedDeviceID()` → читает из Keychain key `device_id_for_idfv_<idfv>`
   - `save(deviceID:)` → сохраняет после успешного login
   - `clearStoredDeviceID()` → удаляет на explicit logout
   - Использует `UIDevice.current.identifierForVendor` (Apple IDFV — стабильный per-app per-physical-device, переживает app reinstall)
   - Хранит в Keychain (KeychainAccess library) с access group приложения

2. **`urlForOIDCLogin()`** — передаёт `storedDeviceID` в `client.urlForOidc(deviceId:)`. MAS принимает (Matrix-spec позволяет client задавать device_id). Synapse возвращает тот же device_id если та же сессия, иначе создаёт новый.

3. **`loginWithOIDCCallback()`** — после успешного login сохраняет `client.session().deviceId` в keychain. Первый login: nil → fresh → save. Повторный: задан → возвращается тот же → overwrite no-op.

4. **`AppCoordinator.logout(isSoft: false)`** explicit — вызывает `clearStoredDeviceID()` перед `unregisterForRemoteNotifications`. Soft logout (`isSoft=true`) early returns раньше → keychain не трогается → следующий login переиспользует device_id.

5. **DiagLog "STMOB98"** в три точки: `urlForOIDCLogin reuse`, `save`, `clear`.

#### Acceptance
- Чистая установка → login → device_id A → save в keychain
- Soft logout (token expired, MAS revoke) → keychain не трогаем
- Re-login → keychain отдаёт A → передаём в MAS → Synapse возвращает тот же A → **один device_id total**
- Explicit logout (юзер тапнул "Sign Out") → `clearStoredDeviceID` → next login: новый device_id B
- 5 logout/login циклов → у юзера в Synapse **1 device_id** (раньше 5)
- Pushers count = 1 на app_id (раньше 5)

#### Связь с другими задачами
- **STMOB-90** (high) — корень — теперь зафиксен через STMOB-98 (та же причина — генерация новых device_id)
- **STMOB-95** (pusher cleanup, build 99) — теперь opportunistic, root cause устранён
- **STALK-230** (Molly, server-side pusher cleanup) — backstop остаётся живым на случай других путей stale pushers

#### Файлы:
- `ios/ElementX/Sources/Services/Authentication/AuthenticationService.swift` — +`MatrixDeviceIDKeychain` enum, +`KeychainAccess` import, +`UIKit` import, передача `storedDeviceID` в `urlForOidc`, save после callback
- `ios/ElementX/Sources/Application/AppCoordinator.swift` — `clearStoredDeviceID()` в explicit logout flow

---

### 56. ✅ VoIP CallKit avatar — placeholder fallback + Intent donation (build 102 — STMOB-99 Phase 2)

**Дата**: 2026-05-03
**Коммит**: `c9a4839e` (build 102+)
**Plane**: STMOB-99 (medium)

#### Симптом
При входящем VoIP звонке на iPhone CallKit fullscreen показывал **имя** звонящего, но **аватарка отсутствовала** — пустое серое поле. Обычные push-уведомления (m.room.message) показывают аватарку через `NSE.NotificationContentBuilder.addCommunicationContext()` с `INSendMessageIntent + INPerson.image + interaction.donate()`. VoIP path в `ElementCallService` этого не делал.

#### Корень — разные code paths
- **Обычные push:** NSE имеет ~30 сек, грузит avatar через `mediaProvider.loadThumbnailForSource()`, donate'ит INSendMessageIntent
- **VoIP push:** PushKit completion лимит ~5 сек, при device-locked токен может быть протухший. Только CXCallUpdate с именем + roomID, никакого Intent donation

#### Phase 2 (этот коммит) — placeholder fallback + Intent donation
1. **`AppGroupAvatarCache` enum** (file-private в `ElementCallService.swift`):
   - `readAvatar(for: id) -> Data?` — читает .jpg из App Group `Library/Caches/avatars/<safeKey>.jpg`
   - `saveAvatar(_:for:)` — пишет туда
   - `clearAll()`
   - `safeKey` — alphanumeric-safe замена для userID/roomID
   - App Group shared между main app и all extensions → доступно из VoIP push handler **синхронно с диска**

2. **`donateIncomingCallIntent(senderMXID:callerName:roomID:hasVideo:)`** — `@MainActor`:
   - Layer A: `AppGroupAvatarCache.readAvatar(senderMXID)` — pre-cache hit (для known контактов после Phase 1)
   - Layer B fallback: `Avatars.generatePlaceholderAvatarImageData(name: callerName, id: personID, size: 100x100)` — initials кружочек, цвет deterministic от ID
   - `INPerson(handle, displayName, image)` → `INStartCallIntent(contacts: [person], callCapability: video/audio)` → `interaction.donate()`
   - iOS подхватывает для CallKit fullscreen

3. **Hook в `pushRegistry didReceiveIncomingPushWith`** — `Task @MainActor` с donate, **параллельно** с `reportNewIncomingCall`. Не блокирует CallKit deadline.

#### Phase 1 (cache populate из main app — ОТЛОЖЕНО)
- Hook на `mediaProvider` thumbnail loads / room sync для записи реальных аватарок known контактов
- Будет отдельной итерацией. Phase 2 даёт immediate visible improvement (initials placeholder) — Phase 1 потом улучшит до реальных фото

#### Phase 3 (group call room avatar — ОТЛОЖЕНО)
- Для group calls показывать room avatar (Element Web так делает). Пока initials по callerName.

#### Acceptance
- 1:1 от unknown контакта → color-initials placeholder в CallKit ("ИЖ" для Ивана Жилина) — **сейчас работает**
- 1:1 от known контакта (после Phase 1 cache populate) → реальная аватарка из cache — Phase 1
- Group call → room avatar — Phase 3
- CallKit shown time не увеличилось (donate на отдельном Task, не блокирует)

#### Файлы:
- `ios/ElementX/Sources/Services/ElementCall/ElementCallService.swift` — +`Intents` import, +`AppGroupAvatarCache` enum, +`donateIncomingCallIntent` helper @MainActor, hook в pushRegistry handler

---

### 57. ✅ STMOB-100 PiP active speaker через @Published activeSpeakers + STMOB-101 v3 event-driven rotation (build 102)

**Дата**: 2026-05-03
**Коммиты**: `a8c9dfc0` (STMOB-100), `fe45cba9` (STMOB-101 v3)
**Plane**: STMOB-100 (medium), STMOB-101 (urgent)

#### A. STMOB-100 — PiP мини-окно не переключалось на active speaker (`a8c9dfc0`)

Build 99 / CHANGELOG #52 попытка фикса (`28259ff9`) не работала: заменил `remotes.first(where: isSpeaking)` на `max(by: audioLevel)` — логика правильная, но `audioLevel` не `@Published`. SwiftUI computed property `activeSpeaker` пересчитывается только при `@ObservedObject` change → audioLevel changes не триггерят re-render → PiP залипает на первом по JOIN.

**v2 правильный путь:**
- `LiveKitRoomManager`: новый `@Published var activeSpeakers: [Participant] = []`
- `RoomDelegate room(_:didUpdateSpeakingParticipants:)` — обновляется SDK автоматически (sorted by audioLevel desc)
- `ActiveSpeakerMiniView`: использует `roomManager.activeSpeakers` вместо локального sort
- Filter remote-only (исключая local participant — себя в PiP не показываем), `!muted` фильтр, fallback `remotes.first`

SwiftUI re-render теперь триггерится `@Published activeSpeakers` — PiP переключается на active speaker через 1-2 сек.

#### B. STMOB-101 v3 — Event-driven E2EE key rotation, убрали timer cascade (`fe45cba9`)

**Регрессия build 100/101.** Molly STMOB-101 цифры: tymbay 99.7% e2eeDecryptFail в recording, ms.implica случайно OK. Bondar шлёт `m.room.encrypted` каждые 30 сек → каждый Element Call widget делает SFrame KID ratchet → у egress / Key Server / KS-Bridge cached только initial KID, последующие frames с новым KID → cipher auth fail.

**v1 (build 99/100):** for-loop 12×10s regenerate + while 30s rebroadcast — 13+ ratchets за первые 2 мин.
**v2 (build 101):** то же + DiagLog + foreground observer.
**v3 (этот коммит):** event-driven, close to Element Call upstream:

- ❌ Удалили for-loop 12×10s regenerate
- ❌ Удалили while-loop 30s rebroadcast
- ❌ Удалили `keyRebroadcastTask` property
- ✅ Initial `sendOurEncryptionKey` — один раз 3s после start
- ✅ Foreground entry → `rebroadcastCurrentEncryptionKey` (same key, no rotation)
- ✅ JOIN newcomer/reconnect (`$remoteParticipants` new identity) → `rebroadcastCurrentEncryptionKey` (same KID — newcomer должен расшифровать)
- ✅ LEAVE (identity исчезла) → `sendOurEncryptionKey` (regenerate KID — security E2EE rotation, leaving peer не decrypt'ит future)

Rotations теперь только при реальных membership events. Между ними KID стабилен → egress / KS-Bridge успевают догнать.

**NB:** STMOB-101 цифра "bondar plaintext publish" (e2eeDecryptOK=0 Fail=0) — НЕ plaintext. Real-time live calls работают (web слышит iPhone и наоборот) — если бы bondar публиковал plaintext, web/iOS decrypt fail и silence. **Это вероятно STMOB-89 identity mismatch:** egress lookup'ит ключ по identity LiveKit RTP, а KS-Bridge хранит под другой identity → egress не находит ключ → не пытается decrypt → counters OK=0 Fail=0. Отдельная задача STMOB-89.

#### Acceptance
- Long groupcall >5 мин, 3+ participants — recording должен decrypt большинство участников
- Web force-refresh после 3 мин — должен сразу слышать bondar (JOIN trigger покроет)
- В Synapse от bondar `m.room.encrypted` events — теперь только при JOIN/LEAVE events, не каждые 30 сек
- PiP мини-окно (group call) — переключается на active speaker через 1-2 сек

#### Файлы:
- `ios/ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — +`@Published activeSpeakers`, +`room(_:didUpdateSpeakingParticipants:)` delegate
- `ios/ElementX/Sources/Screens/CallScreen/View/NativeCallVideoView.swift` — `ActiveSpeakerMiniView.activeSpeaker` использует `roomManager.activeSpeakers`
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — удалили timer loops, расширили `$remoteParticipants` observer для JOIN/LEAVE events, оставили foregroundObserver

---

### 58. ✅ STMOB-151 — Meeting "Начать звонок" silent fail fix + диагностика (build 174)

**Дата**: 2026-05-24
**Plane**: STMOB-151
**Коммит**: `1f390d9e` (ios)

#### Симптом (dp.bondar отчёт 22:03-22:05 на iPhone build 173)

Юзер открыл MeetingDetailScreen, нажал "Начать звонок" — ничего не произошло. Ни UI feedback, ни записей в лог 81 (DiagLog), ни alert. Кнопка выглядит мёртвой.

#### Анализ цепочки actions

Цепочка передачи `.joinCall` action через 5 хопов оказалась целой:

```
Button .joinCall
  → MeetingDetailViewModel.joinCall()
  → actionsSubject.send(.joinCall(roomId:))
  → MeetingsScreenCoordinator → .startCall
  → WidgetsTabFlowCoordinator → .startCall
  → UserSessionFlowCoordinator.presentCallScreen(roomID:)
```

**Обрыв на последнем хопе** — `UserSessionFlowCoordinator.swift:460-466`:

```swift
private func presentCallScreen(roomID: String) async {
    guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
        return   // ← SILENT FAIL
    }
    presentCallScreen(roomProxy: roomProxy)
}
```

Если `roomForIdentifier` вернул не `.joined` (а `nil` / `.invited` / `.left`), guard молча выходил. UI не показывает ошибку, MXLog ничего не пишет, DiagLog тоже пусто — silent swallow.

**Вероятные сценарии для meeting room:**
1. Room ещё не sync'нута локально (server создал room по meeting code, прислал invite, но iOS rust-sdk не успел подтянуть в локальный store) → `roomForIdentifier` = nil
2. Юзер в state `.invited`, не `.joined` (meeting сервис auto-invite, но iOS клиент не accept'ит автоматом)
3. Локальный store stale после backgrounding (STMOB-133) — sync остановлен

В `MeetingDetailViewModel.joinCall` второй silent guard для `meetingCode` empty, и `MXLog.error("sTalk: ensureRoom failed")` без UI alert. Вся цепочка swallows errors.

#### Fix (build 174)

**A. UserSessionFlowCoordinator.presentCallScreen(roomID:)** — auto-join + диагностика

Switch по всем кейсам `RoomProxyType`:
- `.joined` → present (как раньше)
- `.invited` / `.none` → `clientProxy.joinRoom(roomID, via: [])`, потом re-fetch → present
- `.left` → joinRoom (для повторного присоединения)
- `.knocked` / `.banned` → error toast (нельзя join без approval)

Каждая ветка пишет `DiagLog.write("Meeting", ...)` — теперь видно где именно цепочка обрывается.

При неуспехе — `userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))` (toast).

**B. MeetingDetailViewModel.joinCall** — трассировка + UI error

- `DiagLog.write("Meeting", "MeetingDetailViewModel.joinCall PRESSED meeting=... matrixRoomId=... code=...")` — entry trace
- `DiagLog` для каждой ветки (direct path / ensureRoom)
- Если ни `matrixRoomId` ни `meetingCode` — `state.bindings.alertInfo` (UI alert), не silent return
- Если `ensureRoom` failed — `DiagLog` + `alertInfo` (раньше swallow `MXLog.error`)

**C. MeetingDetailScreen** — `.alert(item: $context.alertInfo)` для error display

**D. Hop-by-hop трассировка**

- `MeetingsScreenCoordinator` — `DiagLog.write("Meeting", "...joinCall → .startCall")` в handler
- `WidgetsTabFlowCoordinator` — `DiagLog.write("Meeting", "...startCall → UserSessionFlow")` в handler

Теперь при нажатии кнопки в лог 81 (`nse-events.log`) последовательность:
```
Meeting MeetingDetailViewModel.joinCall PRESSED meeting=... matrixRoomId=!XXX:stalk... code=...
Meeting MeetingDetailViewModel.joinCall direct path room=!XXX:stalk...
Meeting MeetingsScreenCoordinator .joinCall → .startCall room=!XXX:stalk...
Meeting WidgetsTabFlowCoordinator .startCall room=!XXX:stalk... → UserSessionFlow
Meeting presentCallScreen(roomID:) START room=!XXX:stalk...
Meeting presentCallScreen room=!XXX:stalk... state=joined → present
```

Если room в `.invited` — будет видна попытка `joinRoom` и её результат.

#### Файлы:
- `ios/ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift` — переписан `presentCallScreen(roomID:)` + новый helper `joinAndPresentCallScreen`
- `ios/ElementX/Sources/Screens/MeetingsScreen/MeetingDetailViewModel.swift` — DiagLog трассировка `joinCall()`, set `alertInfo` при error
- `ios/ElementX/Sources/Screens/MeetingsScreen/MeetingsScreenModels.swift` — `alertInfo: AlertInfo<UUID>?` в `MeetingDetailViewStateBindings`
- `ios/ElementX/Sources/Screens/MeetingsScreen/View/MeetingDetailScreen.swift` — `.alert(item: $context.alertInfo)`
- `ios/ElementX/Sources/Screens/MeetingsScreen/MeetingsScreenCoordinator.swift` — DiagLog в `.joinCall` handler
- `ios/ElementX/Sources/FlowCoordinators/WidgetsTabFlowCoordinator.swift` — DiagLog в `.startCall` handler
- `ios/project.yml` — build 174

#### Acceptance
- Нажать "Начать звонок" в MeetingDetail для room где state = .invited → join + open call screen (раньше тишина)
- Нажать "Начать звонок" для room где `matrixRoomId = ""` И `meetingCode = nil` → UI alert "Что-то пошло не так" (раньше тишина)
- При `ensureRoom` failure → UI alert + DiagLog запись (раньше только MXLog)
- В DiagLog видна полная цепочка хопов с roomID на каждом — можно понять где обрыв

---

### 59. ✅ STMOB-151 hotfix v2 — roomForIdentifier silent hang после joinRoom (build 175)

**Дата**: 2026-05-25
**Plane**: STMOB-151 (продолжение)
**Коммит**: `33bfa7e9` (ios)

#### Регрессия build 174

Build 174 fix #58 частично работал: цепочка `.joinCall` доходила до `joinAndPresentCallScreen`, `joinRoom` возвращал `.success`, но **`roomForIdentifier(roomID)` зависал** — call screen не открывался с 1-й попытки.

dp.bondar лог 82 (00:16:18) — 1-я попытка:
```
00:16:18.812 presentCallScreen(roomID:) START room=!mkVPBfeZkHWKHQkIHz:stalk...
00:16:18.813 state=nil(not-synced) → joinRoom
00:16:19.091 joinRoom OK → re-fetch
[ничего за 22 секунды]
```

2-я попытка через 23s (00:16:41) — `state=joined → present` сразу, работает.

#### Корень

`ClientProxy.roomForIdentifier`:
```swift
func roomForIdentifier(_ identifier: String) async -> RoomProxyType? {
    let shouldAwait = roomsToAwait.remove(identifier) != nil  // ← мы не insert'нули

    if let room = await buildRoomForIdentifier(identifier) { return room }  // ← cold cache miss

    if !staticRoomSummaryProvider.statePublisher.value.isLoaded {
        _ = await staticRoomSummaryProvider.statePublisher.values.first { $0.isLoaded }
        // ← БЕЗ ТАЙМАУТА. Если sync ещё не подключён после backgrounding —
        //   await висит навсегда (publisher не emit'ит новый value)
    }

    if shouldAwait { await waitForRoomToSync(roomID: identifier) }  // ← skipped

    return await buildRoomForIdentifier(identifier)
}
```

После `joinRoom OK` cold cache может ещё не обновиться (rust-sdk propagation race), и тогда `roomForIdentifier` падает в `await statePublisher.values.first` без таймаута. Висит до следующего sync event.

#### Fix (build 175)

**A. Insert roomID в `roomsToAwait` ДО joinRoom** — это активирует `waitForRoomToSync` (timeout 10s) в `roomForIdentifier` вместо infinite await.

**B. Дополнительный timeout wrapper** на сам `roomForIdentifier(roomID)` — 8 секунд. Если SDK всё равно завис — error toast вместо infinite UI freeze.

```swift
let refetched = await withTimeout(seconds: 8) {
    await self.userSession.clientProxy.roomForIdentifier(roomID)
}
DiagLog.write("Meeting", "presentCallScreen room=\(roomID) re-fetch result=\(refetched.map { ... } ?? "TIMEOUT")")
```

`withTimeout` — простой helper через TaskGroup race между operation и `Task.sleep`.

**Acceptance**:
- 1-я попытка нажатия "Начать звонок" на meeting room в state `.nil/.invited` → join + open call screen (раньше работало только 2-я попытка через 20+ сек)
- В DiagLog видна `re-fetch result=...` — TIMEOUT если SDK завис, или actual RoomProxyType
- При TIMEOUT → error toast, juser может retry

#### Файлы:
- `ios/ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift` — `joinAndPresentCallScreen` insert в roomsToAwait + timeout wrapper, новый helper `withTimeout`
- `ios/project.yml` — build 175

---

### 60. ✅ STMOB-152 iOS DiagLog для incoming encryption_keys + LiveKit identity (build 176)

**Дата**: 2026-05-25
**Plane**: STMOB-152
**Коммит**: `4d8da4c7` (ios)

#### Контекст

Поддержка Molly server-side fix STALK-303 (fan-out guest's encryption_keys через to-device от meet-api appservice). iOS native уже принимает incoming `io.element.call.encryption_keys` через widget bridge — никаких iOS-side code changes для key delivery не нужно. Но без DiagLog не видно реально ли keys доходят до iOS.

Также добавлен DiagLog для hand raise events (STALK-302 Phase 2 correlation).

#### NativeCallSession.swift

В `processIncomingWidgetMessage` (path "encryption_keys" detected) — DiagLog raw payload prefix 300 chars. Это покажет format (array vs object для keys field — important warning Molly уже знает).

В `handleEncryptionKeys`:
- При успешном extract: `DiagLog "E2EE incoming key parsed from=<participantId> index=<n> keyLen=<n>"`
- При guard fail (extract returned nil): `DiagLog "E2EE handleEncryptionKeys EXTRACT FAILED action=<n>"`

#### LiveKitRoomManager.swift

- `participantDidConnect`/`Disconnect` — DiagLog с identity + sid + totalRemote. Видим момент когда guest JOIN'ит call.
- `setHandRaise` — DiagLog `Call hand raise OUTGOING setMetadata raised=<bool>` (iOS публикует metadata).
- `didUpdateMetadata` — DiagLog `Call hand raise INCOMING identity=<id> raised=<bool>` (iOS receives от remote — другой iOS или guest meet-app после Molly STALK-302 patch).

#### Realtime correlation flow (после Molly deploy)

1. dp.bondar joins meeting в iOS, guest joins meeting через meet-app
2. `Call participant JOIN identity=@meet-XXX` появляется в nse-events.log
3. Molly meet-api fan-out отправляет to-device `io.element.call.encryption_keys` каждому non-guest device
4. iOS rust-sdk delivers to widget → `E2EE incoming widget message api=toWidget action=send_to_device`
5. Parsed: `E2EE incoming key parsed from=@meet-XXX:MEETXXX index=0 keyLen=...`
6. LiveKit E2EE manager use key для frame decrypt → guest video shows ✓

**Diagnostic gaps**:
- Step 2 есть, step 4 нет → KS fan-out не достиг iOS (server-side issue, Molly debug)
- Step 4 есть, step 5 EXTRACT FAILED → формат payload не совпадает (Molly warning array vs object)
- Step 5 есть, video всё ещё чёрный → LiveKit E2EE manager не applied key (iOS-side investigation)

#### Файлы
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — incoming encryption_keys DiagLog (2 places)
- `ios/ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — participant JOIN/LEAVE + hand raise OUTGOING/INCOMING DiagLog
- `ios/project.yml` — build 176

---

### 61. ✅ STMOB-152 build 177 — base64url normalization для guest E2EE keys

**Дата**: 2026-05-25
**Plane**: STMOB-152 (продолжение)
**Коммит**: `8df66ffd` (ios)

#### Симптом (после Molly fan-out deploy)

Build 176 + DiagLog показал что Molly server-side fan-out (STALK-303 `b6f4877`) работает: `incoming key parsed from=@meet-051cb6cb:stalk.implica.ru:MEET9011E6 index=0 keyLen=22`. iOS получил ключ от guest. **Но видео всё равно чёрное** — LiveKit SFrame decrypt fail.

#### Root cause

Guest meet-app генерирует ключ через `crypto.randomBytes(16).toString("base64url")` (Node.js, `meet-api-index.js:704,1396`):
- `base64url` = URL-safe base64 БЕЗ padding (RFC 4648 §5)
- 16 bytes → 22 chars, alphabet `-_` вместо `+/`

iOS Swift `Data(base64Encoded:)` **strict про оба**:
- ❌ Не accept unpadded (length not multiple of 4)
- ❌ Не accept `-`/`_` chars

В `NativeCallSession.handleEncryptionKeys` silent fallback на else branch → `keyProvider.setKey(key: base64STRING, ...)` вместо raw bytes → LiveKit SFrame decrypt fails → черный экран.

Лог 85 dp.bondar (01:28:10): guest key `IV9NRa02nGPGQwxjMlAnkA` (22 chars, no `-`/`_` случайно — но ~50% future keys будут содержать `-`/`_`).

#### Fix (build 177)

`NativeCallSession.swift handleEncryptionKeys` — normalize base64url → standard padded base64 перед `Data(base64Encoded:)`:

```swift
let paddedKey: String = {
    var normalized = keyInfo.key
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let mod = normalized.count % 4
    if mod != 0 {
        normalized += String(repeating: "=", count: 4 - mod)
    }
    return normalized
}()
if let rawKey = Data(base64Encoded: paddedKey) {
    setRawKeyInProvider(...)
    DiagLog.write("E2EE", "incoming key DECODED rawBytes=\(rawKey.count) for \(participantId)")
} else {
    DiagLog.write("E2EE", "incoming key BASE64 DECODE FAILED (even padded keyLen=\(paddedKey.count)) for \(participantId)")
    keyProvider.setKey(key: keyInfo.key, ...)
}
```

#### Server-side parallel fix (Molly STALK-303 commit `383963b`)

Параллельно Molly изменила generator на сервере:
```js
// meet-api-index.js:704,1396
crypto.randomBytes(16).toString("base64url")   // 22 chars, alphabet -_
↓
crypto.randomBytes(16).toString("base64")      // 24 chars padded, alphabet +/
```

Это базовый fix — server отдаёт standard padded base64 → iOS любой версии decode'нет правильно. **Build 177 = belt-and-suspenders** на случай future key sources которые отдадут base64url напрямую к iOS (минуя meet-api fan-out path).

#### Acceptance
- В DiagLog: `E2EE incoming key DECODED rawBytes=16 for @meet-XXX:MEETXXX`
- Видео гостя на iPhone не чёрное

#### Файлы
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — base64url normalization в `handleEncryptionKeys`
- `ios/project.yml` — build 177

---

### 62. ✅ STMOB-154 build 178 — iOS host → Web hand raise через Matrix m.reaction

**Дата**: 2026-05-25
**Plane**: STMOB-154
**Коммит**: `b19742765` (ios)

#### Корень

Web Element Call widget слушает только Matrix `m.reaction` events для hand raise (читает room timeline через свой rust-sdk). iOS native использует только LiveKit metadata. Без iOS-side capability — Web участники не видят руку iOS host. Last direction в hand raise matrix (9/9 coverage).

Server-side impersonation alternative не работает: Synapse appservice namespace ограничен `@meet-*` regex, admin token не может send-as `@dp.bondar`. Plus Element Call widget делает client-side validation на `m.relates_to.event_id`'s call.member sender match с reaction sender — даже если bypass admin → widget отфильтрует.

#### Implementation

**NativeCallSession.swift:**
- Property `private(set) var callMemberEventID: String?` — capture'ит event_id своего `org.matrix.msc3401.call.member` state event из `sendJoinViaREST` response. Используется как `m.relates_to.event_id` в hand raise reaction.
- Property `private var handReactionEventID: String?` — текущий активный hand raise event_id для последующего redaction.
- New `sendHandRaiseReaction(raised: Bool) async`:
  - `raised=true`: PUT `/rooms/{room}/send/m.reaction/{txn}` с body `{"m.relates_to": {"rel_type": "m.annotation", "event_id": callMemberEventID, "key": "🖐️"}}`. Save returned event_id в `handReactionEventID`.
  - `raised=false`: PUT `/rooms/{room}/redact/{handReactionEventID}/{txn}` empty body. Reset `handReactionEventID = nil`.
- Generic helper `sendMatrixEvent(url:body:method:)` для REST PUT с access token + parse `event_id` из response.

**CallScreenViewModel.swift toggleHandRaise:**
- После `liveKitRoomManager.setHandRaise(enabled: newValue)` параллельно вызывает `nativeCallSession?.sendHandRaiseReaction(raised: newValue)`.
- Dual path: LK metadata (iOS↔iOS, iOS↔guest) + Matrix m.reaction (iOS→Web).

**DiagLog:**
- `Call hand raise m.reaction SENT eventID=$abc relates_to=$def`
- `Call hand raise REDACTED $old → $new`
- `Call sendHandRaiseReaction ABORT — нет callMemberEventID` (если REST join failed)

#### Implementation choice — REST не widget

Выбран **direct REST API** через `accessToken` вместо `fromWidget action=send_event`:
- Тот же pattern что `sendJoinViaREST` уже использует — proven path
- Не требует capability extension в widget API (capabilities остаются unchanged)
- Меньше moving parts (не зависит от widget driver state / capability negotiation)
- Тот же accessToken = same Matrix identity = same sender в Element Call widget validation

#### Acceptance
- В DiagLog: `Call hand raise m.reaction SENT eventID=$abc relates_to=$def` + `Call hand raise REDACTED ...`
- Web participants видят hand raise icon на iOS host tile в Element Call UI
- Closes 9/9 directions hand raise matrix (last open direction iOS → Web)

#### Файлы
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — callMemberEventID storage + sendHandRaiseReaction + sendMatrixEvent helper
- `ios/ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift` — dual path call в toggleHandRaise
- `ios/project.yml` — build 178

---

### 63. ✅ STMOB-159 — NSE timeout 3s → 10s для cold Synapse race (build 179)

**Дата**: 2026-05-27
**Plane**: STMOB-159
**Коммит**: `3fd8aed03` (ios)

#### Симптом

dp.bondar 2026-05-27 09:00 МСК: в чат #ops пришли 2 сообщения подряд (от @tracy и @molly), iPhone push showed:
1. @molly ad-sync → full content «[ad-sync] 06:00 UTC daily report — no new users...»
2. @tracy DailyStatus → **«sTalk: Уведомление»** baseline placeholder

#### Root cause (лог 87)

```
09:00:15.726 NSE processEvent eventID=$FzH8l3j2... (Tracy DailyStatus)
09:00:18.896 NSE   → failed/timeout retrieving notification item (>3s), DISCARD
09:00:19.115 NSE processEvent eventID=$u3q5vsvf... (Molly ad-sync, 220ms спустя)
09:00:19.263 NSE   preprocess: ...[ad-sync] daily report
09:00:19.266 NSE   → result=shouldDisplay
```

NSE имел кастомный **3-секундный fast-fail timeout** в `NotificationHandler.swift:160-171` для предотвращения hang на ring events (decrypt ratchet keys 19+ сек, NSE мёртв до следующего ring). Для **regular text notifications** когда Synapse «холодный» (давно не обращались) первый retrieve не успевал в 3 сек → `discardNotification()` → `makePassiveContent()` → iOS 26.3 fallback на baseline alert payload (известная limitation STMOB-94).

Второе сообщение (220ms спустя) шло уже по «горячему» каналу — 148ms preprocess success.

#### Fix (build 179)

Bump timeout 3s → 10s в `NSE/Sources/NotificationHandler.swift:165`:

```swift
try? await Task.sleep(nanoseconds: 10_000_000_000)  // было 3_000_000_000
```

10s хватает на cold-start Synapse retrieve. Ring-event hang всё равно перехватит `handleTimeExpiration` перед Apple kill через 30s (margin 20s).

Upstream Element X **не имеет** этого timeout вообще — полагается на `handleTimeExpiration` callback. Наш custom timeout остаётся как защита от worst-case hang (10s достаточно для cold-start, но не для multi-second decrypt loops).

#### Acceptance

- Первое сообщение в чат за день → full content, не «Уведомление» placeholder
- Ring events suppress'ятся как раньше через NSE → CallKit takeover (нет regression STMOB-99)

#### Файлы

- `ios/NSE/Sources/NotificationHandler.swift` — bump 3s → 10s + updated DiagLog «>10s»
- `ios/project.yml` — build 179

---

### 64. ✅ STMOB-163 — filter egress / service bot tiles из call UI (build 180)

**Дата**: 2026-05-28
**Plane**: STMOB-163
**Коммит**: `4d174b96` (ios)

#### Симптом

dp.bondar 2026-05-27 в звонке Aibolit (8 участников, recording on): появились дубликаты tile с identities `EG_x9eZ5hFvkm72`, `EG_TUEMsLFN9Soa`, `EG_32V9NQYKb4vP`, `EG_eQPoVYi9Vom9` — placeholder «E» аватар + mic-off иконка. Захламляют сетку — для 8 user видно 12 tiles.

#### Root cause

Molly переключила recording на **multichannel** (STALK-237) — теперь по одному track egress на каждого user (не один composite). Каждый egress подключается как LiveKit participant с identity `EG_XXX`, kind=`.egress`. iOS UI не фильтровал — все попадали в `remoteParticipants`.

#### Fix (build 180)

Новое computed property `LiveKitRoomManager.displayParticipants` — filter через `participant.kind == .standard`:

```swift
var displayParticipants: [RemoteParticipant] {
    remoteParticipants.filter { $0.kind == .standard }
}
```

LiveKit `ParticipantKind` enum:
- `.standard` — real user
- `.ingress`, `.egress`, `.sip`, `.agent` — bots / recorders

**Преимущества над identity-prefix или publish-tracks filter** (согласовано с Molly):
- Protocol-level API — не зависит от identity convention (если Molly через месяц поменяет `EG_` → стабильно)
- Не зависит от publish tracks — muted user всё ещё `.standard`, visible
- Future-proof: новые service kinds (`.agent` для AI bot, etc) автоматически hide

#### UI references update

Все usages `roomManager.remoteParticipants` → `displayParticipants` в:
- `NativeCallVideoView.swift` (15 references)
- `CallScreen.swift` (1)
- `CallScreenModels.swift` (2)
- `CallScreenViewModel.swift` (4 — auto-end check учитывает только real users)

Combine subscription `liveKitRoomManager.$remoteParticipants` в `NativeCallSession.swift` оставлено как есть — E2EE key rebroadcast адресован ВСЕМ participants включая egress (egress тоже должен decrypt'ить).

#### Acceptance

- Запись в групповом звонке: только real users в tile grid
- Counter «N участников» считает только display participants (без egress)
- При muted local mic/camera — user всё ещё видим

#### Файлы

- `ios/ElementX/Sources/Services/LiveKit/LiveKitRoomManager.swift` — новый `displayParticipants`
- `ios/ElementX/Sources/Screens/CallScreen/View/NativeCallVideoView.swift`
- `ios/ElementX/Sources/Screens/CallScreen/View/CallScreen.swift`
- `ios/ElementX/Sources/Screens/CallScreen/CallScreenModels.swift`
- `ios/ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift`
- `ios/project.yml` — build 180

---

### 65. ✅ Экран набора — аватар собеседника + «Вызов» с анимированными точками (build 249)

**Дата**: 2026-07-16
**Коммит**: `fa59fb695` (ios)

#### Симптом / запрос

dp 2026-07-16: на экране набора (до подключения к звонку) показывалась только буква-инициал в круге и голый спиннер `ProgressView` рядом с «Вызов...». Требование: (1) если у комнаты/собеседника есть аватар — показывать картинку, а не букву; (2) убрать спиннер, вместо него надпись «Вызов» с анимированными точками (попытки дозвона, в такт гудкам).

Предыстория: сам экран набора (аватар-круг + имя + «Вызов...») добавлен в build 247 взамен «просто пустого» спиннера (`f3b26d554`), гудки исходящего (`RingbackTonePlayer` 425 Гц 1с/4с) — там же.

#### Fix (build 249)

1. **Аватар вместо буквы.** Экран набора рисует `RoomAvatarImage(avatar:avatarSize:.custom(108):mediaProvider:)` — сам грузит картинку комнаты, а для 1:1 (DM) корректно берёт аватар собеседника из heroes; при отсутствии аватара — фолбэк на инициал-плейсхолдер. Прокинуто новое поле `CallScreenViewState.roomAvatar: RoomAvatar?`, заполняется из `roomInfo.avatar` в `CallScreenViewModel.init`.
2. **Спиннер убран, анимированные точки.** Вместо `ProgressView` — `CallingDotsLabel`: база «Вызов»/«Calling» (из `SL10n.callCalling`, хвостовые точки/многоточие срезаются) + точки, циклично набегающие 1→2→3 по `Timer` 0.5с. Ширина точек зафиксирована (18pt), текст не «прыгает».

#### Файлы

- `ios/ElementX/Sources/Screens/CallScreen/CallScreenModels.swift` — новое поле `roomAvatar: RoomAvatar?`
- `ios/ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift` — заполнение `roomAvatar` из `roomInfo.avatar`
- `ios/ElementX/Sources/Screens/CallScreen/View/CallScreen.swift` — экран набора: `RoomAvatarImage` + `CallingDotsLabel`

#### Acceptance

- Исходящий звонок в комнату/DM с аватаром → на экране набора картинка аватара; без аватара → инициал.
- Нет спиннера; «Вызов» с бегущими точками 1→2→3.
- Собеседник ответил → экран сменяется на звонок, гудки глохнут (логика build 247 не тронута).

---

### 66. ✅ STMOB-256 — долгое подключение к звонку: снят 6с глухого сна + диагностика (build 249)

**Дата**: 2026-07-16
**Plane**: STMOB-256
**Коммит**: `659e77bc4` (ios)

#### Симптом

Тестеры UZ (через Сергея, 2026-07-15): «долго подключаешься к звонку». На .uz RTT до Synapse/SFU выше, а критический путь подключения — фиксированные задержки + последовательные сетевые round-trip'ы.

#### Диагностика (тап → звук/видео пошли)

Флоу: `CallScreenViewModel.setupCall()` → `NativeCallSession.start()` → `connectWithGeneratedJWT()` → `connectToLiveKit()`.

- **Фаза A (handshake виджет-драйвера):** `widgetDriver.start()` → request_capabilities → **sleep(1s)** → content_loaded → **sleep(5s)** → io.element.join. Итого **6 секунд фиксированного мёртвого ожидания на каждый звонок**.
- **Фаза B (connectWithGeneratedJWT):** resolve well-known → join REST → delayed-leave → чтение активных → ring → **debugReadCallMemberState (чистый DEBUG-round-trip)** → fetch creds (openid + /sfu/get) → connectToLiveKit. Медиа-путь (creds+connect) стоит позади 4-5 сигнальных запросов.

#### Fix (build 249)

1. **Снят 6с глухой сон.** `sleep(5s)` «ждём негоциацию capabilities» → событийное ожидание `waitForCapabilitiesNegotiation(ceilingMs:5000)`: флаг `capabilitiesNegotiated` поднимается в `processWidgetMessage` после ответа на toWidget capabilities. Worst case = прежние 5s (потолок), типично < 1s. `sleep(1s)` → 400мс.
2. **Убран `debugReadCallMemberState()`** с критического пути — минус один сетевой round-trip на каждый звонок (метод-определение оставлен для отладки, вызов удалён).
3. **Инструментирование `CallPerf` в DiagLog** — метки в мс от `callStartTime` на каждой фазе: widgetDriver.start, capabilities negotiated, io.element.join, jwt resolved, join REST, creds fetched, LiveKit CONNECTED. Даёт точную разбивку на устройстве/.uz.

#### Предложение (фаза 2, после валидации цифрами)

Распараллелить медиа-путь (fetch creds → connect) и сигналинг (join REST → ring → delayed-leave) — сейчас последовательны. Локальный connect не зависит от нашего membership (SFU авторизует по JWT; E2EE-ключи самозалечиваются на remote JOIN + rebroadcast). Держится sequential до получения DiagLog CallPerf с .uz.

#### Файлы

- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift` — `callStartTime`/`elapsedMs()`/`capabilitiesNegotiated`, `waitForCapabilitiesNegotiation`, CallPerf-метки, удаление debug-вызова

#### Дополнение (commit `79089ab45`): CallPerf на пути ОТВЕТА

Для «40с после того как взял трубку» инструментирования только в `NativeCallSession` мало — задержка сидит РАНЬШЕ connect, в ожидании синка комнаты (cold-Synapse). Добавлены CallPerf-маркеры на весь answer→connect: `user ANSWERED` (CXAnswerCallAction) → `startCall dispatched (after 1s)` → `presentCallScreen START` → `roomForIdentifier → <state>` → (если не синкнута) `joinRoom START` → `joinRoom OK → awaiting sync` → `room sync re-fetch → resolved/TIMEOUT(8s)` → NativeCallSession connect-цепочка. Один `grep CallPerf` даёт полный таймлайн с абсолютными таймингами — 40с локализуются в конкретный промежуток (подозреваемый: ожидание синка = cold-Synapse, зона Molly).

Файлы: `ios/ElementX/Sources/Services/ElementCall/ElementCallService.swift`, `ios/ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift`.

---

### 67. ✅ Входящий звонок репортится как аудио (hasVideo=false) — фикс «всегда с видео» (build 249)

**Дата**: 2026-07-16
**Plane**: STMOB-260 (фикс А); Б — прокидка типа звонка от инициатора
**Коммит**: `aa7f856c3` (ios)

#### Симптом

Тестеры UZ: «всегда подключается с видео». Причина на входящем пути: `ElementCallService` репортил каждый входящий в CallKit как ВИДЕО-звонок (`hasVideo: true` захардкожено в donate-intent и `CXCallUpdate`) → система показывала видео-звонок, ощущение «всегда видео».

Экран «аватар + Принять» — системный CallKit UI, свои кнопки микрофона/камеры туда добавить нельзя (ограничение iOS для VoIP).

#### Fix А (build 249)

`hasVideo: true → false` в обоих местах (`ElementCallService.swift` ~445/450). VoIP-payload не несёт тип звонка, поэтому дефолт = аудио (стандартное телефонное поведение); камера включается кнопкой уже в звонке. Реальное состояние камеры при accept и так гасит гвард `isJoiningExistingCall` в `presentCallScreen`.

#### Фаза Б (STMOB-260, с Molly)

Прокинуть тип звонка (audio/video) в ring/VoIP-payload (или `io.stalk.call.initiate`, STMOB-188), чтобы видео-звонок звонил как видео. iOS прочитает поле → `reportNewIncomingCall` с `hasVideo` по типу. Требует бэкенд-части Molly.

#### Файлы

- `ios/ElementX/Sources/Services/ElementCall/ElementCallService.swift` — `hasVideo` входящего = false

---

### 68. ✅ Предупреждение при удалённом старте записи — окно с текстом + ОК (build 250)

**Дата**: 2026-07-16
**Коммит**: `f4d95614a` (ios)

#### Запрос

dp/UZ: «нет предупреждения о старте записи». Локальный старт записи consent-диалог уже имел (`RecordingConsentView`), а при УДАЛЁННОМ старте (другой участник начал запись) была только маленькая красная пилюля `RecordingButton` в тулбаре — не читается как предупреждение.

#### Fix (build 250)

При переходе `isRemoteRecording` idle→recording (детект — поллинг recording-api каждые 5с, `startRecordingPolling`) — помимо красной пилюли показывается **модальное окно** «Идёт запись звонка / Один из участников начал запись этого звонка» с кнопкой ОК (`state.bindings.alertInfo`, гард `!=` → одноразово на переход). Строки `stalk_remote_recording_title/message` (ru/en).

#### Файлы

- `ios/ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift` — alert при remote-recording transition
- `ios/ElementX/Sources/Other/SwiftUI/Views/StalkTheme.swift` — `remoteRecordingTitle/Message`
- `ios/ElementX/Resources/Localizations/{ru,en}.lproj/Localizable.strings`

---

### 69. ✅ STMOB-259 — in-app брифинг «Как пользоваться» + first-run walkthrough (build 250)

**Дата**: 2026-07-16
**Plane**: STMOB-259
**Коммит**: `260b928b1` (ios)

#### Запрос

dp: нужен in-app брифинг — как работают функции, по примеру инструкций в мобильных приложениях. Решение: Настройки + first-run.

#### Реализация (build 250)

- **Экран «Как пользоваться»** в Настройках → секция Support (`questionmark.circle.fill`, sheet). Карточки: Звонки / Запись и транскрибация / Безопасность / Чаты — иконка + заголовок + текст.
- **First-run walkthrough** — 3 карточки со свайпом (Звонки/Запись/Безопасность), «Пропустить»/«Далее»/«Начать», полноэкранно, один раз (флаг `stalk_briefing_shown` в UserDefaults, триггер в `NavigationTabCoordinatorView.onAppear` с задержкой 0.8с).
- Статичный контент, без бэкенда. Строки `stalk_briefing_*` (ru/en).
- Вью (`BriefingScreen`, `BriefingWalkthroughView`, `BriefingCard`) размещены в `SettingsScreen.swift` — проект без синхронизированных групп Xcode 16, новый файл потребовал бы правки pbxproj.

#### Файлы

- `ios/ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift` — строка + BriefingScreen/Walkthrough/Card
- `ios/ElementX/Sources/Application/Navigation/NavigationTabCoordinator.swift` — first-run cover + флаг
- `ios/ElementX/Sources/Other/SwiftUI/Views/StalkTheme.swift` — строки `briefing*`
- `ios/ElementX/Resources/Localizations/{ru,en}.lproj/Localizable.strings`

---

### 70. ✅ STMOB-257 — iOS listener готовности транскрибации через sync (build 250)

**Дата**: 2026-07-16
**Plane**: STMOB-257
**Коммит**: `c3a3f8451` (ios)

#### Контекст

«Долго подтягивается транскрибация» (UZ). iOS поллил статус каждые 10с → до 10с лага после готовности. Molly (STALK-605) добавила событие `im.stalk.transcription_ready` (room-event, `session_id`=egress_id) и положила тип в Sygnal `denied_event_types` (без APNS — решение dp «без оффлайн-пуша», только sync).

#### Реализация (build 250)

`CallDetailScreenViewModel.loadRoomMetadata` подписывается на таймлайн комнаты звонка (`roomProxy.timeline.timelineItemProvider.updatePublisher`) и ловит `im.stalk.transcription_ready`: `.msgLike(.other("...transcription_ready"))` → парсит `debugInfo.originalJSON` → `content.session_id`. При совпадении с `egressId` — мгновенно `loadTranscription()`. Быстрее 10с-поллинга; поллинг оставлен как fallback. Событие приходит ПОСЛЕ звонка (виджет не работает), поэтому слушаем основной sync-таймлайн, не widget. Deny-лист гасит только пуш, sync не трогает. Паттерн — как приём `encryption_keys` в `NativeCallSession`.

#### Файлы

- `ios/ElementX/Sources/Screens/CallDetailScreen/CallDetailScreenViewModel.swift` — timeline-listener transcription_ready

---

### 71. ✅ Гудки исходящего чинены + мгновенное закрытие экрана при завершении (build 251)

**Дата**: 2026-07-17
**Коммит**: `729bcbc34` (ios)

По NSE-логу 130 (device, build 250) вскрылись два бага звонка:

**Гудки не играли.** `RingbackTonePlayer` в коде с build 247, но гейт `startRingbackIfInitiator` требовал `state.callParticipantsCount == 0`, а счётчик = `max(membership, displayParticipants+1)` — включает себя (+1) и выставляется в 1 подпиской почти сразу при connect → условие всегда ложно → ни одного `ringback START` в логах. Фикс: захват `startedAsInitiator` при init (в комнате не было звонка на старте, ДО подписок) + `!shouldPlayRingback` + нет remote. Теперь гудки играют у инициатора до ответа.

**Экран висел ~5с при завершении.** `endCall` закрывал UI только в `defer` — после всей очистки (leave REST 3.7с + hangup + disconnect); юзер тыкал «Завершить» 8 раз. Фикс: `.dismiss` СРАЗУ в начале endCall, очистка доигрывает в фоне (`Task { await endCall() }` держит self сильно → VM жива до конца очистки даже после снятия оверлея; очистка гарантирована, не обрывается).

Файл: `ios/ElementX/Sources/Screens/CallScreen/CallScreenViewModel.swift`.

---

### 72. ✅ STMOB-260 iOS — тип звонка из ring-payload → hasVideo (build 251)

**Дата**: 2026-07-17
**Plane**: STMOB-260
**Коммит**: `729bcbc34` (ios, ElementCallService)

Web (Molly, `6a4a0ccffe`) и Android (Andy) кладут `call_type: "audio"|"video"` в ring-событие. iOS читает `dict["call_type"]` в `ElementCallService.handleRoomCallNotification` → `reportNewIncomingCall(hasVideo:)`: `video`→камера, `audio`/поле отсутствует→аудио. Форвард-совместимо с фиксом А (STMOB-256): старый сервер без поля → аудио. Так видео-звонок звонит как видео, а не «всегда аудио».

Файл: `ios/ElementX/Sources/Services/ElementCall/ElementCallService.swift`.

---

### 73. ✅ Редизайн справки/онбординга — пошаговые подсказки + все разделы (build 251)

**Дата**: 2026-07-17
**Plane**: STMOB-259 (доработка)
**Коммиты**: `2d282bd1c`, `243160b16` (ios)

Фидбек dp: справка «ужасно» — портянка текста, неточность про шифрование, не все разделы. Переделано:
- **Экран «Как пользоваться» (Настройки):** `List` секциями по функциям, каждая = заголовок с иконкой + шаги (иконка + короткая строка). Покрыты Контакты/чаты, Звонки, Фон в звонке, Запись, Приложения/встречи, Безопасность.
- **First-run walkthrough:** буллеты вместо абзаца, 4 карточки (+ Приложения), крупнее и по центру.
- **Фикс текста:** «в защищённых чатах шифруются» вместо «все звонки зашифрованы» (не все комнаты E2EE).

Файлы: `SettingsScreen.swift`, `StalkTheme.swift`, `Localizations/{ru,en}`.

---

### 74. ✅ Три call-фикса по device-логам 131/132 (build 252)

**Дата**: 2026-07-17
**Коммит**: `c0e10c462` (ios)

По логам 131/132 с устройства (build 251):

1. **Ответ на пуше не открывал приложение** (юзер: «принимаю — не переходит, только после ручной разблокировки виден звонок»). Корень: фикс А `hasVideo=false` → CallKit трактует как аудио → iOS НЕ выводит app на передний план при ответе с локскрина (для видео — выводит). Экран звонка создавался, но телефон не разблокировался. **Фикс: `hasVideo=true` всегда** (`ElementCallService`). Камеру «всегда с видео» гасит гвард `isJoiningExistingCall`, а не CallKit hasVideo — та жалоба остаётся закрытой. call_type → стартовая камера = отдельная доработка STMOB-260 (через startWithVideoEnabled, не hasVideo).

2. **Исходящий показывал «принято» до ответа** (лог 132: мы LiveKit CONNECTED @57.6, remote вошёл @01:16:01 — 3.5с таймер шёл, пока собеседник ещё звонит). Корень: `callStatus=.connected` при НАШЕМ SFU-connect. **Фикс: инициатор остаётся в `.connecting` («Вызов…» + гудки) до входа первого real-участника** (`CallScreenViewModel`: гейт `!startedAsInitiator` в .connected + переход в remoteParticipants-подписке), экран показывает набор пока `callStatus == .connecting` (`CallScreen.content`). Заодно гудки теперь осмысленны весь звонок-ожидание.

3. **`isCallMinimized` не сбрасывался** в `setOverlayCoordinator` (латентный) → новый звонок мог открыться мини-окном 140×200 вместо фуллскрина. Синхронизирован с presentationMode.

Файлы: `ElementCallService.swift`, `CallScreenViewModel.swift`, `CallScreen.swift`, `NavigationTabCoordinator.swift`.

---

### 75. ✅ Загарджены ВСЕ преждевременные переходы инициатора в .connected (build 253)

**Дата**: 2026-07-17
**Коммит**: `77a164a18` (ios)

Доводка #74: в build 252 гейт `!startedAsInitiator` стоял не на всех путях `callStatus = .connected` (из 6 сайтов загарджено 2). Ревизия по логу 134 (веб v448) добавила гейты ещё на 3:

- **LiveKit `$connectionState` fallback (STMOB-80)** — ставил connected на НАШЕМ подключении к SFU (~4с), потенциально раньше всех. Защитный гейт `!startedAsInitiator`. NB: в реальном логе 134 экран тут и так не флипал (гудки стартовали ПОСЛЕ нашего connect), но путь оставался открытым — закрыт как defence-in-depth.
- **MatrixRTC call.member 1:1** (`callParticipants.count >= 2`) и **group** (`callParticipants.contains(ownUserID)`) — веб постит membership в лобби до реального входа в SFU.

Теперь у инициатора «принято» ставит ТОЛЬКО реальный вход remote в SFU (`remoteParticipants`-подписка). Проверено на устройстве (лог 134, звонок 11:55): гудки 11с, переход ровно по `participant JOIN totalRemote=1`.

Файл: `CallScreenViewModel.swift`.

---

### 76. ✅ 15с таймаут на MatrixRTC REST — .uz cold-start не вешает connect (build 253)

**Дата**: 2026-07-17
**Коммит**: `5d49bc00e` (ios)

UZ-фидбек «долго подключаешься»: часть висяков — сетевые REST-вызовы на `URLSession.shared` (дефолтный request-таймаут 60с). На мёртвом/медленном .uz cold-start homeserver путь подключения к звонку висел минутами.

**Фикс:** единая `restSession` с `timeoutIntervalForRequest/Resource = 15` и **`waitsForConnectivity = false`** на все 11 REST-вызовов `NativeCallSession`. `waitsForConnectivity=false` — ключевой: иначе таймаут не тикает, пока система «ждёт связи», что и давало многоминутный висяк на reachable-но-немом хосте. Мёртвый хост теперь падает за 15с, а не 60с.

Фаза 1 из плана извлечения `MatrixRTCRestClient` (Фаза 2 — вынос pure-REST методов в отдельный `Sendable`-класс — опциональна, отложена; таймаут-выигрыш от неё не зависит).

Файл: `NativeCallSession.swift`.

---

### 77. ✅ Аудио-first на всех путях входа в звонок + self-healing гудков (build 254)

**Дата**: 2026-07-17
**Коммит**: `1b70a492e` (ios)

Лог 136 (build 253, STALK-610 прогон): гейт инициатора работает ✅, но три новых симптома с одним корнем — «аудио»-звонок публиковал **камеру** через ~1.3с после старта гудков (`publish media: mic=on camera=on`). Публикация видео-трека реконфигурирует AVAudioSession → (1) AVAudioEngine гудков молча глохнет (тишина после первого гудка при живом экране набора), (2) индикатор камеры вспыхивает ON, (3) при ответе камера остаётся включённой.

Причина: пути входа теряли аудио-флаг — `videoEnabled: true` хардкод/дефолт в: карточке контакта (`RoomMembersFlowCoordinator` ×2), профиле из Чатов (`ChatsTabFlowCoordinator`), деталях комнаты (`RoomFlowCoordinator .presentCall`), перезвоне из истории/Встреч (`UserSessionFlowCoordinator.presentCallScreen(roomID:)` ×2). dp звонил из карточки контакта → камера ON.

**Фиксы:**
1. **Аудио-first везде**: видео-звонок стартует ТОЛЬКО явной видео-кнопкой в шапке комнаты (`displayCall`); все прочие входы = камера off (включается в звонке).
2. **RingbackTonePlayer self-healing**: подписка на `AVAudioEngineConfigurationChange` → пересборка движка. Гудки переживают реконфиг сессии (публикация камеры в легитимном видео-звонке, смена роута на AirPods). DiagLog: `ringback RESTART after audio config change`.

Файлы: `UserSessionFlowCoordinator.swift`, `RoomFlowCoordinator.swift`, `RoomMembersFlowCoordinator.swift`, `ChatsTabFlowCoordinator.swift`, `CallScreenViewModel.swift`.

---

### 78. ✅ Качество гудков после рестарта движка (build 255)

**Дата**: 2026-07-17
**Коммит**: `1061576d3` (ios; +SwiftFormat `67e682f56`)

Тест 254 (dp, видео-звонок, лог 137 обрезан — разбор по описанию + коду): self-healing #77 работает (звук продолжается вместо тишины), но после публикации камеры гудок звучал «совсем не похоже на системный» и рвано. Три дефекта пересборки:

1. Новый движок читал **транзиентный HW-рейт** в момент реконфига → тон генерился под неправильный sample rate → другая высота/тембр.
2. Ритм начинался **с нуля** (гудок сразу, без выдержки паузы 4с).
3. Реконфиг приходит **пачкой** (камера+роут+режим) → серия рестартов, каждый с гудком.

**Фикс** (`RingbackTonePlayer`): фиксированный формат генерации **48кГц** с явным `AVAudioFormat` на коннекте (миксер ресемплит в HW — питч не зависит от состояния сессии); позиция в периоде 1с/4с переживает пересборку (wall-clock учёт, `rememberPeriodPosition`); дебаунс рестарта **250мс**. Гудки в видео-звонке звучат идентично аудио-звонку весь набор.

Файл: `CallScreenViewModel.swift`.

---

### 79. ✅ 0xDEAD10CC-митигации: гейты фоновых триггеров записи (build 256)

**Дата**: 2026-07-17
**Коммит**: `ce1b6b048^` (ios, fix+bump)

Крашы 0xDEAD10CC на 250 (01:17) и 254 (16:33): tokio-worker заморожен в `rusqlite execute_batch → sqlite3PagerCommitPhaseOne → pwrite/fsync`. Диагноз (мульти-агентный воркфлоу, адверсарно проверен): **race «фоновое CPU-окно → SDK докатывает WAL-коммит → ре-суспенд посреди записи»**. НЕ возврат бага 240 — stopSync отработал за 22 мин до kill. Хронология 254: bg task истёк 16:10:55 → NSE-пуши 16:32:51 → «Meetings GET» 16:33:05 (фоновое CPU-окно главного приложения!) → kill 16:33:07.

Ключевой факт: `syncService.stop()` НЕ закрывает сторы/локи — для этого в SDK 26.06.03 есть `Client.pause()` (док: «releasing all connections and file locks… to avoid 0xdead10cc kills»), который форк не вызывает, а upstream держит за флагом `clientPausingAndResumingEnabled`.

**Фиксы 256 (нулевой риск, триггеры урока 240 не тронуты):**
1. Meetings-поллер (120с, `HomeScreenViewModel.refreshMeetingRoomIDs`) — no-op в фоне (DiagLog `refresh skipped (app in background)`).
2. Транскрипционный поллер (10с, `CallDetailScreenViewModel.startPolling`) — no-op в фоне.
3. `ClientProxy.forceTokenRefresh` — skip в фоне (401→OIDC-персист в sqlite без bg task; DiagLog `forceTokenRefresh skipped (background)`).
4. BGAppRefresh — DiagLog-маркеры `START/END/EXPIRED` (кандидат в источники CPU-окна; по следующему дампу видно, стрелял ли перед kill).
5. Completion-гигиена ранних выходов `AppCoordinator.stopSync` (класс 0x8badf00d).

**План 257:** порт upstream-модели `client.pause()/resume()` (`reconcileServiceState`, сериализация `serviceStateTask`) за флагом, с DiagLog-замером `client.pause() took Xms`. Гейт включения: стабильно < 2-3с на устройстве.

Файлы: `HomeScreenViewModel.swift`, `CallDetailScreenViewModel.swift`, `ClientProxy.swift` (+`import UIKit`), `AppCoordinator.swift`.

---

### 80. ✅ client.pause()/resume() за флагом — главный фикс 0xDEAD10CC (build 257)

**Дата**: 2026-07-17
**Коммит**: `8ac88078b^` (ios, feat+bump)

Дамп 256 (20:02:46) доказал диагноз экспериментом: митигации #79 отработали (в логе `refresh skipped (app in background)` ×2, `BGAppRefresh START` не стрелял, ни Meetings GET, ни token refresh) — а краш всё равно случился с замороженным WAL-commit. Значит **пишет сам SDK**: после `syncService.stop()` сторы и файловые локи остаются открытыми, и в любом фоновом CPU-окне tokio-потоки докатывают записи → ре-суспенд посреди `pwrite` → kill.

**Фикс — порт upstream-модели:**
- `ClientProxy.stopSync`: после `syncService.stop()` → `try await client.pause()` (док SDK: «releasing all connections and file locks… to avoid 0xdead10cc kills… after stopping the SyncService»); completion ждёт конца pause (bg task живёт всё время); замер `client.pause() OK took Xms` в DiagLog.
- `ClientProxy.startSync`: `client.resume()` ПЕРЕД `syncService.start()`; фейл resume → лог + фолбэк на обычный start.
- Сериализация переходов цепочкой `serviceTransitionTask` (upstream serviceStateTask-паттерн) — быстрый свернул/развернул не даёт resume влезть посреди pause.
- Флаг `clientPauseInBackgroundEnabled` (default **OFF**) + тумблер в Developer Options (секция «0xDEAD10CC») — device-замеры до раскатки; гейт включения по умолчанию: стабильно <2-3с.

Файлы: `AppSettings.swift`, `DeveloperOptionsScreenModels.swift`, `DeveloperOptionsScreen.swift`, `ClientProxy.swift`.

---

### 81. ✅ client.pause — флаг ON по умолчанию, гейт пройден (build 258)

**Дата**: 2026-07-18
**Коммит**: `cc336abd4^` (ios, feat+bump)

Ночной device-гейт на 257 (лог 140, тумблер включён, подтверждено dp): `client.pause()` **8-11мс** стабильно (6 вызовов, 0 фейлов — в 250 раз лучше гейта 2-3с), `client.resume()` 22-41мс (0 фейлов, «0ms»-вызовы = идемпотентный повтор), парность pause/resume полная (8 expiring / 8 stopSync DONE), **0 крашей 0xDEAD10CC за ночь**, синк живой после каждого разворота.

`clientPauseInBackgroundEnabled` defaultValue false → **true**. Тумблер в Developer Options оставлен аварийным выключателем. Build 258 = кандидат App Store 26.04.09.

Файл: `AppSettings.swift`.

---

### 82. ✅ Рендер markdown в plain-body сообщениях (build 259)

**Дата**: 2026-07-19
**Коммит**: `5aa26ff69` (ios)

Жалоба dp: «в чатах не принимаются md-сообщения» — боты (#ops и др.) шлют markdown plain-текстом БЕЗ `formatted_body`, upstream рендерит буквально («**жирный**», сырые списки). Отправка с iOS уже работала (`messageEventContentFromMarkdown`), сломан был только приём.

**Решение — `StalkMarkdown`** (enum в `AttributedStringBuilder.swift`, без нового файла): консервативный md→HTML конвертер в `fromPlain`; включается ТОЛЬКО при уверенных признаках (`**пары**`, код-спаны/fence, `[ссылки](url)`, заголовки, цитаты `> `, списки от 2+ строк, `~~зачёркнутый~~`); результат идёт через существующий `fromHTML`-пайплайн — цитаты/код-блоки/списки/ссылки/пиллы-меншены бесплатно. Безопасность: HTML-эскейп ДО конвертации, `href` только `https?://` без кавычек, статический DTCoreText-рендер.

**Адверсарное ревью (воркфлоу, 3 линзы) — 10 багов найдено и закрыто до коммита:** эмоты «* name …» не становятся списком, подписи к медиа и топик комнаты без md (`fromPlain(detectMarkdown: false)` через протокол-расширение), однострочный ```` ```код``` ````, гарды `2**3`, обратный порядок восстановления токенов (код-спан внутри ссылки), `<ol start="N">` + пустые строки в списках, кэш первым + прекомпилированные регексы, U+FFFC-гигиена, голые URL в плейсхолдеры. + Пойман и починен exclusivity-краш (inout-алиасинг → локальное замыкание; крашлог `swift_beginAccess`).

Проверено на #ops в симуляторе: жирный/код/списки рендерятся, крашей нет.

Файлы: `AttributedStringBuilder.swift`, `AttributedStringBuilderProtocol.swift`, `RoomTimelineItemFactory.swift`, `RoomDetailsScreenViewModel.swift`.

---

### 83. ✅ Сага пустых плашек: NSE-реестр, expiration-фолбэк, кэш сессий, дедлайн + фикс «нужно приглашение» (build 260)

**Дата**: 2026-07-20
**Коммит**: `20d0c12cf^` (ios, fix+bump)

Симптом у dp (259) и Тымбая (258): часть пушей — сырые пустые плашки «sTalk», тап открывал превью «нужно приглашение» при живом membership. Диагноз (мульти-агентный воркфлоу + логи обоих устройств + Sygnal-сверка Molly: payload плашек и нормальных пушей байт-в-байт одинаков, mutable-content=1 у всех → сервер чист):

1. **Параллельные didReceive затирали единственное поле `notificationHandler`** → expiration затёртого = молчаливый no-op → iOS показывала сырой eventIdOnly payload (плашка Тымбая 23:57 в бурсте из 5 пушей). **Фикс: реестр `pendingRequests` по request.identifier** + единственная точка доставки (unregister-гард от дублей).
2. **Запрос без хендлера (инит сессии не успел) молчал на expiration.** Фикс: немедленный фолбэк «sTalk / Новое сообщение» с room_id.
3. **Полный клиент (3 SQLCipher-стора + OlmMachine) строился на КАЖДЫЙ пуш** → бюджетные киллы по времени (27с фетч + инит > 30с бюджета при холодном Synapse 28-29с) → iOS переставала запускать NSE вовсе (мёртвая зона 7ч у dp, 9 запусков/8ч у Тымбая). **Фикс: static-кэш `NSEUserSession` по userID** (один клиент на процесс).
4. **Дедлайн-бюджет didReceive+24с** вместо фиксированных 27с (учитывает инит; ~6с на финализацию всегда) + кап 2с на синхронный FFI `displayName` в generic-пути.
5. **«Нужно приглашение» по тапу**: `buildRoomForIdentifier` на запаузенном сторе (client.pause, 258) кидал store-closed → catch → nil → превью. **Фикс: ретрай после `serviceTransitionTask`**.

DiagLog-маркеры для проверки: `fetch budget Ns`, `NSE session cache HIT/MISS`, `expire with NO handler → fallback`, `retrying after service transition`.

Файлы: `NotificationServiceExtension.swift`, `NotificationHandler.swift`, `ClientProxy.swift`.

---

### 84. ✅ «Нужно приглашение» по тапу — форсить resume перед резолвом комнаты (build 261)

**Дата**: 2026-07-20
**Коммит**: `e87bd3f7c^` (ios)

260 НЕ закрыл баг (лог 143, dp на 260): тап по ЧИТАЕМОМУ пушу #ops (member-комната, 14 участников) → экран «Вам необходимо приглашение». Корень уточнён: тап опережает `didBecomeActive → startSync`, стор запаузен (`client.pause`, с 258), `client.getRoom` → nil → `presentJoinRoomScreen`.

Фикс #83 (ретрай после `serviceTransitionTask`) был неверен: в момент тапа `serviceTransitionTask` = ЗАВЕРШЁННАЯ pause-задача (resume ещё не запланирован, т.к. тап-роут опередил lifecycle-колбэк) → `await` мгновенный, ретрай снова на запаузенном сторе. (Также в #83 ошибочно указан «DiagLog-маркер retrying» — фактически там был `MXLog`, в diag-лог не пишется.)

**Фикс 261:** `ClientProxy.roomForIdentifier` после первого nil ЯВНО вызывает `startSync()` (форсит resume) и ждёт `serviceTransitionTask`, затем ретрай — порядок lifecycle-колбэков больше не важен. `startSync` идемпотентен (resume 0ms на живом клиенте, подтверждено логами). Сломанный wrapper `buildRoomForIdentifier` из 260 удалён.

Файл: `ClientProxy.swift`. ⚠️ Требует device-теста (гонка не воспроизводится на симуляторе): свернуть app >5с → тап по читаемому пушу → открывается комната, не «нужно приглашение».

---

### 85. ✅ Свой юзер показывался «не в сети» в списке участников звонка (build 262)

**Дата**: 2026-07-24
**Коммит**: `a45054463` (ios)

Скрин dp (в звонке ТТ, 2/2 участников): сам (@dp.bondar) в секции «не в сети» в `CallParticipantsSheet`, заголовок «Участники (1)» вместо (2). Не реальная presence — display-баг: `activeCallParticipantIDs` строился из `roomInfo.activeRoomCallParticipants` (события `m.call.member` из Synapse), которые **не содержат себя** (лаг sync / SDK не кладёт self). При этом счётчик шапки уже делал `+1` за себя → рассинхрон, локальный юзер падал в `notInCall`.

**Фикс:** локальный юзер всегда активен в звонке, который смотрит — `roomProxy.ownUserID` добавляется в `activeCallParticipantIDs`, если его там нет. Сам переходит в активную секцию, заголовок = (2). Фантомов нет (sheet фильтрует по реальным `CallParticipantInfo`). Проверить на реальном звонке (симулятор не собирает).

Файл: `CallScreenViewModel.swift`.

---

### 86. ✅ STMOB-234/235 — демонстрация экрана: застывший кадр в своей плитке, мёртвая кнопка камеры, перехват системной записью (build 263)

**Дата**: 2026-07-25
**Коммит**: `b201e1050` (ios) + бамп `ee4520dd6`

Два бага тестеров от 2026-06-15 (зеркала STALK-445/446), у которых оказался общий корень.

**STMOB-235 — застывший кадр.** После выключения демонстрации в своей плитке оставался последний кадр экрана вместо аватарки (участники при этом видели аватарку корректно — расходилось только локальное состояние). Корня два:
- `updateState()` клал в `@Published localVideoTrack` **первую немьютнутую видео-публикацию любого источника**. `videoTracks` — это values словаря, порядок недетерминирован, а при выключенной камере (аудио-first по умолчанию) screen-share вообще единственный кандидат;
- `setScreenShare()` не звал `updateState()`, а делегата `didUnpublishTrack` в менеджере не было. Для screen-share SDK делает именно **unpublish** (у камеры/микрофона — mute), поэтому единственный живой путь к пересчёту (`didUpdateIsMuted`) не срабатывал, и `localVideoTrack` держал остановленный трек. `VideoView` остаётся с последним кадром.

**STMOB-234, половина «кнопка камеры не реагирует».** Тот же трек ломал тумблер: observer в `CallScreenViewModel` читает `localVideoTrack != nil` как «камера включена», тап → `setCamera(false)` → `updateState()` → снова screen-share трек → `isVideoEnabled` откатывался в `true`. Камеру нельзя было ни включить, ни выключить, пока идёт шаринг. Вторая причина «камера включается сама после сворачивания» — залипающий `wasCameraEnabledBeforeBackground`: он считался ПОСЛЕ раннего `guard` по `connectionState` и никогда не сбрасывался, поэтому уход в фон во время реконнекта оставлял протухшее `true` с прошлого цикла, и на возврате `setCamera(true)` **публиковал** новый камера-трек (в аудио-звонке publication нет, так что это не unmute, а publish).

**STMOB-234, половина «freeze при системной записи».** Исходный триаж считал, что шаринг идёт через ReplayKit broadcast extension — **это неверно**: таргета расширения в сборке нет (`grep -c -i broadcast sTalk.xcodeproj/project.pbxproj` = 0, в PlugIns билда только NSE и ShareExtension), `BroadcastBundleInfo.hasExtension == false` (app group расширения `group.ru.implica.stalk` не совпадает с нашим `group.ru.implica.stalk.app`), поэтому SDK уходит в `createInAppScreenShareTrack` → `RPScreenRecorder.shared().startCapture`. Системная запись экрана iPhone забирает тот же синглтон: поток sample buffer'ов молча прекращается, а страховок нет — errorHandler у `startCapture` в SDK игнорируется, авто-unpublish при остановке капчера сделан только для `BroadcastScreenCapturer`. Публикация остаётся живой и не muted → у всех висит последний кадр.

**Фикс:**
- `updateState()` — `localVideoTrack` только из публикаций с `source == .camera`; `isScreenSharing` выводится из **фактической** публикации, а не из намерения юзера (SDK при full reconnect / room move делает `republishAllTracks` = unpublish + publish, и флаг-из-намерения после такого цикла врал бы: кнопка «выключено», а экран продолжает уходить участникам);
- делегат `didUnpublishTrack` (пересчёт состояния при ЛЮБОЙ остановке, в т.ч. внешней) + ветка screen-share в `didPublishTrack` — ватчдог перевешивается на новый трек после republish;
- `ScreenShareWatchdog` (`VideoRenderer` + `RPScreenRecorderDelegate`): авто-стоп демонстрации по **паре** признаков — делегат сообщил о потере И кадров нет дольше 5с, причём простой начался после сигнала. Порознь оба признака врут: ReplayKit шлёт кадры по изменению экрана (пауза на статичном документе легальна), а `isAvailable` дёргается и от нашего собственного захвата. Взвод снимается устойчивым потоком кадров (кадры в первые 1.5с после сигнала — хвост очереди капчера, не признак живости). Телеметрия в DiagLog раз в 30с (DiagLog при переполнении сносит файл целиком);
- VM подписан на `$isScreenSharing` (раньше на него не был подписан никто — UI знал о шаринге только из собственного тапа) + алерт «Демонстрация остановлена» при внешнем обрыве;
- `wasCameraEnabledBeforeBackground` одноразовый и считается до `guard`;
- self-view PiP в 1:1 гейтится по `isLocalVideoEnabled` (раньше рендерился по одному `localVideoTrack != nil`).

Файлы: `LiveKitRoomManager.swift`, `CallScreenViewModel.swift`, `NativeCallVideoView.swift`.

**Проверка:** симулятор — сборка зелёная, приложение стартует, обычный звонок не затронут (симуляторный фейковый трек тоже `source == .camera`). Сама демонстрация экрана на симуляторе недоступна (`setScreenShare` под `#if targetEnvironment(simulator)` — no-op), поэтому нужен device-тест: (1) шаринг вкл → своя плитка показывает камеру/аватар, экран только в плитке «Ваш экран»; (2) шаринг выкл → аватарка сразу, без застывшего кадра; (3) кнопка камеры работает в обе стороны во время шаринга; (4) сворачивание/возврат — камера не включается сама; (5) старт системной записи при активном шаринге → демонстрация гаснет с алертом, снять DiagLog (что реально приходит: `screenRecorderDidChangeAvailability`, `didStopRecording`, оба или ничего — на этой посылке держится порог авто-стопа).

---

### 87. ✅ Свой экран не показываем себе + пустая плашка после звонка (build 264)

**Дата**: 2026-07-25
**Коммит**: `c7507514f` (ios)

Device-тест dp на 263 (логи 144/145 + скрин): при своей демонстрации экрана «видео меня и собеседника уезжает, я его не вижу, и куча отражений себя».

**Корень:** плитка «Ваш экран» (STMOB-129, build 160) добавлялась ПЕРВОЙ в `participantItems`, рендерилась во всю ширину 16:9 и поднимала флаг `hasScreenShare`. А он в `GroupCallLayout` меняет аспект тайлов на 1.0, отключает раскладку «1 крупный + 2» для трёх участников и **включает скролл** — камеры физически уезжали за пределы вьюпорта. Плюс рекурсия: in-app ReplayKit-захват снимает наше же окно, в котором эта плитка и нарисована.

**Фикс:** свой screen-share себе не показываем вообще (чужой — как раньше). Индикация трансляции — компактная плашка «Вы транслируете экран» вверху экрана звонка; подсветки кнопки ••• недостаточно, `isActive` горит ещё и от включённого фона. Каскадом чинятся все перекосы раскладки, потому что `hasScreenShare` больше не поднимается от своего шаринга.

**Заодно:**
- цикл чужих шарингов: skip по локальной identity (класс STMOB-131 — виртуальный участник `<я>:screen` вернул бы свой экран «с чужого входа») + требование `isSubscribed` (без него сетка рисовала тайл, который `hasRemoteScreenShare` не считает → раскладка не уходила в speaker, landscape-фуллскрин не включался);
- **авто-стоп демонстрации ускорен**: жёсткий сигнал ReplayKit (`didStopRecording` «Запись прервана другой программой») гасит шаринг через 1.5с вместо 5с. На устройстве (лог 145) сигнал пришёл 12:05:37, стоп был 12:05:43 — долго. Мягкий `availability=false` по-прежнему ждёт полный порог: он дёргается и от нашего же `startCapture`;
- **пустая плашка после звонка** (лог 144, 11:59:18.917 → 11:59:19.435): NSE распознаёт E2EE-хвост звонка по call-active маркеру и отдаёт заглушку — отменить доставку из расширения нельзя, `contentHandler` вызвать обязан. Но приложение было в форграунде, `roomID` у заглушки нет → `shouldDisplayInAppNotification` возвращал `true`, и iOS показывала пустой баннер и пустую строку в Центре уведомлений. Теперь заглушка несёт маркер `stalk_suppressed`, `willPresent` её не презентует и подметает накопившиеся в фоне (там `willPresent` не вызывается вовсе). Серверный запрет типа события (Sygnal `denied_event_types`, зона Molly) остаётся правильным дополнением;
- `en.lproj`: добавлены `stalk_call_you_are_sharing` и ключи алерта «Демонстрация остановлена» (были только русские `value:` — англоязычный юзер видел русский текст), удалён мёртвый `stalk_call_your_screen`.

Файлы: `NativeCallVideoView.swift`, `CallScreen.swift`, `LiveKitRoomManager.swift`, `NotificationManager.swift`, `NotificationConstants.swift`, `NSE/NotificationHandler.swift`, `en.lproj/Localizable.strings`.

**Проверка:** сборка зелёная; демонстрация на симуляторе недоступна → device-тест: группа 2/3/4 участника в портрете и landscape при СВОЁМ шаринге (сетка не скроллится, аспекты нормальные, плашка видна), чужой шаринг = тайл 16:9 + авто-speaker + landscape-фуллскрин, собеседник видит мой экран, авто-стоп при системной записи стал быстрее.

**Что НЕ вошло:** STMOB-262 (после полного обрыва сети медиа не восстанавливается — LiveKit не замечает потерю, ни видео ни демонстрация не возвращаются). Отдельный билд по решению dp.

---

### 88. ✅ STMOB-263 — встреча с телефона больше не светится в «Чатах» (build 265)

**Дата**: 2026-07-25
**Коммит**: `65e98787e` (ios)

Скрин dp: комната встречи «Тест шаринга» висит в общем списке чатов спустя час после создания. По задумке (STMOB-244) встречи скрыты из общего списка и живут только под фильтром «Встречи».

**Корень:** признак «это комната встречи» был прокси — множество `matrix_room_id` из `GET /api/meetings`, которое жило ТОЛЬКО в памяти `HomeScreenViewModel` и обновлялось раз в 120с (в фоне тик пропускается). Комната создаётся сервером лениво (`POST /api/meet/ensure-room` при первом входе) и прилетает в список чатов через sync МГНОВЕННО → окно видимости до ~2 минут. При этом клиент в этот момент держал room id в руках (ответ ensure-room) и выбрасывал его.

Хуже, у прокси-признака есть постоянные утечки на сервере: write-back room id в meet-api сделан fire-and-forget (PATCH без проверки ответа) → `matrix_room_id` может не появиться никогда; при пересоздании комнаты старая остаётся у всех, кто успел зайти; вошедший по ссылке `/meet/s/<code>` не попадает в участники встречи, и его `/api/meetings` эту встречу не вернёт вовсе.

**Почему не как в вебе:** web фильтрует по маркеру `io.stalk.meeting` прямо в state комнаты (приезжает тем же sync). В нашем пине matrix-rust-sdk геттера произвольных state-событий НЕТ (в FFI только `sendStateEventRaw` / `canUserSendState`), поэтому прямой паритет сейчас недостижим.

**Фикс:** `MeetingRoomRegistry` — постоянный реестр room id встреч в App Group UserDefaults. Пополняется там, где клиент узнаёт id (ответ `ensure-room`, список meetings-api), переживает холодный старт, при пополнении шлёт событие → список чатов перерисовывается сразу (комната могла прийти в sync раньше, чем вернулся ensure-room). Фильтр берёт объединение реестра и списка из API.

**Остаток:** комнаты, id которых клиент никогда не узнавал, останутся видимыми до первого открытия встречи. Ретроактивный признак возможен через `RoomInfo.creators` (комнаты встреч создаёт админ-токен meet-api) — отдельной задачей. Серверная половина отдана Molly (надёжный write-back + участники при входе по ссылке).

Файлы: `MeetingsService.swift`, `HomeScreenViewModel.swift`, `AppSettings.swift`.

---

### 89. ✅ STMOB-262 — медиа не восстанавливалось после обрыва сети (build 265)

**Дата**: 2026-07-25
**Коммит**: `0f490cf9f` (ios)

Device-тест dp (лог 145): в звонке сеть выключили полностью, вернули — ни видео, ни демонстрация экрана больше не доходили до собеседника до конца звонка. Захват при этом жил (ватчдог демонстрации насчитал 4271 кадр): кадры шли в никуда, и ни SDK, ни приложение этого не замечали.

**Поправка к первоначальному диагнозу:** «LiveKit не заметил обрыва» по логу НЕ доказуемо. Quick reconnect в SDK не меняет `connectionState` (тот переключается только в полном реконнекте), поэтому «SDK спал» и «SDK молча крутил свою лестницу» в логе неразличимы. Отсюда первый слой фикса — наблюдаемость.

**Наблюдаемость:** мост логов SDK в DiagLog (`LiveKitDiagLogBridge`: уровень фильтруется до материализации autoclosure, allow-list, дедуп 1/сек, бюджет 20 строк/сек — DiagLog при переполнении сносит файл целиком, и болтливый SDK смыл бы ровно те улики, ради которых мост делался) + делегаты `didStart/didUpdate/didCompleteReconnectWithMode` и connection quality. `didComplete` ветвится по фактическому состоянию: делегат приходит и на провале лестницы.

**Детектор доставки** (`MediaEgressWatchdog`): `TrackDelegate` на локальных камере, демонстрации и микрофоне (в аудио-звонке видео-треков нет вовсе). `reportStatistics` включается точечно на этих треках, а не через `RoomOptions` — иначе таймер 1 Гц повиснет на каждом удалённом треке (нагрев, с которым бились в 241); на стопе выключается. Считаем рост `bytesSent`/`packetsSent`/`framesEncoded` по всем rid + simulcast, снимок держим свой (у SDK `previous` объявлен weak и к следующему тику пуст). Вердикт только по **паре** признаков: байты стоят ≥6с И подтверждение (ICE disconnected/failed, либо сеть пропадала <30с назад, либо захват растёт при стоящем энкодере). Игнорируем законные паузы: mute, все rid inactive (dynacast), нет новых кадров от источника, и молчим пока сетевого пути нет вовсе.

**Лестница восстановления** — только штатные пути SDK (ручной `unpublish/publish` в build 45 положил и видео, и звук): ступень 1 `debug_simulate(.quickReconnect)` запускается без ожидания (внутри SDK ждёт всю свою retry-лестницу — до 10 попыток, десятки секунд, а нам нужно окно 8с); успех определяется по РОСТУ БАЙТОВ, а не по отсутствию исключения (`debug_simulate` не пробрасывает ошибку даже при полном провале); ступень 2 `.fullReconnect` — только если ступень 1 доказанно не помогла и приложение активно (`republishAllTracks` обрывается на первой неудачной публикации, в фоне демонстрация не поднимется). Single-flight, cooldown 30с, максимум 2 цикла за звонок, задача отменяется при завершении звонка.

**Чтобы ремонт не убивал звонок** (это нашло ревью, в первой версии фикса звонок гарантированно завершался): полный реконнект обнуляет `remoteParticipants` (SDK шлёт `participantDidDisconnect` на каждого) — авто-энд «все ушли» на этом завершал звонок с REST-leave. Теперь он гейтится признаком переподключения и подтверждается повторной проверкой через 3с (то же для 1:1 авто-энда). Фантомный LEAVE во время реконнекта больше не **ротирует** E2EE-ключ, только re-advertise того же. Окно грации: при LiveKit `.disconnected` сессия не закрывается, пока идёт ремонт, но не дольше 20с.

**Поведение:** quick reconnect больше не дёргается на ПРОПАДАНИЕ сетевого пути — на мёртвой сети он взводил лестницу SDK на ~45-50с и глушил её же детекторы; теперь только на восстановление.

**UI:** плашка «Нет связи — восстанавливаем…» (раньше UI молчал и показывал идущий таймер, хотя пользователя никто не слышал).

Файлы: `LiveKitRoomManager.swift`, `NativeCallSession.swift`, `CallScreenViewModel.swift`, `CallScreen.swift`, `CallScreenModels.swift`.

**Кандидаты в upstream LiveKit** (подтверждены чтением пина 18851350): (1) ping-watchdog взводится ПОСЛЕ отправки ping — зависший `send` на мёртвом, но не закрытом сокете не взводит таймаут никогда, и весь исходящий сигналинг замолкает; (2) ошибки отправки сигнальных запросов молча съедаются; (3) ICE-уровень игнорируется целиком (`didChange: IceConnectionState` — пустая заглушка). Пин не двигаем: переезд требует ревалидации всего E2EE/VP9-стека.

**Device-тест (обязателен, симулятор этот класс не воспроизводит):** авиарежим 60с → возврат; короткий провал 10с (ремонт НЕ должен запускаться); wifi→cellular на ходу; фон во время обрыва; группа 3+ (нагрев и отсутствие ложняков от dynacast). Каждый прогон — с выгрузкой DiagLog: строки `LKSDK`, egress-телеметрия, вердикт детектора, ступени ремонта.

---

### 90. ✅ STMOB-264 — участие в звонке как инвариант: веб перестал терять iOS после обрыва сети (build 266)

**Дата**: 2026-07-25
**Коммит**: `6d456ec67` (ios)

Device-тест dp на 265, логи iOS 146/147 + консоль веба. Симптом дикий: после обрыва сети iOS переподключается и **видит** веб, а веб больше не видит от iOS ни видео, ни звука — при том что медиа реально уходит в SFU.

**Корень, доказанный логами обеих сторон.** При входе в звонок iOS регистрирует серверный отложенный leave (MSC4140): `delayed leave scheduled delay=20000ms`, и раз в 8с шлёт `restart`. Во время обрыва рестарты падают (`delayed leave restart FAILED` ×3), сервер через 20с **выполняет** отложенный leave и снимает наше `m.call.member`. Дальше рестарты возвращают `404` (delay_id больше нет), а iOS продолжает долбиться в мёртвый delay и **никогда не переотправляет участие**.

Веб в тот же момент пишет ровно то же самое со своей стороны: `[MatrixAudioRenderer] Audio track @dp.bondar:…:Que9n9te7L has no matching matrix call member, current members: @rusty:…` — треки приходят, но сопоставить их с участником звонка не с чем. Отсюда же «веб быстро теряет звонок»: для него мы не участник, он остаётся один и закрывает звонок.

Хронология (лог 146): 21:20:09 join + delay scheduled → 21:20:42 сеть пропала → ~21:21:02 сервер снял участие → 21:21:06.6 `restart → 404` → 21:21:07.1 веб фиксирует, что участника нет → 21:21:14.8 iOS переподключился к SFU (медиа пошло, участия нет).

**Системная причина, а не «не обработали 404».** Участие писалось ОДИН раз при входе и охранялось «выключателем мертвеца»; сверки «что в состоянии комнаты» против «что мы реально делаем» не было вовсе. Любой сбой подтверждений выкидывал нас из участников навсегда.

**Фикс — инвариант:** пока сессия в звонке, наше `m.call.member` обязано быть в состоянии комнаты. Сверщик `reconcileCallMembership(trigger:)` сравнивает желаемое с фактическим и восстанавливает расхождение независимо от причины (сработавший отложенный leave, ресет состояния, редакция события, рестарт сервера, чужой клиент). Источник правды — событие о НАШЕМ участии из комнаты: оно и раньше приходило и разбиралось в `updateCallMembers(from:)` (там считаются активные устройства для рассылки ключей), но на свою запись в этом списке никто не смотрел. Триггеров три: событие из комнаты, `404` от подтверждения (быстрый путь, когда sync отстаёт) и завершённое переподключение SDK. Сверка идемпотентна, single-flight, не чаще раза в 5с, потолок 5 восстановлений за звонок (если участие снимают снова и снова — это уже серверная история, а не наш обрыв). При восстановлении: переотправка join, новый отложенный leave, повторная раздача E2EE-ключа (для собеседника мы «новый участник»).

Отдельно `delayedLeaveMs` 20с → 30с по решению dp. Это теперь **просто запас**: корректность на нём больше не держится, при любом значении участие восстановится.

Файл: `NativeCallSession.swift`.

**Device-тест:** обрыв сети >30с в звонке с вебом → после возврата веб снова видит видео и слышит звук iOS, звонок не закрывается. В DiagLog: `membership: наше участие пропало из состояния комнаты → восстанавливаю`, `membership recon #1 (…) → переотправляю join`, `membership восстановлено`.

---

### 91. ✅ STMOB-261 — CallKit-цикл входящего: «Недавние», зелёная плашка, история без дублей (build 270)

**Дата**: 2026-07-26
**Коммит**: `<TBD>` (ios)

Device-тест dp на 269 + лог 149 и скриншот «Недавних». Три жалобы — два корня.

**1. Входящий звонок жил в CallKit 2 секунды.** Сессия наблюдения фазы «звонит» (`observeIncomingCall`) следит за составом участников звонка в комнате: если в нём появляется наш userID — значит «ответили на другом устройстве», и CallKit-сессия закрывается (`.answeredElsewhere`). После перехода на полный цикл CallKit (269) отвечаем мы **здесь же** — и через ~2с после ответа в состояние комнаты прилетает эхо нашего собственного `m.call.member`. Наблюдатель честно отрабатывал по написанному и гасил только что принятый звонок: лог 149 — `didActivate 17:42:14.211` → своё же членство `17:42:16.110` → `didDeactivate 17:42:16.209`, в «Недавних» «Входящий вызов — 2 с», зелёной плашки при сворачивании нет, а `markNativeCallActive` в 17:42:17.6 переиспользовал уже мёртвый идентификатор сессии.

Фикс системный, а не «игнорировать своё эхо»: фаза «звонит» заканчивается в момент локального ответа, поэтому её наблюдатели там же и снимаются — `disarmIncomingRingWatchers()` в обработчике `CXAnswerCallAction` (и он же теперь в `reportEndedCall`, где раньше отменяли всё, кроме подписки на состояние комнаты). Живым звонком дальше управляет экран звонка.

**2. Принятый входящий попадал в историю дважды — и мог стать «пропущенным».** Запись о звонке создавали два места: `UserSessionFlowCoordinator.presentCallScreen()` — всегда как **исходящий**, и `CallHistoryCoordinator` на `.startCall` — как **входящий**. Для принятого входящего звонка отрабатывали оба. Сверх того тот же наблюдатель из п.1 после завершения звонка слал `.missedCall`, и принятый звонок помечался пропущенным.

Фикс: один владелец записи. Экран звонка — единственный, кто заводит и закрывает запись о состоявшемся звонке, направление берётся из уже вычисленного `isJoiningExistingCall` (`presentCallScreen(configuration:startWithVideoEnabled:direction:)`). `CallHistoryCoordinator` теперь заводит запись только для звонков **без экрана** (непринятые) и игнорирует `missedCall` для звонка, который идёт на экране.

**3. В «Недавних» вместо имени — сырой room ID** (`Профиль в соцсети: !AlJFAes…:stalk.implica.ru`). У исходящего звонка handle уже был по имени, у входящего остался room ID: `update.remoteHandle` теперь имя звонящего (fallback — room ID).

**4. Сверщик участия возвращал нас в звонок после «положил трубку».** В 269 гард `isLeavingCall` ставился в `stop()`, а очистка нашего `m.call.member` (`tearDownCallSession`) стартует раньше: лог 149 — `clearCallMember PUT 200` в 17:42:27.5 → эхо в 17:42:27.556 → `membership recon #1 → переотправляю join`, и в одном из случаев (17:41:09) участие реально восстановилось. Для собеседника мы висели в звонке ещё до 30с после отбоя. Намерение уйти объявляется теперь ПЕРВЫМ действием завершения: `NativeCallSession.beginLeaving()` из `endCall()`/`performStopCleanup()`.

Файлы: `ElementCallService.swift`, `UserSessionFlowCoordinator.swift`, `CallHistoryCoordinator.swift`, `NativeCallSession.swift`, `CallScreenViewModel.swift`.

**Device-тест:** входящий звонок принять → свернуть (зелёная плашка идёт), завершить → в «Недавних» имя звонящего и реальная длительность; в истории звонков ОДНА запись «входящий»; непринятый звонок → одна запись «пропущенный»; после отбоя собеседник (веб) сразу перестаёт видеть нас в звонке.

---

### 92. ✅ STMOB-266 — тихий notify звонка: осмысленный баннер вместо пустой плашки

**Дата**: 2026-07-26
**Коммит**: `<TBD>` (ios)

Жалоба dp на 269: «лишний пуш на входящем звонке из комнаты — пуш пустой, а не звонок».

**Разбор.** Со стороны iOS в логе 149 видно: в 17:41:23 на звонок пришёл ОБЫЧНЫЙ APNs (`NSE preprocess: contentType=nil → unsupportedShouldDiscard` → заглушка), VoIP-пуша не было вовсе; следующий звонок в ту же комнату в 17:42:12 получил VoIP и штатный CallKit. Molly подняла журналы Sygnal: событие `$OfrEYY…` — тип `org.matrix.msc4075.call.notify` с **`intent=silent`**. Правка в `voip_filter_pushkin` от 2026-05-16 намеренно пропускает silent-варианты через обычный пушер («в группе звонок не должен звонить всем, но человек должен видеть, что звонок начался»), а VoIP-пушер их дропает («CallKit reserved for ring intent»). То есть доставка штатная с обеих сторон — **не совпал контракт**: сервер шлёт информационное событие, а NSE не умеет его отрисовать.

**Решение (вариант dp — Б):** делать плашку осмысленной, а не глушить. Глушить нельзя: иначе про групповой звонок в фоне не узнать вовсе.

**iOS-часть.** Баннер собирается из payload ДО подъёма сессии SDK (`CallNoticePayload` + `CallNoticeGate` в `NSE/Sources/NotificationHandler.swift`, точка входа в `NotificationServiceExtension.swift`): по этим типам SDK контента не даёт в принципе, а так это работает и на залоченном девайсе, и без credentials, и не тратит 24-секундный бюджет расширения. Ветка открывается ТОЛЬКО на `call_notify_type = notify`; при `ring` и при отсутствии поля — ничего не меняется (обратная совместимость со старым сервером). Гейт: свежий VoIP-маркер (<30с, CallKit уже на экране) → молчим; `call-active` маркер (мы в этом звонке, +2 мин грации) → молчим; протухший звонок (`expires_ts`, запасное — возраст события >120с) → молчим; дедуп по `event_id` и семантический по комнате (веб шлёт 2-3 notify на один звонок).

Второй слой — на данных SDK, работает уже сейчас, без серверных изменений: `handleCallNotification` для не-ring возвращал `.processedShouldDiscard` (та же пустая плашка) — теперь показывает баннер с тем же гейтом, а `NotificationContentBuilder` разводит ring (рингтон, `.timeSensitive`) и notify (обычный звук, `.active`, категория `call`).

Тап по баннеру ведёт В КОМНАТУ, а не сразу в звонок: пока пуш шёл, звонок мог кончиться — тогда прямой `.call(roomID:)` завёл бы новый звонок вместо присоединения. В шапке комнаты кнопка присоединиться уже есть.

Строки заведены и в `ru.lproj`, и в `en.lproj` (не только `value:` в коде): сервер использует те же ключи как `loc-key` в `aps.alert`, чтобы текст был осмысленным даже если NSE не успеет отработать — для `loc-key` фолбэк из кода не применяется.

Файлы: `NSE/Sources/NotificationHandler.swift`, `NSE/Sources/NotificationServiceExtension.swift`, `NSE/Sources/NotificationContentBuilder.swift`, `NotificationConstants.swift`, `NotificationManager.swift`, `AppCoordinator.swift`, `Localizable.strings` (ru/en).

**Серверная половина (Molly, STALK-572, ETA 27.07):** обогащение APNs-payload обычного пушера — `event_type` (сырой), `call_notify_type`, `sender_display_name`, `sender`, `room_name`, `is_direct`, `expires_ts`, плюс `aps.alert.loc-key`. Контракт согласован в #ops.

**Device-тест:** звонок из групповой комнаты при свёрнутом приложении → баннер «Иван Жилин начал звонок» (не пустой), тап открывает комнату с кнопкой присоединиться; звонок 1:1 по-прежнему приходит CallKit-звонком; второй notify по тому же звонку баннер не дублирует; свой звонок баннером не отзывается.

---

### 93. ✅ Разбор ревью 271: сессия входящего, перезвон из «Недавних», живой захват камеры (build 272)

**Дата**: 2026-07-26
**Коммит**: `c64949b62` (ios)

Adversarial-ревью кода 270/271 (три независимых прохода + проверка каждой находки на опровержение) дало 9 подтверждённых дефектов; три из них тут же подтвердились логом dp 151 и скриншотами с устройства.

**1. CallKit-сессия входящего умирала через секунду после ответа при холодном старте.** `observeIncomingCall` вызывается ещё раз, когда поднимается сессия (`setClientProxy`), а при убитом приложении это происходит уже ПОСЛЕ ответа. Наблюдатели фазы «звонит», снятые в обработчике ответа, возвращались, и первое же событие с нашим участием читалось как «ответили на другом устройстве». Лог 151: `didActivate 18:59:18.245` → `didDeactivate 18:59:19.169`; на устройстве это выглядело как «звонок идёт, а времени не видно» — системного таймера нет, потому что для CallKit звонка уже нет. Гард по `answeredCallKitID` до и после `await`.

**2. Отбой до соединения не закрывал ничего.** `tearDownCallSession` адресовал завершение только `ongoingCallID`, который в нативном режиме появляется лишь после connect. Если звонок завершался раньше (не дошли до экрана, join упал, звонящий бросил трубку), не уходил ни `.endCall` в историю — метка активного звонка залипала и глушила последующие пропущенные из этой комнаты, — ни завершение CallKit: системный звонок висел активным до ручного нажатия. Теперь завершение адресуется `ongoingCallID ?? incomingCallID`, с прямым `reportCall(endedAt:)` если транзакцию система отклонила.

**3. Имя в CallKit-handle ломало перезвон из «Недавних».** Перезвон приходит через `INStartVideoCallIntent`, и `AppCoordinator.handleUserActivity` читает `personHandle.value` как roomID. После правки 269/270 туда клалось имя — перезвон уходил бы в комнату «Сергей». Вернула машинный идентификатор; имя показывает `localizedCallerName`, теперь и у исходящего (`reportCall(with:updated:)` сразу после старта транзакции).

**4. Маркер «звонок кончился» отделён от «звонок идёт».** Один маркер с TTL 120с обслуживал две разные задачи: подавление E2EE-хвостов после отбоя (грация нужна) и решение «показывать ли баннер о звонке» (грация вредна). Лог 151: `19:01:07` отбой → `19:01:42` и `19:02:00` баннеры о новых звонках погашены как «call-active marker». Теперь `call-tail` пишется отдельно, `isCallActive` (45с, heartbeat 30с) отвечает за «идёт прямо сейчас», `isCallOrTail` — за подавление хвостов.

**5. Дедуп NSE считал дубликатом любую ошибку `open()`.** Каталог дедупа лежит под классом защиты по умолчанию и недоступен до первой разблокировки после перезагрузки — то есть уведомление гасилось ровно там, где ветка баннера задумана работать (она специально стоит до гарда `isDeviceLocked`). Дубликат теперь только по `EEXIST`, каталог создаётся без защиты (файлы пустые, смысл несут имя и mtime).

**6. Мёртвый захват камеры больше не проходит молча.** Лог 151, хвост предыдущего звонка: `egress camera: bytes=0 packets=0 encoded=0 captured=0 active=true ice=connected flat=30с` — трек опубликован, ICE соединён, а источник не отдал НИ ОДНОГО кадра; собеседник видит чёрный экран, мы — ничего. Сторож это состояние специально пропускал («нет кадров — отправлять нечего»), не отличая «камеру выключили» от «камера включена и не снимает». Добавлен отдельный детектор (трек не на паузе, `active`, кадров нет 8с подряд) и своё лечение: перепубликация камеры вместе с процессором фона, одна попытка на звонок, и только когда приложение активно (в фоне остановка камеры законна).

Файлы: `ElementCallService.swift`, `CXProviderProtocol.swift`, `LiveKitRoomManager.swift`, `NSE/Sources/NotificationHandler.swift`, `Localizable.strings` (ru/en).

**Серверная часть (Molly):** для групповых комнат `loc-key` = `stalk_notification_call_started_in_room` с двумя аргументами (имя, комната) — иначе в фолбэк-алерте не видно, в какой комнате звонок; плюс запрошен `call_id` в payload, чтобы дедуп баннеров был по звонку, а не по комнате.

---

### 94. ✅ Звонок без E2EE при неизвестном состоянии шифрования; перезвон в группу; честный тип звонка (builds 273-274)

**Дата**: 2026-07-26
**Коммиты**: `b7d6eb79a`, `19494e615` (ios)

Три жалобы dp с устройства: «не вижу видео в обе стороны», «в группу не перезванивает из Недавних», «нет таймера в Динамическом острове на входящем».

**1. Видео: комната подключалась БЕЗ шифрования — и это ломало ВЕСЬ медиатракт.**
Разбор занял три билда, потому что участок между «капчер стартовал» и «кадр ушёл в трек» не логировался вовсе; в 273 туда добавлены лог первого кадра камеры, проверка размеров трека через 4с после публикации и зонд первого кадра на ЧУЖИХ видеотреках. После этого лог 154 ответил сразу — и опроверг рабочую гипотезу: камера жива, `камера: ПЕРВЫЙ кадр 1280x720` есть в каждом звонке, а предупреждение SDK `Cannot re-compute sender parameters without dimensions` оказалось следом снятия трека, а не мёртвого захвата.

Настоящая причина видна при сравнении двух соседних звонков. Там, где видео не было ни в одну сторону: нет строки `post-connect: e2eeManager=present`, ключа нет (`rebroadcast SKIPPED — no current key`), дорожки опубликованы с `encryptionType=0`, зонд чужого видео молчит. Там, где видео есть: `e2eeManager=present`, `initial sendOurEncryptionKey`, `encryptionType=1`, `видео от @rusty…: ПЕРВЫЙ кадр 320x180`. То есть в шифрованной комнате мы подключились к SFU открытыми: своё медиа собеседник принять не может, чужое расшифровать нечем — обе стороны видят чёрный экран, и ни одной ошибки в UI.

Состояние шифрования бралось снимком `roomInfo.isEncrypted`, который схлопывает `unknown` в `false`. Для сообщений это безопасно (SDK доуточняет состояние до отправки — так и написано в комментарии upstream), для звонка фатально: снимок берётся ОДИН раз и определяет весь медиатракт до конца звонка. `unknown` особенно вероятен при входе в уже идущий звонок сразу после старта приложения — отсюда и «через раз». Теперь `JoinedRoomProxy.encryptionStateForCall()` спрашивает SDK явно (`latestEncryptionState`), а при неизвестном ответе считает комнату шифрованной: открытая публикация в шифрованный звонок — это и поломка, и утечка.

**2. Перезвон в группу из системных «Недавних».** `handleUserActivity` разбирал только `INStartVideoCallIntent`. Видеозаписью в «Недавних» становится входящий (он объявляется `hasVideo=true`) — поэтому 1:1 перезванивался. Групповой звонок попадает в «Недавние» нашим исходящим, который зарегистрирован как аудио, и система шлёт `INStartCallIntent`/`INStartAudioCallIntent` — их обработчик молча игнорировал. Разбираются все три намерения, все три объявлены в `NSUserActivityTypes`.

**3. Тип звонка для системы.** Входящий всегда объявляется видео (иначе iOS не выводит его на передний план), и после ответа это враньё остаётся: в «Недавних» аудиозвонок подписан «ВИДЕОВЫЗОВ», а в «Динамическом острове» система рисует видеозвонок значком камеры — без счётчика длительности. `setCallHasVideo` сообщает фактический тип по состоянию камеры при входе в звонок и на каждое переключение видео.

Файлы: `JoinedRoomProxy.swift`, `RoomProxyProtocol.swift`, `CallScreenViewModel.swift`, `ElementCallService.swift`, `ElementCallServiceProtocol.swift`, `LiveKitRoomManager.swift`, `AppCoordinator.swift`, `Info.plist`/`target.yml`.

**Device-тест:** войти в УЖЕ идущий звонок сразу после старта приложения → в логе `звонок: шифрование комнаты = true`, `e2eeManager=present`, `encryptionType=1`, видео с обеих сторон; перезвон из «Недавних» по групповой записи → открывается комната и начинается звонок; входящий аудиозвонок принять и свернуть → в острове счётчик, в «Недавних» не «ВИДЕОВЫЗОВ».

---

### 95. ✅ CallKit-цикл добит: длительность, перезвон, имя в «Недавних», аватар вместо серого круга (builds 275-277)

**Дата**: 2026-07-26
**Коммиты**: `4da05aa3a`, `54ab4f148`, `8589b85e0`, `9f248501a`, `f00064be1` (ios)

Серия device-тестов dp по CallKit. Каждый симптом получил доказанную причину.

**Длительность и таймер входящего (275).** Ответ подтверждался `action.fulfill()` без даты — система не считала звонок соединённым: в «Недавних» «0 с» на 28-секундном звонке (лог 155, 20:37:27→20:37:55), в «Динамическом острове» счётчик отсутствовал или стоял на нуле. У исходящего болезни не было, потому что там момент соединения сообщается явно. Теперь `fulfill(withDateConnected:)`. Подтверждено скриншотом: «1 мин» вместо «0 с».

**Перезвон в группу (275).** Разбор намерений (273) был необходим, но недостаточен: подписка стояла только на `INStartVideoCallIntent`. Групповой звонок попадает в «Недавние» нашим исходящим, зарегистрированным как аудио, поэтому активность до приложения не доходила вовсе — в логе ни одной строки о перезвоне, приложение просто открывалось. Подписываемся на все три типа.

**Имя в «Недавних» и серые кнопки перезвона (276).** Звонок представлялся системе двумя разными идентификаторами: в CallKit-handle roomID (по нему работает перезвон), а карточка с именем и аватаром дарилась под MXID отправителя. Связать одно с другим система не может — отсюда и родовой заголовок «ВИДЕОВЫЗОВ STALK» с сырым `!room:server` вместо имени, и неактивные кнопки перезвона. Главный идентификатор карточки теперь совпадает с handle звонка, MXID остался псевдонимом для Siri; для исходящего карточка дарится так же, с именем комнаты.

**Направление в истории (275).** Бралось из снимка состояния комнаты (`hasRoomCall` + участники). На ответе из убитого приложения синк ещё догоняет, и принятый ВХОДЯЩИЙ записывался исходящим. Теперь признак берётся у сервиса звонков (CallKit-звонок либо явная пометка входа в идущий звонок), снимок — запасной вариант.

**Замёрзшая картинка и серый круг (275, 277).** SDK при выключении камеры не удаляет публикацию, а мьютит её: запасная ветка выбора трека возвращала замьюченный трек, и вместо исчезновения картинки собеседник «замерзал» последним кадром (275). Дальше вскрылось следствие: заглушка «камера выключена» в 1:1 не получала участников из Matrix и умела показать только инициалы из идентификатора LiveKit — у веба он выглядит как `@user:server:DEVICE`, инициалы из него не выводятся, оставался пустой серый круг (277).

**Тип звонка для системы (274).** Входящий всегда объявляется видео (иначе iOS не выводит его на передний план), после ответа это враньё видно в «Недавних» («ВИДЕОВЫЗОВ» на аудиозвонке) и в «Динамическом острове». Теперь сообщается фактический тип. Решение dp: при включённой камере счётчика в острове нет — это штатное поведение iOS для видеозвонков, длительность при этом пишется верно, оставляем как есть.

**Диагностика вместо догадок (277).** «Собеседник выключил камеру» и «камера включена, а кадров нет» снаружи неотличимы — публикация есть в обоих случаях. Состояние чужой публикации пишется при подписке и на каждое изменение. Плюс детектор рассинхрона шифрования (276): комната без шифрования, а от собеседника пришёл ключ — значит он шифрует, мы нет, и картинки не будет ни у кого при полностью «зелёном» соединении.

**Открыто.** Групповое видео: комната `!AlJFAes…` серверно НЕ шифрована (подтвердила Molly), iOS ведёт себя правильно; версия про общий ключ на вебе опровергнута логом 157 — от веба не пришло ни одного ключа. Причина пока не названа, диагностика 277 должна доназвать её следующим прогоном. Групповой звонок в системных «Недавних» помечается исходящим — это не ошибка записи: групповой звонок не звонит (тихое уведомление), значит входящего на устройстве не было; чтобы система считала его входящим, групповые звонки должны идти с намерением «ring» — продуктовое решение.

---

### 96. ✅ Видео тех, кто уже в звонке; таймер при входе в идущий звонок; эхо самого себя (build 278)

**Дата**: 2026-07-26
**Коммит**: `4d3ab263d` (ios)

**Видео приходило не от всех — и признак оказался жёстким.** Сравнение двух соседних звонков (лог 160): участник, вошедший ПОСЛЕ нас, виден сразу (`видео от @rusty…: ПЕРВЫЙ кадр 320x180`); участник, который был в комнате ДО нас, не давал ни кадра — при том что трек подписан и `muted=false`. Для группового звонка это основной сценарий, поэтому «видео не работает» выглядело случайным.

Механика в SDK: трек считается видимым, только если к нему привязан хотя бы один приёмник, участвующий в адаптивной подписке (`containsOneOrMoreAdaptiveStreamEnabledRenderers`). У тех, кто уже в комнате, подписка происходит в момент нашего connect — плитка ещё не смонтирована, «видимых» приёмников ноль, и SDK гасит трек (`shouldReceive = false`). Добавленный в 273 диагностический зонд первого кадра объявлял себя неучаствующим в адаптивной подписке и потому не спасал. Теперь зонд — полноценный приёмник с нулевым размером: трек остаётся включённым на самом лёгком слое, пока UI не привяжет настоящий рендерер.

**Своё эхо среди чужих участников.** В списке remote-участников приходил НАШ собственный идентификатор (`@dp.bondar…Que9n9te7L`, лог 159 21:27) — вторая сессия или сервис записи. Раскладка 1:1 отдавала ему главное место вместо собеседника, а трек собеседника оставался без приёмника. Собственный идентификатор отфильтрован.

**Таймер исходящего при входе в идущий звонок.** Система считает длительность, только если «соединяется» пришло раньше «соединён». При входе в уже идущий звонок собеседник в комнате с первой миллисекунды, признак «соединились» срабатывал мгновенно и обгонял регистрацию звонка: лог 159 — `connected 21:26:55.801`, `connecting 21:26:55.805`. Отсчёт не начинался, в «Динамическом острове» висела плашка без счётчика. Ранний «соединён» теперь откладывается и отдаётся сразу после «соединяется».

**Device-тест (пройден dp):** Иван заходит в звонок первым с камерой, iOS вторым → видео видно сразу.

---

### 97. ✅ Счётчик длительности исходящего: отчёты только после того, как система завела звонок (build 279)

**Дата**: 2026-07-26
**Коммит**: `1c9e0a5` (ios, см. `git log` — «отчёты о состоянии исходящего»)

Плашка звонка показывалась без счётчика при входе в уже идущий звонок. Рабочая версия «iOS прячет счётчик у видеозвонков» была снята наблюдением dp: значок в плашке — трубка, то есть система считала звонок аудио.

Настоящая причина — в порядке системных событий (лог 161):

```
21:50:29.624  транзакция CXStartCallAction принята (completion контроллера)
21:50:29.642  provider(_:perform: CXStartCallAction) — система завела звонок
```

Отчёты `startedConnectingAt` / `connectedAt` уходили по факту принятия транзакции, то есть ДО того, как звонок для системы появился. Такой отчёт игнорируется: звонок остаётся «соединяющимся», отсчёт не начинается, в «Недавних» «0 с». Оба отчёта перенесены в обработчик действия; придерживание раннего «соединён» (build 278) сохранено — оно нужно, когда собеседник уже в комнате и признак соединения срабатывает мгновенно.

**Правило:** для исходящего звонка отчёты о состоянии имеют смысл только после `provider(_:perform: CXStartCallAction)`. Принятая транзакция — ещё не заведённый звонок.

**Device-тест (пройден dp):** вход в идущий звонок → сворачивание → счётчик идёт.

---

### 98. ✅ Окно звонка при сворачивании, фантомный «silent», значок упоминания, читаемый идентификатор (build 280)

**Дата**: 2026-07-27
**Коммиты**: `521d6face`, `a99dad183`, `b239d621f`, `bc56fa485` (ios)

**Плавающее окно с видео при сворачивании.** Раньше оставалась только зелёная плашка со счётчиком; dp показал, как это выглядит у конкурента. Проводка событий окна в экранах уже была проложена (`CallScreenModels`, `CallScreenViewModel`, `UserSessionFlowCoordinator`) — не хватало источника. Добавлены контроллер содержимого на `AVPictureInPictureVideoCallViewController`, менеджер окна и невидимая подложка на экране звонка: система требует, чтобы источник был в иерархии в момент ухода в фон.

Рисуем строго через `RenderMode.sampleBuffer` (системный слой). Обычный рендерер LiveKit работает через видеокарту, а отправка работы на неё из фона завершается снятием процесса — поэтому просто отдать в окно существующую вьюху нельзя. Наш форк LiveKit этот режим уже содержит (`SampleBufferVideoRenderer.swift`).

Кого показываем в окне: чужая демонстрация экрана → говорящий → первый с включённой камерой. Тот же порядок, что и в мини-окне на экране, иначе при возврате картинка прыгает. Пропал трек — окно не закрываем, показываем подпись. Ограничения, принятые осознанно: своя камера в фоне не живая (iOS останавливает захват), окно появляется только при включённом системном переключателе; иначе остаётся прежняя плашка.

Заодно исправлено: ветка запуска окна не заводила счётчик и обработчик возврата, в отличие от обычного сворачивания — после закрытия окна пользователь оставался с плашкой без времени и без способа вернуться в звонок.

**Фантомный звонок «silent» в системных «Недавних».** iOS требует сообщать о входящем на каждый VoIP-пуш, иначе убивает процесс. Когда показывать звонок не надо (идёт разговор, дубль, протухший вызов), мы сообщаем о заглушке и гасим её — но у основного провайдера включена запись в «Недавние», и заглушка оседала там красной строкой «silent». Признака «не писать в Недавние» у отдельного звонка нет, он задаётся конфигурацией провайдера — заглушки уведены на второй, «тихий». Причину подтвердил журнал Sygnal: payload был корректным (`sender_display_name: Сергей Троцкий`, `notify_type: ring`), строку подставляла наша сторона.

**Значок упоминания не пропадал после открытия чата.** Упоминание висит на событии звонка (в payload звонка приходит `m.mentions` с userID), а такие события в ленте не рисуются; квитанция ставится по элементам ленты и через них не перешагивает. Инвариант: открыли комнату — счётчик обязан обнулиться; после дешёвого пути проверяем факт и при необходимости помечаем прочитанным на уровне комнаты, где учитываются все события.

**Читаемый идентификатор звонка.** В системной карточке строкой «Профиль в соцсети» показывался сырой `!aSRCTT…:server`. Личный звонок теперь идёт под MXID собеседника (опознаём фактом: `directRoomForUserID` совпадает с комнатой звонка), групповой остаётся на идентификаторе комнаты. Перезвон научен разрешать MXID обратно. Кнопки самой карточки этим не оживить — для них нужен телефонный номер, которого у нас нет (проверено на карточке конкурента: там работает сохранённый контакт с номером).

**Device-тест:** свернуть звонок с видео → окно с видео собеседника, тап по нему возвращает в звонок, плашка со счётчиком идёт; звонок во время разговора → в «Недавних» нет строки «silent»; открыть чат с «@» → значок пропадает; карточка звонка в «Телефоне» → MXID вместо room id.

---

### 99. 🆕 «Айлок» в закладке «Приложения»: нативный чат с ИИ-агентом (STMOB-274)

**Дата**: 2026-07-30
**Коммит**: `acea1f571` (ios)

В вебе Айлок встроен нативным React-19 островом поверх door-2-шлюза (кит Tracy, шлюз Molly, движок партнёров). На iOS повторено то же, но своим кодом — веб-остров в мобильный клиент не переносится: он завязан на same-origin страницу веба и требует одного base-path на 16 МБ чанков.

**Контракт снят с прода, а не с документации.** Живые пробы шлюза + разбор раздаваемого бандла `/salamander-chat/ailock-chat.mjs` (плюс догруженный чанк `chunk-T67QRKUU.mjs`, который резолвит внешние функции кита) дали точный контур:

```
BASE = https://<homeserver>/api/ailock/v1/api/v1
```

Двойной `/api/v1` — не опечатка: ingress монтирует шлюз на `/api/ailock/v1`, а кит сам дописывает `/api/v1`. Путь `/api/ailock/api/v1/*` отдаёт 405 от SPA и нашим не является. Авторизация — MAS-токен самого клиента в `Authorization: Bearer` (шлюз токен не подставляет).

**Отправить сообщение можно только по вебсокету** — REST-роута для отправки нет (`POST /conversations/{id}/messages` → 404). Отсюда вся архитектура экрана: `POST /sessions` отдаёт `{conversation_id, ws_ticket}`, тикет одноразовый и живёт секунды, поэтому свежая сессия создаётся перед КАЖДЫМ подключением, а не один раз при открытии.

**Текст ответа собирается только из дельт `agent.token`.** Событие `agent.response` для обычного ответа — это терминатор без текста; идентификаторов и порядковых номеров в протоколе нет вообще. Отступление от кита сделано осознанно: если дельты потерялись, а в терминаторе текст есть — показываем его, иначе пользователь получил бы пустой ответ.

**История приходит не сообщениями, а сырыми строками LLM-лога.** Поэтому разбор повторяет логику острова: строки `channel == "system"` отбрасываются, ответы человека на вопрос агента приезжают как `role == "tool"` и переворачиваются обратно в реплики пользователя (иначе пропадают из ленты), подряд идущие ответы ассистента склеиваются, а вложения достаются из строк-маркеров `__IMAGE_URL__` / `__FILE_URL__` внутри tool-сообщений.

**Файлы в обе стороны.** Вложение пользователя: `POST /conversations/{id}/attachments`, multipart, поле `file`, ровно один файл на запрос, полученные идентификаторы уходят в кадре вместе с текстом. Файл от агента приезжает событием `agent.file {url, filename, mime_type}` и открывается системным листом. Ограничение: канонический путь скачивания кита `/api/v1/uploads/*` шлюзом сейчас не проксируется (404 на всех вариантах) — запрошено у Molly; до открытия роута файл от агента показывается, но может не скачаться.

**Скоуп сознательно урезан.** Кит умеет инструменты, суб-агентов, todo-списки и артефакты — обработчики этих событий есть в бандле, но наш агент сейчас даёт только чат и историю. Поэтому UI под них не рисуется, а парсер молча игнорирует неизвестные события и схлопывает любую «работу» в одну строку «Работает…». Когда движок начнёт слать больше, поток не сломается.

**Раскладка** взята у мобильных LLM-клиентов: реплика пользователя — компактный пузырь справа, ответ агента — во всю ширину без пузыря (длинный markdown в пузыре нечитаем), кнопка отправки во время генерации превращается в «стоп», автопрокрутка отключается, если пользователь сам ушёл вверх. Разметка считается один раз на готовом сообщении — рендерить её на каждый токен нельзя.

**Появление в закладке.** Реестр apps-api пока записи не отдаёт, поэтому приложение подмешивается локально — но только там, где door-2 реально развёрнут: клиент один раз за запуск проверяет роут и на домене без шлюза (например market.implica.ru, где 404) просто ничего не показывает. Серверная запись с тем же идентификатором имеет приоритет, дублей не будет. Локальная запись в дисковый кэш не пишется, иначе пережила бы появление настоящей.

**Открыто у Molly (запрошено 30.07):** примет ли door-2 токен нативного клиента `ru.implica.stalk`; какой `agent_id` каноничен для мобилы; запись `ailock` в apps-api с `type:"builtin"` (не-builtin у нас скрыт после реджекта Apple 2.1(a)); статус на .uz.

**Проверка:** сборка зелёная, экран поднимается. Device-тест не пройден: симулятор залогинен на market.implica.ru, где Айлока нет — нужен вход на мисти.

---

### 100. 🎤 Голосовой ввод в «Айлоке» + уточнённый файловый контур (STMOB-274)

**Дата**: 2026-07-30
**Коммиты**: `b7a098a00`, `618deb0e4`, `6362f0957`, `9404afe3c` (ios)

**Диктовка.** В поле ввода Айлока появился микрофон: диктуешь — распознанный текст падает в поле, отправка остаётся за пользователем (правку распознанного никто не отменял). Пока поле пустое, микрофон стоит на месте кнопки отправки; во время записи вместо поля — панель с таймером, живым индикатором уровня, отменой и «готово».

Пишем **WAV PCM mono 16 кГц**, а не Opus: STT движка Айлока Opus не декодирует, а перекодировать на телефоне незачем. Маршрут согласован отдельным — `POST /api/recording/stt/dictate`, multipart, единственное поле `audio`. Он отличается от транскрибации голосовых (STALK-666) тем, что авторизует **пользователя**, а не доступ к чужому медиа: у диктовки нет события Matrix, поэтому `event_id`/`room_id` там бессмысленны. Ключ тенанта STT остаётся на сервере.

Серверные границы — 25 МиБ и 300 секунд, длительность считается на сервере из самого WAV. Запись режем на **двух минутах**: ≈3.8 МБ, до обеих границ далеко, а диктовка в поле ввода длиннее двух минут смысла не имеет. Ошибки приходят единым конвертом `{error, message, retry_after_seconds}` — разбираем по машинным кодам, на 429 показываем секунды до повтора. 403/404/405 прячут микрофон до конца сессии: на домене без recording-api мёртвой кнопки быть не должно.

**Файлы от агента — честная граница.** Разбор бандла показал, что кит качает их по `/api/v1/uploads/{name}`, а этот путь door-2 не проксирует. Выяснилось, что это не дефект конфигурации, а контракт: путь адресуется именем файла, владение по нему не проверить (решение STALK-653) — открывать его не будут. Проверка со стороны движка подтвердила и второе: в событии `agent.file` нет `attachment_id`, а вывод агента пока живёт в локальном uploads-контуре. Перенос в `chat_attachments` — M24 Ф3, ориентир 10.08.

Поэтому: карточку файла от агента показываем, но **кнопку скачивания не предлагаем** — мёртвых кнопок в интерфейсе быть не должно. `attachment_id` уже читается и из события, и из истории: когда движок начнёт его слать, скачивание пойдёт по owner-scoped пути без единой правки клиента. Вложения самого пользователя работают полностью, качаются по `GET /conversations/{id}/attachments/{attId}`.

**Замер door-2.** По запросу владельца контура в лог выводится только метод, путь и HTTP-статус — ни токена, ни тела, ни ПДн. Строка идёт и в `os_log`, и в тестерскую выгрузку; на ней и снимется PASS/gap приёма токена нативного клиента.

**Ревизия перед сдачей.** Код, который ни разу не выполнялся против живого сервера, прогнан через адверсарную ревизию: четыре ревизора по осям (контракт, конкурентность, состояния экрана, интеграция), каждая находка проверялась двумя скептиками на опровержение. Из 58 кандидатов подтвердилось 26 — почти все в управлении состоянием, то есть ровно то, что вылезло бы у пользователя руками.

Три ломали основной сценарий. Смена беседы не сбрасывала идентификатор стримящегося сообщения и буфер дельт (в отличие от «нового чата»), поэтому следующий ответ агента терялся целиком: заготовка не создавалась, дельты уходили в никуда. Признак «идёт генерация» залипал после возврата из фона — композер навсегда оставался в режиме «стоп», а сам «стоп» выходил по отсутствию сокета, то есть был мёртвой кнопкой. Отмена реконнекта перезапускала реконнект: цепочка переживала уход в фон и закрытие экрана и поднимала сокет в фоне — против правила 0xDEAD10CC.

Остальное: бесконечный цикл переподключений (счётчик обнулялся по факту рукопожатия, а не живого кадра); исчерпание попыток оставляло «работает» навсегда; одна задача на историю и отправку — отправка убивала догрузку истории; текст и файлы пропадали при ошибке отправки; вложения молча терялись при ответе на вопрос агента; гонка двух сессий; кэш пробы и ключ последней беседы не были привязаны к аккаунту и домену; диктовка перенастраивала общую аудио-сессию поверх активного звонка. Всё исправлено (`e489fb3ba`).

**Проверено вживую:** проба доступности и тихая деградация — на market.implica.ru, где door-2 отвечает 404, Айлок в закладке корректно не появляется (в логе `Ailock door-2 available = false`), приложение работает штатно.

**Не проверено:** ничего из этого не запускалось против живого сервера — симулятор залогинен на market.implica.ru, где door-2 отдаёт 404. Нужен вход на мисти. Маршрут диктовки на стороне сервера появится 31.07 к 15:00 МСК.

---

### 101. 📦 Сборка 307 (26.04.11) — Айлок уезжает на живую проверку

**Дата**: 2026-07-31
**Коммит**: `92aa5a7fc` + бамп версии (ios)

Первая сборка с «Айлоком». Уезжает ради одного замера: `POST /sessions` настоящим employee-токеном с телефона — единственное, чего нельзя снять из репозитория. Статус попадёт в лог строкой `Ailock POST /sessions -> NNN` и в тестерскую выгрузку.

По вердикту владельца контура перед сборкой снято два клиентских решения. `agent_id` клиент больше не отправляет вовсе — агента назначает gateway своим дефолтом, а зашитый веб-агент однажды разошёлся бы с сервером. Автоматический фолбэк диктовки на multipart убран: повтор после любого `400` маскировал бы по-настоящему битую запись и удваивал нагрузку на распознавание; канон — сырой WAV, проверенный живой пробой.

Показывается Айлок только там, где door-2 реально отвечает: клиент один раз за сессию проверяет маршрут и на доменах без него не рисует приложение вовсе. Проверено вживую на market.implica.ru — `Ailock door-2 available = false`, плитки нет.

В эту же сборку попал «Диск» на стадии первого этапа — он в работе, тестировать его рано.

---

### 102. 🔔 Пустые пуши «Новое сообщение»: диагноз зависания и починка заглушки (STMOB-277)

**Дата**: 2026-07-31
**Коммит**: `61cf49acd` (ios, ветка stmob-ns-blur)

По логу dp «nse-events 202» (26.04.11/307) 19 из 42 пушей за вечер показались заглушкой. Причина найдена сопоставлением лога NSE, истории #ops и ingress-логов Misty посекундно: сервер невиновен (sync 0.03–0.07с, context 0.016с) — `getNotification()` в Rust SDK виснет ~25–32с **до первого сетевого запроса**, fallback `/context` вылетает уже после сгорания бюджета. Наш 23-секундный таймаут Rust-вызов не отменяет (uniffi игнорирует Swift cancellation) — зомби держит общий NotificationClient процесса, и следующий пуш встаёт за ним (head-of-line): поэтому падает первый пуш после паузы, а пришедшие в течение минуты после — проходят. Точное место ступора (crypto-лок vs сериализация NotificationClient) добивается по SDK console-логам с устройства (7-тап после пустой плашки) — запрошены у dp.

Пока причина не убита, заглушка сделана полноценной: несёт `room_id`/`event_id`/`receiver_id` и threadIdentifier в формате билдера — тап открывает чат (раньше был no-op), группируется с уведомлениями комнаты. Дедуп-отметка события при показе заглушки снимается — повторная доставка того же event_id больше не глотается как «дубль», а успешный ретрай снимает заглушку из Центра уведомлений (приём redaction-пути). Правки прогнаны через адверсарную ревизию (3 линзы × скептики): подтверждённая гонка зачистки с expiration-доставкой закрыта исключением собственного `request.identifier`; повторный таймаут не копит заглушки; EmptyProxy не затирает информативную заглушку худшим баннером; состояние хендлера — под замком.

---

### 103. 📺 PiP пропадал на весь звонок после неудачного отбоя предыдущего (STMOB-278)

**Дата**: 2026-07-31
**Коммит**: `052849b14` (ios, ветка stmob-ns-blur)

dp: «в групповом звонке вообще нет PiP» (30.07), при этом воспроизвести на свежем запуске не удалось — и это оказалось частью механизма. Код-аудит (3 линзы × адверсариальные верификаторы, 10 подтверждённых находок) свёл пять из них к одной корневой причине: засов «отбой был — окно не заводить» на PiP-синглтоне сбрасывался только в `stop()`, а `stop()` пропускался, когда экран звонка сносится раньше фоновой очистки LiveKit (dismiss мгновенный, cleanup до ~16с — dismantle видел старый roomManager ещё `.connected`). Засов переживал звонок и молча убивал системное окно на весь следующий; группа страдала статистически — она почти всегда идёт после другого звонка той же сессии.

Фикс: засов скоуплен на звонок — чужой `LiveKitRoomManager` в `start()` означает новый звонок, засов снимается; пересборка дерева того же звонка после отбоя держит его (STMOB-301 не регрессирует). Вторым фиксом `hasVideoNow` считает демонстрацию экрана видео: групповой звонок «без камер, но с демкой» раньше не взводил автозапуск окна вовсе.

Дорешено с dp тем же днём (`2de1b0388`): PiP-окно теперь появляется и во время гудков видеозвонка — подложка вынесена в общий хелпер и смонтирована на экране набора; при ответе собеседника его видео доезжает прямо в окно. Голосовой набор окна не даёт (автозапуск только при живом видео, STMOB-284 не регрессирует). Второе решение dp: «заранее» видео не предугадывать — звонок, начавшийся как аудио, окна не получает, пока видео реально не появилось (чёрный квадрат бесит) — оставлено как есть, посев признака видео у джойнера отклонён.

---

### 104. 🤖 Айлок: markdown в ленте, карточная панель ввода, синяя иконка Календаря

**Дата**: 2026-07-31 (вечер, по скринам dp с 312)
**Коммит**: `c609f54b6` (ios, stmob-ns-blur); иконка — design/meetings-calendar.png → apps-api (Molly)

Три замечания dp по живой 312. Ответы движка приходят полноценным markdown, а лента рендерила только инлайн (жирный работал, `###`-заголовки, списки и код-блоки — сырой текст): теперь блоки разбираем сами (`AilockMarkdownText` в AilockChatScreen.swift — заголовки, списки с исходной нумерацией, цитаты, код-блоки, линейки; инлайн — системным парсером; стриминг по-прежнему plain, разметка один раз на готовом ответе; парсер проверен скриптом на тексте с экрана dp, поймана и закрыта ловушка «абзац после списка приклеивается к пункту»). Панель композера из слепого среза стала карточкой со скруглённым верхом и мягкой тенью по референсу. Иконка Календаря: после серии статичных вариантов dp выбрал **живую плитку-дату** (`7f921a859`) — день недели + сегодняшнее число на teal #2FA98C референса, по образцу системного виджета. Рисуется клиентом в widgetIcon (WidgetsListScreen.swift), iconUrl для meetings-calendar игнорируется; запрос на замену PNG в apps-api у Molly снят.

---

### 105. 💾 Нативный Диск: иконки типов, двухстрочные имена, аватарки шаринга, превью, поиск (STMOB-275)

**Дата**: 2026-08-01
**Коммит**: `b6a0a5288` (ios, stmob-ns-blur)

Пакет замечаний dp по живому скрину: иконки файлов различаются по расширению узнаваемыми цветами (Word синий, PDF красный, Excel зелёный, PPT оранжевый, txt серый, архивы коричневые, аудио индиго, видео розовое; фолбэк — серверная категория); имя файла в списке — две строки с обрезанием посередине; у расшаренных файлов — до трёх аватарок получателей внахлёст + «+N» (профили лениво через `clientProxy.profile(for:)`, резолвер прокинут координаторами, до загрузки — инициалы); карточки изображений показывают настоящую миниатюру (незашифрованные с mxc; зашифрованным сервер превью отдать не может — глиф с замком); поиск по имени со стройкой в навбаре — при первом запросе докачиваются все страницы пагинации, поиск честный по всему Диску. Представление по папкам отложено до серверного контракта (у клиента только folderId, имён нет — запрошен у Molly).

---

### 106. 💾 Айлок → Диск: «Сохранить на Диск» на ответе агента + Диск-документы в списке (STMOB-274/275)

**Дата**: 2026-08-03
**Коммит**: `f928d23e9` (ios, stmob-ns-blur)

По запросу dp «результат ответа айлок добавить на диск к себе». Долгий тап по готовому ответу агента → меню «Скопировать» / «Сохранить на Диск»: текст уходит Диск-документом (`POST /api/files/blob?diskDoc=1` — контракт веба, снят из files-api-code и проверен живой пробой: upload → чтение → удаление), имя — из первой строки ответа (markdown-обвязка срезается, 40 символов), зелёный тост подтверждения. Во время стриминга меню нет — сохранилась бы обрезанная середина.

Ключевая находка пробы: Диск-документы в `GET /api/files` НЕ входят — веб подмешивает их отдельным `GET /disk-docs`; повторено на iOS (`fetchDiskDocs()` + подмешивание в «Все» тем же правилом, что расшаренное). Без этого сохранённый ответ был бы невидим в своём же Диске.

Адверсариальное ревью (3 линзы × скептики, 8 подтверждённых): гейт пустого состояния Диска переведён на объединённый список (на свежем аккаунте документ прятался за «Здесь пока нет файлов»); «+» в имени дожимается в %2B (Node-парсер декодировал бы пробелом — проверено на поде); /disk-docs разбирается поштучно c DiagLog, blobId терпим к числу, ts через Int64(exactly:) вместо трапающегося Int64(Double); сетевой сбой загрузки пишется в выгрузку; меню на текстовом блоке, не на всём сообщении (не перехватывает долгий тап файловых карточек); тост анимирован. Сквозной смоук на симуляторе: вопрос → ответ → сохранение → документ первой строкой в «Все» (MD-плитка, 274 Б).

---

### 107. 🌪️ «Контакты» больше не штормят справочник пользователей (STMOB-303, сборка 337)

**Дата**: 2026-09-28
**Коммит**: `b2d81c3c4` (ios, stmob-ns-blur)

На проде iOS 26.20.x слал `POST /user_directory/search` до 1422 раз в минуту, 80% отказов 429. Модель «Контактов» живёт всю сессию и на каждое изменение списка комнат шла в справочник: пустой поиск плюс перебор 26 букв, без отмены прошлого похода. Отказ 429 выглядел как пустой результат и сам запускал новый перебор.

Что сделано. `UserDirectoryFetchGate`: не больше одного похода одновременно; после удачи — не чаще раза в 10 минут; после отказа — отступ 1-2-4… с, не меньше, чем просит сервер. Любой отказ останавливает поход целиком. Сеть и слияние разведены: список собирается локально из последнего известного состава справочника. Поиск участников на экране встреч гасит дребезг и отменяет прошлый запрос.

⚠️ SDK 26.06.03 отдаёт 429 у `search_users` не как `MatrixApi(.limitExceeded)`, а текстом в `ClientError.Generic`. Разбираются обе формы: `ClientProxyError.isRateLimited` / `retryAfter`.

---

### 108. 🚪 Участник чата больше не видит «нужно приглашение» (STALK-951, сборка 338)

**Дата**: 2026-09-28
**Коммит**: `cdc7d0c8f` (ios, stmob-ns-blur)

Тап по пушу из чата, созданного, пока приложение спало, открывал экран присоединения с «нужно приглашение». Комнаты ещё нет в памяти SDK, а превью без закешированной комнаты теряет членство, которое вернул сервер (`room_preview.rs`). Симптом возвращался в третий раз: правки 260/261 лечили только паузу хранилища.

Что сделано. Ожидание синка комнаты (до 10 с) — для любого тапа по уведомлению, а не только по приглашению. Экран присоединения: локальная joined-комната сразу ведёт в чат. Неизвестное членство даёт режим с кнопкой вместо догадки «нужно приглашение». Когда синк привозит комнату joined, экран сам уводит в чат.

---

### 109. 🟢 Присутствие: ограниченный опрос и один писатель своего статуса (STMOB-304, сборка 339)

**Дата**: 2026-09-29
**Коммит**: `52e4cb1d8` (ios, stmob-ns-blur)

Логи ingress misty за 12,8 ч показали две причины. Все 429 на присутствие — это PUT своего статуса: его слали два писателя при лимите Synapse 1 PUT в 10 с на учётку. GET уходили пачками до 114 в секунду с одного телефона. На sliding sync присутствие не приходит вовсе, поэтому опрос остаётся, но ограниченный.

Свой статус пишет теперь только `OwnPresenceManager`: online раз в 20 с, так как Synapse снимает устройство через 30 с. На 429 он ждёт `retry_after_ms`, на 401 — новый токен, при выходе из аккаунта останавливается. `PresenceService` опрашивает то, что нужно экранам: видимые строки «Чатов» и «Контактов», собеседника открытой комнаты и в фоне 30 недавних собеседников. Бюджет — пачка 20, дальше 0,5 запроса в секунду. 429 ставит на паузу всех, 403 без общей комнаты кэшируется на 6 ч. Точка «в сети» гаснет через 5 минут.

---

### 110. 🧹 Хвосты STALK-951 / STMOB-304 и зелёный набор юнит-тестов (STMOB-307…311, сборка 340)

**Дата**: 2026-09-29
**Коммиты**: `fa5c94f4b` (хвосты), `f85792225` (тесты) (ios, stmob-ns-blur)

- **STMOB-307.** Ответ прямо из уведомления ждёт комнату так же, как тап. Если чат не доехал, приходит локальное уведомление «не отправлено» — раньше ответ молча пропадал. В фоне обработка держится фоновой задачей со штатной остановкой синка (0xDEAD10CC).
- **STMOB-308.** Экран присоединения спрашивает у SDK членство при каждом изменении списка комнат и раз в 2 с. Теперь он видит чаты «низкий приоритет» и приглашение, принятое на другом устройстве.
- **STMOB-309.** `addRoomsToAwait` — атомарная вставка вместо изменяемого свойства. Решение «куда вести тап и что ждать» вынесено в тестируемую функцию. Отложенные комнаты холодного старта объединяются.
- **STMOB-311.** Скрытые вкладки «Чаты» и «Контакты» не опрашивают присутствие. Расписание своего статуса перенесено на монотонные часы. Абсурдный Retry-After отбрасывается, потолок — 5 минут.
- **STMOB-310.** 69 падавших тестов и краш процесса разобраны: 1082 теста, 0 падений, три прогона подряд со случайным порядком. Тесты проверяли апстрим, а не форк — каждая правка подписана коммитом форка, который изменил поведение. Заодно найден продуктовый дефект: в ru/uz эмоут «/me» терял «*» и пробел («Иванмашет»).

При обновлении исходников Element X: перенести коммиты по порядку `b2d81c3c4` → `cdc7d0c8f` → `52e4cb1d8` → `fa5c94f4b` → `f85792225`. Мок `ClientProxyMock` дописан вручную — после регенерации Sourcery проверить блоки `addRoomsToAwait` / `roomMembership`.

---

### 111. Статус «был в сети» в деталях личного чата (STALK-999)

**Дата**: 2026-10-06
**Коммит**: [`b8fafb6a9`](https://github.com/ank1n/element-x-ios/commit/b8fafb6a9c79604710f7bdc07233200f84c1dcc0), включён в `stmob-ns-blur` поверх `11cc6bb26`.

Экран деталей личного чата уже умел показывать «В сети» и время последней активности, но модель не заполняла `dmPresence`. Теперь она получает сохранённое присутствие и обновления из общего `PresenceService`, регистрирует отдельный интерес к собеседнику и снимает только этот интерес при закрытии экрана. При отсутствии данных время активности не выдумывается. Используется существующий ограниченный опрос, отдельного сетевого цикла нет.

**Проверка**: 33 теста `RoomDetailsScreenViewModelTests` прошли из основной рабочей папки; полный UnitTests — **1085 тестов, 0 падений, 0 пропусков**. Полный результат: `ios/build-archive/stalk-999-full-signed-20261006.xcresult`, iPhone 17 Pro Max, iOS Simulator 26.3.1. Первоначальный полный прогон без подписи остановлен после ошибок Keychain `-34018`: для общего набора нужно сохранять штатную подпись и entitlements, не задавать `CODE_SIGNING_ALLOWED=NO`.

Обычная Debug-сборка схемы `ElementX` завершилась `BUILD SUCCEEDED`, установлена и запущена на том же симуляторе. Приложение показывает экран входа, процесс после запуска работает; снимок — `ios/build-archive/stalk-999-launch-20261006.png`. Коммит отправлен в `origin/stmob-ns-blur`.

Номер версии остаётся `26.20.09 (340)`; новый выпуск в TestFlight/App Store пока не подготовлен. Для проверки статуса в живом чате нужен вход в приложение; приёмка на физическом устройстве отдельно не подтверждена.

При обновлении исходников Element X переносить `b8fafb6a9` после пакета presence/UnitTests `52e4cb1d8 → fa5c94f4b → f85792225`. Изменены `RoomDetailsScreenViewModel.swift` и `RoomDetailsScreenViewModelTests.swift`.

---

### 112. Скрыта секция «Тема» в деталях личного чата

**Дата**: 2026-10-06
**Коммит**: [`e59b0676e`](https://github.com/ank1n/element-x-ios/commit/e59b0676e).

По решению пользователя секция «Тема», включая кнопку «Добавить тему» и существующий текст темы, не показывается в личных чатах. Условие `hasTopicSection` в `RoomDetailsScreenModels.swift` теперь учитывает `!isDirect`. Проверены SwiftFormat и Debug-сборка (`BUILD SUCCEEDED`); приложение обновлено и запущено на iPhone 17 Pro Max Simulator. Отдельный полный прогон тестов для этой правки отображения не выполнялся.

При обновлении Element X перенести `e59b0676e` после `b8fafb6a9`.

---

### 113. Ссылки на чаты и встречи: гостевой браузер, разовые встречи и проверка сервера (STALK-968)

**Дата**: 2026-10-06
**Коммит**: [`92caed936`](https://github.com/ank1n/element-x-ios/commit/92caed936).

Поддержаны `/meet/s/<код>` и разовые `/meet/<код>`, а также кнопки `ru.implica.stalk://<host>/...`. Файлы meet-app и некорректные коды не становятся маршрутами встречи. При отсутствии сессии встреча возвращается в браузер с `no_universal_links=true`; во время восстановления сессии маршрут ожидает его результата. Ссылка на чат сохраняет исходный URL до входа. При несовпадении сервера с активной сессией и для незнакомого хоста ссылка уходит в браузер, не разрешается токеном другого сервера. Автоматического переключения аккаунта нет.

Добавлены понятные ошибки отменённой встречи, истёкшей ссылки и отказа в доступе (ru/en/uz). `market.implica.ru` добавлен в допустимые хосты и YAML associated domains; XcodeGen обновил entitlements.

**Проверка**: целевой набор 36/36; полный UnitTests **1095/1095**, без падений. Debug-сборка прошла и установлена на iPhone 17 Pro Max Simulator. Присланная пользователем ссылка на чат открыла нужную комнату; присланная встреча открыла нативный звонок, в диагностике подтверждено LiveKit `.connecting → .connected` за 3,3 с. Скриншоты находятся в `ios/build-archive/stalk-968-chat-opened-20261006.png` и `stalk-968-meeting-20261006.png`; полная тестовая запись — `stalk-968-full-20261006.xcresult`. Качество медиа, гостевой браузерный звонок и физическое устройство отдельно не проверены.

Публичные AASA prod/dev на момент проверки содержат правильный `Z44H678J3R.ru.implica.stalk`, исключение `no_universal_links`, но не разрешающие компоненты чатов/встреч. Их включение после device-проверки остаётся серверной работой Molly. В живой ConfigMap Sygnal Team ID также `Z44H678J3R`; локальный манифест production-matrix сохраняет устаревшее `54NX5S5VS2`. Серверная конфигурация этим коммитом не менялась. Номер выпуска пока `26.20.09 (340)`, доставка новой версии в TestFlight/App Store не выполнялась.

При обновлении Element X переносить `92caed936` после `e59b0676e`; изменения associated domains брать из `ElementX/SupportingFiles/target.yml`, затем запускать XcodeGen.

---

### 114. Меню «Вид», локальные фильтры и меню участника звонка (STMOB-313)

**Дата**: 2026-10-06
**Коммит**: [`b1fe942ef`](https://github.com/ank1n/element-x-ios/commit/b1fe942ef).

В нативном звонке добавлено меню «Вид»: галерея, говорящий с миниатюрами, докладчик. Явный выбор сохраняется в рамках звонка, в том числе при демонстрации и возвращении к экрану звонка. Переключатели «Скрыть своё видео» и «Скрыть участников без видео» меняют только отображение: захват камеры, микрофон и участие не переключаются. Пустая галерея показывает объяснение. В landscape говорящий с миниатюрами использует боковую полосу; докладчик — основную область без галереи.

У плитки есть обычное меню и меню долгого нажатия: закрепить с миниатюрами, закрепить как докладчика, открепить, посмотреть доступный контакт. Закрепление отмечается в галерее и режиме говорящего. Для основной области приоритет: демонстрация → действующее закрепление → говорящий → первый участник. Уход закреплённого очищает pin. Карточка известного Matrix-участника использует существующий профиль и открывается поверх звонка; действия начала второго разговора в ней скрыты. Для гостя или неизвестной identity пункт контакта не предлагается.

**Проверки**: полный UnitTests — **1099/0**; после окончательной доводки раскладок и значка закрепления — **22/0** целевых тестов. Финальные пояснения меню прошли отдельную Debug-сборку (`BUILD SUCCEEDED`). Приложение установлено на iPhone 17 Pro Max Simulator. Точный состав результатов и границы: `ios/build-archive/stmob-313-evidence.json`, `.xcresult` и JSON-сводки рядом.

Maestro проверил пункты меню, выбор галереи/докладчика и скрытие своего видео. В реальном SFU-звонке **iOS Simulator + два временных Chrome-гостя** проверены pin с миниатюрами, pin докладчика, unpin, фильтр видео и отсутствие недоступного контакта гостя. Гости использовали синтетические камеры, их микрофоны выключены; качество звука этим не принималось. Счётчик кадров тестового видео продолжал расти; в журнале LiveKit нет переподключения между переключениями. Скриншоты: `stmob-313-view-menu.png`, `stmob-313-pinned-speaker.png`, `stmob-313-pinned-presenter.png`, `stmob-313-video-filter.png`. Гостевые браузерные сессии закрыты после проверки, звонок завершён.

Остаётся приёмка физического iPhone, карточки авторизованного участника с возвратом, демонстрации и ориентации, сочетаний выключения камеры/ухода участника. Поддержка iPad не расширялась. Это локальная Debug-поставка для симулятора `26.20.09 (340)`, не новый выпуск TestFlight/App Store.

При обновлении Element X переносить `b1fe942ef` после `92caed936`; вместе с изменениями CallScreen переносить параметр профиля `allowsConversationActions` и передачу `userSession` из координатора сессии.

---

### 115. Режимы звонка только с трёх участников; сохранение вида при 3 → 2 → 3

**Дата**: 2026-10-06
**Коммит**: [`6a3e95b1a`](https://github.com/ank1n/element-x-ios/commit/6a3e95b1a).

По замечаниям пользователя основная камера исключается из миниатюр в режиме говорящего, включая landscape и список переполнения. При показе демонстрации камера докладчика может оставаться в миниатюрах: это другой видеопоток. Активный говорящий не возвращает исключённую или скрытую плитку в полосу.

Меню «Вид» и закрепление доступны только при наличии как минимум двух реальных remote-участников плюс местного участника. Для двух включается обычная раскладка: собеседник крупно, местное видео — PiP при включённой камере. Пользовательский `layoutOverride` и локальные настройки не очищаются при уменьшении количества участников. При переходе 3 → 2 → 3 восстанавливается прежний вид; закрепление сохраняется, если сам участник не покинул звонок. Карточка доступного контакта не зависит от доступности режимов.

**Проверки**: `build-for-testing` и финальная Debug-сборка успешны; 24 целевых теста — 0 падений. Добавлены проверки точного перехода 3 → 2 → 3 с сохранением режима, pin и локальной настройки, а также исключения основной камеры из миниатюр с отдельным случаем демонстрации. Обновление установлено на прежний iPhone 17 Pro Max Simulator после завершения пользовательского звонка.

Живые проверки подтвердили доступность меню при трёх и его отсутствие после уменьшения до двух; снимки `layout-followup-three-speaker.png` и `layout-followup-two.png` в `ios/build-archive/`. Полный живой обратный переход не объявляется пройденным: первая гостевая фикстура закрылась по своему таймеру до заключительной проверки, а повторный браузерный гость не подключился. Причина второй не установлена. Сохранение выбора при обратном переходе подтверждено целевым тестом. Все временные браузерные сессии закрыты.

При обновлении Element X переносить `6a3e95b1a` после `b1fe942ef`. Номер публичного выпуска не менялся.

---

### 116. TestFlight: 26.20.09 (341) отправлена через Transporter

**Дата**: 2026-10-06
**Коммит выпуска**: [`b26db13bd`](https://github.com/ank1n/element-x-ios/commit/b26db13bd).

Подписанный Release-архив и экспорт App Store Connect завершились успешно. Основное приложение, NSE и ShareExtension имеют единые `26.20.09 (341)`; подпись Apple Distribution команды `Z44H678J3R` проверена через системное хранилище доверия. IPA — 127,3 МБ, ZIP целый, тестовых бандлов нет. Состав — изменения STALK-999, STALK-968, STMOB-313 и правка дубля/перехода 3 → 2 → 3 до `6a3e95b1a`.

По прямому поручению пользователя загрузка выполнена через GUI Transporter под уже авторизованной командой Sergey Tymbay. Transporter показал **«Отправлено 6 окт. 2026 г. в 18:38»**, затем **«Приложение обрабатывается»**. Это подтверждение доставки в App Store Connect; завершение обработки и доступность тестерам отдельно проверяются. В историю App Store и на публичный выпуск эта отправка автоматически не засчитывается.

Артефакты в `ios/build-archive/`: `sTalk-341.xcarchive`, `export-341/sTalk.ipa`, `archive-341.log`, `export-341.log`, `release-341.json`, `transporter-341-status.png`. SHA256 IPA: `3d300bda3aa40115ca6167893fc39e8c6a400f204a2b3925d168cf7a8d6db768`. В манифесте сохранены SHA исходников, номер, команда и статус доставки.

При переносе на обновлённый Element X функциональные коммиты переносить до коммита номера выпуска; номер новой сборки выбирать по фактической истории доставки, не копировать 341 автоматически.

---

### 117. История звонков: немедленное отображение кеша и независимое обновление

**Дата**: 2026-10-07
**Коммит**: [`5344f56f0`](https://github.com/ank1n/element-x-ios/commit/5344f56f0).

По сообщению пользователя разобран `nse-events 224.log` и путь загрузки вкладки «Звонки». В исходном журнале нет замеров загрузки истории. Код сначала ожидал записи сервера (до трёх попыток по 30 секунд), затем последовательно обходил комнаты; только после этого отображал локальную историю. Старый кеш записей использовался при ошибке, события комнат не сохранялись между запусками. Вкладка запускала загрузку даже без открытия пользователем.

Теперь локальные звонки видны сразу; сохранённый на диске снимок записей, событий комнат, встреч и данных контактов восстанавливается до сетевого обновления. Ключ кеша разделён по аккаунту и серверу. Свежесть — пять минут; запросы выполняются при открытой вкладке и активном приложении, устаревшие источники обновляются независимо. События комнат загружаются с ограничением в четыре параллельных запроса, свежесть хранится отдельно для каждой комнаты. Ошибка сохраняет прежний список. Повторные жесты обновления объединяются; изменение локального звонка учитывается даже во время загрузки. Убраны повторные попытки для произвольных ошибок записей; 401 допускает одно обновление токена. Идентификаторы событий стабильны между запусками; обогащение аватаров объединяется с текущим списком без возврата устаревшего снимка.

**Проверки**: 27 целевых тестов и полный UnitTests **1111/1111**, без падений; Debug-сборка успешна и установлена на прежний iPhone 17 Pro Max Simulator. Тестами проверены локальное отображение до сети, сохранение кеша при ошибке, восстановление с диска, изоляция аккаунтов, отсутствие запросов на скрытой вкладке/в фоне, независимость источников и обновление длительности существующего звонка. На живой сессии записи появились за 344 мс; обновление 43 комнат заняло около 1,6 с, итоговый список — 69 строк. Повторное открытие подтвердило `fresh cache: no history requests`. Артефакты: `ios/build-archive/call-history-cache-full-20261007.xcresult`, `call-history-cache-targeted-v4-20261007.xcresult`, `call-history-cache-app-20261007.log`, `call-history-fresh-cache-reopened.png`.

Исправление отправлено в `stmob-ns-blur`. Номер выпуска не менялся; отправленная ранее TestFlight 341 этого исправления не содержит. При переносе на обновлённый Element X переносить все семь файлов коммита, включая управление активностью вкладки из координатора сессии.

---

### 118. TestFlight: исправление истории звонков отправлено в сборке 342

**Дата**: 2026-10-07
**Коммит выпуска**: [`46ad3dcd2`](https://github.com/ank1n/element-x-ios/commit/46ad3dcd2).

Подписанный Release-архив и экспорт `26.20.09 (342)` успешно завершены. Сборка включает исправление истории звонков `5344f56f0` поверх ранее отправленной 341. Номера основного приложения, NSE и ShareExtension совпадают; целостность ZIP и подпись архива проверены. До упаковки прошли 1111 тестов без падений.

IPA отправлен через GUI Transporter под существующей командой Sergey Tymbay. Подтверждение: **«Отправлено 7 окт. 2026 г. в 11:51»**, текущий статус — **«Приложение обрабатывается»**. Готовность 342 тестерам пока не подтверждена. Заодно Transporter подтвердил готовность предыдущей 341 к внутреннему тестированию.

Артефакты в `ios/build-archive/`: `sTalk-342.xcarchive`, `export-342/sTalk.ipa`, `archive-342.log`, `export-342.log`, `release-342.json`, `transporter-342-status.png`. IPA — 133,5 МБ; SHA256: `c962b7c9a76f297f7b9304e7404b987c386f649643b853e01b6a698092d848d5`. При переносе функциональности сначала применять `5344f56f0`, затем выбирать новый свободный номер выпуска.

---

### 119. App Store: версия 26.20.09 (342) отправлена на проверку Apple

**Дата**: 2026-10-08
**Исходники выпуска**: [`46ad3dcd2`](https://github.com/ank1n/element-x-ios/commit/46ad3dcd2).

По прямому поручению пользователя «давай опубликуем» в существующей сессии App Store Connect создана версия 26.20.09 и выбрана обработанная сборка 342 (ID `654d61d3-2748-44ac-910d-05c71ca674d3`). В русской и английской локализациях сохранены новые заметки о выпуске: восстановление участия в звонке при нестабильной связи, кеш истории, виды группового звонка, ссылки на чаты/встречи, присутствие и уведомления. Настройка выпуска — автоматически после одобрения Apple, всем пользователям сразу. Существующие описание, контакты и данные входа для ревью унаследованы от предыдущего выпуска.

После окончательного Submit for Review подтверждены **Waiting for Review** и **1 Item Submitted**. Это отправка на проверку, не завершённая публикация: до одобрения публичной остаётся 26.20.08 (324). Исправление STMOB-284 (`3b9b1cbdc`) входит в выбранную сборку; отсутствие подтверждённой проверки плохой связи на физическом iPhone этим действием не меняется. Статус задачи в TrackIT не изменён.

Доказательство и манифест: `ios/build-archive/stalk-342-app-review-submitted.png`, `ios/build-archive/release-342.json`. Повторная загрузка IPA не потребовалась. При обновлении исходников переносить функциональные коммиты из предыдущих пунктов; действия App Store Connect относятся к поставке и не требуют нового коммита приложения.

По дополнительному запросу о данных непосредственной публикации актуальная карточка выпуска и оба текста сохранены в `app-store-screenshots/RELEASE-TEXTS.md`; прежняя инструкция 207 оставлена ниже как архив. Локальные `fastlane/metadata/ru/release_notes.txt` и `en-US/release_notes.txt` синхронизированы с App Store Connect в [`a0f2f2c22`](https://github.com/ank1n/element-x-ios/commit/a0f2f2c22). Это документация, новый бинарник не собирался.

---

### 120. iOS: совместимость с обновлёнными стикерами, поиском и Диском

**Дата**: 2026-10-16
**Коммит**: [`6f23a53a0`](https://github.com/ank1n/element-x-ios/commit/6f23a53a0).

По поручению пользователя сверены новые исходники веб-клиента и RoboDOC Disk. У веба проверены общий каталог стикеров, Matrix account data `im.stalk.sticker_preferences`, ограничение недавних десятью отправками, открытие пикера на недавних и компактные анимации (`d9ed707d67`, `13bfc04fa6`, `40b89c46bd`, `9f9db91156`). Для поиска использован контракт `SearchApi.ts` из `12dae1138d`, для Диска — `internal/httpapi/handlers_list.go`: поле ответа `nextBeforeId` передаётся обратно параметром **before_id**, а не beforeId.

В iOS добавлен выбор общих наборов из «+ → Стикеры»: недавние, поиск по названию, избранные наборы через долгое нажатие. Избранное и десять последних успешно отправленных стикеров синхронизируются тем же account data, что и веб; локальный кеш разделён по аккаунту и серверу, неотправленные изменения повторяются при открытии. Ошибка отправки не добавляет стикер в недавние. Отправка использует SDK `m.sticker`, сохраняет метаданные анимации и отношение ветки обсуждения. HTTP 401 допускает одно обновление токена; токен передаётся заголовком.

В ленте WebP-анимация декодируется покадрово без массива всех полноразмерных кадров; учитываются Reduce Motion, фон и энергосбережение. Поддержано `im.stalk.animated_preview_url` для открытых событий; зашифрованный источник не подменяется. Размер стикера в ленте ограничен 136 pt с сохранением пропорций, открытие оригинала сохранено. Локализации добавлены на русском, английском и узбекском.

Нативный **поиск сообщений** использует `/api/search` с `mode=basic`, `type=message`, фильтром комнаты и пагинацией. Используются типизированные цели перехода; маркеры подсветки удаляются из текста без вставки HTML. Отказ доступа/5xx не маскируется пустой выдачей; возврат к Matrix `/search` предусмотрен только при отсутствии нового маршрута. Диск сохраняет и передаёт обе части курсора; одинаковое время соседних файлов больше не считается повтором курсора.

**Проверки**: полный UnitTests **1120/1120**, затем после финальной обработки компактных превью — **51/51** целевых тестов (10 контрактных и 41 композера). Debug-сборка успешна и установлена на прежний iPhone 17 Pro Max Simulator. Maestro подтвердил переход из тестовой комнаты в «+ → Стикеры», вкладку недавних и поле поиска; отправка сообщений в рабочие комнаты не выполнялась. Живая загрузка каталога/синхронизация с вебом не принята: приложение показывало «Сервер недоступен», HTTPS-проба с Mac завершалась SSL_ERROR_SYSCALL даже с прямым resolve на IP Misty. Системные настройки сети не менялись. Тестами с HTTP-фикстурами подтверждён account-data контракт и добавление в недавние после успешной отправки.

Артефакты: `ios/build-archive/compatibility-20261016.json`, `compat-full-20261016.xcresult`, `compat-final-targeted-20261016.xcresult`, `compat-app-final-20261016.log`, `compat-sticker-picker-20261016.png`. Объём этой поставки — совместимость и перечисленные нативные функции; полный перенос веб-поиска по всем типам/закреплённых запросов и новых фото-коллекций/редакторов Диска не выполнялся. Физический iPhone и живой обмен стикерами между клиентами ещё требуют приёмки. Новая сборка в TestFlight/App Store не отправлялась; номер выпуска не менялся.

При обновлении Element X переносить весь коммит, включая новый сервис, RoomProxy/координатор композера, изменения LoadableImage/фабрики стикеров, локализации и XcodeGen-проект. Для повторной генерации проекта использовать `project.yml`.


### 121. Капибары, пользовательские эмодзи и графические реакции

**Дата**: 2026-10-16. **Код**: [846cc0429](https://github.com/ank1n/element-x-ios/commit/846cc0429).

Добавлены тот же встроенный набор капибар и восемь пользовательских эмодзи, что на вебе: исходные PNG/MXC, русские shortcode-алиасы, пикер композера, графические реакции. Код, ссылки и атрибуты HTML не переписываются; удаление shortcode не оставляет половину токена. Общие наборы, недавние и избранное предыдущей поставки сохранены. Для переноса применить коммит вместе с интеграцией 1887f4aa7 и выполнить XcodeGen; ассеты обязательны.

### 122. Звонки: фактические участники, приглашения, руки и локальный звук

**Дата**: 2026-10-16. **Код**: [d25232814](https://github.com/ank1n/element-x-ios/commit/d25232814).

Панель использует фактическое присутствие LiveKit и сохраняет профили участников Matrix. «В звонке», «Не в звонке» и успешное приглашение различаются; устаревшее членство Matrix не блокирует кнопку повторного приглашения. Параллельные приглашения одному человеку объединяются, 401 повторяется со свежим токеном и тем же txn ID. Добавлены очередь поднятых рук, локальное отключение звука конкретного участника и монотонные таймеры звонка/записи. Код встречи теперь выдаёт только сервер после сохранения. Ранее исправленные 3→2→3, отсутствие двойной плитки и обновление RTC-членства сохранены. Реальная смешанная связь >15 минут проверяется владельцем на новой версии. При переносе применить и 1887f4aa7 (маршруты и локализации).

### 123. Нативный поиск, Диск/фото, файлы Айлока и единая доступность приложений

**Дата**: 2026-10-16. **Код**: [1887f4aa7](https://github.com/ank1n/element-x-ios/commit/1887f4aa7).

Полный поиск открывается из Чатов отдельной кнопкой документа с лупой. Поддержаны серверные типы/фасеты/условия, все цели перехода, история и закреплённые условия по аккаунту, явный smart-запрос через штатную сессию Айлока. BIGSERIAL ID принимается строкой без потери точности; метаданные semantic.tail/facet_type/truncated не теряются. Старый smart-topic сбрасывается при изменении текста. Даты, отправитель и другие ручные условия не подменяются планировщиком. Серверного planner-only/tool-disable флага исследованный контракт не предоставляет; инструкции агенту не объявлены capability.

Канонические ссылки /#/files/open и io.stalk.file_share открывают конкретный ACL-защищённый документ. Для старого сообщения с явной подписью «ID документа» показана кнопка; произвольные UUID не распознаются. Текстовый отчёт без расширения читается нативно, бинарные документы — через Quick Look без редактирования. Исходный отправитель Rusty по-прежнему обязан формировать настоящую ссылку/карточку: iOS не меняет бота. Токен чужому домену не отправляется.

Добавлены /apps-api/availability, managed/revision/clients, разделение кеша и проверки списка/прямого открытия/deep link. Известное управляемое отключение не обходится fallback-каталогом. Старый 404 допускает legacy только для ранее неуправляемой установки.

Айлок восстанавливает tool attachments и live agent.file без дублей, проверяет owner-scoped путь и текущую беседу до получения токена, запрещает внешние адреса/redirect и повторяет 401 один раз. Inline images ограничены по размеру декодирования; временными файлами владеет показывающий экран/модель, лимиты upload проверяются до чтения всего файла.

Фото Диска: каталог/OCR/EXIF, дата съёмки без timezone сохраняет локальный день, added/modified разделены; saved filters используют namespace images/media/documents, а content categories errors/interfaces/reports остаются отдельными коллекциями. Есть системы, альбомы, роли read/add/manage, обложка и порядок, избранное по всем владельцам, ограниченные миниатюры и явное открытие оригинала. Редактор сохраняет отдельную JPEG-копию; canDownload/read-only соблюдаются, медиа учитывают активный звонок. RU/EN/UZ локализации включены.

Проверки и границы: журнал `docs/project-status/2026-10-16-ios-update-execution.txt`, матрица `2026-10-16-ios-update-acceptance.txt`. 1138/0 — промежуточный общий набор; финальные результаты и артефакт выпуска фиксируются отдельной записью после проверки. Живая проверка apps/Disk/102 фото выполнена на iPhone 17 Pro Max Simulator; физический iPhone, отзыв доступа и смешанный длинный звонок не объявляются принятыми. Инвентаризация 330 refs не является манифестом production или доказательством просмотра каждого diff. Для переноса нужны все три коммита 846cc0429 → d25232814 → 1887f4aa7, затем `xcodegen generate --spec project.yml`.


### 124. Карточки shared-файлов Диска и внутренних/внешних ссылок

**Дата**: 2026-10-16. **Код**: [54945227b](https://github.com/ank1n/element-x-ios/commit/54945227b).

По дополнительному поручению владельца перед сборкой проверены и добавлены карточки для `io.stalk.file_share` в `m.notice`/`m.text`, канонического `#/files/open?blob=...`, относительного HTML href, standalone `#doc/<UUID>` и публичной ссылки `/s/<token>` на известном Диске/текущем origin. Карточка сохраняет точный адрес и host, дубли приватного документа по blobID объединяются. Ссылки встреч и папок не становятся карточками файлов. У одиночного URL показана карточка; подпись смешанного сообщения остаётся. Размер и право shared-файла сохранены, длинное имя занимает две строки.

Публичная ссылка открывается в браузере с исходными проверками пароля/истечения/скачивания. При включённых link previews её имя и размер читаются только public API через ephemeral transport без Matrix токена, browser cookies и redirect; защищённая/удалённая ссылка остаётся карточкой без скрытых метаданных. Рендер карточки не меняет ACL и не скачивает содержимое. Добавлен default English fallback к RU/en-US/UZ локализациям; вход в поиск/просмотр документа убирает клавиатуру.

Целевые проверки карточек и Timeline — 33/33 до финального дополнения public metadata; снимки ImageRenderer при ширине 390 pt, обычном и крупном тексте приложены к xcresult. Окончательные результаты полного набора и поставка — в журнале исполнения и следующем пункте. При переносе применить после 846cc0429 → d25232814 → 1887f4aa7 и выполнить XcodeGen.


### 125. Локальная подписанная версия для приёмки: 26.20.10 (343)

**Дата**: 2026-10-16. **Версия**: [f1b428c58](https://github.com/ank1n/element-x-ios/commit/f1b428c58). Функции: пункты 121–124, коммиты 846cc0429 → d25232814 → 1887f4aa7 → 54945227b.

После завершения реализации и дополнения карточек Диска полный UnitTests прошёл **1156/1156**; финальная проверка карточек/локализации — **9/9**. На симуляторе открыты apps/Disk/102 фото, basic-поиск report с 394 результатами и исходный текстовый TrackIT-отчёт. Реальные SwiftUI-карточки проверены на ширине iPhone при обычном и крупном шрифте. Физический телефон, публичная ссылка с password/expiry, отзыв доступа и смешанный звонок >15 минут остаются для приёмки владельцем.

Release-архив и экспорт IPA успешны: `ios/build-archive/sTalk-343.xcarchive`, `ios/build-archive/export-343/sTalk.ipa` (128.7 MiB). Подпись `codesign --verify --deep --strict` и Team Z44H678J3R проверены. Приложение, NSE и ShareExtension — 26.20.10/343. SHA-256 IPA: `1e98861ab177041f1aa5439cc65e3e9c016a9214593c52b62fe5d2bbc6de4d88`. RU/EN «Что нового» подготовлено локально; source push в stmob-ns-blur выполнен.

Это **локальная сборка для проверки**, не доставка TestFlight и не публикация App Store. Браузерная ASC-сессия истекла, доступность upload number в ASC не подтверждена; проверить при последующей доставке через Transporter. Манифест и границы приёмки: `ios/build-archive/release-343.json`, `docs/project-status/2026-10-16-ios-update-acceptance.txt`. Для переноса на новый Element X применять функциональные коммиты всей цепочкой и затем генерировать проект из `project.yml`; выпускной коммит отдельно обновляет номер/метаданные.


### 126. Ссылки Диска используют прежнюю карточку файла

**Дата**: 2026-10-16. **Код**: [1425bb9b6](https://github.com/ank1n/element-x-ios/commit/1425bb9b6).

По замечанию владельца убрана отдельная вёрстка ссылок Диска. `StalkDiskLinkCardView` теперь только передаёт данные и исходное действие в существующий `StalkFileShareView`: прежние цветной значок типа файла, белая карточка, цвета и градиентная кнопка сохранены для всех видов ссылок. У публичной ссылки добавлена пометка «Внешняя ссылка». Если URL не сообщает фактические права, поле права скрывается; shared-событие по-прежнему показывает настоящие permission/size/recipients. Public metadata и исходный адрес открытия сохранены.

Проверки: **30/30** целевых тестов (карточки, Timeline Factory и Timeline VM). Снимки существующей/shared, внутренней и внешней карточек на 390 pt при large/xxxLarge просмотрены: `ios/build-archive/disk-cards-reuse-visuals/`. Код отправлен в origin/stmob-ns-blur.

Это исправление выполнено **после** передачи владельцем сборки 343. В уже отправленную IPA оно не входит. Новые архив/IPA не создавались, Transporter не запускался. При переносе на новый Element X применить после 54945227b.


### 127. Подписанная 344 с прежним видом карточек Диска

**Дата**: 2026-10-16. **Выпускной коммит**: [09d069901](https://github.com/ank1n/element-x-ios/commit/09d069901). **UI-правка**: [1425bb9b6](https://github.com/ank1n/element-x-ios/commit/1425bb9b6).

Собрана 26.20.10 (344), содержащая переиспользование существующего StalkFileShareView с пометкой внешней ссылки. Последняя UI-правка прошла 30 целевых тестов и проверку снимков; полный 1156/0 — функциональная база до двухфайлового изменения вида. Signed archive/export и Debug build успешны. Подпись и версии app/NSE/ShareExtension — 26.20.10/344 — проверены; Debug установлен и запущен на прежнем симуляторе.

IPA: `ios/build-archive/export-344/sTalk.ipa` (128.7 MiB). SHA-256: `56bcbf64f6c07fac9e63a41dea2cd4c46141dd85fa8756c5c6649fa607cbbaff`. Манифест: `ios/build-archive/release-344.json`. Коммиты отправлены в origin/stmob-ns-blur. Это локальная IPA для проверки/Transporter, новой доставки 344 в ASC не выполнялось. Сборку 343 ранее отправил сам владелец.


### 128. Оставшийся перенос поиска, фото и карточек встреч с веба

**Дата**: 2026-10-16. **Код**: [129e5b79b](https://github.com/ank1n/element-x-ios/commit/129e5b79b).

Выполнены пункты 1–18 из `docs/project-status/2026-10-16-ios-web-parity-remaining.txt`. Поиск Диска использует серверный индекс вложений вместе с авторитетным каталогом, находит содержимое и старые имена, учитывает contentHit расшаренных файлов, shelf-документы и настоящие права. Первые совпадения имени не ждут всех страниц индекса, скрытые строки не обрывают пагинацию, частичные отказы сохраняют успешную выдачу. Ограниченность сырого серверного окна обозначается предупреждением; backend не развёртывался.

Системный поиск поддерживает умные условия без темы, обычную предварительную выдачу и fallback при отказе планировщика, объединённый справочник с признаком полноты, людей/личные чаты, метки задач и серий встреч, голосовой запрос. Диктовка не отбирает и не восстанавливает поверх звонка общую аудиосессию; панель действий адаптируется к доступной ширине.

Фото: вложенные папки и исключения, OCR-предложения систем с подтверждением, алиасы и исправление назначений, изменение существующих пресетов/автоальбомов, обзор альбомов, месяцы и OCR-фрагменты, последовательный просмотр и слайд-шоу после успешной загрузки. Matrix-источники проходят SDK; при ошибке разбора обычного сообщения повторно проверяется конкретное событие текущей Matrix-сессией, без преобразования необязательных размеров и миниатюр, а исходник загружает SDK. Удалённые сообщения и недоступные источники не обходятся ссылкой MXC из старого файлового индекса; без ключей зашифрованный источник не загружается.

Редактор работает с оригиналом, поддерживает стрелки/рамки/непрозрачную закраску, отражение/произвольную обрезку, перемещение надписей, цвет/размер текста и undo/redo. Имя, PNG/JPEG и папка назначения выбираются явно. RAM-бюджет проверяется до выделения больших растров, уменьшение качества требует явного выбора; PNG-прозрачность и непрозрачность закраски после преобразований покрыты пиксельными проверками. Карточки встреч сохраняют окружение форматированного текста, загружают public-info, показывают отсутствие/истечение/отказ/ошибку с повтором. Переводы и доступные подписи добавлены для en/en-US/ru/uz.

Для переноса на следующий Element X применять функциональные коммиты 129e5b79b → 7b068606d → 893feb47c поверх базы 09d069901; выпускной 804aa63e3 отдельно меняет номер.

Айлок во встрече/звонке (19/20) отложен по указанию владельца. Проверки и границы приёмки: `docs/project-status/2026-10-16-ios-parity-acceptance.txt`.

Выявленные общим прогоном прежние сбои устранены отдельно: защита голосового кэша через FileManager и ожидание инициализации настроек в тесте — [7b068606d](https://github.com/ank1n/element-x-ios/commit/7b068606d). Оценка RAM симулятора, где iOS API возвращает ноль, использует ограниченную статистику хоста; проверка на физическом устройстве сохранена — [893feb47c](https://github.com/ank1n/element-x-ios/commit/893feb47c).

Полный прогон основной интеграции: **1290 тестов, 0 падений/пропусков**. После завершающей оценки памяти Simulator и переименования конфликтующего ключа без смены перевода: **61/61** редактора/поиска. 17 прежних тестов кэша/настроек также пройдены трижды. Снимки реального PNG-рендера и живой UI просмотрены; физический iPhone и фактическая доставка учитываются отдельно.


### 129. Подписанная 345 для приёмки переноса

**Дата**: 2026-10-16. **Выпускной коммит**: [804aa63e3](https://github.com/ank1n/element-x-ios/commit/804aa63e3). Функциональная цепочка описана в пункте 128.

Собрана 26.20.10 (345): signed archive/export и Debug успешны. Подпись проверена для архива и распакованной IPA (`codesign --verify --deep --strict`); app/NSE/ShareExtension — 26.20.10/345, Team Z44H678J3R. Debug установлен и запущен на прежнем iPhone 17 Pro Max Simulator, версия проверена по установленному Info.plist. Исходники отправлены в origin/stmob-ns-blur.

IPA: `ios/build-archive/export-345/sTalk.ipa` (129.4 MiB). SHA-256: `a8e282e131ff8ea095174ebb3146cbe00e1e9a87de90995ead1ae466708997f0`. Манифест: `ios/build-archive/release-345.json`. Это локальный выпуск для пользовательской приёмки; физический iPhone, фактический микрофон/VoiceOver и длинный смешанный звонок ещё требуют проверки. Айлок во встрече/звонке (19/20) отложен; реализованы 1–18. Автоматической доставки этой IPA не выполнялось.


### 130. История звонков: связанные задачи и итоги статусов

**Дата**: 2026-10-18. **Код**: [1f4b42cb5](https://github.com/ank1n/element-x-ios/commit/1f4b42cb5). Web-основание: STALK-1133 (47920ab926 / 592c7ed281 / 1eed7abace), STALK-1134 (d84205c35c).

Счётчик реальных связанных TrackIT issues приходит с существующим `/api/recording/list`: отдельные запросы задач для строк истории не добавлены. Новые `createdTaskCount`, `callId`, `sessionIds` сохраняются в кэше и локально объединённых строках. Неизвестный/ошибочный новый счётчик не ломает историю; старый API/кэш поддержаны. У фрагментов одной комнаты/звонка используется максимум call-wide count, а не сумма. Кнопка отдельно от записи, визуальный предел 99+, VoiceOver читает полное число; нажатие открывает сразу вкладку задач.

Карточка независимо от аудио/готовности транскрипции загружает задачи всех recording-сессий. Сводка считает уникальные (project, issue), выбирает более свежий status_synced_at и показывает «Всего», «Бэклог» (включая unstarted), «В работе», «Готово», а при наличии — «Отменено» и неизвестный статус. Названия статусов не используются для определения группы. Сводка и список карточек используют одну загрузку; ошибка не превращается в ноль, есть повтор, поздние ответы закрытого экрана отбрасываются. После возвращения и создания задачи данные обновляются, а история перечитывает только recordings. Оптимистический +1 не используется при idempotent ответах. Скрытие созданных предложений использует исходные session-связи, поэтому дедупликация статистики не возвращает предложение в список создания.

Проверки: **54/54** первого целевого прогона; после дополнительного исправления — **1333 теста, 0 падений** полного набора. Живая история/карточка проверены на существующем звонке: 7 задач, 6 бэклог, 1 в работе, 0 готовых; кнопка открыла Tasks. Рендер при обычном/xxxLarge просмотрен. Для QA задачи и звонки не создавались. Переводы добавлены для en/en-US/ru/uz. План/приёмка: `docs/project-status/2026-10-18-call-linked-task-statistics.txt`.

Для переноса на следующий Element X применить 1f4b42cb5 после базы 804aa63e3; выпускной номер 346 меняет отдельный 13370599c. Календарь STALK-1135 и Айлок в звонке в этот перенос не входят.


### 131. Локальная подписанная 346 со статистикой задач звонка

**Дата**: 2026-10-18. **Выпускной коммит**: [13370599c](https://github.com/ank1n/element-x-ios/commit/13370599c), функциональный [1f4b42cb5](https://github.com/ank1n/element-x-ios/commit/1f4b42cb5).

26.20.10 (346): Release archive/export и Debug успешны. Проверены подписи архива и распакованной IPA (`codesign --verify --deep --strict`), Team Z44H678J3R и версии app/NSE/shareextension 346. Debug установлен и запущен на прежнем iPhone 17 Pro Max Simulator; installed Info.plist подтверждает 346. Полный прогон функционального кода: **1333/1333**, пропусков 0. Исходники отправлены в origin/stmob-ns-blur.

IPA: `ios/build-archive/export-346/sTalk.ipa` (129.6 MiB), SHA-256 `18a46654d988cb8710d86012c76c682b2642c459356ae56f97419977b6ba0f2b`. Манифест: `ios/build-archive/release-346.json`. Выпуск локальный для приёмки, Transporter агентом не открывался; фактическая доставка пользователем не проверялась. Уже доставленная 345 не заменяется этим файлом. Физический iPhone и изменение живых задач требуют пользовательской приёмки; QA читал существующие данные без создания задач/звонков.


### 132. Треды, звонки в календаре и участники итогов

**Дата**: 2026-10-18. **Код**: [b09bfc775](https://github.com/ank1n/element-x-ios/commit/b09bfc775), [122c7d684](https://github.com/ank1n/element-x-ios/commit/122c7d684), [b444a3362](https://github.com/ank1n/element-x-ios/commit/b444a3362). Номер 347 отдельно: [78b51aad1](https://github.com/ank1n/element-x-ios/commit/78b51aad1). Web-основание: STALK-1128 / STMOB-316, STALK-1135/1136/1137, STALK-1126. SDK остаётся 26.06.03.

Включены штатные Matrix threads с однократной миграцией прежнего эксперимента. Готовые SDK/UI отвечают за экран ветки, отправку, черновики, media, сводку ответов, E2EE и receipts. Новый список обсуждений использует `ThreadListService`, обновления, пагинацию и явный retry. Входы из шапки/сведений комнаты. Вложенные треды у ответов/стикеров и треды у неподдерживаемых событий исключены. Ошибка/поздняя загрузка ветки не оставляет сломанную навигацию. Push/NSE используют штатный thread route; быстрый ответ сохраняет root при холодном старте и отправляется в ветку без fallback в общую ленту.

Календарь дополняется локальным слоем существующего account-bound кэша истории. Совпадение комнаты и пересечение времени привязывает звонок к встрече, иной день остаётся отдельным. Повторные фрагменты не умножают задачи. Есть красная отметка/фильтр отдельных звонков, переходы к сведениям и задачам, читаемые карточки и короткая длительность. Никаких искусственных встреч/приглашений/напоминаний. Обновления останавливаются при уходе со вкладки; ошибка сохраняет кэш и показана явно. Статусы задач получили цвет и мягкий фон.

Фактические участники определяются по RTC attendance и tracks, а не по составу комнаты; метаданные не теряются при объединении локальной/серверной истории. Device suffix убирается с сохранением порта, технический EG_ исключается, гости не получают ложных профилей. В новых итогах разбираются `speaker_id`, `assignee`, `mentions`; профили открываются по точным Matrix ID, одноимённые люди не смешиваются. Старые записи поддержаны. en/en-US/ru/uz.

Проверки: полный набор **1349/0**, после последних граничных случаев/форматирования и назначения 347 — **43/0**, пропусков нет. Просмотрены UIKit-hosted fixtures normal/xxxLarge. Первые ImageRenderer-снимки календаря/сведений были неполными и как визуальная приёмка не засчитаны. Сценарии совместной проверки веб↔Android↔iPhone, реальные unread/E2EE/push и v3 pipeline остаются открыты; отдельных unread-счётчиков каждой строки SDK ThreadListItem не выдаёт. STMOB-316 не объявлена принятой. Рабочие сообщения/звонки/задачи для QA не создавались, backend не менялся, Айлок в звонке и каналы исключены.

Для переноса на новый Element X: функциональный b09bfc775, затем 122c7d684 и b444a3362; выпускные метаданные 78b51aad1 учитывать отдельно. План/доказательства: `docs/project-status/2026-10-18-threads-calendar-implementation.txt`. Это изменения после старого IPA 346.


### 133. Локальная подписанная347 с тредами и календарём звонков

**Дата**: 2026-10-18. **Итоговый коммит**: [b444a3362](https://github.com/ank1n/element-x-ios/commit/b444a3362); функциональная цепочка описана в пункте132. Исходники отправлены в рабочую ветку.

Release archive/export успешны; подписи архива и распакованного IPA проверены `codesign --verify --deep --strict`, Team Z44H678J3R. Приложение/NSE/ShareExtension — 26.20.10 (347). Debug347 установлен и запущен на прежнем iPhone17ProMax Simulator без активации окна Mac; просмотрен снимок списка чатов. Полный набор1349/0, финальные целевые43/0, пропусков нет.

IPA: `ios/build-archive/export-347/sTalk.ipa` (129.8 MiB), SHA-256 `c419454d39ac071a85bbd75c51c46435f080ea56a83f3cd4924dd18544fd49e4`. Манифест `ios/build-archive/release-347.json`. Это локальный кандидат для приёмки: новый импорт в Transporter/загрузка/публикация не выполнялись, старая346 сохранена. Совместная физическая QA остаётся; пользовательское описание — `docs/project-status/2026-10-18-threads-calendar-release-notes.txt`.


### 134. Поиск перенесён в Приложения, исправлена мобильная вёрстка

**Дата**: 2026-10-20. **Коммит**: [3c7d60f75](https://github.com/ank1n/element-x-ios/commit/3c7d60f757ae45742567b2aad742600e01323394).

Общий поиск открывается отдельной нативной плиткой «Поиск» на вкладке Приложения; кнопка из шапки Чатов удалена. Локальный поиск списка чатов/внутри комнаты сохранён. Переходы результатов проходят через общую маршрутизацию к нужному чату/профилю/записи/приложению. Плитка не дублируется при старом кэше, показывается без ожидания проб Диска/Айлока. Search остаётся доступной локальной функцией при отсутствии записи реестра; явное отключение или запрет платформы имеет приоритет. Остальные ограничения managed-реестра сохранены.

Действия поиска разделены на два ряда, фильтры прокручиваются, результаты показываются карточками с отдельными метаданными. Новые строки en/en-US/ru/uz. **42 связанных теста, 0 падений/пропусков**, просмотрены UIKit-снимки 320/390pt normal/xxxLarge. Прогон выполнен под общей OS-блокировкой с -jobs2 / Swift-j2 / одним test worker, ресурсным контролем каждые20с; swap снижался, pressure normal. Полный локальный набор не запускался. План и артефакты: `docs/project-status/План работ — 2026-10-20.txt`. Новый Release/IPA не создавался.


### 135. Подписанная348 для проверки поиска

**Дата**: 2026-10-20. **Выпускной коммит**: [3a69737c5](https://github.com/ank1n/element-x-ios/commit/3a69737c5); функциональный — пункт134. 26.20.10(348): archive/export и подписи архива/распакованной IPA проверены, TeamZ44H678J3R, app/NSE/ShareExtension348. Исходники отправлены в рабочую ветку. Сборка под общей OS-блокировкой, -jobs2/Swift-j2/nice10, мониторинг20с: давление normal, swap снижался, оставшихся worker-процессов нет. Связанные тесты42/0 пройдены до назначения нового номера.

IPA:`ios/build-archive/export-348/sTalk.ipa` (129.8MiB), SHA-256`471850c9809f4631d044f315e49b54ab18e4f7eb565821299161f3a699801cb3`. Манифест:`ios/build-archive/release-348.json`. Добавлена в Transporter один раз;348 проверена в активных с кнопкой Отправить, агент её не нажимал. Это готовность к отправке, не подтверждённая доставка/TestFlight/AppStore. Пользовательская приёмка остаётся.



### 136. Имена документов, итоги звонков и каналы

**Дата**: 2026-10-20. **Локальный коммит**: `2148ba4c4` ([адрес после разрешённой отправки](https://github.com/ank1n/element-x-ios/commit/2148ba4c423e6861db976b36c8391005136cb3dd)). Push отклонён автоматической проверкой, коммит пока только локальный.

STMOB-319: общий импорт документа сохраняет исходное имя вместо UUID; копирование file representation выполняется внутри callback, байтовый fallback сохраняет suggestedName. Одинаковые имена изолированы, UIImage остаётся PNG. STMOB-320: завершённые итоги под call.initiate — участники, длительность, запись/расшифровка, задачи по статусам; авторизованный ограниченный polling, дедуп и открытие сведений. STMOB-318: каталог/фильтр каналов, комментарии m.thread, раздельные серверные права, закрытие обсуждения/запрет комментатора, персональная подписка и архив read-only. Изменение комментариев требует capability backend и сохраняет остальные PL. Обычный тип комнаты кэшируется по аккаунту для offline; разрешения перед отправкой проверяются заново.

**137 связанных тестов, 0 падений/пропусков**, просмотрены UIKit-снимки large/xxxLarge. Память контролировалась под общей OS-блокировкой; два прогона остановлены на warning, итоговый после normal завершился exit0 без компиляции. Подробности и артефакты: `docs/project-status/2026-10-20-ios-319-320-318-implementation.txt`. Физические Mail/Files/Word, совместная native/web E2EE/push/роли и реальный звонок остаются для приёмки. Новый Release/IPA после348 не создавался, в Transporter ничего не добавлялось.


### 137. WIP: полный пакет каналов, карточка звонка и переговорные

**Дата**: 2026-10-21. **Локальные коммиты**: `7d08afa5d`, `da36a97aa`. Исходники не отправлены на remote; это рабочий срез до приёмки.

STMOB-318: публикации с Markdown и image+caption, серверные черновики/расписание, сохранение ввода при409, запрет plaintextdrafts для E2EE, admin appearance/history, archive/restore и management с CAS, metadata sync и немедленный отзыв native прав. Пересылка сохраняет канал-источник и карточку Диска без списка прежних получателей. STMOB-320: аватары фактических участников, VoiceOver/имя по нажатию, цвета групп/0задач, boundedbackoff/refreshafterreconnect/очистка при отзыве и скрытие бота из превью. STMOB-323: комнаты в списке/карточке/форме, офисы/последние/поиск/busy/can_book, ошибки, фото, checkin/release/неявки и nativeUNreminder; FreeNow15/30/60 с подтверждённой бронью до отметки прихода, без автоматического повторения POST.

Полная компиляция app+UnitTests крупного среза прошла (220с, pressure normal); **23 host-проверки моделей/JSON прошли**, с UIColor/локализацией-заглушками. Полный новый runtime-набор iOS не подтверждён: локальные прогоны останавливались монитором при warningпамяти; две HTTP-fixture исправлены на httpBodyStream, повторное исполнение ещё нужно. Физическая/dev web↔iOS/E2EE/push/scheduling/roles QA остаётся, включая pointer при E2EE-forward и фактическую доставку reminder. Новый IPA/Release не создавался. Точный статус, ограничения локального UNreminder и артефакты — `docs/project-status/План работ — 2026-10-21.txt`.

---

**Дата создания**: 2026-01-28
**Последнее обновление**: 2026-10-21

Проверка WIP STMOB-318/320/323, 21.10.2026: HEAD da36a97aa успешно собран;
212 связанных iOS-тестов прошли (0 failures, 0 skipped), включая 31 новых
StalkNativeUpdatesTests. Проверены 8 снимков интерфейса large/xxxLarge.
Отчёт: ios/build-archive/318-320-323-owner-final-summary.json.
Приёмка между web и iOS и на физическом устройстве остаётся; нового IPA нет.

Кандидат26.21.10(349),21.10.2026: дополнительно исправлены появление брони,
добавленной в web в открытой карточке iOS, гонка старого GET с check-in и
причина ручного освобождения. При отказе/удалении отменяется напоминание.
49 связанных тестов после исправлений PASS (0 failures/skipped).
Release archive/IPA подписаны и проверены, app+NSE+Share349. IPA импортирована
вTransporter один раз, кэш подтверждён SHA256; готовность UI/отправка не подтверждены.
Исходник f0717057a, манифест ios/build-archive/release-349.json.

После349, коммит4bbe5de18: дополнения переговорныхSTALK-1162/1179 —
message ошибкиroom_policy наPOST/PUT, объяснениеpending, отдельныйrejected,
checkin в«Свободно сейчас»только дляconfirmed.53связанныхтестаPASS;
4UIснимка просмотрены. Изменения пока только в исходниках, не вIPA349.

Обновления после349, 21.10.2026 — 70913c309 / кандидат350(781727f3f).
Выполнены5пунктов:mentionsподписейSDK,обычныеfilecardsвстилеДиска,
channelinsights/audit/capability+ACL,созданиеканала,фактическаямetadataвстреч.
154общих+70послеtimezoneфикса PASS;0ошибок/пропусков;320ptUIпроверен.
Release350строится,манифестios/build-archive/release-350.json.
Серверныеpublicationdrafts по0.4непринимаютm.mentions;ихформатнерасширялся.
Живаяприёмка/TestFlightнеподтверждены;доставкунеподменятьсборкой.

Предпоставочные исправления350: 4a18b3abe сохраняет favourite/unread/mention/
ongoing-call badge в строке встречи (74 теста PASS); af676a709 отключает новый
summary в режиме поиска, где обычные комнаты должны показывать сообщение.
Номер остаётся350, предварительные архивы не передавались. Итоговый pipeline
сначала проверяет поиск, затем собирает и подписывает финальный архив.

Итог350: источникaf676a709, 26.21.10(350), app/NSE/Shareподписаны/проверены.
Послеsearchscopeфикса26/0. IPA350импортированавTransporterединожды,
cacheSHA256совпадает,фокусCodeсохранён. Sendне нажимался;живойdevice/devQAнет.
План:docs/project-status/План выполнения обновлений — 2026-10-21.txt.


### 2026-11-04 — Нативный второй фактор при входе (STALK-1254)

- Сохранена собственная форма логина/пароля. Поле одноразового кода появляется только после OTP challenge Keycloak для уже настроенного фактора.
- Код отправляется в той же OIDC-сессии с серверными полями CSRF и выбранным credential; неверный код допускает ручной повтор без повторной отправки пароля.
- Отмена и закрытие координатора прерывают ожидающий ввод. Код не сохраняется в Keychain; callback больше не печатается NativeLogin в журнал.
- Проверки: `sh ios/Tools/Tests/run-native-otp.sh` — обычный вход, OTP, retry, cancel, ошибка пароля, cross-origin, OTP после redirect. Реальная MFA-учётка и первичная настройка фактора этим набором не проверены.
- Перенос при обновлении upstream: HeadlessOIDCAuthenticator; NativeLoginScreen (View, ViewModel, Models, Coordinator); три ключа stalk_auth_otp_* в en/ru. Первичная настройка MFA (QR/секрет) не реализована этим изменением.

Коммит для переноса: `e1f802b3de67963c6e9d17c759335b43aae3a2a1`, локальная ветка `fix/native-otp-20261104` (чужие WIP не включены). Финальная Release-сборка симулятора прошла; журнал `/tmp/stalk-native-otp-final-build.log`. Публикация ветки заблокирована автоматической проверкой разрешений.


### 2026-11-11 — Сборка 369: отказ и тайм-аут исходящего, повторный звонок, камера при подключении (STMOB-327/328/329)

- **STMOB-327:** исходящий звонок слушает rtc.decline к своему rtc.notification и закрывается со статусом «Отклонён». Если ответа нет, он закрывается через 30 с (раньше 90) со статусом «Нет ответа».
- **STMOB-328:** новый вызов сразу после прошлого стартует как обычный вызов с рингом. Своё устаревшее членство в звонке больше не принимается за идущий звонок.
- **STMOB-329:** «камера», нажатая во время подключения, запоминается и применяется при connect. VM больше не гасит её после подключения.
- **Проверки** (STALK-1270, раунд 4, 11.11, симулятор вместе с вебом и Android):
  - отказ 3/3 за 4,5–5,3 с;
  - повторные вызовы 13/13;
  - камера во время connecting публикуется через 0,22 с после connected;
  - группы WAI5 E2EE и WAI8 plain/E2EE без ошибок.
- **Сборка:** ветка `release/369` = `stmob-ns-blur` @ 8844d2b8c (сборка 368) + три исправления. QA-диагностика симулятора (тон, плитки, пауза перед connect) в выпуск не входит, она живёт в `qa/stalk1270-round3`.
- **Выпуск:** IPA 26.21.11 (369), sha256 `be190fad1088e32b3407dfad81ef229283ea41d5e9a9291fcdbf5f1a44d3a850`. dp отправил её через Transporter 11.11.

Коммиты для переноса:
- [0a5ee93cf](https://github.com/ank1n/element-x-ios/commit/0a5ee93cf) — отказ, срок и повторный звонок;
- [c8b422151](https://github.com/ank1n/element-x-ios/commit/c8b422151) — 30 с;
- [434542920](https://github.com/ank1n/element-x-ios/commit/434542920) — камера при подключении;
- [aaa5bfa3d](https://github.com/ank1n/element-x-ios/commit/aaa5bfa3d) — номер сборки.


### 2026-11-11 — Сборка 370: повтор подключения к звонку и сообщение о неудаче (STMOB-330)

- Если подключение к LiveKit упало по тайм-ауту или из-за сети, iOS через 1 с повторяет его один раз с тем же токеном, но только если человек не положил трубку. На смоуке 369 так подвело 1 подключение из ~8: ICE поднялся, а рукопожатие транспорта не завершилось за 10 с.
- Если не удался и повтор, вместо молча закрытого экрана — сообщение «Не удалось подключиться к звонку. Повторите попытку.» (ru/en/uz).
- «Все ушли» проверяется только после connected и одной проверкой: пустой список после неудачной попытки останавливал сессию посреди повтора, а серия пустых снимков звала stop() до пяти раз.
- Страховочный REST-выход (CallScreenViewModel) не трогает уже снятое участие и пишет в формате самой записи — {} для записи на устройство. Раньше он писал старый {"memberships":[]}, и веб видел участие iOS живым.
- QA-флаг `STALK_QA_FAIL_CONNECTS=N` (только симулятор) роняет первые N попыток.
- Проверки 11.11 (симулятор + веб, Molly): повтор, двойная неудача, обычный вход, выход, «все ушли» — все PASS; CallScreenViewModelTests 13/0.
- Выпуск: IPA 26.21.11 (370), sha256 `2a2b1d5e3bda551e7c21d2083068e21403d3c16483cf8619cb640f82b2941af9`, ветка `fix/stmob-330` = `release/369` + правка.

Коммиты для переноса:
- [4739e99d3](https://github.com/ank1n/element-x-ios/commit/4739e99d3) — правка;
- [c7b2d4a47](https://github.com/ank1n/element-x-ios/commit/c7b2d4a47) — номер сборки.


### 2026-11-15 — Сборка 372 (26.21.12): сохранённые сообщения, задачи комнаты, напоминания о встречах, звонок после ответа на другом устройстве (STMOB-331/332/333/334)

- **STMOB-333**, паритет с вебом:
  - «Сохранённые» (STALK-1383): копия сообщения с полем `ru.stalk.saved_from`, комната из account data `ru.stalk.saved_messages`, действие «Убрать из сохранённых».
  - Задачи комнаты (STALK-1374): список, создание из одного или нескольких сообщений (до 20), значок на сообщениях-основаниях, передача в TrackIT.
  - Напоминание о встрече (SMAIL-46), в том числе на самом iPhone: локальные уведомления и календарь «sTalk».
- **STMOB-331/332:** pinch-zoom демонстрации экрана; участники видны во время своей демонстрации.
- **STMOB-334, звонок после ответа на другом устройстве.** Воспроизведено с Molly 15.11 на iPhone dp, журнал снят по кабелю:
  - После answeredElsewhere/declinedElsewhere пометка «звонит» жила 90 с и глушила следующий вызов в ту же комнату: беззвучная заглушка, остаётся только баннер. Теперь снимается сразу.
  - Холодный старт: наблюдатель фазы «звонит» верил снимку комнаты из хранилища с собственным call.member прошлого процесса и гасил вызов через 0,7 с. Теперь своё участие засчитывается только по обновлению, пришедшему синком.
  - Проверено на 372: холодный старт — звонит до ответа, гаснет через ~90 мс после JOIN веба; новый вызов через 38 с после ответа звонит полноценно. ElementCallServiceTests 7/0.
- **Выпуск:** 371 в App Store Connect не ушла (403, не принято соглашение; принято 13.11). 372 = `release/372` @ a2e639dd1, dp отправил её через Transporter 15.11.

Коммиты для переноса:
- [18e2308f2](https://github.com/ank1n/element-x-ios/commit/18e2308f2), [b1247ad01](https://github.com/ank1n/element-x-ios/commit/b1247ad01), [3e8d3be66](https://github.com/ank1n/element-x-ios/commit/3e8d3be66), [85e6f0634](https://github.com/ank1n/element-x-ios/commit/85e6f0634), [169acacf4](https://github.com/ank1n/element-x-ios/commit/169acacf4) — STMOB-333;
- [1650ca933](https://github.com/ank1n/element-x-ios/commit/1650ca933) — слияние STMOB-331/332;
- [37a9199a8](https://github.com/ank1n/element-x-ios/commit/37a9199a8), [87c2f2a9b](https://github.com/ank1n/element-x-ios/commit/87c2f2a9b) — STMOB-334;
- [a2e639dd1](https://github.com/ank1n/element-x-ios/commit/a2e639dd1) — номер сборки.
