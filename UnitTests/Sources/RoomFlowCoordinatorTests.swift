//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDKMocks
import XCTest

@MainActor
class RoomFlowCoordinatorTests: XCTestCase {
    var clientProxy: ClientProxyMock!
    var timelineControllerFactory: TimelineControllerFactoryMock!
    var roomFlowCoordinator: RoomFlowCoordinator!
    var navigationStackCoordinator: NavigationStackCoordinator!
    var cancellables = Set<AnyCancellable>()
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }
    
    func testRoomPresentation() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        
        try await clearRoute(expectedActions: [.finished])
        XCTAssertNil(navigationStackCoordinator.rootCoordinator)
    }
    
    func testRoomDetailsPresentation() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .roomDetails(roomID: "1"))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomDetailsScreenCoordinator)
        
        try await clearRoute(expectedActions: [.finished])
        XCTAssertNil(navigationStackCoordinator.rootCoordinator)
    }
    
    func testNoOp() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .roomDetails(roomID: "1"))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomDetailsScreenCoordinator)
        let detailsCoordinator = navigationStackCoordinator.rootCoordinator
        
        roomFlowCoordinator.handleAppRoute(.roomDetails(roomID: "1"), animated: true)
        await Task.yield()
        
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomDetailsScreenCoordinator)
        XCTAssert(navigationStackCoordinator.rootCoordinator === detailsCoordinator)
    }
    
    func testPushDetails() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await process(route: .roomDetails(roomID: "1"))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomDetailsScreenCoordinator)
    }
    
    func testChildRoomFlow() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await process(route: .childRoom(roomID: "2", via: []))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        
        try await process(route: .childRoom(roomID: "3", via: []))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 2)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators.last is RoomScreenCoordinator)
        
        try await clearRoute(expectedActions: [.finished])
        XCTAssertNil(navigationStackCoordinator.rootCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
    }
    
    /// Tests the child flow teardown in isolation of it's parent.
    func testChildFlowTearDown() async throws {
        setupRoomFlowCoordinator(asChildFlow: true)
        navigationStackCoordinator.setRootCoordinator(BlankFormCoordinator())
        
        try await process(route: .room(roomID: "1", via: []))
        try await process(route: .roomDetails(roomID: "1"))
        XCTAssertTrue(navigationStackCoordinator.rootCoordinator is BlankFormCoordinator, "A child room flow should push onto the stack, leaving the root alone.")
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 2)
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.last is RoomDetailsScreenCoordinator)
        
        try await clearRoute(expectedActions: [.finished])
        XCTAssertTrue(navigationStackCoordinator.rootCoordinator is BlankFormCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 2, "A child room flow should leave its parent to clean up the stack.")
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator, "A child room flow should leave its parent to clean up the stack.")
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.last is RoomDetailsScreenCoordinator, "A child room flow should leave its parent to clean up the stack.")
    }
    
    func testChildRoomMemberDetails() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await process(route: .childRoom(roomID: "2", via: []))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        
        try await process(route: .roomMemberDetails(userID: RoomMemberProxyMock.mockMe.userID))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 2)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators.last is RoomMemberDetailsScreenCoordinator)
    }
    
    func testChildRoomIgnoresDirectDuplicate() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await process(route: .childRoom(roomID: "1", via: []))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0,
                       "A room flow shouldn't present a direct child for the same room.")
        
        try await process(route: .childRoom(roomID: "2", via: []))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        
        try await process(route: .childRoom(roomID: "1", via: []))
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 2,
                       "Presenting the same room multiple times should be allowed when it's not a direct child of itself.")
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators.last is RoomScreenCoordinator)
    }
    
    func testRoomMembershipInvite() async throws {
        setupRoomFlowCoordinator(roomType: .invited(roomID: "InvitedRoomID"))
        
        try await process(route: .room(roomID: "InvitedRoomID", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is JoinRoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await clearRoute(expectedActions: [.finished])
        XCTAssertNil(navigationStackCoordinator.rootCoordinator)
        
        setupRoomFlowCoordinator(roomType: .invited(roomID: "InvitedRoomID"))
        
        try await process(route: .room(roomID: "InvitedRoomID", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is JoinRoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        // "Join" the room
        clientProxy.roomForIdentifierClosure = { _ in
            .joined(JoinedRoomProxyMock(.init()))
        }
        
        try await process(route: .room(roomID: "InvitedRoomID", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
    }
    
    func testChildRoomMembershipInvite() async throws {
        setupRoomFlowCoordinator(asChildFlow: true, roomType: .invited(roomID: "InvitedRoomID"))
        navigationStackCoordinator.setRootCoordinator(BlankFormCoordinator())
        
        try await process(route: .room(roomID: "InvitedRoomID", via: []))
        XCTAssertTrue(navigationStackCoordinator.rootCoordinator is BlankFormCoordinator, "A child room flow should push onto the stack, leaving the root alone.")
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.last is JoinRoomScreenCoordinator)
        
        try await clearRoute(expectedActions: [.finished])
        XCTAssertNil(navigationStackCoordinator.stackCoordinators.last, "A child room flow should remove the join room scren on dismissal")
        
        setupRoomFlowCoordinator(asChildFlow: true, roomType: .invited(roomID: "InvitedRoomID"))
        navigationStackCoordinator.setRootCoordinator(BlankFormCoordinator())
        
        try await process(route: .room(roomID: "InvitedRoomID", via: []))
        XCTAssertTrue(navigationStackCoordinator.rootCoordinator is BlankFormCoordinator, "A child room flow should push onto the stack, leaving the root alone.")
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.last is JoinRoomScreenCoordinator)
        
        // "Join" the room
        clientProxy.roomForIdentifierClosure = { _ in
            .joined(JoinedRoomProxyMock(.init()))
        }
        
        try await process(route: .room(roomID: "InvitedRoomID", via: []))
        XCTAssertTrue(navigationStackCoordinator.rootCoordinator is BlankFormCoordinator, "A child room flow should push onto the stack, leaving the root alone.")
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssertTrue(navigationStackCoordinator.stackCoordinators.last is RoomScreenCoordinator)
    }
    
    func testEventRoute() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .event(eventID: "1", roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await process(route: .childEvent(eventID: "2", roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        try await process(route: .childEvent(eventID: "3", roomID: "2", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is RoomScreenCoordinator)
    }
    
    func testThreadedEventRoutes() async throws {
        ServiceLocator.shared.settings.threadsEnabled = true
        setupRoomFlowCoordinator()
        
        // Navigate directly to the threaded event
        var configuration = JoinedRoomProxyMockConfiguration(id: "1")
        var roomProxy = JoinedRoomProxyMock(configuration)
        
        var roomInfoSubject = CurrentValueSubject<RoomInfoProxyProtocol, Never>(RoomInfoProxyMock(configuration))
        roomProxy.infoPublisher = roomInfoSubject.asCurrentValuePublisher()
        
        var mockedEvent = TimelineEventSDKMock()
        mockedEvent.threadRootEventIdReturnValue = "1"
        roomProxy.loadOrFetchEventDetailsForReturnValue = .success(mockedEvent)
        
        clientProxy.roomForIdentifierClosure = { _ in
            .joined(roomProxy)
        }
        
        try await process(route: .event(eventID: "2", roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators[0] is ThreadTimelineScreenCoordinator)
        
        // From the thread screen, navigate to another threaded event in the same room, and in the same thread.
        let threadCoordinator = navigationStackCoordinator.stackCoordinators[0] as? ThreadTimelineScreenCoordinator
        try await process(route: .childEvent(eventID: "3", roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        XCTAssert(navigationStackCoordinator.stackCoordinators[0] is ThreadTimelineScreenCoordinator)
        XCTAssertIdentical(navigationStackCoordinator.stackCoordinators[0], threadCoordinator)
        // Would be nice to test if the focusEvent function has been called but there is no way to mock that.
        
        // From the thread screen, navigate to another threaded event in the same room, but in a different thread.
        mockedEvent = TimelineEventSDKMock()
        mockedEvent.threadRootEventIdReturnValue = "4"
        roomProxy.loadOrFetchEventDetailsForReturnValue = .success(mockedEvent)
        try await process(route: .childEvent(eventID: "5", roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 2)
        XCTAssert(navigationStackCoordinator.stackCoordinators[0] is ThreadTimelineScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[1] is ThreadTimelineScreenCoordinator)
        
        // From the thread screen, navigate to another threaded event in a different room.
        configuration = JoinedRoomProxyMockConfiguration(id: "2")
        roomProxy = JoinedRoomProxyMock(configuration)
        
        roomInfoSubject = CurrentValueSubject<RoomInfoProxyProtocol, Never>(RoomInfoProxyMock(configuration))
        roomProxy.infoPublisher = roomInfoSubject.asCurrentValuePublisher()
        
        mockedEvent = TimelineEventSDKMock()
        mockedEvent.threadRootEventIdReturnValue = "1"
        roomProxy.loadOrFetchEventDetailsForReturnValue = .success(mockedEvent)
        
        clientProxy.roomForIdentifierClosure = { _ in
            .joined(roomProxy)
        }
        
        try await process(route: .childEvent(eventID: "2", roomID: "2", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 4)
        XCTAssert(navigationStackCoordinator.stackCoordinators[0] is ThreadTimelineScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[1] is ThreadTimelineScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[2] is RoomScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[3] is ThreadTimelineScreenCoordinator)
        
        // From the thread screen, navigate to an event of the same room that is not threaded
        mockedEvent = TimelineEventSDKMock()
        mockedEvent.threadRootEventIdReturnValue = nil
        roomProxy.loadOrFetchEventDetailsForReturnValue = .success(mockedEvent)
        
        try await process(route: .childEvent(eventID: "3", roomID: "2", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 5)
        XCTAssert(navigationStackCoordinator.stackCoordinators[0] is ThreadTimelineScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[1] is ThreadTimelineScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[2] is RoomScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[3] is ThreadTimelineScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators[4] is RoomScreenCoordinator)
    }
    
    func testShareMediaRoute() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        let sharePayload: ShareExtensionPayload = .mediaFiles(roomID: "1", mediaFiles: [.init(url: .picturesDirectory, suggestedName: nil)])
        try await process(route: .share(sharePayload))
        
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        XCTAssertTrue((navigationStackCoordinator.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is MediaUploadPreviewScreenCoordinator)
        
        try await process(route: .childRoom(roomID: "2", via: []))
        XCTAssertNil(navigationStackCoordinator.sheetCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        
        try await process(route: .share(sharePayload))
        
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        XCTAssertTrue((navigationStackCoordinator.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is MediaUploadPreviewScreenCoordinator)
    }
    
    func testShareTextRoute() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        let sharePayload: ShareExtensionPayload = .text(roomID: "1", text: "Important text")
        try await process(route: .share(sharePayload))
        
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        
        XCTAssertNil(navigationStackCoordinator.sheetCoordinator, "The media upload sheet shouldn't be shown when sharing text.")
        
        try await process(route: .childRoom(roomID: "2", via: []))
        XCTAssertNil(navigationStackCoordinator.sheetCoordinator)
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 1)
        
        try await process(route: .share(sharePayload))
        
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
        XCTAssertNil(navigationStackCoordinator.sheetCoordinator, "The media upload sheet shouldn't be shown when sharing text.")
    }
    
    func testLeavingRoom() async throws {
        setupRoomFlowCoordinator()
        
        var configuration = JoinedRoomProxyMockConfiguration()
        let roomProxy = JoinedRoomProxyMock(configuration)
        
        let roomInfoSubject = CurrentValueSubject<RoomInfoProxyProtocol, Never>(RoomInfoProxyMock(configuration))
        roomProxy.infoPublisher = roomInfoSubject.asCurrentValuePublisher()
        
        clientProxy.roomForIdentifierClosure = { _ in
            .joined(roomProxy)
        }
        
        try await process(route: .room(roomID: "1", via: []))
        
        let fulfillment = deferFulfillment(roomFlowCoordinator.actions) { action in
            action == .finished
        }
        
        configuration.membership = .left
        roomInfoSubject.send(RoomInfoProxyMock(configuration))
        
        try await fulfillment.fulfill()
    }
    
    // MARK: - STALK-951
    
    func testMemberLandingOnJoinScreenIsTakenToTheRoom() async throws {
        // Тап по пушу опередил синк: координатор и экран присоединения комнату не нашли,
        // а превью (from_known_room) уже знает, что мы участник закрытого чата.
        setupRoomFlowCoordinator()
        let resolve = clientProxy.roomForIdentifierClosure
        let attempts = ResolveAttempts()
        clientProxy.roomForIdentifierClosure = { roomID in
            guard await attempts.next() > 2 else { return nil }
            return await resolve?(roomID)
        }
        clientProxy.roomPreviewForIdentifierViaClosure = { roomID, _ in
            .success(RoomPreviewProxyMock(.init(roomID: roomID, membership: .joined, joinRule: .invite)))
        }
        
        try await process(route: .room(roomID: "1", via: []))
        
        try await waitUntil { self.navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator }
        XCTAssertEqual(navigationStackCoordinator.stackCoordinators.count, 0)
    }
    
    func testMemberWaitsOnJoinScreenUntilTheRoomSyncs() async throws {
        // Синк чат ещё не привёз: SDK отдаёт превью без членства. Экран не закрывается с
        // ошибкой и не пишет «нужно приглашение», а сам уводит в чат, когда комната приедет.
        setupRoomFlowCoordinator()
        let resolve = clientProxy.roomForIdentifierClosure
        let isSynced = SyncFlag()
        clientProxy.roomForIdentifierClosure = { roomID in
            await isSynced.value ? await resolve?(roomID) : nil
        }
        clientProxy.roomPreviewForIdentifierViaClosure = { roomID, _ in
            .success(RoomPreviewProxyMock(.init(roomID: roomID, membership: nil, joinRule: .invite)))
        }
        let roomList = CurrentValueSubject<[RoomSummary], Never>([])
        let staticProvider = RoomSummaryProviderMock(.init(state: .loaded([])))
        staticProvider.roomListPublisher = roomList.asCurrentValuePublisher()
        clientProxy.staticRoomSummaryProvider = staticProvider
        
        try await process(route: .room(roomID: "1", via: []))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssert(navigationStackCoordinator.rootCoordinator is JoinRoomScreenCoordinator)
        
        await isSynced.set()
        let room = RoomSDKMock()
        room.membershipReturnValue = .joined
        roomList.send([RoomSummary.mock(id: "1", name: "Никита Сокол").withRoom(room)])
        
        try await waitUntil { self.navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator }
    }
    
    func testLateJoinAfterLeavingTheJoinScreenIsIgnored() async throws {
        // Экран увидел комнату joined и отправил .joined, но пока координатор её собирал,
        // человек ушёл назад. Поздний неудачный ответ не должен показывать ошибку и
        // второй раз закрывать поток, которого уже нет.
        setupRoomFlowCoordinator()
        let resolve = clientProxy.roomForIdentifierClosure
        let attempts = ResolveAttempts()
        let gate = ResolveGate()
        clientProxy.roomForIdentifierClosure = { roomID in
            switch await attempts.next() {
            case 1: return nil
            case 2: return await resolve?(roomID)
            default:
                await gate.wait()
                return nil
            }
        }
        
        try await process(route: .room(roomID: "1", via: []))
        try await waitUntil { await gate.isWaiting }
        
        try await clearRoute(expectedActions: [.finished])
        let secondFinish = deferFailure(roomFlowCoordinator.actions, timeout: 1) { $0 == .finished }
        await gate.open()
        try await secondFinish.fulfill()
    }
    
    func testUnresolvableJoinedRoomDismissesTheFlow() async throws {
        // Экран увидел комнату joined, а координатор собрать её не смог — закрываемся с ошибкой.
        setupRoomFlowCoordinator()
        let resolve = clientProxy.roomForIdentifierClosure
        let attempts = ResolveAttempts()
        clientProxy.roomForIdentifierClosure = { roomID in
            await attempts.next() == 2 ? await resolve?(roomID) : nil
        }
        
        try await process(route: .room(roomID: "1", via: []), expectedActions: [.finished])
        XCTAssertNil(navigationStackCoordinator.rootCoordinator)
    }
    
    // MARK: - Spaces
    
    func testSpacePermalink() async throws {
        setupRoomFlowCoordinator()
        
        try await process(route: .room(roomID: "1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        
        try await process(route: .childRoom(roomID: "space1", via: []))
        XCTAssert(navigationStackCoordinator.rootCoordinator is RoomScreenCoordinator)
        XCTAssert(navigationStackCoordinator.stackCoordinators.first is SpaceScreenCoordinator)
    }
    
    // MARK: - Private
    
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition wasn't met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    
    private func process(route: AppRoute) async throws {
        roomFlowCoordinator.handleAppRoute(route, animated: true)
        // A single yield isn't enough when creating the new flow coordinator.
        try await Task.sleep(for: .milliseconds(100))
    }
    
    private func clearRoute(expectedActions: [RoomFlowCoordinatorAction]) async throws {
        try await processRouteOrClear(route: nil, expectedActions: expectedActions)
    }
    
    private func process(route: AppRoute, expectedActions: [RoomFlowCoordinatorAction]) async throws {
        try await processRouteOrClear(route: route, expectedActions: expectedActions)
    }
    
    private func processRouteOrClear(route: AppRoute?, expectedActions: [RoomFlowCoordinatorAction]) async throws {
        guard !expectedActions.isEmpty else {
            return
        }
        
        var fulfillments = [DeferredFulfillment<RoomFlowCoordinatorAction>]()
        
        for expectedAction in expectedActions {
            fulfillments.append(deferFulfillment(roomFlowCoordinator.actions) { action in
                action == expectedAction
            })
        }
        
        if let route {
            roomFlowCoordinator.handleAppRoute(route, animated: true)
        } else {
            roomFlowCoordinator.clearRoute(animated: true)
        }
        
        for fulfillment in fulfillments {
            try await fulfillment.fulfill()
        }
    }
    
    private func setupRoomFlowCoordinator(asChildFlow: Bool = false, roomType: RoomType? = nil) {
        cancellables.removeAll()
        clientProxy = ClientProxyMock(.init(userID: "hi@bob",
                                            roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms))),
                                            spaceServiceConfiguration: .populated))
        timelineControllerFactory = TimelineControllerFactoryMock(.init())
        
        clientProxy.roomPreviewForIdentifierViaClosure = { [roomType] roomID, _ in
            switch roomType {
            case .invited:
                return .success(RoomPreviewProxyMock.invited(roomID: roomID))
            default:
                fatalError("Something isn't set up right")
            }
        }
        
        let navigationSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: false))
        navigationStackCoordinator = NavigationStackCoordinator()
        navigationSplitCoordinator.setDetailCoordinator(navigationStackCoordinator)
        
        let roomID = switch roomType {
        case .invited(let roomID):
            roomID
        default:
            "1"
        }
        
        let flowParameters = CommonFlowParameters(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                  bugReportService: BugReportServiceMock(.init()),
                                                  elementCallService: ElementCallServiceMock(.init()),
                                                  timelineControllerFactory: timelineControllerFactory,
                                                  emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                                  linkMetadataProvider: LinkMetadataProvider(),
                                                  appMediator: AppMediatorMock.default,
                                                  appSettings: ServiceLocator.shared.settings,
                                                  appHooks: AppHooks(),
                                                  analytics: ServiceLocator.shared.analytics,
                                                  userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                  notificationManager: NotificationManagerMock(),
                                                  stateMachineFactory: StateMachineFactory())
        
        roomFlowCoordinator = RoomFlowCoordinator(roomID: roomID,
                                                  isChildFlow: asChildFlow,
                                                  navigationStackCoordinator: navigationStackCoordinator,
                                                  flowParameters: flowParameters)
    }
}

private enum RoomType {
    case invited(roomID: String)
}

private actor ResolveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    
    var isWaiting: Bool {
        continuation != nil
    }
    
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SyncFlag {
    private(set) var value = false
    
    func set() {
        value = true
    }
}

private extension RoomSummary {
    func withRoom(_ room: RoomSDKMock) -> RoomSummary {
        RoomSummary(room: room,
                    id: id,
                    joinRequestType: joinRequestType,
                    name: name,
                    isDirect: isDirect,
                    isSpace: isSpace,
                    avatarURL: avatarURL,
                    heroes: heroes,
                    activeMembersCount: activeMembersCount,
                    lastMessage: lastMessage,
                    lastMessageDate: lastMessageDate,
                    lastMessageState: lastMessageState,
                    unreadMessagesCount: unreadMessagesCount,
                    unreadMentionsCount: unreadMentionsCount,
                    unreadNotificationsCount: unreadNotificationsCount,
                    notificationMode: notificationMode,
                    canonicalAlias: canonicalAlias,
                    alternativeAliases: alternativeAliases,
                    hasOngoingCall: hasOngoingCall,
                    isMarkedUnread: isMarkedUnread,
                    isFavourite: isFavourite,
                    isTombstoned: isTombstoned)
    }
}

private actor ResolveAttempts {
    private var count = 0
    
    func next() -> Int {
        count += 1
        return count
    }
}
