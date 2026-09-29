//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import XCTest

/// STMOB-304: опрос присутствия — кого спрашиваем, как часто и что делаем с отказами сервера.
@MainActor
final class PresenceServiceTests: XCTestCase {
    private var clock: PresenceTestClock!
    private var transport: FakePresenceTransport!
    private var store: InMemoryForbiddenStore!
    private var token: String?
    private var refreshRequests = 0

    override func setUp() {
        clock = PresenceTestClock()
        transport = FakePresenceTransport()
        store = InMemoryForbiddenStore()
        token = "token-1"
        refreshRequests = 0
    }

    // MARK: - Кого спрашиваем

    func testPollsOnlyUsersSomeScreenIsShowing() async {
        let service = makeService()
        service.setInterest(["@a:x", "@b:x"], for: .chats)
        service.setInterest(["@c:x"], for: .room("!r:x"))

        await service.pollOnce()
        XCTAssertEqual(transport.requestedUserIDs, ["@a:x", "@b:x", "@c:x"])

        // Строки ушли с экрана — их больше не спрашиваем, собеседника открытой комнаты — да.
        service.removeInterest(for: .chats)
        transport.reset()
        clock.advance(by: PresenceService.offlineRefreshInterval)
        await service.pollOnce()
        XCTAssertEqual(transport.requestedUserIDs, ["@c:x"])
    }

    func testInterestIsReplacedWithinKeyAndMergedAcrossKeys() {
        let service = makeService()
        service.setInterest(["@a:x", "@b:x"], for: .contacts)
        service.setInterest(["@b:x", "@c:x"], for: .chats)
        service.setInterest(["@d:x"], for: .contacts)

        XCTAssertEqual(service.polledUserIDs, ["@b:x", "@c:x", "@d:x"])
    }

    /// STMOB-311: скрытая вкладка не опрашивается, а её набор строк помнится до возврата —
    /// вкладки рисуются все сразу, и onAppear при возврате не придёт.
    func testSuspendedInterestIsSkippedButRemembered() async {
        let service = makeService()
        service.setInterest(["@chat:x"], for: .chats)
        service.setInterest(["@contact:x"], for: .contacts)
        service.setSuspended(.chats, true)
        
        await service.pollOnce()
        XCTAssertEqual(transport.requestedUserIDs, ["@contact:x"])
        
        transport.reset()
        service.setSuspended(.chats, false)
        await service.pollOnce()
        XCTAssertEqual(transport.requestedUserIDs, ["@chat:x"])
    }
    
    func testOwnUserIsNeverPolled() async {
        let service = makeService()
        service.setInterest(["@me:x", "@a:x"], for: .chats)

        await service.pollOnce()

        XCTAssertEqual(transport.requestedUserIDs, ["@a:x"])
    }

    // MARK: - Как часто

    func testBudgetCapsBurstAndRate() async {
        let service = makeService()
        service.setInterest((0..<100).map { "@u\($0):x" }, for: .contacts)

        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, PresenceService.burst, "The first poll should be capped by the burst.")

