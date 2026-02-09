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

**Последний коммит**: `d8fb603` - поиск сообщений внутри чата (inline search bar)

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
- [ ] Добавить Lottie dependency в Package.swift / project.yml
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

---

**Дата создания**: 2026-01-28
**Последнее обновление**: 2026-02-09
