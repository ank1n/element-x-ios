# 🔍 Отладка проблемы с TabBar

## ❌ Проблема

После всех попыток исправления TabBar **всё ещё не отображается** на iPhone 17 Pro с iOS 28.2.

**Что было сделано**:
- ✅ Добавлен `widgets` в enum `HomeTab`
- ✅ Добавлен widgets в `setTabs()`
- ✅ Добавлен `barVisibilityOverride = .visible` для всех трёх вкладок
- ✅ Проект собран успешно
- ✅ Приложение установлено и запущено
- ❌ **TabBar не появляется даже после входа в аккаунт**

## 🎯 Коммиты

- `21dd96e` - Добавлены файлы Widgets UI
- `68a68b4` - Интеграция Widgets в UserSessionFlowCoordinator
- `1deb412` - Добавлен `barVisibilityOverride = .visible` для Widgets
- `a91a56f` - Добавлен `barVisibilityOverride = .visible` для всех вкладок

## 🔬 Что проверить

### Гипотеза 1: TabBar скрыт из-за fullScreenCover

В `UserSessionFlowCoordinator.swift` есть код:

```swift
navigationTabCoordinator.setFullScreenCoverCoordinator(onboardingStackCoordinator, animated: animated)
```

**Проверить**: Может ли onboarding показываться как fullScreenCover даже после входа?

### Гипотеза 2: iOS 28.2 beta имеет проблему с TabBar

**Окружение**:
- iPhone 17 Pro (симулятор)
- iOS 28.2 (или 26.2 runtime)
- Xcode последней версии
- Deployment target: iOS 18.5

**Проверить**: Работает ли TabBar на симуляторе с более старой версией iOS?

### Гипотеза 3: В Element X TabBar показывается только на iPad

**Проверить**:
1. Запустить оригинальную версию Element X (коммит `69349d6`) на iPhone
2. Войти в аккаунт
3. Проверить показывается ли TabBar с 2 вкладками (Chats, Spaces)

### Гипотеза 4: Вкладка открыта в detailCoordinator

**Код в NavigationTabCoordinator.swift**:
```swift
func barVisibility(in horizontalSizeClass: UserInterfaceSizeClass?) -> Visibility {
    if let barVisibilityOverride {
        barVisibilityOverride  // Должно возвращать .visible!
    } else if horizontalSizeClass == .compact, navigationSplitCoordinator?.detailCoordinator != nil {
        .hidden
    } else {
        .automatic
    }
}
```

**Проверить**: Вызывается ли метод `barVisibility()` и что он возвращает?

## 🛠️ Отладка в Xcode

### Шаг 1: Открыть проект в Xcode

```bash
cd /Users/ankin/Documents/element-x-fork/ios
open ElementX.xcodeproj
```

### Шаг 2: Добавить breakpoint

**Файл**: `ElementX/Sources/Application/Navigation/NavigationTabCoordinator.swift`
**Строка**: 308

```swift
.toolbar(module.details.barVisibility(in: horizontalSizeClass), for: .tabBar)
```

**Цель**: Проверить вызывается ли этот код и что возвращает `barVisibility()`.

### Шаг 3: Добавить breakpoint в barVisibility

**Файл**: `ElementX/Sources/Application/Navigation/NavigationTabCoordinator.swift`
**Строка**: 41-50 (весь метод `barVisibility`)

**Добавить watch expression**:
- `barVisibilityOverride`
- `horizontalSizeClass`
- `navigationSplitCoordinator?.detailCoordinator`

### Шаг 4: Добавить breakpoint в setTabs

**Файл**: `ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift`
**Строка**: 107

```swift
navigationTabCoordinator.setTabs([
    .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
    .init(coordinator: spacesSplitCoordinator, details: spacesTabDetails),
    .init(coordinator: widgetsStackCoordinator, details: widgetsTabDetails)
])
```

**Цель**: Убедиться что setTabs() вызывается с 3 вкладками.

### Шаг 5: Запустить и проверить

1. В Xcode: **Product → Run** (⌘R)
2. Войти в аккаунт Matrix
3. Breakpoints должны сработать
4. Проверить значения переменных

## 📝 Лог отладки

### Что нужно записать:

1. **setTabs() вызван?**
   - [ ] Да
   - [ ] Нет
   - Количество вкладок: ___

2. **barVisibility() вызван?**
   - [ ] Да
   - [ ] Нет
   - Для каких вкладок: ___

