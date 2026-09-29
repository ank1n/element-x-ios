//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import XCTest

@MainActor
class JoinRoomScreenViewModelTests: XCTestCase {
    private enum TestMode {
        case joined
        case knocked
        case invited
        case banned
    }
    
    var viewModel: JoinRoomScreenViewModelProtocol!
    /// Такт локальной проверки членства — в тестах подаём вручную (STMOB-308).
    private var membershipTicks: PassthroughSubject<Void, Never>!
    
    var clientProxy: ClientProxyMock!
    var appSettings: AppSettings!
    
    var context: JoinRoomScreenViewModelType.Context {
        viewModel.context
    }
    
    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        ServiceLocator.shared.register(appSettings: appSettings)
    }
    
    override func tearDown() {
        viewModel = nil
        clientProxy = nil
        AppSettings.resetAllSettings()
    }

    func testInteraction() async throws {
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "There shouldn't be any seen invites before running the tests.")
        
        setupViewModel()
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .joinable }.fulfill()
        
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "Only an invited room should register the room ID as a seen invite.")
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        context.send(viewAction: .join)
        try await deferred.fulfill()
    }
    
    func testAcceptInviteInteraction() async throws {
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "There shouldn't be any seen invites before running the tests.")
        
        setupViewModel(mode: .invited)
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .invited(isDM: false) }.fulfill()
        
        XCTAssertEqual(appSettings.seenInvites, ["1"], "The invited room's ID should be registered as a seen invite.")
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        context.send(viewAction: .acceptInvite)
        try await deferred.fulfill()
        
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "The after accepting an invite the invite should be forgotten in case the user leaves.")
    }
    
    func testDeclineInviteInteraction() async throws {
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "There shouldn't be any seen invites before running the tests.")
        
        setupViewModel(mode: .invited)
        
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .invited(isDM: false) }.fulfill()
        XCTAssertEqual(appSettings.seenInvites, ["1"], "The invited room's ID should be registered as a seen invite.")
        
        context.send(viewAction: .declineInvite)
        
        XCTAssertEqual(viewModel.context.alertInfo?.id, .declineInvite)
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .dismiss }
        context.alertInfo?.secondaryButton?.action?()
        try await deferred.fulfill()
        
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "The after declining an invite the invite should be forgotten in case another invite is received.")
    }
    
    func testKnockedState() async throws {
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "There shouldn't be any seen invites before running the tests.")
        setupViewModel(mode: .knocked)
        
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .knocked }.fulfill()
        
        XCTAssertTrue(appSettings.seenInvites.isEmpty, "Only an invited room should register the room ID as a seen invite.")
    }
    
    func testCancelKnock() async throws {
        setupViewModel(mode: .knocked)
        
        try await deferFulfillment(viewModel.context.$viewState) { state in
            state.mode == .knocked
        }.fulfill()
        
        context.send(viewAction: .cancelKnock)
        XCTAssertEqual(viewModel.context.alertInfo?.id, .cancelKnock)
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            action == .dismiss
        }
        context.alertInfo?.secondaryButton?.action?()
        try await deferred.fulfill()
    }
    
    func testDeclineAndBlockInviteLegacyInteraction() async throws {
        setupViewModel(mode: .invited)
        clientProxy.underlyingIsReportRoomSupported = false
        let expectation = expectation(description: "Wait for the user to be ignored")
        clientProxy.ignoreUserClosure = { userID in
            defer { expectation.fulfill() }
            XCTAssertEqual(userID, "@test:matrix.org")
            return .success(())
        }
        
        try await deferFulfillment(viewModel.context.$viewState) { $0.roomDetails != nil }.fulfill()
        
        context.send(viewAction: .declineInviteAndBlock(userID: "@test:matrix.org"))
        
        try await deferFulfillment(viewModel.context.$viewState) { $0.bindings.alertInfo != nil }.fulfill()
        XCTAssertEqual(viewModel.context.alertInfo?.id, .declineInviteAndBlock)
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            action == .dismiss
        }
        context.alertInfo?.secondaryButton?.action?()
        await fulfillment(of: [expectation], timeout: 10)
        try await deferred.fulfill()
    }
    
    func testDeclineAndBlockInviteInteraction() async throws {
        setupViewModel(mode: .invited)
        try await deferFulfillment(viewModel.context.$viewState) { $0.roomDetails != nil }.fulfill()
        let deferredAction = deferFulfillment(viewModel.actionsPublisher) { $0 == .presentDeclineAndBlock(userID: "@test:matrix.org") }
        context.send(viewAction: .declineInviteAndBlock(userID: "@test:matrix.org"))
        try await deferredAction.fulfill()
    }
    
    func testForgetRoom() async throws {
        setupViewModel(mode: .banned)
        
        try await deferFulfillment(viewModel.context.$viewState) { $0.roomDetails != nil }.fulfill()
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            action == .dismiss
        }
        context.send(viewAction: .forget)
        try await deferred.fulfill()
    }
    
    // MARK: - STALK-951: участник не застревает на экране присоединения
    
    func testJoinedPreviewTakesMemberToTheRoom() async throws {
        // Сценарий жалобы: при первом запросе комнаты в памяти SDK ещё нет, а к превью
        // (from_known_room) синк её уже привёз — мы участник закрытого чата.
        let attempts = ResolveAttempts()
        setupMemberViewModel(preview: .joinedInviteOnly) {
            await attempts.next() > 1 ? .joined(JoinedRoomProxyMock(.init(id: "1"))) : nil
        }
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        try await deferred.fulfill()
        
        XCTAssertNotEqual(context.viewState.mode, .inviteRequired)
    }
    
    func testUnknownMembershipOffersJoinButton() async throws {
        // Главный сценарий жалобы: синк чат ещё не привёз. Без комнаты в памяти SDK
        // выбрасывает из превью членство (room_preview.rs, cached_room == nil) — знаем
        // только правило «по приглашению». Это не повод писать «нужно приглашение».
        setupMemberViewModel(preview: .inviteRequired)
        
        let noJoin = deferFailure(viewModel.actionsPublisher, timeout: 1) { $0 == .joined(.roomID("1")) }
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .unknown }.fulfill()
        try await noJoin.fulfill()
    }
    
    /// Превью joined бывает, только когда комната есть в памяти SDK; nil от roomForIdentifier тогда
    /// значит, что собрать её не удалось. Пока SDK не подтвердил членство — кнопка входа; как только
    /// подтвердил — отдаём координатору: он попробует ещё раз, а не получится — покажет ошибку.
    func testJoinedPreviewWithUnbuildableRoomOffersJoinButtonThenHandsOver() async throws {
        setupMemberViewModel(preview: .joinedInviteOnly)
        
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .joinable }.fulfill()
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        setMembership(.joined)
        membershipTicks.send()
        try await deferred.fulfill()
    }
    
    func testStoppedScreenIgnoresLateRoomSync() async throws {
        let roomList = setupMemberViewModel(preview: .inviteRequired)
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .unknown }.fulfill()
        
        viewModel.stop()
        
        let noJoin = deferFailure(viewModel.actionsPublisher, timeout: 1) { $0 == .joined(.roomID("1")) }
        deliver(.joined, via: roomList)
        try await noJoin.fulfill()
    }
    
    func testJoinedPreviewWithStaleInviteWaitsForSync() async throws {
        // Приглашение приняли на другом устройстве: локально комната ещё «приглашение».
        let roomList = setupMemberViewModel(preview: .joinedInviteOnly) {
            let roomProxy = InvitedRoomProxyMock(.init())
            roomProxy.rejectInvitationReturnValue = .success(())
            return .invited(roomProxy)
        }
        
        let noJoin = deferFailure(viewModel.actionsPublisher, timeout: 1) { $0 == .joined(.roomID("1")) }
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .joinable }.fulfill()
        try await noJoin.fulfill()
        
        // Синк привёз вход — уводим в чат без нажатия.
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        deliver(.joined, via: roomList)
        try await deferred.fulfill()
    }
    
    func testLocallyJoinedRoomSkipsThePreview() async throws {
        setupMemberViewModel(preview: .inviteRequired) { .joined(JoinedRoomProxyMock(.init(id: "1"))) }
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        try await deferred.fulfill()
        // Даём загрузке экрана дойти до конца: без раннего выхода она запросила бы превью.
        try await Task.sleep(for: .milliseconds(200))
        
        XCTAssertFalse(clientProxy.roomPreviewForIdentifierViaCalled, "A joined room doesn't need a preview from the server.")
    }
    
    func testRoomArrivingAsJoinedTakesMemberToTheRoom() async throws {
        // Синк привёз комнату уже после того, как экран открылся.
        let roomList = setupMemberViewModel(preview: .inviteRequired)
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .unknown }.fulfill()
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        deliver(.joined, via: roomList)
        try await deferred.fulfill()
    }
    
    /// STMOB-308: комната с меткой «низкий приоритет» в отфильтрованный список не попадает —
    /// экран всё равно замечает вход по локальной проверке членства.
    func testMembershipChangeOutsideTheRoomListIsNoticed() async throws {
        setupMemberViewModel(preview: .inviteRequired)
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .unknown }.fulfill()
        
        let noJoin = deferFailure(viewModel.actionsPublisher, timeout: 0.5) { $0 == .joined(.roomID("1")) }
        setMembership(.joined)
        try await noJoin.fulfill()
        
        // Список не менялся — заметил такт локальной проверки.
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .joined(.roomID("1")) }
        membershipTicks.send()
        try await deferred.fulfill()
    }
    
    func testFormerMemberStillNeedsAnInvite() async throws {
        // Человек вышел из закрытой комнаты: SDK её знает, и превью несёт членство «left».
        let roomList = setupMemberViewModel(preview: RoomPreviewProxyMock(.init(membership: .left, joinRule: .invite))) { .left }
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .inviteRequired }.fulfill()
        
        let deferred = deferFailure(viewModel.actionsPublisher, timeout: 1) { $0 == .joined(.roomID("1")) }
        deliver(.left, via: roomList)
        try await deferred.fulfill()
        
        XCTAssertEqual(context.viewState.mode, .inviteRequired)
    }
    
    func testJoinIsReportedOnceWhenButtonFinishesFirst() async throws {
        try await assertJoinIsReportedOnce(roomListIsFirst: false)
    }
    
    func testJoinIsReportedOnceWhenRoomListIsFirst() async throws {
        try await assertJoinIsReportedOnce(roomListIsFirst: true)
    }
    
    // MARK: - Helpers
    
    /// Вход подтверждают и кнопка, и список комнат — в каком бы порядке они ни пришли,
    /// действие должно уйти одно.
    private func assertJoinIsReportedOnce(roomListIsFirst: Bool) async throws {
        let roomList = setupMemberViewModel(preview: .joinable)
        try await deferFulfillment(viewModel.context.$viewState) { $0.mode == .joinable }.fulfill()
        // Превью с алиасом — вход идёт через joinRoomAlias; подменяем оба пути входа.
        let join: () async -> Result<Void, ClientProxyError> = {
            self.deliver(.joined, via: roomList)
            if roomListIsFirst {
                // Даём наблюдателю списка комнат отработать раньше, чем вернётся вход.
                try? await Task.sleep(for: .milliseconds(200))
            }
            return .success(())
        }
        clientProxy.joinRoomViaClosure = { _, _ in await join() }
        clientProxy.joinRoomAliasClosure = { _ in await join() }
        
        var joinedActions = 0
        let cancellable = viewModel.actionsPublisher.sink { action in
            if action == .joined(.roomID("1")) {
                joinedActions += 1
            }
        }
        context.send(viewAction: .join)
        try await Task.sleep(for: .milliseconds(700))
        cancellable.cancel()
        
        XCTAssertTrue(clientProxy.joinRoomAliasCalled || clientProxy.joinRoomViaCalled, "The join button should have been processed.")
        XCTAssertEqual(joinedActions, 1)
    }
    
    /// Экран обычной комнаты «1»: превью, локальная комната и список комнат, в который тест
    /// может «довезти» комнату синком.
    @discardableResult
    private func setupMemberViewModel(preview: RoomPreviewProxyMock,
                                      room: @escaping () async -> RoomProxyType? = { nil }) -> CurrentValueSubject<[RoomSummary], Never> {
        clientProxy = ClientProxyMock(.init())
        clientProxy.joinRoomViaReturnValue = .success(())
        clientProxy.roomPreviewForIdentifierViaReturnValue = .success(preview)
        clientProxy.roomForIdentifierClosure = { _ in await room() }
        
        let roomList = CurrentValueSubject<[RoomSummary], Never>([])
        let provider = RoomSummaryProviderMock(.init(state: .loaded([])))
        provider.roomListPublisher = roomList.asCurrentValuePublisher()
        clientProxy.staticRoomSummaryProvider = provider
        
        membershipTicks = PassthroughSubject()
        viewModel = JoinRoomScreenViewModel(source: .generic(roomID: "1", via: []),
                                            appSettings: appSettings,
                                            userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                            userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                            membershipCheckTicks: membershipTicks.eraseToAnyPublisher())
        return roomList
    }
    
    /// Синк привёз комнату: SDK знает членство, список комнат изменился.
    private func deliver(_ membership: Membership, via roomList: CurrentValueSubject<[RoomSummary], Never>) {
        setMembership(membership)
        roomList.send([Self.roomSummary(membership: membership)])
    }
    
    /// Членство знает SDK только для нашей комнаты «1» — чужой id не должен сработать.
    private func setMembership(_ membership: Membership) {
        clientProxy.roomMembershipRoomIDClosure = { $0 == "1" ? membership : nil }
    }
    
    private static func roomSummary(membership: Membership) -> RoomSummary {
        let room = RoomSDKMock()
        room.membershipReturnValue = membership
        return RoomSummary(room: room,
                           id: "1",
                           joinRequestType: nil,
                           name: "Никита Сокол",
                           isDirect: true,
                           isSpace: false,
                           avatarURL: nil,
                           heroes: [],
                           activeMembersCount: 2,
                           lastMessage: nil,
                           lastMessageDate: nil,
                           lastMessageState: nil,
                           unreadMessagesCount: 0,
                           unreadMentionsCount: 0,
                           unreadNotificationsCount: 0,
                           notificationMode: .allMessages,
                           canonicalAlias: nil,
                           alternativeAliases: [],
                           hasOngoingCall: false,
                           isMarkedUnread: false,
                           isFavourite: false,
                           isTombstoned: false)
    }
    
    private func setupViewModel(throwing: Bool = false, mode: TestMode = .joined) {
        ServiceLocator.shared.settings.knockingEnabled = true
        
        clientProxy = ClientProxyMock(.init())
        
        clientProxy.joinRoomViaReturnValue = throwing ? .failure(.sdkError(ClientProxyMockError.generic)) : .success(())
        clientProxy.joinRoomAliasReturnValue = clientProxy.joinRoomViaReturnValue
        
        switch mode {
        case .knocked:
            clientProxy.roomPreviewForIdentifierViaReturnValue = .success(RoomPreviewProxyMock.knocked)
            
            clientProxy.roomForIdentifierClosure = { _ in
                let roomProxy = KnockedRoomProxyMock(.init())
                // to test the cancel knock function
                roomProxy.cancelKnockUnderlyingReturnValue = .success(())
                return .knocked(roomProxy)
            }
        case .joined:
            clientProxy.roomPreviewForIdentifierViaReturnValue = .success(RoomPreviewProxyMock.joinable)
        case .invited:
            clientProxy.roomPreviewForIdentifierViaReturnValue = .success(RoomPreviewProxyMock.invited())
            clientProxy.roomForIdentifierClosure = { _ in
                let roomProxy = InvitedRoomProxyMock(.init())
                roomProxy.rejectInvitationReturnValue = .success(())
                return .invited(roomProxy)
            }
        case .banned:
            clientProxy.roomPreviewForIdentifierViaReturnValue = .success(RoomPreviewProxyMock.banned)
            clientProxy.roomForIdentifierClosure = { _ in
                let roomProxy = BannedRoomProxyMock(.init())
                roomProxy.forgetRoomReturnValue = .success(())
                return .banned(roomProxy)
            }
        }
        
        viewModel = JoinRoomScreenViewModel(source: .generic(roomID: "1", via: []),
                                            appSettings: appSettings,
                                            userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                            userIndicatorController: ServiceLocator.shared.userIndicatorController)
    }
}

private extension RoomPreviewProxyMock {
    /// Закрытый чат, в котором мы, по словам сервера, уже участник.
    static var joinedInviteOnly: RoomPreviewProxyMock {
        .init(.init(membership: .joined, joinRule: .invite))
    }
}

private actor ResolveAttempts {
    private var count = 0
    
    func next() -> Int {
        count += 1
        return count
    }
}

extension JoinRoomScreenViewModelAction: @retroactive Equatable {
    /// A close enough approximation for tests.
    public static func == (lhs: JoinRoomScreenViewModelAction, rhs: JoinRoomScreenViewModelAction) -> Bool {
        switch (lhs, rhs) {
        case (.joined(.roomID(let lhsRoomID)), .joined(.roomID(let rhsRoomID))):
            lhsRoomID == rhsRoomID
        case (.joined(.space(let lhsSpace)), .joined(.space(let rhsSpace))):
            lhsSpace.id == rhsSpace.id
        case (.dismiss, .dismiss):
            true
        case (.presentDeclineAndBlock(let lhsUserID), .presentDeclineAndBlock(let rhsUserID)):
            lhsUserID == rhsUserID
        default:
            false
        }
    }
}
