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

### 65. ✅ STMOB-246 — E2EE key parser: gate handleEncryptionKeys к toWidget

**Дата**: 2026-06-23
**Коммиты**: `8512cc064`

#### Описание:
NSE-лог prod (build 98) показал 6× `E2EE handleEncryptionKeys EXTRACT FAILED`. Диагноз: не баг шифрования — приложение прогоняло СВОИ исходящие `fromWidget` (native-key-* `send_to_device` с `messages.*.*.keys{}`, native-roomkey-* `send_event` без `sender`) через входящий парсер → `participantId` пустой → FAILED. Реальные удалённые ключи приходят как `toWidget` (`content.keys[]` + `sender`) и парсятся ок (`incoming key DECODED`).

#### Изменение:
- `handleWidgetMessage`: обработка `encryption_keys` только при `message.api == "toWidget"`. Свои исходящие больше не парсим. Поведение шифрования НЕ меняется — чистка лог-шума (no-op).

#### Файлы:
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift`

#### Связано (отдельная работа, ждёт спеку Molly STALK-505):
Единый формат ключей Web/iOS/Android/Guest — приём обоих входящих shape'ов (`toWidget send_event` + `send_to_device` dual-channel), адресность recipients (не `"*"`), re-advertise на reconnect, index-rekey. Согласовано в #ops с Molly/Andy.

---

### 66. ✅ STMOB-246 — re-advertise того же ключа на смене сети (без ротации)

**Дата**: 2026-06-23
**Коммиты**: `fc82e07fc`

#### Описание:
`handleNetworkPathChange` на каждом Wi-Fi↔LTE вызывал `sendOurEncryptionKey()` — РЕ-генерация нового random ключа (всё на index 0). Пиры перезаписывали slot 0, in-flight кадры под старым ключом-0 кратко не расшифровывались (глитч на смене сети).

#### Изменение:
- network-change → `rebroadcastCurrentEncryptionKey()` (тот же ключ/index, без ротации) — как остальные re-advertise триггеры (foreground/reconnect/JOIN) и канон Molly/Andy (resend по index, не ротация).
- Отправка пока остаётся `"*"`-wildcard; адресные recipients — отдельная targeting-правка, валидируется на STALK-506.

#### Файлы:
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift`

---

### 67. ✅ STMOB-246 — гейт room-event SEND ключа за флагом (канон to-device-only)

**Дата**: 2026-06-24
**Коммиты**: `a47f61201`

#### Описание:
Канон STALK-505 (согласован Web/iOS/Android, Molly): SEND ключа = только адресный to-device; room-event SEND депрекейтим у всех (room-event персистит ключ в стейте комнаты = слабая forward secrecy + заставляет Web флипаться в broadcast при любом room-event ключе). RECEIVE room-event ОСТАЁТСЯ (fallback для легаси-отправителей).

#### Изменение:
- Флаг `kSendKeyViaRoomEvent` (default `true` = no-op) гейтит наши исходящие `send_event`-ключи в `sendOurEncryptionKey` + `rebroadcastCurrentEncryptionKey`. Приём room-event не трогаем. Стенд STALK-506 флипает в `false` → проверка, что to-device-only расшифровывается всеми (Web/iOS/Android/гость) перед удалением.

#### Файлы:
- `ios/ElementX/Sources/Services/NativeCall/NativeCallSession.swift`

#### Связано:
STMOB-247 (membership-settled re-advertise — предусловие снятия room-event), ветка `stmob-246-e2ee-targeting` (адресность recipients), STALK-505 (канон/спека), STALK-506 (стенд).

---

**Дата создания**: 2026-01-28
**Последнее обновление**: 2026-06-24
