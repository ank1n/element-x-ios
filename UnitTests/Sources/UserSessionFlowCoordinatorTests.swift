//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class UserSessionFlowCoordinatorTests: XCTestCase {
    var userSessionFlowCoordinator: UserSessionFlowCoordinator!
    var rootCoordinator: NavigationRootCoordinator!
    var userIndicatorController: UserIndicatorControllerMock!
    let stateMachineFactory = PublishedStateMachineFactory()
    
    let networkReachabilitySubject: CurrentValueSubject<NetworkMonitorReachability, Never> = .init(.reachable)
    let homeserverReachabilitySubject: CurrentValueSubject<NetworkMonitorReachability, Never> = .init(.reachable)
    var cancellables = Set<AnyCancellable>()
    
    var tabCoordinator: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>? {
        rootCoordinator?.rootCoordinator as? NavigationTabCoordinator
    }

    /// STMOB-310: в sTalk пять вкладок (Контакты, Звонки, Чаты, Приложения, Профиль — 7c6f3f713),
    /// «Чаты» больше не первая. Split-координатор среди вкладок один — у «Чатов».
    var chatsSplitCoordinator: NavigationSplitCoordinator? {
        tabCoordinator?.tabCoordinators.compactMap { $0 as? NavigationSplitCoordinator }.first
    }

    /// STMOB-310: настройки в sTalk — последняя вкладка «Профиль», а не шит поверх таббара (7c6f3f713).
    var profileNavigationStack: NavigationStackCoordinator? {
        tabCoordinator?.tabCoordinators.last as? NavigationStackCoordinator
    }

    var detailCoordinator: CoordinatorProtocol? {
        chatsSplitCoordinator?.detailCoordinator
    }

    var detailNavigationStack: NavigationStackCoordinator? {
        detailCoordinator as? NavigationStackCoordinator
    }
    
    override func setUp() async throws {
        cancellables.removeAll()
        
        rootCoordinator = NavigationRootCoordinator()
        
        let clientProxy = ClientProxyMock(.init(userID: "hi@bob", roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        clientProxy.homeserverReachabilityPublisher = homeserverReachabilitySubject.asCurrentValuePublisher()
        
        let networkMonitor = NetworkMonitorMock.default
        networkMonitor.reachabilityPublisher = networkReachabilitySubject.asCurrentValuePublisher()
        let appMediator = AppMediatorMock.default
        appMediator.networkMonitor = networkMonitor
        
        userIndicatorController = UserIndicatorControllerMock()
        
        let flowParameters = CommonFlowParameters(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                  bugReportService: BugReportServiceMock(.init()),
                                                  elementCallService: ElementCallServiceMock(.init()),
                                                  timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                  emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                                  linkMetadataProvider: LinkMetadataProvider(),
                                                  appMediator: appMediator,
                                                  appSettings: ServiceLocator.shared.settings,
                                                  appHooks: AppHooks(),
                                                  analytics: ServiceLocator.shared.analytics,
                                                  userIndicatorController: userIndicatorController,
                                                  notificationManager: NotificationManagerMock(),
                                                  stateMachineFactory: stateMachineFactory)
        
        // STMOB-311: координатор ставит на паузу опрос присутствия скрытых вкладок — нужен сервис.
        AppCoordinator.sharedPresenceService = PresenceService(homeserver: "https://example.org",
                                                               tokenProvider: { nil },
                                                               ownUserID: "hi@bob",
                                                               transport: FakePresenceTransport(),
                                                               forbiddenStore: InMemoryForbiddenStore())

        userSessionFlowCoordinator = UserSessionFlowCoordinator(isNewLogin: false,
                                                                navigationRootCoordinator: rootCoordinator,
                                                                appLockService: AppLockServiceMock(),
                                                                flowParameters: flowParameters)
        
        userSessionFlowCoordinator.start()
    }

    override func tearDown() {
        AppCoordinator.sharedPresenceService = nil
    }

    // MARK: Presence

    /// STMOB-311: вкладки нарисованы все сразу, поэтому строки скрытых «Чатов» и «Контактов»
    /// считаются видимыми. Опрос их присутствия идёт только для выбранной вкладки.
    func testPresenceOfHiddenTabsIsSuspended() async throws {
        // Наборы строк выставляют сами экраны вкладок; здесь проверяем только паузу по вкладке.
        let presence = try XCTUnwrap(AppCoordinator.sharedPresenceService)
        XCTAssertFalse(presence.isSuspended(.chats), "sTalk starts on the Chats tab.")
        XCTAssertTrue(presence.isSuspended(.contacts))
        
        tabCoordinator?.selectedTab = .contacts
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presence.isSuspended(.chats))
        XCTAssertFalse(presence.isSuspended(.contacts))
        
        tabCoordinator?.selectedTab = .calls
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presence.isSuspended(.chats))
        XCTAssertTrue(presence.isSuspended(.contacts))
        
        tabCoordinator?.selectedTab = .chats
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(presence.isSuspended(.chats))
        XCTAssertTrue(presence.isSuspended(.contacts))
    }
    
    // MARK: Navigation

    func testInitialState() {
        XCTAssertNotNil(chatsSplitCoordinator)
        XCTAssertNil(detailCoordinator)
        // STMOB-310: sTalk стартует на вкладке «Чаты» (70d48a932).
        XCTAssertEqual(tabCoordinator?.selectedTab, .chats)
    }
    
    func testSettingsPresentation() async throws {
        // STMOB-310: маршрут .settings в sTalk переключает на вкладку «Профиль» и не меняет
        // состояние UserSessionFlowCoordinator (состояния .settingsScreen в форке нет),
        // поэтому ждать перехода нечего — проверяем вкладку и корень её стека.
        XCTAssertEqual(tabCoordinator?.selectedTab, .chats)
        try await process(route: .settings)
        XCTAssertEqual(tabCoordinator?.selectedTab, .profile)
        XCTAssertTrue(profileNavigationStack?.rootCoordinator is SettingsScreenCoordinator)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
    }
    
    func testRoomPresentation() async throws {
        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        XCTAssertTrue(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNotNil(detailCoordinator)
    }
    
    func testRoomPresentationClearsSettings() async throws {
        // STMOB-310: настройки — вкладка «Профиль»; «убрать настройки» = вернуться на «Чаты».
        try await process(route: .settings)
        XCTAssertEqual(tabCoordinator?.selectedTab, .profile)
        XCTAssertTrue(profileNavigationStack?.rootCoordinator is SettingsScreenCoordinator)
        XCTAssertNil(detailCoordinator)
        
        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        XCTAssertEqual(tabCoordinator?.selectedTab, .chats)
        XCTAssertNil((tabCoordinator?.sheetCoordinator))
        XCTAssertTrue(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNotNil(detailCoordinator)
    }
    
    func testChildRoomPresentation() async throws {
        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        let detailNavigationStack = try XCTUnwrap(detailNavigationStack, "There must be a navigation stack.")
        XCTAssertTrue(detailNavigationStack.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNotNil(detailCoordinator)
        
        let deferred = deferFulfillment(detailNavigationStack.observe(\.stackCoordinators.count)) { $0 == 1 }
        try await process(route: .childRoom(roomID: "2", via: []))
        try await deferred.fulfill()
        XCTAssertTrue(detailNavigationStack.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNotNil(detailCoordinator)
        XCTAssertEqual(detailNavigationStack.stackCoordinators.count, 1)
        XCTAssertTrue(detailNavigationStack.stackCoordinators.first is RoomScreenCoordinator)
    }
    
    func testShareMediaRouteWithoutRoom() async throws {
        // STMOB-310: настройки — вкладка «Профиль», переход состояния UserSessionFlowCoordinator
        // при шаринге не происходит; вместо него проверяем возврат на вкладку «Чаты».
        try await process(route: .settings)
        XCTAssertEqual(tabCoordinator?.selectedTab, .profile)
        XCTAssertTrue(profileNavigationStack?.rootCoordinator is SettingsScreenCoordinator)
        XCTAssertNil(chatsSplitCoordinator?.sheetCoordinator)

        let sharePayload: ShareExtensionPayload = .mediaFiles(roomID: nil, mediaFiles: [.init(url: .picturesDirectory, suggestedName: nil)])
        try await process(route: .share(sharePayload),
                          expectedChatsState: .shareExtensionRoomList(sharePayload: sharePayload))
        XCTAssertEqual(tabCoordinator?.selectedTab, .chats)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertTrue((chatsSplitCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is RoomSelectionScreenCoordinator)
    }
    
    func testShareMediaRouteWithRoom() async throws {
        try await process(route: .event(eventID: "1", roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        XCTAssertTrue(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertNil(chatsSplitCoordinator?.sheetCoordinator)

        let sharePayload: ShareExtensionPayload = .mediaFiles(roomID: "2", mediaFiles: [.init(url: .picturesDirectory, suggestedName: nil)])
        try await process(route: .share(sharePayload),
                          expectedChatsState: .roomList(detailState: .room(roomID: "2")))

        XCTAssertTrue(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertTrue((chatsSplitCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is MediaUploadPreviewScreenCoordinator)
    }
    
    func testShareTextRouteWithoutRoom() async throws {
        // STMOB-310: см. testShareMediaRouteWithoutRoom — настройки в sTalk это вкладка.
        try await process(route: .settings)
        XCTAssertEqual(tabCoordinator?.selectedTab, .profile)
        XCTAssertTrue(profileNavigationStack?.rootCoordinator is SettingsScreenCoordinator)
        XCTAssertNil(chatsSplitCoordinator?.sheetCoordinator)

        let sharePayload: ShareExtensionPayload = .text(roomID: nil, text: "Important Text")
        try await process(route: .share(sharePayload),
                          expectedChatsState: .shareExtensionRoomList(sharePayload: sharePayload))
        XCTAssertEqual(tabCoordinator?.selectedTab, .chats)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertTrue((chatsSplitCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is RoomSelectionScreenCoordinator)
    }
    
    func testShareTextRouteWithRoom() async throws {
        try await process(route: .event(eventID: "1", roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        XCTAssertTrue(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertNil(chatsSplitCoordinator?.sheetCoordinator)

        let sharePayload: ShareExtensionPayload = .text(roomID: "2", text: "Important text")
        try await process(route: .share(sharePayload),
                          expectedChatsState: .roomList(detailState: .room(roomID: "2")))

        XCTAssertTrue(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertNil(chatsSplitCoordinator?.sheetCoordinator, "The media upload sheet shouldn't be shown when sharing text.")
    }
    
    // MARK: Indicators
    
    func testReachabilityIndicators() async throws {
        // Given a flow in its initial state.
        try await Task.sleep(for: .milliseconds(100))
        
        // Then no reachability indicators should be shown.
        XCTAssertFalse(userIndicatorController.submitIndicatorDelayCalled)
        XCTAssertEqual(retractReachabilityIndicatorCallsCount, 1) // The initial state removes the indicator.
        
        // When the homeserver becomes unreachable.
        homeserverReachabilitySubject.send(.unreachable)
        try await Task.sleep(for: .milliseconds(100))
        
        // Then a server unreachable indicator should be shown.
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayCallsCount, 1)
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title, L10n.commonServerUnreachable)
        XCTAssertEqual(retractReachabilityIndicatorCallsCount, 1)
        
        // When the network also becomes unreachable.
        networkReachabilitySubject.send(.unreachable)
        try await Task.sleep(for: .milliseconds(100))
        
        // Then the server unreachable indicator should be replaced with an offline indicator.
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayCallsCount, 2)
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title, L10n.commonOffline)
        XCTAssertEqual(retractReachabilityIndicatorCallsCount, 1)
        
        // When the homeserver becomes reachable again.
        homeserverReachabilitySubject.send(.reachable)
        try await Task.sleep(for: .milliseconds(100))
        
        // Then there should still be an offline indicator (as we don't yet support air-gapped servers on iOS).
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayCallsCount, 3)
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title, L10n.commonOffline)
        XCTAssertEqual(retractReachabilityIndicatorCallsCount, 1)
        
        // When the network becomes reachable again.
        networkReachabilitySubject.send(.reachable)
        try await Task.sleep(for: .milliseconds(100))
        
        // Then the indicator should be hidden now as everything is back to normal
        XCTAssertEqual(userIndicatorController.submitIndicatorDelayCallsCount, 3)
        XCTAssertEqual(retractReachabilityIndicatorCallsCount, 2)
    }
    
    // MARK: - Helpers
    
    private func process(route: AppRoute,
                         expectedUserSessionState: UserSessionFlowCoordinator.State? = nil,
                         expectedChatsState: ChatsTabFlowCoordinatorStateMachine.State? = nil) async throws {
        let deferredUserSession: DeferredFulfillment? = if let expectedUserSessionState {
            deferFulfillment(stateMachineFactory.userSessionFlowStatePublisher.delay(for: .milliseconds(100), scheduler: DispatchQueue.main)) {
                $0 == expectedUserSessionState
            }
        } else {
            nil
        }
        
        let deferredChatsState: DeferredFulfillment? = if let expectedChatsState {
            deferFulfillment(stateMachineFactory.chatsTabFlowStatePublisher.delay(for: .milliseconds(100), scheduler: DispatchQueue.main)) {
                $0 == expectedChatsState
            }
        } else {
            nil
        }
        
        userSessionFlowCoordinator.handleAppRoute(route, animated: true)
        try await deferredUserSession?.fulfill()
        try await deferredChatsState?.fulfill()
    }
    
    /// Other services retract indicators, so this filters based on the reachability ID.
    /// STMOB-310: идентификатор переименован при ребрендинге Element X → sTalk (580ba8863).
    private var retractReachabilityIndicatorCallsCount: Int {
        userIndicatorController
            .retractIndicatorWithIdReceivedInvocations
            .filter { $0 == "ru.implica.stalk.reachability.notification" }
            .count
    }
}