        transport.reset()
        clock.advance(by: 10)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, Int(10 * PresenceService.refillPerSecond), "After the burst the rate is capped by the refill.")
    }

    func testNeverAskedUsersGoBeforeStaleOnes() async {
        let service = makeService()
        let first = (0..<PresenceService.burst).map { "@a\($0):x" }
        service.setInterest(first, for: .contacts)
        await service.pollOnce()

        // Все первые снова пора спросить, но бюджета на всех не хватит: новые, ещё ни разу
        // не спрошенные, идут первыми (по алфавиту они были бы последними).
        clock.advance(by: PresenceService.offlineRefreshInterval)
        service.setInterest(first + ["@new1:x", "@new2:x"], for: .contacts)
        transport.reset()
        await service.pollOnce()

        XCTAssertEqual(transport.requestCount, PresenceService.burst)
        XCTAssertTrue(transport.requestedUserIDs.isSuperset(of: ["@new1:x", "@new2:x"]))
    }

    func testConcurrencyIsLimited() async {
        let service = makeService()
        transport.delay = .milliseconds(20)
        service.setInterest((0..<PresenceService.burst).map { "@u\($0):x" }, for: .contacts)

        await service.pollOnce()

        XCTAssertEqual(transport.requestCount, PresenceService.burst)
        XCTAssertLessThanOrEqual(transport.maxConcurrent, PresenceService.maxConcurrent)
    }

    func testOfflineUsersAreAskedAtHalfTheOnlineWindow() async {
        let service = makeService()
        service.setInterest(["@a:x"], for: .chats)
        await service.pollOnce()

        transport.reset()
        clock.advance(by: PresenceService.offlineRefreshInterval - 1)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 0)

        clock.advance(by: 1)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testOnlineUsersAreRefreshedMoreOften() async {
        let service = makeService()
        transport.responses["@a:x"] = .ok(#"{"presence":"online","last_active_ago":1000}"#)
        service.setInterest(["@a:x"], for: .chats)
        await service.pollOnce()
        XCTAssertEqual(service.presenceSubject.value["@a:x"]?.isOnline(at: clock.now), true)

        transport.reset()
        clock.advance(by: PresenceService.onlineRefreshInterval)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testVisibleRowsGoBeforeTheBackgroundSweep() async {
        let service = makeService()
        service.setInterest((0..<40).map { "@partner\($0):x" }, for: .chatPartners)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, PresenceService.burst - PresenceService.backgroundReserve,
                       "The background never spends the reserve kept for visible rows.")

        // Новый экран видимых строк получает запросы сразу, хотя фоновые ещё ни разу не спрошены.
        transport.reset()
        let visible = (0..<PresenceService.backgroundReserve).map { "@visible\($0):x" }
        service.setInterest(visible, for: .chats)
        await service.pollOnce()
        XCTAssertEqual(transport.requestedUserIDs, Set(visible))
    }

    func testBackgroundSweepIsSlowEvenForOnlineUsers() async {
        let service = makeService()
        transport.responses["@partner:x"] = .ok(#"{"presence":"online","last_active_ago":1000}"#)
        service.setInterest(["@partner:x"], for: .chatPartners)
        await service.pollOnce()

        transport.reset()
        clock.advance(by: PresenceService.onlineRefreshInterval)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 0, "Background partners are refreshed at the slow pace only.")

        clock.advance(by: PresenceService.offlineRefreshInterval - PresenceService.onlineRefreshInterval)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 1)
    }

    // MARK: - Отказы сервера

    /// Собеседник нового личного чата ещё не принял приглашение — общей комнаты нет, 403.
    /// Через минуту он вступит: запоминать отказ на часы нельзя.
    func testForbiddenChatPartnerIsAskedAgainSoon() async {
        let service = makeService()
        transport.responses["@new:x"] = .status(403)
        service.setInterest(["@new:x"], for: .room("screen"))
        await service.pollOnce()

        transport.reset()
        transport.responses["@new:x"] = nil
        clock.advance(by: PresenceService.offlineRefreshInterval)
        await service.pollOnce()

        XCTAssertEqual(transport.requestedUserIDs, ["@new:x"])
        XCTAssertTrue(store.load().isEmpty, "A room partner's 403 is not persisted.")
    }

    /// Вкладка «Чаты» скрыта, но общая комната с человеком от этого не пропала: его 403 на часы
    /// не запоминаем, даже если спросили его из-за строки «Контактов».
    func testSuspendedChatsStillMakeTheUserRoomBacked() async {
        let service = makeService()
        transport.responses["@partner:x"] = .status(403)
        service.setInterest(["@partner:x"], for: .chats)
        service.setSuspended(.chats, true)
        service.setInterest(["@partner:x"], for: .contacts)
        
        await service.pollOnce()
        
        XCTAssertEqual(transport.requestedUserIDs, ["@partner:x"])
        XCTAssertTrue(store.load().isEmpty)
    }
    
    /// Человек из справочника получил 403 (общей комнаты не было), потом с ним завели личный чат:
    /// запомненный отказ больше не должен его прятать.
    func testCachedForbiddenIsIgnoredOnceThereIsASharedRoom() async {
        let service = makeService()
        transport.responses["@colleague:x"] = .status(403)
        service.setInterest(["@colleague:x"], for: .contacts)
        await service.pollOnce()
        XCTAssertFalse(store.load().isEmpty)

        transport.reset()
        transport.responses["@colleague:x"] = nil
        service.setInterest(["@colleague:x"], for: .room("screen"))
        clock.advance(by: PresenceService.offlineRefreshInterval)
        await service.pollOnce()

        XCTAssertEqual(transport.requestedUserIDs, ["@colleague:x"])
    }

    func testForbiddenUserIsSkippedEvenAfterRestart() async {
        let service = makeService()
        transport.responses["@stranger:x"] = .status(403)
        service.setInterest(["@stranger:x"], for: .contacts)
        await service.pollOnce()

        transport.reset()
        clock.advance(by: PresenceService.offlineRefreshInterval * 2)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 0, "A 403 means no shared room — don't ask again for hours.")

        // Новый запуск приложения: кэш 403 не теряется.
        let restarted = makeService()
        restarted.setInterest(["@stranger:x"], for: .contacts)
        await restarted.pollOnce()
        XCTAssertEqual(transport.requestCount, 0)

        clock.advance(by: PresenceService.forbiddenTTL)
        await restarted.pollOnce()
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testRateLimitPausesAllRequestsForTheServerDelay() async {
        let service = makeService()
        transport.responses["@a:x"] = .status(429, body: #"{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":8000}"#)
        service.setInterest(["@a:x"], for: .chats)
        service.setInterest(["@b:x"], for: .room("!r:x"))
        await service.pollOnce()

        transport.reset()
        transport.responses["@a:x"] = nil
        clock.advance(by: 7)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 0, "Nothing is sent until the server's retry_after_ms has passed.")

        clock.advance(by: 1)
        await service.pollOnce()
        XCTAssertGreaterThan(transport.requestCount, 0)
    }

    func testRateLimitStopsTheRestOfTheWave() async {
        let service = makeService()
        transport.responses = Dictionary(uniqueKeysWithValues: (0..<PresenceService.burst).map { ("@u\($0):x", FakePresenceTransport.Response.status(429)) })
        service.setInterest((0..<PresenceService.burst).map { "@u\($0):x" }, for: .contacts)

        await service.pollOnce()

        XCTAssertEqual(transport.requestCount, PresenceService.maxConcurrent, "Only the first chunk goes out, the rest waits for the backoff.")
    }

    func testUnauthorizedWaitsForANewToken() async {
        let service = makeService()
        transport.defaultResponse = .status(401)
        service.setInterest((0..<PresenceService.burst).map { "@u\($0):x" }, for: .contacts)

        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, PresenceService.maxConcurrent, "The wave stops at the first 401.")

        // Токен тот же — со старым токеном каждый запрос был бы тем же 401.
        transport.reset()
        transport.defaultResponse = .ok(#"{"presence":"offline"}"#)
        clock.advance(by: 10)
        await service.pollOnce()
        XCTAssertEqual(transport.requestCount, 0)

        token = "token-2"
        await service.pollOnce()
        XCTAssertGreaterThan(transport.requestCount, 0)
        XCTAssertTrue(transport.authorizations.allSatisfy { $0 == "Bearer token-2" })
        XCTAssertEqual(refreshRequests, 1, "One refresh request per rejected token, not per failed request.")
    }

    func testNetworkFailureIsRetriedOnTheNextStep() async {
        let service = makeService()
        transport.defaultResponse = .networkError
        service.setInterest(["@a:x"], for: .chats)
        await service.pollOnce()

        transport.reset()
        transport.defaultResponse = .ok(#"{"presence":"offline"}"#)
        clock.advance(by: PresenceService.tickInterval)
        await service.pollOnce()

        XCTAssertEqual(transport.requestedUserIDs, ["@a:x"], "A failed request doesn't count as an answer.")
    }

    // MARK: - Разбор и жизненный цикл

    func testParsingHonoursTheFiveMinuteRule() {
        let now = Date()
        let recent = PresenceService.parse(Data(#"{"presence":"online","last_active_ago":60000}"#.utf8), answeredAt: now)
        let stale = PresenceService.parse(Data(#"{"presence":"online","currently_active":true,"last_active_ago":1200000}"#.utf8), answeredAt: now)

        XCTAssertEqual(recent?.isOnline(at: now), true)
        XCTAssertEqual(stale?.isOnline(at: now), false)
        // Затухание локально: через пять минут точка гаснет без нового запроса.
        XCTAssertEqual(recent?.isOnline(at: now.addingTimeInterval(PresenceService.onlineWindow)), false)
    }

    func testStartedServiceIsReleasedWithItsSession() async throws {
        var service: PresenceService? = makeService()
        weak var weakService = service
        service?.start()
        // Цикл успел начаться и уснуть до следующего шага.
        try await Task.sleep(for: .milliseconds(50))

        service = nil
        await Task.yield()

        XCTAssertNil(weakService, "The polling loop must not keep the service alive after the session is gone.")
    }

    func testStopEndsPolling() {
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isPolling)

        service.stop()

        XCTAssertFalse(service.isPolling)
    }

    /// Уход в фон посреди волны: оставшиеся пачки не уходят в сеть.
    func testStopCancelsTheRestOfTheWave() async throws {
        let service = makeService()
        transport.delay = .milliseconds(200)
        service.start()
        service.setInterest((0..<PresenceService.burst).map { "@u\($0):x" }, for: .contacts)
        // Дожидаемся, пока первая пачка реально ушла в сеть.
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(transport.requestCount, 0, "The wave must have started for this test to mean anything.")

        service.stop()
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(transport.requestCount, PresenceService.maxConcurrent, "Only the chunk already in flight is sent.")
    }

    /// Опрос стоит (пауза после 429), новых ответов нет — но точка всё равно должна погаснуть.
    func testFadedDotIsRepublishedWhilePollingIsPaused() async {
        let service = makeService()
        transport.responses["@a:x"] = .ok(#"{"presence":"online","last_active_ago":1000}"#)
        service.setInterest(["@a:x"], for: .chats)
        await service.pollOnce()

        var emissions = 0
        let cancellable = service.presenceSubject.dropFirst().sink { _ in emissions += 1 }
        // Через 30 с — отказ по частоте, пауза до потолка отступа.
        transport.responses["@a:x"] = .status(429, body: #"{"retry_after_ms":600000}"#)
        clock.advance(by: PresenceService.onlineRefreshInterval)
        await service.pollOnce()
        XCTAssertEqual(emissions, 0)

        // Пауза ещё идёт, а пять минут с последней активности уже прошли.
        transport.reset()
        clock.advance(by: PresenceService.onlineWindow - PresenceService.onlineRefreshInterval)
        await service.pollOnce()
        cancellable.cancel()

        XCTAssertEqual(transport.requestCount, 0, "Polling is still paused.")
        XCTAssertEqual(emissions, 1)
        XCTAssertEqual(service.presenceSubject.value["@a:x"]?.isOnline(at: clock.now), false)
    }

    // MARK: - Helpers

    private func makeService() -> PresenceService {
        PresenceService(homeserver: "https://example.org/",
                        tokenProvider: { [unowned self] in token },
                        tokenRefresher: { [unowned self] in await MainActor.run { self.refreshRequests += 1 } },
                        ownUserID: "@me:x",
                        transport: transport,
                        forbiddenStore: store,
                        now: { [clock] in clock!.now })
    }
}

/// STMOB-304: правила отправки своего статуса.
@MainActor
final class OwnPresenceScheduleTests: XCTestCase {
    private let start = ContinuousClock.now
    private let token = "token-1"

    func testOnlineIsRepeatedBeforeSynapseDropsIt() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        XCTAssertEqual(schedule.nextAction(now: start, currentToken: token), .send(.online))

        schedule.record(.accepted, for: .online, sentAt: start, answeredAt: start)
        XCTAssertEqual(schedule.nextAction(now: start, currentToken: token), .wait(OwnPresenceSchedule.pingInterval))
        XCTAssertLessThan(OwnPresenceSchedule.pingInterval, 30, "Synapse drops a non-syncing client after 30 s.")
        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(OwnPresenceSchedule.pingInterval)), currentToken: token), .send(.online))
    }

    /// Следующий пинг считается от начала отправки, а не от ответа: иначе пауза на сервере росла бы
    /// на время каждого запроса.
    func testPingIsCountedFromTheStartOfTheSend() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        schedule.record(.accepted, for: .online, sentAt: start, answeredAt: start.advanced(by: .seconds(3)))

        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(OwnPresenceSchedule.pingInterval)), currentToken: token), .send(.online))
    }

    func testOtherStatusesAreSentOnce() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .unavailable
        schedule.record(.accepted, for: .unavailable, sentAt: start, answeredAt: start)

        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(600)), currentToken: token), .idle)
    }

    func testRateLimitWaitsForTheServerDelayInsteadOfDroppingTheStatus() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        schedule.record(.rateLimited(retryAfter: 7), for: .online, sentAt: start, answeredAt: start)

        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(3)), currentToken: token), .wait(4))
        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(7)), currentToken: token), .send(.online))
    }

    /// Лимит Synapse — один PUT в 10 с: смена статуса сразу после принятого PUT ждёт окна,
    /// а не получает гарантированный 429.
    func testStatusChangeWaitsForTheRateWindow() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        schedule.record(.accepted, for: .online, sentAt: start, answeredAt: start)

        schedule.desiredStatus = .unavailable
        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(1)), currentToken: token), .wait(OwnPresenceSchedule.minPutInterval - 1))
        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(OwnPresenceSchedule.minPutInterval)), currentToken: token), .send(.unavailable))
    }

    func testQuickFlapBackToOnlineSendsNothingNew() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        schedule.record(.accepted, for: .online, sentAt: start, answeredAt: start)

        // Неактивно → снова активно, пока «unavailable» ещё не ушёл.
        schedule.desiredStatus = .unavailable
        schedule.desiredStatus = .online

        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(2)), currentToken: token), .wait(OwnPresenceSchedule.pingInterval - 2))
    }

    /// Один сбой сети не должен ронять в offline: первый повтор быстрый, дальше — с ростом.
    func testFailuresAreRetriedQuicklyThenBackOff() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        var delays: [TimeInterval] = []
        var now = start
        for _ in 0..<5 {
            schedule.record(.failed, for: .online, sentAt: now, answeredAt: now)
            guard case .wait(let delay) = schedule.nextAction(now: now, currentToken: token) else {
                return XCTFail("Expected a wait after a failure")
            }
            delays.append(delay)
            now = now.advanced(by: .seconds(delay))
        }

        XCTAssertEqual(delays, [2, 4, 8, 10, 10])
    }

    func testUnauthorizedWaitsForANewToken() {
        var schedule = OwnPresenceSchedule()
        schedule.desiredStatus = .online
        schedule.record(.unauthorized(token: token), for: .online, sentAt: start, answeredAt: start)

        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(30)), currentToken: token), .wait(OwnPresenceSchedule.tokenCheckInterval))
        XCTAssertEqual(schedule.nextAction(now: start.advanced(by: .seconds(30)), currentToken: "token-2"), .send(.online))
    }

    func testRateLimitDelayIsReadFromTheBody() {
        let response = PresenceHTTPResponse(statusCode: 429,
                                            body: Data(#"{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":9500}"#.utf8),
                                            retryAfterHeader: nil)
        XCTAssertEqual(OwnPresenceManager.result(of: response, status: .online, token: token), .rateLimited(retryAfter: 9.5))
    }

    /// Кривой прокси: бесконечность ронила бы процесс в Duration/Int, сутки — гасили бы статус.
    func testAbsurdRetryAfterIsCappedOrIgnored() {
        let huge = PresenceHTTPResponse(statusCode: 429, body: Data(#"{"retry_after_ms":1e300}"#.utf8), retryAfterHeader: nil)
        let infinite = PresenceHTTPResponse(statusCode: 429, body: Data(), retryAfterHeader: "inf")
        let negative = PresenceHTTPResponse(statusCode: 429, body: Data(), retryAfterHeader: "-5")
        
        XCTAssertEqual(PresenceRequest.retryAfter(from: huge), PresenceRequest.maxRetryAfter)
        XCTAssertNil(PresenceRequest.retryAfter(from: infinite))
        XCTAssertNil(PresenceRequest.retryAfter(from: negative))
    }
    
    func testRateLimitDelayFallsBackToTheHeader() {
        let response = PresenceHTTPResponse(statusCode: 429, body: Data(), retryAfterHeader: "12")
        XCTAssertEqual(PresenceRequest.retryAfter(from: response), 12)
    }
}

/// STMOB-304: «Чаты» опрашивают собеседников видимых строк с запасом, а не весь список.
@MainActor
final class HomeScreenPresenceRowsTests: XCTestCase {
    private let rooms = (0..<50).map { _ in HomeScreenRoom.placeholder() }

    func testWithoutRangeTakesTheFirstScreen() {
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: rooms, visibleRange: nil).count, 20)
    }

    func testVisibleRangeIsWidenedByAMargin() {
        let rows = HomeScreenViewModel.presenceRows(in: rooms, visibleRange: 10..<15)
        XCTAssertEqual(rows.startIndex, 5)
        XCTAssertEqual(rows.endIndex, 20)
    }

    func testRangeIsClampedToTheList() {
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: rooms, visibleRange: 0..<3).startIndex, 0)
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: rooms, visibleRange: 45..<50).endIndex, 50)
        XCTAssertTrue(HomeScreenViewModel.presenceRows(in: [], visibleRange: nil).isEmpty)
    }

    /// Прокрутили длинный список, потом фильтр оставил 8 строк: экран диапазон уже не пришлёт.
    func testShortListAfterFilterIsPolledWhole() {
        let filtered = Array(rooms.prefix(8))
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: filtered, visibleRange: 30..<40).count, 8)
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: Array(rooms.prefix(7)), visibleRange: 10..<20).count, 7)
        // Диапазон внутри короткого списка: верхние строки на экране тоже нужны.
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: Array(rooms.prefix(12)), visibleRange: 10..<20).count, 12)
    }

    func testStaleRangeBeyondTheListFallsBackToTheFirstScreen() {
        XCTAssertEqual(HomeScreenViewModel.presenceRows(in: Array(rooms.prefix(30)), visibleRange: 40..<50).count, 20)
    }
}

