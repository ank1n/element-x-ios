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

**Последний коммит**: `a5d8724` - feat: badge непрочитанных на вкладке Чаты

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
- [ ] Добавить Lottie dependency в Package.swift / project.yml
- [ ] Разрешить конфликты в UserSessionFlowCoordinator.swift
- [ ] Проект собирается без ошибок
- [ ] 5 вкладок с SF Symbol иконками работают
- [ ] Underline фильтры отображаются на всех экранах
- [ ] Зелёные/серые/красные бейджи корректны
- [ ] Записи звонков воспроизводятся

---

**Дата создания**: 2026-01-28
**Последнее обновление**: 2026-02-06