3. **barVisibilityOverride значение**:
   - Chats: ___
   - Spaces: ___
   - Widgets: ___

4. **horizontalSizeClass**:
   - [ ] .compact (iPhone)
   - [ ] .regular (iPad)

5. **navigationSplitCoordinator?.detailCoordinator**:
   - [ ] nil
   - [ ] не nil (какой координатор?)

6. **Возвращаемое значение barVisibility()**:
   - Chats: ___
   - Spaces: ___
   - Widgets: ___

## 🔍 Альтернативная проверка через UI Inspector

### В Xcode Simulator:

1. Запустить приложение
2. Войти в аккаунт
3. В меню: **Debug → View Debugging → Capture View Hierarchy**
4. Найти в иерархии:
   - `UITabBarController`
   - `UITabBar`
   - Проверить свойство `isHidden`

### Или через lldb:

В Xcode Debug console:
```lldb
(lldb) po [[[UIApplication sharedApplication] keyWindow] recursiveDescription]
```

Найти UITabBar и проверить:
```lldb
(lldb) e (BOOL)[<адрес_UITabBar> isHidden]
```

## 📊 Проверка через код

Добавить временный print в `NavigationTabCoordinator.swift`:

```swift
func barVisibility(in horizontalSizeClass: UserInterfaceSizeClass?) -> Visibility {
    print("🔍 barVisibility called")
    print("   barVisibilityOverride: \(String(describing: barVisibilityOverride))")
    print("   horizontalSizeClass: \(String(describing: horizontalSizeClass))")
    print("   detailCoordinator: \(String(describing: navigationSplitCoordinator?.detailCoordinator))")

    if let barVisibilityOverride {
        print("   → returning: \(barVisibilityOverride)")
        return barVisibilityOverride
    } else if horizontalSizeClass == .compact, navigationSplitCoordinator?.detailCoordinator != nil {
        print("   → returning: .hidden")
        return .hidden
    } else {
        print("   → returning: .automatic")
        return .automatic
    }
}
```

Затем пересобрать и запустить, смотреть логи в Xcode Console.

## 🎯 Ожидаемый результат

После отладки должны понять:
1. Вызывается ли `setTabs()` с 3 вкладками?
2. Вызывается ли `barVisibility()` для каждой вкладки?
3. Возвращает ли `barVisibility()` значение `.visible`?
4. Отображается ли UITabBar в иерархии view?
5. Если UITabBar существует но не виден - в чём причина?

## 💡 Возможные решения

### Решение 1: Если barVisibilityOverride не работает

Попробовать изменить `.automatic` на `.visible` по умолчанию:

```swift
func barVisibility(in horizontalSizeClass: UserInterfaceSizeClass?) -> Visibility {
    if let barVisibilityOverride {
        barVisibilityOverride
    } else if horizontalSizeClass == .compact, navigationSplitCoordinator?.detailCoordinator != nil {
        .visible  // Изменено с .hidden!
    } else {
        .visible  // Изменено с .automatic!
    }
}
```

### Решение 2: Если TabBar скрыт fullScreenCover

Проверить в `UserSessionFlowCoordinator` не вызывается ли:
```swift
navigationTabCoordinator.setFullScreenCoverCoordinator(...)
```

после входа в аккаунт.

### Решение 3: Если проблема в iOS 28.2

Попробовать на симуляторе iPhone с iOS 17 или 18.

### Решение 4: Если Element X не использует TabBar на iPhone

Возможно в Element X TabBar показывается только на iPad, а на iPhone используется другая навигация. В этом случае нужно переделать архитектуру.

## 📖 Документация

**Изученные файлы**:
- `ElementX/Sources/Application/Navigation/NavigationTabCoordinator.swift` - Координатор TabBar
- `ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift` - Инициализация вкладок
- `ElementX/Sources/FlowCoordinators/ChatsTabFlowCoordinator.swift` - Логика вкладки Chats

**SwiftUI API**:
- `.toolbar(_:for:)` - управление видимостью toolbars включая TabBar
- `Visibility` enum: `.visible`, `.hidden`, `.automatic`
- `TabView` - стандартный TabBar в SwiftUI

## ⏭️ Следующие шаги

1. Запустить в Xcode с breakpoints
2. Записать значения переменных
3. Найти почему TabBar не отображается
4. Применить соответствующее решение
5. Протестировать

---

**Дата**: 2026-01-28
**Коммит**: `a91a56f`