// MARK: - Test doubles

final class PresenceTestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

final class InMemoryForbiddenStore: PresenceForbiddenStore {
    private var value: [String: Date] = [:]

    func load() -> [String: Date] {
        value
    }

    func save(_ forbiddenUntil: [String: Date]) {
        value = forbiddenUntil
    }
}

/// Отвечает по заранее заданным ответам и считает запросы. Вызывается из дочерних задач — под замком.
final class FakePresenceTransport: PresenceTransport, @unchecked Sendable {
    enum Response {
        case ok(String)
        case status(Int, body: String = "{}")
        case networkError
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _inFlight = 0
    private var _maxConcurrent = 0

    var responses: [String: Response] = [:]
    var defaultResponse: Response = .ok(#"{"presence":"offline","last_active_ago":3600000}"#)
    var delay: Duration?

    var requestCount: Int {
        lock.withLock { _requests.count }
    }

    var requestedUserIDs: Set<String> {
        Set(lock.withLock { _requests }.compactMap(Self.userID(of:)))
    }

    var authorizations: [String] {
        lock.withLock { _requests }.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
    }

    var maxConcurrent: Int {
        lock.withLock { _maxConcurrent }
    }

    func reset() {
        lock.withLock {
            _requests = []
            _maxConcurrent = 0
        }
    }

    func send(_ request: URLRequest) async throws -> PresenceHTTPResponse {
        let userID = Self.userID(of: request) ?? ""
        let response: Response = lock.withLock {
            _requests.append(request)
            _inFlight += 1
            _maxConcurrent = max(_maxConcurrent, _inFlight)
            return responses[userID] ?? defaultResponse
        }
        defer { lock.withLock { _inFlight -= 1 } }

        if let delay {
            try? await Task.sleep(for: delay)
        }

        switch response {
        case .ok(let body):
            return PresenceHTTPResponse(statusCode: 200, body: Data(body.utf8), retryAfterHeader: nil)
        case .status(let code, let body):
            return PresenceHTTPResponse(statusCode: code, body: Data(body.utf8), retryAfterHeader: nil)
        case .networkError:
            throw URLError(.notConnectedToInternet)
        }
    }

    private static func userID(of request: URLRequest) -> String? {
        guard let components = request.url?.pathComponents, components.count >= 2 else { return nil }
        return components[components.count - 2].removingPercentEncoding
    }
}
