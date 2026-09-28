//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import XCTest

@MainActor
class ContactsListScreenTests: XCTestCase {
    // MARK: - ContactFilter Tests

    func testContactFilterTitles() {
        XCTAssertEqual(ContactFilter.all.title, SL10n.contactsAll)
        XCTAssertEqual(ContactFilter.online.title, SL10n.contactsOnline)
        XCTAssertEqual(ContactFilter.favorites.title, SL10n.contactsFavorites)
    }

    func testContactFilterAllCases() {
        XCTAssertEqual(ContactFilter.allCases.count, 3)
    }

    // MARK: - ContactItem Tests

    func testContactItemIdentifiable() {
        let contact = makeContact(id: "test-1", name: "Alice")
        XCTAssertEqual(contact.id, "test-1")
        XCTAssertEqual(contact.displayName, "Alice")
    }

    func testContactItemEquality() {
        let a = makeContact(id: "1", name: "Alice")
        let b = makeContact(id: "1", name: "Alice")
        XCTAssertEqual(a, b)
    }

    func testContactItemInequality() {
        let a = makeContact(id: "1", name: "Alice")
        let b = makeContact(id: "2", name: "Bob")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - ContactsListScreenViewState Tests

    func testViewStateInitialValues() {
        let state = ContactsListScreenViewState()
        XCTAssertTrue(state.contacts.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.selectedFilter, .all)
        XCTAssertEqual(state.onlineCount, 0)
        XCTAssertEqual(state.favoritesCount, 0)
    }

    func testViewStateOnlineCount() {
        var state = ContactsListScreenViewState()
        state.contacts = [
            makeContact(id: "1", name: "Alice", isOnline: true),
            makeContact(id: "2", name: "Bob", isOnline: false),
            makeContact(id: "3", name: "Carol", isOnline: true)
        ]
        XCTAssertEqual(state.onlineCount, 2)
    }

    func testViewStateFavoritesCount() {
        var state = ContactsListScreenViewState()
        state.contacts = [
            makeContact(id: "1", name: "Alice", isFavorite: true),
            makeContact(id: "2", name: "Bob", isFavorite: false),
            makeContact(id: "3", name: "Carol", isFavorite: true),
            makeContact(id: "4", name: "Dave", isFavorite: true)
        ]
        XCTAssertEqual(state.favoritesCount, 3)
    }

    // MARK: - STMOB-303: сторож походов в справочник

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testGateAllowsOnlyOneFetchAtATime() {
        var gate = UserDirectoryFetchGate()
        XCTAssertTrue(gate.tryBegin(now: t0))
        XCTAssertFalse(gate.tryBegin(now: t0), "второй поход при незаконченном первом")
        XCTAssertFalse(gate.tryBegin(now: t0.addingTimeInterval(3600)), "незаконченный поход не отпускается по времени")
    }

    func testGateWaitsRefreshIntervalAfterSuccess() {
        var gate = UserDirectoryFetchGate()
        XCTAssertTrue(gate.tryBegin(now: t0))
        gate.finish(.success, now: t0)

        XCTAssertFalse(gate.tryBegin(now: t0.addingTimeInterval(gate.refreshInterval - 1)))
        XCTAssertTrue(gate.tryBegin(now: t0.addingTimeInterval(gate.refreshInterval)))
    }

    func testGateHonoursServerRetryAfter() {
        var gate = UserDirectoryFetchGate()
        XCTAssertTrue(gate.tryBegin(now: t0))
        gate.finish(.rateLimited(retryAfter: 30), now: t0)

        XCTAssertFalse(gate.tryBegin(now: t0.addingTimeInterval(29.9)))
        XCTAssertTrue(gate.tryBegin(now: t0.addingTimeInterval(30)))
    }

    func testGateBacksOffExponentiallyFromOneSecond() {
        var gate = UserDirectoryFetchGate()
        var now = t0
        for expected in [1.0, 2, 4, 8, 16] {
            XCTAssertTrue(gate.tryBegin(now: now))
            gate.finish(.failed, now: now)
            XCTAssertEqual(gate.nextAllowed.timeIntervalSince(now), expected, accuracy: 0.001)
            now = gate.nextAllowed
        }
    }

    func testGateKeepsOwnBackoffWhenServerAsksForLess() {
        var gate = UserDirectoryFetchGate()
        var now = t0
        for _ in 0..<3 {
            XCTAssertTrue(gate.tryBegin(now: now))
            gate.finish(.failed, now: now)
            now = gate.nextAllowed
        }
        // Четвёртый отказ: свой отступ уже 8 с, сервер просит 1 с — ждём 8.
        XCTAssertTrue(gate.tryBegin(now: now))
        gate.finish(.rateLimited(retryAfter: 1), now: now)
        XCTAssertEqual(gate.nextAllowed.timeIntervalSince(now), 8, accuracy: 0.001)
    }

    func testGateBackoffIsCapped() {
        var gate = UserDirectoryFetchGate()
        var now = t0
        for _ in 0..<64 {
            XCTAssertTrue(gate.tryBegin(now: now))
            gate.finish(.failed, now: now)
            XCTAssertLessThanOrEqual(gate.nextAllowed.timeIntervalSince(now), gate.maxBackoff)
            now = gate.nextAllowed
        }
    }

    func testGateResetsBackoffAfterSuccess() {
        var gate = UserDirectoryFetchGate()
        var now = t0
        for _ in 0..<4 {
            XCTAssertTrue(gate.tryBegin(now: now))
            gate.finish(.failed, now: now)
            now = gate.nextAllowed
        }
        XCTAssertTrue(gate.tryBegin(now: now))
        gate.finish(.success, now: now)
        now = gate.nextAllowed

        XCTAssertTrue(gate.tryBegin(now: now))
        gate.finish(.failed, now: now)
        XCTAssertEqual(gate.nextAllowed.timeIntervalSince(now), 1, accuracy: 0.001, "после удачи отступ снова с секунды")
    }

    // MARK: - STMOB-303: распознавание отказа по частоте

    /// Так SDK 26.06.03 отдаёт 429 у поиска по справочнику: Client::search_users возвращает
    /// голый HttpError, и FFI превращает его в ClientError.Generic с текстом. Первая версия
    /// правки ждала MatrixApi(.limitExceeded) и на проде 429 не узнавала.
    func testRateLimitIsReadFromGenericSDKError() {
        let error = Self.sdkRateLimited(retryAfter: "Delay(10s)")
        XCTAssertTrue(error.isRateLimited)
        XCTAssertEqual(error.retryAfter, 10)
        XCTAssertEqual(UserDirectoryFetchGate.Outcome(error), .rateLimited(retryAfter: 10))
    }

    func testRateLimitIsReadFromMatrixApiError() {
        // Другие вызовы идут через matrix_sdk::Error и дают MatrixApi — их тоже узнаём.
        let error = ClientProxyError.sdkError(ClientError.MatrixApi(kind: .limitExceeded(retryAfterMs: 2500),
                                                                    code: "M_LIMIT_EXCEEDED",
                                                                    msg: "Too Many Requests",
                                                                    details: nil))
        XCTAssertTrue(error.isRateLimited)
        XCTAssertEqual(error.retryAfter, 2.5)
    }

    func testRateLimitWithoutDeadline() {
        XCTAssertEqual(UserDirectoryFetchGate.Outcome(Self.sdkRateLimited(retryAfter: nil)), .rateLimited(retryAfter: nil))
        XCTAssertEqual(UserDirectoryFetchGate.Outcome(.httpError(status: 429, body: "")), .rateLimited(retryAfter: nil))
    }

    func testRetryDelayIsParsedFromRumaDebugText() {
        XCTAssertEqual(ClientProxyError.retryDelay(inDebugDescription: "retry_after: Some(Delay(10s))"), 10)
        XCTAssertEqual(ClientProxyError.retryDelay(inDebugDescription: "retry_after: Some(Delay(1.5s))"), 1.5)
        XCTAssertEqual(ClientProxyError.retryDelay(inDebugDescription: "retry_after: Some(Delay(500ms))"), 0.5)
        XCTAssertNil(ClientProxyError.retryDelay(inDebugDescription: "retry_after: Some(DateTime(SystemTime { tv_sec: 1 }))"))
        XCTAssertNil(ClientProxyError.retryDelay(inDebugDescription: "retry_after: None"))
    }

    func testOtherErrorsAreNotRateLimited() {
        let errors: [ClientProxyError] = [
            .sdkError(ClientError.Generic(msg: "error sending request", details: "Reqwest(reqwest::Error { kind: Request })")),
            .sdkError(ClientError.Generic(msg: "the server returned an error: [500 / M_UNKNOWN] boom", details: nil)),
            .sdkError(ClientError.MatrixApi(kind: .forbidden, code: "M_FORBIDDEN", msg: "", details: nil)),
            .httpError(status: 500, body: ""),
            .forbiddenAccess
        ]
        for error in errors {
            XCTAssertFalse(error.isRateLimited, "\(error)")
            XCTAssertNil(error.retryAfter, "\(error)")
            XCTAssertEqual(UserDirectoryFetchGate.Outcome(error), .failed, "\(error)")
        }
    }

    func testGateCapsServerRetryAfter() {
        var gate = UserDirectoryFetchGate()
        XCTAssertTrue(gate.tryBegin(now: t0))
        gate.finish(.rateLimited(retryAfter: 24 * 3600), now: t0)
        XCTAssertEqual(gate.nextAllowed.timeIntervalSince(t0), gate.maxBackoff, accuracy: 0.001)
    }

    // MARK: - STMOB-303: модель «Контактов» целиком

    /// Пятьдесят изменений списка комнат подряд — один поход в справочник, а не пятьдесят.
    func testRoomListChangesTriggerSingleDirectoryFetch() async throws {
        let harness = makeHarness { _, _ in .success(.init(results: [.mockAlice], limited: false)) }
        for _ in 0..<50 {
            harness.roomList.send([])
        }
        try await settle()

        XCTAssertEqual(harness.searches, [""], "на удачный пустой поиск перебор букв не нужен")
        XCTAssertTrue(harness.contactIDs.contains(UserProfileProxy.mockAlice.userID))
    }

    /// Отказ 429 на пустом поиске больше не запускает перебор алфавита.
    func testRateLimitOnEmptySearchStopsWithoutLetterFallback() async throws {
        let harness = makeHarness { _, _ in .failure(Self.sdkRateLimited(retryAfter: "Delay(5s)")) }
        for _ in 0..<50 {
            harness.roomList.send([])
        }
        try await settle()

        XCTAssertEqual(harness.searches, [""], "было: 1 отказ → 27 запросов, каждый тоже 429")
    }

    /// Перебор букв обрывается на первом отказе, а собранное до отказа попадает в список.
    func testLetterFallbackStopsAtFirstRateLimit() async throws {
        let harness = makeHarness { term, _ in
            switch term {
            case "": .success(.init(results: [], limited: false))
            case "a", "b": .success(.init(results: [.mockAlice], limited: false))
            default: .failure(Self.sdkRateLimited(retryAfter: nil))
            }
        }
        for _ in 0..<50 {
            harness.roomList.send([])
        }
        try await settle()

        XCTAssertEqual(harness.searches, ["", "a", "b", "c"])
        XCTAssertTrue(harness.contactIDs.contains(UserProfileProxy.mockAlice.userID), "успевшее до отказа не теряется")
    }

    /// Пустой поиск удачен, но пуст — перебор букв один раз, без повторов на новых изменениях.
    func testLetterFallbackRunsOncePerRefreshInterval() async throws {
        let harness = makeHarness { _, _ in .success(.init(results: [], limited: false)) }
        for _ in 0..<50 {
            harness.roomList.send([])
        }
        try await settle()

        XCTAssertEqual(harness.searches.count, 27, "пустой поиск и 26 букв — ровно один раз")
    }

    /// Регрессия первой версии правки: собеседник с личным чатом пропадал из «Контактов» на
    /// десять минут, стоило чату исчезнуть из списка комнат (поиск или фильтр в «Чатах»
    /// сужают тот же общий список). Теперь он остаётся справочной записью сразу и без сети.
    func testContactStaysWhenItsDirectRoomLeavesRoomList() async throws {
        let harness = makeHarness { _, _ in .success(.init(results: [.mockBob], limited: false)) }
        let bob = UserProfileProxy.mockBob
        harness.roomList.send([Self.directRoom(with: bob)])
        try await settle()

        XCTAssertEqual(harness.contacts.filter { $0.matrixUserID == bob.userID }.map(\.id), [Self.directRoomID(bob)],
                       "пока чат в списке — одна запись, из комнаты, без справочного дубля")

        harness.roomList.send([]) // «Чаты» отфильтровали список, личного чата в нём больше нет
        try await settle()

        XCTAssertEqual(harness.contacts.filter { $0.matrixUserID == bob.userID }.map(\.id), [bob.userID],
                       "человек остался — справочной записью")
        XCTAssertEqual(harness.searches, [""], "и для этого не понадобилось снова идти в сеть")
    }

    /// После неудачи повтор приходит сам, даже если в комнатах ничего не меняется —
    /// иначе у нового сотрудника без чатов «Контакты» остались бы пустыми до перезапуска.
    func testFailedFetchIsRetriedWithoutRoomListChanges() async throws {
        var attempt = 0
        let harness = makeHarness { _, _ in
            attempt += 1
            return attempt == 1 ? .failure(.sdkError(ClientError.Generic(msg: "timeout", details: nil)))
                : .success(.init(results: [.mockAlice], limited: false))
        }
        try await settle()
        XCTAssertEqual(harness.searches, [""])

        harness.clock.now = t0.addingTimeInterval(5) // отступ после первой неудачи — 1 с
        try await Task.sleep(for: .milliseconds(1500))

        XCTAssertEqual(harness.searches, ["", ""], "второй поход без единого изменения списка комнат")
        XCTAssertTrue(harness.contactIDs.contains(UserProfileProxy.mockAlice.userID))
    }

    // MARK: - Helpers

    private final class TestClock {
        var now: Date
        init(_ now: Date) {
            self.now = now
        }
    }

    @MainActor private struct Harness {
        let viewModel: ContactsListScreenViewModel
        let roomList: CurrentValueSubject<[RoomSummary], Never>
        let recorder: SearchRecorder
        let clock: TestClock
        var searches: [String] {
            recorder.terms
        }

        var contacts: [ContactItem] {
            viewModel.context.viewState.contacts
        }

        var contactIDs: Set<String> {
            Set(contacts.map(\.id))
        }
    }

    private final class SearchRecorder {
        var terms: [String] = []
    }

    /// Точная форма отказа 429 от SDK для поиска по справочнику (см. ClientProxyError.isRateLimited).
    private static func sdkRateLimited(retryAfter: String?) -> ClientProxyError {
        let retry = retryAfter.map { "Some(\($0))" } ?? "None"
        return .sdkError(ClientError.Generic(msg: "the server returned an error: [429 / M_LIMIT_EXCEEDED] Too Many Requests",
                                             details: "Api(Server(ClientApi(Error { status_code: 429, body: Standard(StandardErrorBody { kind: LimitExceeded(LimitExceededErrorData { retry_after: \(retry) }), message: \"Too Many Requests\" }) })))"))
    }

    private static func directRoomID(_ user: UserProfileProxy) -> String {
        "!dm-\(user.userID)"
    }

    private static func directRoom(with user: UserProfileProxy) -> RoomSummary {
        RoomSummary(room: RoomSDKMock(),
                    id: directRoomID(user),
                    joinRequestType: nil,
                    name: user.displayName ?? user.userID,
                    isDirect: true,
                    isSpace: false,
                    avatarURL: nil,
                    heroes: [user],
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

    private func makeHarness(search: @escaping (String, UInt) -> Result<SearchUsersResultsProxy, ClientProxyError>) -> Harness {
        let roomList = CurrentValueSubject<[RoomSummary], Never>([])
        let provider = RoomSummaryProviderMock(.init(state: .loaded([])))
        provider.roomListPublisher = roomList.asCurrentValuePublisher()

        let recorder = SearchRecorder()
        // Уникальный пользователь на каждый тест: кэш контактов лежит в UserDefaults по userID,
        // и чужой кэш подмешал бы в проверку записи из прошлого теста.
        let userID = "@me-\(UUID().uuidString):example.com"
        let clientProxy = ClientProxyMock(.init(userID: userID, roomSummaryProvider: provider))
        clientProxy.searchUsersSearchTermLimitClosure = { term, limit in
            await MainActor.run { recorder.terms.append(term) }
            return await MainActor.run { search(term, limit) }
        }

        // Часы стоят, пока тест их не передвинет: всё, что сторож не пустил сейчас,
        // само по себе не пустит.
        let clock = TestClock(t0)
        let viewModel = ContactsListScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                    now: { clock.now })
        return Harness(viewModel: viewModel, roomList: roomList, recorder: recorder, clock: clock)
    }

    /// Даём отработать переходам на главную очередь и асинхронным походам.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func makeContact(id: String,
                             name: String,
                             isOnline: Bool = false,
                             isFavorite: Bool = false) -> ContactItem {
        ContactItem(id: id,
                    displayName: name,
                    avatarURL: nil,
                    matrixUserID: "@\(name.lowercased()):example.com",
                    isOnline: isOnline,
                    lastSeenDate: nil,
                    isFavorite: isFavorite)
    }
}
