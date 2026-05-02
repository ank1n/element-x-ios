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

**Дата создания**: 2026-01-28
**Последнее обновление**: 2026-05-02
