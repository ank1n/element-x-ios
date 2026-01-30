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

## 🎯 Текущий статус

**Версия Element X**: Форк на основе upstream develop
**Ветка**: develop
**Функционал**:
- ✅ Вкладка Widgets добавлена
- ✅ TabBar видимость исправлена
- ✅ Приложение собрано и установлено
- ⏳ Требуется тестирование пользователем

**Последний коммит**: `1deb412` - Fix TabBar visibility for Widgets tab

---

## 📖 Документация

Дополнительные документы:
- `QUICK-TEST-STEPS.md` - Инструкция по быстрой проверке
- `HOW-TO-SEE-TABBAR.md` - Решение проблем с TabBar
- `XCODE-CLEAN-BUILD-STEPS.md` - Инструкция по чистой сборке
- `TABBAR-FIX.md` - Подробности о фиксе TabBar

---

## 🤝 Сотрудничество

Все изменения внесены совместно с:
**Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>**

---

**Дата создания**: 2026-01-28
**Последнее обновление**: 2026-01-28
