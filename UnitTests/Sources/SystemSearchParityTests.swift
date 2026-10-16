// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Combine
@testable import ElementX
import Foundation
import XCTest

@MainActor
final class SystemSearchParityTests: XCTestCase {
    private var domains: [String] = []
    private var sessions: [URLSession] = []

    override func tearDown() {
        sessions.forEach { $0.invalidateAndCancel() }
        domains.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        sessions = []; domains = []
        super.tearDown()
    }

    private func plan(_ overrides: [String: Any] = [:]) throws -> String {
        var object: [String: Any] = ["q": "", "types": [], "has": [], "expand": [], "unsupported": []]
        object.merge(overrides) { _, new in new }
        return try String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchParityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        return session
    }

    private func client() -> ClientProxyMock {
        ClientProxyMock(.init(homeserver: "https://search-parity.invalid", userID: "@me:example.org"))
    }

    private func model(planner: @escaping @MainActor (SystemSearchConditions) async throws -> SystemSearchConditions) -> SystemSearchViewModel {
        let domain = "SystemSearchParityTests.\(UUID().uuidString)"
        domains.append(domain)
        return SystemSearchViewModel(client: client(), session: session(), defaults: UserDefaults(suiteName: domain)!, planner: planner)
    }

    func testFilterOnlyPlanSendsEmptyQueryAndInclusiveDateRange() throws {
        var original = SystemSearchConditions()
        original.query = "презентации за прошлую неделю"
        let decoded = try SystemSearchService.decodePlan(plan(["format": "presentation", "from": "2026-10-05", "to": "2026-10-11"]), preserving: original)
        XCTAssertTrue(decoded.canSearch)
        XCTAssertEqual(decoded.query, original.query)
        XCTAssertEqual(decoded.topic, "")
        let items = try decoded.queryItems()
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "")
        XCTAssertEqual(items.first { $0.name == "format" }?.value, "presentation")
        let iso = ISO8601DateFormatter()
        let upper = try XCTUnwrap(items.first { $0.name == "to" }?.value.flatMap(iso.date(from:)))
        XCTAssertEqual(Calendar.current.component(.day, from: upper), 12)
    }

    func testEverySupportedFilterCanEnableAnEmptyTopicSearch() throws {
        let plans: [[String: Any]] = [["types": ["attachment"]], ["format": "pdf"], ["has": ["email"]], ["from": "2026-10-01"], ["to": "2026-10-16"]]
        for value in plans {
            let decoded = try SystemSearchService.decodePlan(plan(value), preserving: .init())
            XCTAssertTrue(decoded.canSearch, "\(value)")
            XCTAssertNoThrow(try decoded.queryItems())
        }
        XCTAssertThrowsError(try SystemSearchService.decodePlan(plan(), preserving: .init()))
    }

    func testUnsupportedConditionsDisclosedWhileManualFiltersWin() throws {
        var original = SystemSearchConditions()
        original.query = "найди отчёт"
        original.types = ["message"]; original.period = "month"; original.roomIds = ["!manual:example.org"]
        original.sender = "@manual:example.org"; original.senderName = "Выбранный человек"
        original.format = "pdf"; original.sort = "newest"; original.has = ["email"]
        let decoded = try SystemSearchService.decodePlan(plan(["q": "отчёт", "types": ["attachment"], "format": "document", "from": "2026-01-01", "unsupported": ["owner", "status"]]), preserving: original)
        XCTAssertEqual(decoded.types, original.types)
        XCTAssertEqual(decoded.period, original.period)
        XCTAssertEqual(decoded.roomIds, original.roomIds)
        XCTAssertEqual(decoded.sender, original.sender)
        XCTAssertEqual(decoded.senderName, original.senderName)
        XCTAssertEqual(decoded.format, original.format)
        XCTAssertEqual(decoded.sort, original.sort)
        XCTAssertEqual(decoded.has, original.has)
        XCTAssertEqual(Set(decoded.unsupported ?? []), ["owner", "status"])
    }

    func testRejectsMalformedRestrictionsEvenWhenManualFilterWouldOverrideThem() throws {
        var original = SystemSearchConditions(); original.query = "отчёт"; original.format = "pdf"; original.period = "week"
        let invalid: [[String: Any]] = [
            ["q": "отчёт", "format": "executable"], ["q": "отчёт", "format": 12],
            ["q": "отчёт", "sort": "oldest"], ["q": "отчёт", "from": "2026-02-30"],
            ["q": "отчёт", "from": "2026-10-10", "to": "2026-10-01"],
            ["q": "отчёт", "room": 123], ["q": "отчёт", "unsupported": ["invented"]],
            ["q": "отчёт", "types": ["task"], "sender": "Иван"],
            ["q": "отчёт", "expand": ["one", "two", "three"]], ["q": "отчёт", "unknown": true]
        ]
        for value in invalid {
            XCTAssertThrowsError(try SystemSearchService.decodePlan(plan(value), preserving: original), "\(value)")
        }
    }

    func testAcceptsSingleJSONFenceButRejectsProse() throws {
        let raw = try plan(["q": "отчёт"])
        XCTAssertEqual(try SystemSearchService.decodePlan("```json\n\(raw)\n```", preserving: .init()).topic, "отчёт")
        XCTAssertThrowsError(try SystemSearchService.decodePlan("Ответ: " + raw, preserving: .init()))
    }

    func testSenderMergeRetainsAliasesAndPrefersCurrentContactName() {
        let merged = SystemSearchPerson.merge([
            .init(id: "@petr:example.org", name: "Пётр Старый"),
            .init(id: "@petr:example.org", name: "Пётр Новый"),
            .init(id: "invalid", name: "Нельзя выбрать")
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.name, "Пётр Новый")
        XCTAssertTrue(merged[0].matchesSender("стар"))
        XCTAssertTrue(merged[0].matchesSender("петр нов"))
    }

    func testLimitedMissingAndMalformedDirectoryResponsesStayIncomplete() throws {
        for raw in [
            #"{"results":[{"user_id":"@petr:example.org","display_name":"Пётр"}],"limited":true}"#,
            #"{"results":[]}"#,
            #"{"results":[],"limited":0}"#,
            #"{"results":[{"user_id":"bad"}],"limited":false}"#
        ] {
            let result = try SystemSearchService.decodeDirectory(Data(raw.utf8), key: "results")
            XCTAssertFalse(result.complete)
            XCTAssertNotNil(SystemSearchViewModel.directoryNotice(result))
        }
        let result = try SystemSearchService.decodeDirectory(Data(#"{"results":[],"limited":false}"#.utf8), key: "results")
        XCTAssertTrue(result.complete)
    }

    func testLookupMergesOrganizationAndDirectoryAndRetainsOldName() async {
        let service = SystemSearchService(client: client(), session: session())
        let result = await service.lookupSenders(query: "петр")
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.contactsAvailable)
        XCTAssertEqual(result.people.filter { $0.id == "@petr:example.org" }.count, 1)
        let person = result.people.first { $0.id == "@petr:example.org" }
        XCTAssertEqual(person?.name, "Пётр Новый")
        XCTAssertTrue(person?.matchesSender("старый") == true)
        XCTAssertTrue(result.people.contains { $0.id == "@anna:example.org" })
    }

    func testPeopleMatchingIgnoresHomeserverAndSupportsShortPrefixesAndWordOrder() {
        let person = SystemSearchPerson(id: "@ivan:stalk.implica.ru", name: "Иван Петров")
        XCTAssertFalse(person.matchesPeople("implica"))
        XCTAssertFalse(person.matchesPeople("stalk"))
        XCTAssertFalse(person.matchesPeople("ан"))
        XCTAssertTrue(person.matchesPeople("ив"))
        XCTAssertTrue(person.matchesPeople("петров иван"))
        XCTAssertTrue(person.matchesPeople("@ivan:stalk"))
        XCTAssertFalse(SystemSearchPerson(id: person.id, name: person.id).matchesPeople("implica"))
    }

    func testPeopleTargetsUseProfileUnlessAnExistingDMIsAvailable() throws {
        var person = SystemSearchPerson(id: "@petr:example.org", name: "Пётр")
        XCTAssertEqual(person.target.kind, "user")
        XCTAssertEqual(person.target.user_id, person.id)
        person.dmRoomID = "!dm:example.org"
        XCTAssertEqual(person.target.kind, "room")
        XCTAssertEqual(person.target.room_id, person.dmRoomID)
        let legacy = try JSONDecoder().decode(SystemSearchTarget.self, from: Data(#"{"kind":"room","room_id":"!old:example.org"}"#.utf8))
        XCTAssertNil(legacy.user_id)
        XCTAssertNil(SystemSearchTarget(kind: "room").user_id)
    }

    private func hit(type: String, meta: String = "{}") throws -> SystemSearchHit {
        try JSONDecoder().decode(SystemSearchHit.self, from: Data("{\"id\":1,\"entity_id\":\"entity\",\"entity_type\":\"\(type)\",\"meta\":\(meta)}".utf8))
    }

    func testBadgesFollowEntityTypeAndTolerateOlderServers() throws {
        XCTAssertEqual(try hit(type: "task", meta: #"{"intake":true,"archived":true}"#).badges, [NSLocalizedString("Intake", comment: "Badge"), NSLocalizedString("В архиве", comment: "Badge")])
        XCTAssertEqual(try hit(type: "comment", meta: #"{"archived":true}"#).badges, [NSLocalizedString("В архиве", comment: "Badge")])
        XCTAssertEqual(try hit(type: "meeting", meta: #"{"series_collapsed":4}"#).badges, [String(format: NSLocalizedString("stalk_search_series_remaining", comment: "Series count"), Int64(4))])
        XCTAssertTrue(try hit(type: "message", meta: #"{"intake":true,"series_collapsed":4}"#).badges.isEmpty)
        XCTAssertTrue(try hit(type: "task").badges.isEmpty)
    }

    func testMalformedBadgeFieldsCannotBreakSearchOrInventMarks() throws {
        XCTAssertTrue(try hit(type: "task", meta: #"{"intake":"true","archived":1}"#).badges.isEmpty)
        for value in ["0", "-1", "1.5", "true", "\"4\""] {
            XCTAssertTrue(try hit(type: "meeting", meta: "{\"series_collapsed\":\(value)}").badges.isEmpty)
        }
    }

    func testSmartSearchShowsPreliminaryResultsThenFallsBackWithoutLosingFilters() async throws {
        let gate = SearchParityPlannerGate()
        let model = model { _ in try await gate.wait() }
        model.conditions.query = "исходная фраза"
        model.conditions.types = ["message"]; model.conditions.sender = "@manual:example.org"
        model.conditions.roomIds = ["!manual:example.org"]; model.conditions.format = "pdf"; model.conditions.period = "week"
        let original = model.conditions
        let preliminary = expectation(description: "Lexical results visible before planner finishes")
        let fallback = expectation(description: "Automatic fallback notice")
        var subscriptions: Set<AnyCancellable> = []
        model.$hits.filter { !$0.isEmpty }.prefix(1).sink { _ in preliminary.fulfill() }.store(in: &subscriptions)
        model.$notice.compactMap { $0 }.filter { $0.contains(NSLocalizedString("Не удалось уточнить запрос через Айлок. Показаны результаты по исходной фразе; ваши фильтры сохранены.", comment: "Fallback notice")) }.prefix(1).sink { _ in fallback.fulfill() }.store(in: &subscriptions)
        model.search(smart: true)
        await fulfillment(of: [preliminary], timeout: 2)
        XCTAssertTrue(model.loading)
        XCTAssertEqual(model.conditions, original)
        let url = try XCTUnwrap(URLComponents(string: XCTUnwrap(model.hits.first).text))
        XCTAssertEqual(url.queryItems?.first { $0.name == "q" }?.value, original.query)
        XCTAssertEqual(url.queryItems?.first { $0.name == "sender" }?.value, original.sender)
        XCTAssertEqual(url.queryItems?.first { $0.name == "room" }?.value, original.roomIds[0])
        XCTAssertEqual(url.queryItems?.first { $0.name == "format" }?.value, "pdf")
        gate.fail()
        await fulfillment(of: [fallback], timeout: 2)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.hits.isEmpty)
        XCTAssertEqual(model.conditions, original)
        model.stop()
    }

    func testCancelledPlannerCannotOverwriteNewConditions() async {
        let gate = SearchParityPlannerGate()
        let started = expectation(description: "Planner started")
        gate.started = { started.fulfill() }
        let model = model { _ in try await gate.wait() }
        model.conditions.query = "старый запрос"
        model.search(smart: true)
        await fulfillment(of: [started], timeout: 2)
        model.updateQuery("новый запрос")
        gate.fail()
        let completed = expectation(description: "New query completes")
        let subscription = model.$hits.filter { hits in
            guard let text = hits.first?.text else { return false }
            return URLComponents(string: text)?.queryItems?.first { $0.name == "q" }?.value == "новый запрос"
        }.prefix(1).sink { _ in completed.fulfill() }
        model.search()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(model.conditions.query, "новый запрос")
        XCTAssertNil(model.conditions.topic)
        XCTAssertNil(model.error)
        withExtendedLifetime(subscription) { model.stop() }
    }

    func testSupportedPlanSearchRetainsUnsupportedWarningAfterResultsArrive() async throws {
        let raw = try plan(["q": "отчёт", "format": "document", "unsupported": ["owner"]])
        let model = model { try SystemSearchService.decodePlan(raw, preserving: $0) }
        model.conditions.query = "документ владельца Иван"; model.conditions.format = "pdf"
        let completed = expectation(description: "Planned results loaded")
        let subscription = model.$hits.filter { hits in
            guard let text = hits.first?.text else { return false }
            return URLComponents(string: text)?.queryItems?.first { $0.name == "q" }?.value == "отчёт"
        }.prefix(1).sink { _ in completed.fulfill() }
        model.search(smart: true)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(model.conditions.format, "pdf")
        XCTAssertEqual(model.conditions.query, "документ владельца Иван")
        XCTAssertTrue(try model.notice?.contains(XCTUnwrap(SystemSearchService.unsupportedLabels["owner"])) == true)
        XCTAssertNil(model.error)
        withExtendedLifetime(subscription) { model.stop() }
    }

    func testIncompleteOrAmbiguousInferredSenderRequiresExplicitChoice() throws {
        let person = SystemSearchPerson(id: "@ivan:example.org", name: "Иван")
        XCTAssertNil(SystemSearchService.resolveSender("Иван", directory: .init(people: [person], complete: false)))
        XCTAssertEqual(SystemSearchService.resolveSender(person.id, directory: .init(people: [person], complete: false))?.id, person.id)
        let other = SystemSearchPerson(id: "@ivan2:example.org", name: "Иван")
        XCTAssertNil(SystemSearchService.resolveSender("Иван", directory: .init(people: [person, other], complete: true, contactsAvailable: true)))
        XCTAssertEqual(SystemSearchService.resolveSender("Иван", directory: .init(people: [person], complete: true, contactsAvailable: true))?.id, person.id)
        var conditions = SystemSearchConditions(); conditions.query = "сообщения Ивана"; conditions.pendingSenderQuery = "Иван"
        XCTAssertThrowsError(try conditions.queryItems(), "An unresolved sender must never silently broaden the request")
    }

    func testPendingSenderKeepsSupportedPlanAndBlocksResultsUntilChosen() async {
        let model = model { original in
            var result = original
            result.mode = "smart"; result.topic = "отчёт"; result.types = ["attachment"]; result.pendingSenderQuery = "Иван"
            return result
        }
        model.conditions.query = "отчёт, который прислал Иван"; model.conditions.format = "pdf"
        let pending = expectation(description: "Sender needs explicit choice")
        let subscription = model.$notice.compactMap { $0 }.filter { $0.contains(String(format: NSLocalizedString("stalk_search_sender_unverified", comment: "Sender needs selection"), "Иван")) }.prefix(1).sink { _ in pending.fulfill() }
        model.search(smart: true)
        await fulfillment(of: [pending], timeout: 2)
        XCTAssertEqual(model.conditions.topic, "отчёт")
        XCTAssertEqual(model.conditions.types, ["attachment"])
        XCTAssertEqual(model.conditions.format, "pdf")
        XCTAssertEqual(model.senderQuery, "Иван")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.hasMore)
        withExtendedLifetime(subscription) { model.stop() }
    }

    func testMissingOrganizationContactsCannotProveSenderNameUniqueness() {
        let person = SystemSearchPerson(id: "@ivan:example.org", name: "Иван")
        let matrixOnly = SystemSearchDirectory(people: [person], complete: true, contactsAvailable: false)
        XCTAssertNil(SystemSearchService.resolveSender("Иван", directory: matrixOnly))
        XCTAssertNil(SystemSearchService.resolveSender("ив", directory: matrixOnly))
        XCTAssertNotNil(SystemSearchViewModel.directoryNotice(matrixOnly))
        // A literal, known MXID is an explicit identity, rather than a guessed name.
        XCTAssertEqual(SystemSearchService.resolveSender(person.id, directory: matrixOnly)?.id, person.id)
    }

    func testLookupReportsIncompleteWhenOrganizationDirectoryFails() async {
        // This test host is intercepted too; the stub fails only its org-directory request.
        let unavailableClient = ClientProxyMock(.init(homeserver: "https://contacts-unavailable.invalid", userID: "@me:example.org"))
        let unavailable = SystemSearchService(client: unavailableClient, session: session())
        let result = await unavailable.lookupSenders(query: "петр")
        XCTAssertFalse(result.complete)
        XCTAssertFalse(result.contactsAvailable)
        XCTAssertTrue(result.people.contains { $0.id == "@petr:example.org" })
        XCTAssertNil(SystemSearchService.resolveSender("Пётр Старый", directory: result))
    }

    func testEmptyCustomRangeCannotEnableOrSilentlyBroadenSearch() throws {
        var conditions = SystemSearchConditions()
        conditions.period = "range"
        XCTAssertFalse(conditions.canSearch)
        XCTAssertFalse(conditions.valid)
        XCTAssertThrowsError(try conditions.queryItems())
        conditions.query = "отчёт"
        XCTAssertTrue(conditions.canSearch)
        XCTAssertThrowsError(try conditions.queryItems(), "An incomplete chosen date restriction must not silently disappear")
        conditions.query = ""; conditions.types = ["attachment"]
        XCTAssertThrowsError(try conditions.queryItems())
        conditions.types = []; conditions.rangeFrom = "2026-10-01"
        XCTAssertTrue(conditions.valid)
        XCTAssertTrue(conditions.canSearch)
        XCTAssertNotNil(try conditions.queryItems().first { $0.name == "from" })
        conditions.rangeFrom = ""; conditions.rangeTo = "2026-10-16"
        XCTAssertTrue(conditions.valid)
        XCTAssertTrue(conditions.canSearch)
        XCTAssertNotNil(try conditions.queryItems().first { $0.name == "to" })
    }

    func testBlankCustomRangeShowsValidationErrorWithoutStartingSearch() {
        let model = model { _ in throw SystemSearchError.plannerFailed }
        model.conditions.period = "range"
        model.search()
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(model.error, SystemSearchError.invalidConditions.localizedDescription)
        model.stop()
    }

    func testReturningToAllResultsKeepsSemanticTailReachable() async {
        let model = model { _ in throw SystemSearchError.plannerFailed }
        model.conditions.query = "semantic-pagination"
        await waitForSearch(model) { model.search() }
        XCTAssertEqual(model.hits.count, 1)
        XCTAssertEqual(model.total, 3)
        XCTAssertTrue(model.hasMore)
        await waitForSearch(model) { model.browse("message") }
        XCTAssertFalse(model.hasMore, "A selected facet must use its own count")
        await waitForSearch(model) { model.browse(nil) }
        XCTAssertTrue(model.hasMore, "The All tab must include the two semantic-only results")
        await waitForSearch(model) { model.more() }
        XCTAssertEqual(Set(model.hits.map(\.id)), ["1", "2", "3"])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
        model.stop()
    }

    private func waitForSearch(_ model: SystemSearchViewModel, action: () -> Void) async {
        let completed = expectation(description: "Search request completes")
        let subscription = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in completed.fulfill() }
        action()
        await fulfillment(of: [completed], timeout: 2)
        withExtendedLifetime(subscription) { }
    }

    func testDictationCleanupRestoresOnlyItsOwnSessionAndIsIdempotent() throws {
        let session = SearchParityAudioSession()
        session.category = .playback; session.mode = .spokenAudio; session.categoryOptions = [.mixWithOthers]
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
        try lease.activate()
        XCTAssertTrue(lease.ownsSession)
        XCTAssertEqual(session.activeChanges, [true])
        lease.release()
        XCTAssertEqual(session.activeChanges, [true, false])
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        XCTAssertEqual(session.categoryOptions, [.mixWithOthers])
        XCTAssertFalse(lease.ownsSession)
        lease.release()
        XCTAssertEqual(session.activeChanges, [true, false])
        XCTAssertEqual(session.categoryChanges, 2)
    }

    func testDictationCleanupLeavesCallKitOwnedSessionUntouched() throws {
        let session = SearchParityAudioSession()
        var callActive = false
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { callActive })
        try lease.activate()
        callActive = true
        // Even before CallKit/SDK updates category or mode, it has claimed the session.
        lease.release()
        XCTAssertEqual(session.activeChanges, [true])
        XCTAssertEqual(session.categoryChanges, 1)
        callActive = false
        lease.release()
        XCTAssertEqual(session.activeChanges, [true], "Repeated cleanup must not restore stale dictation settings after a call")
        XCTAssertEqual(session.categoryChanges, 1)
    }

    func testSDKCallTakeoverWithoutCallKitPreventsDeactivationAndRestoration() throws {
        for mode in [AVAudioSession.Mode.voiceChat, .videoChat] {
            let session = SearchParityAudioSession()
            let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
            try lease.activate()
            session.category = .playAndRecord; session.mode = mode; session.categoryOptions = [.defaultToSpeaker]
            lease.release()
            XCTAssertEqual(session.activeChanges, [true])
            XCTAssertEqual(session.categoryChanges, 1)
            XCTAssertEqual(session.category, .playAndRecord)
            XCTAssertEqual(session.mode, mode)
            XCTAssertEqual(session.categoryOptions, [.defaultToSpeaker])
        }
    }

    func testDictationCleanupDoesNotRestoreOverAnotherAudioConfiguration() throws {
        let session = SearchParityAudioSession()
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
        try lease.activate()
        session.category = .playAndRecord; session.mode = .default; session.categoryOptions = [.defaultToSpeaker]
        lease.release()
        XCTAssertEqual(session.activeChanges, [true])
        XCTAssertEqual(session.categoryChanges, 1)
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.categoryOptions, [.defaultToSpeaker])
    }

    func testDictationRefusesSDKCallModesBeforeChangingAudioSession() {
        for mode in [AVAudioSession.Mode.voiceChat, .videoChat] {
            let session = SearchParityAudioSession()
            session.category = .playAndRecord; session.mode = mode
            let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
            XCTAssertThrowsError(try lease.activate())
            lease.release()
            XCTAssertEqual(session.categoryChanges, 0)
            XCTAssertTrue(session.activeChanges.isEmpty)
            XCTAssertEqual(session.mode, mode)
        }
    }

    func testDictationRefusesCallKitClaimBeforeChangingAudioSession() {
        let session = SearchParityAudioSession()
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { true })
        XCTAssertThrowsError(try lease.activate())
        lease.release()
        XCTAssertTrue(session.activeChanges.isEmpty)
        XCTAssertEqual(session.categoryChanges, 0)
    }

    func testCallTakeoverDuringActivationIsNotUndoneByFailedStartCleanup() {
        let session = SearchParityAudioSession()
        session.onActive = { [weak session] active in
            if active { session?.category = .playAndRecord; session?.mode = .voiceChat }
        }
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
        XCTAssertThrowsError(try lease.activate())
        lease.release()
        XCTAssertEqual(session.activeChanges, [true])
        XCTAssertEqual(session.categoryChanges, 1)
        XCTAssertEqual(session.mode, .voiceChat)
    }

    func testCallTakeoverDuringDeactivationPreventsStaleCategoryRestore() throws {
        let session = SearchParityAudioSession()
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
        try lease.activate()
        session.onActive = { [weak session] active in
            if !active { session?.category = .playAndRecord; session?.mode = .videoChat }
        }
        lease.release()
        XCTAssertEqual(session.activeChanges, [true, false])
        XCTAssertEqual(session.categoryChanges, 1)
        XCTAssertEqual(session.mode, .videoChat)
    }

    func testFailedActivationRestoresCategoryWithoutDeactivatingAnotherOwner() {
        let session = SearchParityAudioSession()
        session.category = .playback
        session.activationError = AilockVoiceError.recorderFailed
        let lease = AilockVoiceAudioSessionLease(session: session, isCallInProgress: { false })
        XCTAssertThrowsError(try lease.activate())
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.activeChanges, [true])
        lease.release()
        XCTAssertEqual(session.activeChanges, [true])
        XCTAssertEqual(session.categoryChanges, 2)
    }

    func testExplicitVoiceActionRefusesActiveCallsBeforeRequestingMicrophone() {
        let model = SystemSearchViewModel(client: client(), session: session(), isCallActive: { true })
        model.toggleVoice()
        XCTAssertFalse(model.recording)
        XCTAssertFalse(model.transcribing)
        XCTAssertEqual(model.voiceNotice, AilockVoiceError.callInProgress.localizedDescription)
        model.stop()
    }
}

@MainActor
private final class SearchParityPlannerGate {
    var started: (() -> Void)?
    private var continuation: CheckedContinuation<SystemSearchConditions, Error>?
    private var failed = false

    func wait() async throws -> SystemSearchConditions {
        if failed { throw SystemSearchError.plannerFailed }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started?()
        }
    }

    func fail() {
        failed = true
        continuation?.resume(throwing: SystemSearchError.plannerFailed)
        continuation = nil
    }
}

/// Every request is intercepted, including unexpected URLs; these tests cannot reach a server.
private final class SearchParityURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() { }

    override func startLoading() {
        guard let url = request.url else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let object: [String: Any]
        switch url.path {
        case "/api/search":
            var applied: [String: String] = [:]
            for name in ["sender", "sort", "view_type"] {
                applied[name] = value(name)
            }
            if value("q") == "semantic-pagination" {
                let selected = value("view_type") != nil
                let offset = Int(value("offset") ?? "0") ?? 0
                let results: [[String: Any]] = offset == 0
                    ? [["id": "1", "entity_type": "message", "entity_id": "lexical"]]
                    : [["id": "2", "entity_type": "task", "entity_id": "semantic-one", "by": "sense"],
                       ["id": "3", "entity_type": "task", "entity_id": "semantic-two", "by": "sense"]]
                object = ["total": 1, "results": results, "applied_filters": applied,
                          "semantic": ["tail": selected ? 0 : 2],
                          "facets": [["entity_type": "message", "n": 1], ["entity_type": "task", "n": 0, "n_sense": 2]]]
            } else {
                object = ["total": 1, "results": [["id": "1", "entity_type": "message", "entity_id": "event", "snippet": url.absoluteString]], "applied_filters": applied]
            }
        case "/api/org-profile/directory":
            if url.host == "contacts-unavailable.invalid" {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            object = ["users": [["user_id": "@petr:example.org", "display_name": "Пётр Новый"], ["user_id": "@anna:example.org", "display_name": "Анна"]]]
        case "/_matrix/client/v3/user_directory/search":
            object = ["results": [["user_id": "@petr:example.org", "display_name": "Пётр Старый"]], "limited": false]
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

/// Exercises session ownership without permissions, recording, or real audio-session mutations.
private final class SearchParityAudioSession: AilockVoiceAudioSessionProtocol {
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var categoryChanges = 0
    var activeChanges: [Bool] = []
    var activationError: Error?
    var onActive: ((Bool) -> Void)?

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        categoryChanges += 1
        self.category = category; self.mode = mode; categoryOptions = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activeChanges.append(active)
        if active, let activationError { throw activationError }
        onActive?(active)
    }
}
