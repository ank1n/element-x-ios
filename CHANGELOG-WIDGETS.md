# План изменений: Вкладка Widgets

## Версия: 2026-01-27

### Изменения в функционале

#### 1. Добавлена третья вкладка "Виджеты" в TabBar ✅

**Описание**: Новая вкладка в нижнем TabBar для глобального доступа к виджетам из всех комнат.

**Измененные файлы**:
- `ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift`

**Конкретные изменения для применения при обновлении Element X**:

##### Изменение 1: Добавить case в enum HomeTab (строка ~23)
```swift
// БЫЛО:
enum HomeTab: Hashable {
    case chats
    case spaces
}

// СТАЛО:
enum HomeTab: Hashable {
    case chats
    case spaces
    case widgets  // ← ДОБАВИТЬ
}
```

##### Изменение 2: Добавить properties (после строки ~37)
```swift
// ДОБАВИТЬ после spacesTabDetails:
private let widgetsTabFlowCoordinator: WidgetsTabFlowCoordinator
private let widgetsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
```

##### Изменение 3: Инициализация в init (после строки ~92)
```swift
// ДОБАВИТЬ после инициализации spacesTab:
let widgetsStackCoordinator = NavigationStackCoordinator()
widgetsTabFlowCoordinator = WidgetsTabFlowCoordinator(
    navigationStackCoordinator: widgetsStackCoordinator,
    flowParameters: flowParameters
)
widgetsTabDetails = .init(tag: HomeTab.widgets,
                          title: "Виджеты",
                          icon: \.extensions,
                          selectedIcon: \.extensionsSolid)
```

##### Изменение 4: Добавить в setTabs() (строка ~102)
```swift
// БЫЛО:
navigationTabCoordinator.setTabs([
    .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
    .init(coordinator: spacesSplitCoordinator, details: spacesTabDetails)
])

// СТАЛО:
navigationTabCoordinator.setTabs([
    .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
    .init(coordinator: spacesSplitCoordinator, details: spacesTabDetails),
    .init(coordinator: widgetsStackCoordinator, details: widgetsTabDetails)  // ← ДОБАВИТЬ
])
```

##### Изменение 5: Добавить stop() (строка ~124)
```swift
// В методе func stop():
func stop() {
    chatsTabFlowCoordinator.stop()
    widgetsTabFlowCoordinator.stop()  // ← ДОБАВИТЬ
}
```

**Коммит для применения**:
```bash
# Коммит уже создан:
git cherry-pick 21dd96e  # feat: Add Widgets tab flow coordinator

# Или применить вручную изменения из коммита выше
```

---

#### 2. Созданы новые файлы для функционала виджетов ✅

**Новые файлы** (все нужно добавить в Xcode проект):

```
ElementX/Sources/
├── FlowCoordinators/
│   └── WidgetsTabFlowCoordinator.swift         [NEW]
├── Services/
│   └── Widget/
│       ├── WidgetModels.swift                  [EXISTS - уже был создан ранее]
│       └── WidgetService.swift                 [EXISTS - уже был создан ранее]
└── Screens/
    ├── WidgetsListScreen/
    │   ├── WidgetsListScreenCoordinator.swift  [NEW]
    │   ├── WidgetsListScreenModels.swift       [NEW]
    │   ├── WidgetsListScreenViewModel.swift    [NEW]
    │   └── WidgetsListScreen.swift             [NEW]
    └── WidgetWebViewScreen/
        ├── WidgetWebViewScreenCoordinator.swift [NEW]
        ├── WidgetWebViewScreenModels.swift      [NEW]
        ├── WidgetWebViewScreenViewModel.swift   [NEW]
        └── WidgetWebViewScreen.swift            [NEW]
```

**Коммит для применения**:
```bash
# Коммит уже создан:
git cherry-pick 68a68b4  # feat: Add Widgets tab screens and coordinators

# ВАЖНО: После cherry-pick необходимо добавить файлы в Xcode проект
# Используйте скрипт: ruby add_widgets_files.rb
# Или добавьте вручную через Xcode
```

---

#### 3. Recording API для LiveKit Egress ✅

**Описание**: REST API для управления записью LiveKit встреч.

**Создано на сервере**:
- `/root/room-recording.sh` - CLI утилита
- `/tmp/recording-api/` - Node.js API сервис
- Kubernetes deployment в namespace `livekit`

**Endpoints**:
- `GET /health`
- `POST /api/recording/start`
- `POST /api/recording/stop`
- `GET /api/recording/status/:egressId`
- `GET /api/recording/list`

**URL**: `https://api.market.implica.ru`

**Хранилище**: MinIO S3 bucket `livekit-recordings`

**Статус**: ✅ Развернуто и работает

---

### Следующие шаги для применения изменений

1. **Добавить файлы в Xcode проект** (см. WIDGETS-TAB-IMPLEMENTATION-FINAL.md)
2. **Выполнить коммиты** (команды выше)
3. **Собрать проект**: `⌘B` в Xcode или `xcodebuild`
4. **Протестировать** в симуляторе

---

### Как применить изменения к новой версии Element X

Когда Element X обновляется до новой версии:

1. **Сделать merge/rebase** новой версии Element X
2. **Проверить конфликты** в `UserSessionFlowCoordinator.swift`
3. **Вручную применить** изменения 1-5 из раздела выше
4. **Скопировать** новые файлы (WidgetsTabFlowCoordinator, screens)
5. **Добавить файлы** в Xcode проект
6. **Проверить совместимость**:
   - StateStoreViewModel vs StateStoreViewModelV2
   - Изменения в NavigationTabCoordinator
   - Изменения в FlowCoordinatorProtocol
7. **Запустить тесты** и **собрать проект**

---

## История версий

### v1.0 (2026-01-27)
- ✅ Recording API развернут
- ✅ Варианты UI для виджетов (4 варианта)
- ✅ Реализация Варианта 3 (TabBar tab)
- ✅ Все файлы созданы и добавлены в Xcode проект
- ✅ Проект успешно собран (BUILD SUCCEEDED)
- ✅ Используется существующий WidgetWebView с Widget API bridge
- ✅ Интеграция с RoomSummaryProvider
- ✅ Правильные иконки (extensions/extensionsSolid)

---

## Документация

См. также:
- `WIDGETS-TAB-IMPLEMENTATION-FINAL.md` - инструкции по завершению
- `WIDGETS-UI-VARIANTS-VISUAL.md` - визуальные варианты UI
- `RECORDING-API-READY.md` - документация Recording API
