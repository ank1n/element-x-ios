//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import XCTest

@MainActor
final class CallHistoryLinkedTasksTests: XCTestCase {
    func testOptionalCountIsLenientWithoutDroppingHistory() throws {
        for value in [nil, "null", "-1", "1.5", "\"3\"", "true", "[]", "{}", "1e100"] as [String?] {
            let countField = value.map { ",\"createdTaskCount\":\($0)" } ?? ""
            let data = Data("""
            {"success":true,"recordings":[{"egressId":"primary","roomName":"room","status":4,
            "startedAt":"2026-10-18T08:00:00Z"\(countField)}]}
            """.utf8)
            let response = try JSONDecoder().decode(CallHistoryResponse.self, from: data)
            let recording = try XCTUnwrap(response.recordings?.first)
            XCTAssertNil(recording.createdTaskCount, "Invalid count: \(value ?? "missing")")
            let call = try XCTUnwrap(recording.toCallHistoryItem())
            XCTAssertNil(call.createdTaskCount)
            XCTAssertNil(call.taskCountBadge)
            XCTAssertNil(call.recordingURL)
            XCTAssertEqual(call.taskRecordingIDs, ["primary"])
        }
    }

    func testCountBadgeAndNonPlayableSessionMapping() throws {
        for (count, badge) in [(0, nil), (1, "1"), (99, "99"), (100, "99+")] as [(Int, String?)] {
            let data = Data("""
            {"egressId":"primary","roomName":"room","status":4,"startedAt":"2026-10-18T08:00:00Z",
            "callId":"logical","sessionIds":["older","primary","older",""],"createdTaskCount":\(count)}
            """.utf8)
            let api = try JSONDecoder().decode(CallHistoryAPIItem.self, from: data)
            let call = try XCTUnwrap(api.toCallHistoryItem())
            XCTAssertEqual(call.createdTaskCount, count)
            XCTAssertEqual(call.taskCountBadge, badge)
            XCTAssertEqual(call.callId, "logical")
            XCTAssertEqual(call.taskRecordingIDs, ["older", "primary"])
            XCTAssertFalse(call.hasRecording)
        }
    }

    func testCacheBackCompatibilityAndRoundTrip() throws {
        let call = makeCall(id: "api", count: 7, sessions: ["old", "api"])
        var snapshot = CallHistoryCacheSnapshot()
        snapshot.recordings = [call]
        let encoded = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(CallHistoryCacheSnapshot.self, from: encoded)
        XCTAssertEqual(restored.recordings, [call])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var row = try XCTUnwrap((json["recordings"] as? [[String: Any]])?.first)
        for key in ["createdTaskCount", "callId", "recordingSessionIDs"] {
            row.removeValue(forKey: key)
        }
        json["recordings"] = [row]
        let oldCache = try JSONSerialization.data(withJSONObject: json)
        let old = try XCTUnwrap(JSONDecoder().decode(CallHistoryCacheSnapshot.self, from: oldCache).recordings.first)
        XCTAssertNil(old.createdTaskCount)
        XCTAssertNil(old.callId)
        XCTAssertNil(old.recordingSessionIDs)
        XCTAssertEqual(old.taskRecordingIDs, [])
    }

    func testRecordingIDsUseStableSessionsAndLegacyPlaybackButNeverLocalUUID() {
        var call = makeCall(id: UUID().uuidString, count: nil, sessions: ["second", "first", "second", "", " "])
        call = withPlayback(call, url: "https://example.com/recording-api/api/recording/play/legacy?ticket=abc")
        XCTAssertEqual(call.taskRecordingIDs, ["second", "first", "legacy"])
        call.recordingSessionIDs = nil
        XCTAssertEqual(call.taskRecordingIDs, ["legacy"])
        XCTAssertEqual(makeCall(id: UUID().uuidString, count: nil).taskRecordingIDs, [])
        XCTAssertEqual(withPlayback(call, url: "https://example.com/unrelated/file").taskRecordingIDs, [])
    }

    func testReconnectGroupsUnionIDsAndTakeMaximumWithinRoomAndCallOnly() {
        let first = makeCall(id: "a", count: 2, sessions: ["a", "b"], callID: "logical")
        let second = makeCall(id: "b", count: 5, sessions: ["b", "c"], callID: "logical")
        let unknown = makeCall(id: "c", count: nil, sessions: ["c"], callID: "logical")
        let otherRoom = makeCall(id: "d", count: 90, sessions: ["d"], callID: "logical", room: "!other:example.com")
        let otherCall = makeCall(id: "e", count: 70, sessions: ["e"], callID: "other")
        let result = CallHistoryItem.mergingTaskMetadata(in: [first, second, unknown, otherRoom, otherCall])
        XCTAssertEqual(result.map(\.createdTaskCount), [5, 5, 5, 90, 70])
        XCTAssertEqual(Array(result.prefix(3)).map(\.taskRecordingIDs), Array(repeating: ["a", "b", "c"], count: 3))
        XCTAssertEqual(result[3].taskRecordingIDs, ["d"])
        XCTAssertEqual(result[4].taskRecordingIDs, ["e"])
        XCTAssertEqual(CallHistoryItem.mergingTaskMetadata(in: result), result)
    }

    func testLocalMergeMatchesPrimaryOrSessionEvenOutsideTimeWindowAndSurvivesRebuild() async throws {
        for localEgressID in ["primary", "reconnected"] {
            let fixture = makeFixture()
            let (session, local, cache) = fixture
            let localID = local.startCall(roomID: "!room:example.com", direction: .outgoing)
            local.linkRecording(callID: localID, egressId: localEgressID)
            let recording = makeCall(id: "primary", count: 4, sessions: ["older", "reconnected", "primary"], callID: "logical")
            await seed([recording], fixture: fixture)
            let service = LinkedTasksHistoryService()
            let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                                 cacheService: cache, isActive: false, applicationIsActive: { true })
            defer { model.stop() }
            let shown = deferFulfillment(model.context.$viewState.map(\.callHistory)) { $0.first?.createdTaskCount == 4 }
            try await shown.fulfill()
            let row = try XCTUnwrap(model.context.viewState.callHistory.first)
            XCTAssertEqual(model.context.viewState.callHistory.count, 1)
            XCTAssertEqual(row.id, localID)
            XCTAssertNil(row.recordingURL)
            XCTAssertEqual(row.taskRecordingIDs, ["older", "reconnected", "primary"])
            XCTAssertEqual(row.callId, "logical")
            let rebuilt = deferFulfillment(model.context.$viewState.map(\.callHistory)) { $0.first?.contactName == "Renamed" }
            local.updateCallInfo(id: localID, roomDisplayName: "Renamed", participants: [:])
            try await rebuilt.fulfill()
            XCTAssertEqual(model.context.viewState.callHistory.first?.createdTaskCount, 4)
            XCTAssertEqual(model.context.viewState.callHistory.first?.taskRecordingIDs, row.taskRecordingIDs)
            XCTAssertEqual(service.listRequests, 0)
            XCTAssertEqual(service.taskRequests, 0)
        }
    }

    func testLocalMergePrefersItsPrimaryPlaybackOverFailedReconnectFragment() async throws {
        let fixture = makeFixture()
        let (session, local, cache) = fixture
        let localID = local.startCall(roomID: "!room:example.com", direction: .outgoing)
        local.linkRecording(callID: localID, egressId: "primary")
        let failed = makeCall(id: "failed", count: 6, sessions: ["failed"], callID: "logical")
        let playable = withPlayback(makeCall(id: "primary", count: 3, sessions: ["primary"], callID: "logical"),
                                    url: "https://example.com/recording-api/api/recording/play/primary")
        await seed([failed, playable], fixture: fixture)
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, cacheService: cache,
                                             isActive: false, applicationIsActive: { true })
        defer { model.stop() }
        let shown = deferFulfillment(model.context.$viewState.map(\.callHistory)) { $0.first?.createdTaskCount == 6 }
        try await shown.fulfill()
        let row = try XCTUnwrap(model.context.viewState.callHistory.first)
        XCTAssertEqual(model.context.viewState.callHistory.count, 1)
        XCTAssertEqual(row.id, localID)
        XCTAssertEqual(row.recordingURL, playable.recordingURL)
        XCTAssertEqual(row.taskRecordingIDs, ["failed", "primary"])
    }

    func testListLoadsMultipleRowsWithOneListRequestAndNoTasksRequests() async throws {
        let (session, local, cache) = makeFixture()
        let service = LinkedTasksHistoryService()
        service.recordings = (0..<20).map { makeCall(id: "egress-\($0)", count: $0, sessions: ["egress-\($0)"]) }
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { true })
        defer { model.stop() }
        let loaded = deferFulfillment(model.context.$viewState) { !$0.isRefreshingHistory && $0.callHistory.count == 20 }
        try await loaded.fulfill()
        XCTAssertEqual(service.listRequests, 1)
        XCTAssertEqual(service.taskRequests, 0)
    }

    func testTaskNotificationIsAccountScopedAndRefreshesOnlyAuthoritativeList() async throws {
        let fixture = makeFixture()
        let (session, local, cache) = fixture
        let cached = makeCall(id: "primary", count: 2, sessions: ["primary"])
        await seed([cached], fixture: fixture)
        let service = LinkedTasksHistoryService()
        var scans = 0
        let started = expectation(description: "Authoritative list requested")
        var release: CheckedContinuation<[CallHistoryItem], Error>?
        service.fetch = { try await withCheckedThrowingContinuation { release = $0; started.fulfill() } }
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, isActive: false, applicationIsActive: { true }, roomHistoryLoader: {
                                                 scans += 1
                                                 return [:]
                                             })
        defer { model.stop() }
        let restored = deferFulfillment(model.context.$viewState.map(\.callHistory)) { $0.first?.createdTaskCount == 2 }
        try await restored.fulfill()
        model.setActive(true)
        postTasksChanged(userID: "@other:example.com", homeserver: session.clientProxy.homeserver)
        postTasksChanged(userID: session.clientProxy.userID, homeserver: "https://other.example.com")
        NotificationCenter.default.post(name: .stalkCallTasksChanged, object: nil)
        await drainNotifications()
        XCTAssertEqual(service.listRequests, 0)
        postTasksChanged(userID: session.clientProxy.userID, homeserver: session.clientProxy.homeserver)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.context.viewState.callHistory.first?.createdTaskCount, 2)
        var authoritative = cached
        authoritative.createdTaskCount = 0
        let refreshed = deferFulfillment(model.context.$viewState) { !$0.isRefreshingHistory && $0.callHistory.first?.createdTaskCount == 0 }
        release?.resume(returning: [authoritative])
        try await refreshed.fulfill()
        XCTAssertNil(model.context.viewState.callHistory.first?.taskCountBadge)
        XCTAssertEqual(scans, 0)
        XCTAssertEqual(service.listRequests, 1)
        XCTAssertEqual(service.taskRequests, 0)
        let key = CallHistoryCacheSnapshot.key(userID: session.clientProxy.userID, homeserver: session.clientProxy.homeserver)
        let saved = await cache.load(CallHistoryCacheSnapshot.self, forKey: key)
        XCTAssertEqual(saved?.recordings.first?.createdTaskCount, 0)
        XCTAssertNotNil(saved?.roomEventsFetchedAt)
    }

    func testTaskNotificationDuringListRequestQueuesRecordingOnlyRefresh() async throws {
        let (session, local, cache) = makeFixture()
        let service = LinkedTasksHistoryService()
        let started = expectation(description: "Initial request")
        let repeated = expectation(description: "Refresh after task creation")
        var initial: CheckedContinuation<[CallHistoryItem], Error>?
        var refresh: CheckedContinuation<[CallHistoryItem], Error>?
        service.fetch = {
            try await withCheckedThrowingContinuation {
                if service.listRequests == 1 { initial = $0; started.fulfill() }
                else { refresh = $0; repeated.fulfill() }
            }
        }
        var scans = 0
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { true }, roomHistoryLoader: {
                                                 scans += 1
                                                 return [:]
                                             })
        defer { model.stop() }
        await fulfillment(of: [started], timeout: 2)
        postTasksChanged(userID: session.clientProxy.userID, homeserver: session.clientProxy.homeserver)
        await drainNotifications()
        initial?.resume(returning: [makeCall(id: "primary", count: 1, sessions: ["primary"])])
        await fulfillment(of: [repeated], timeout: 2)
        let finished = deferFulfillment(model.context.$viewState) { !$0.isRefreshingHistory && $0.callHistory.first?.createdTaskCount == 4 }
        refresh?.resume(returning: [makeCall(id: "primary", count: 4, sessions: ["primary"])])
        try await finished.fulfill()
        XCTAssertEqual(service.listRequests, 2)
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(service.taskRequests, 0)
    }

    func testShowCallTasksActionKeepsAllSourceIDs() async throws {
        let (session, local, cache) = makeFixture()
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, cacheService: cache, isActive: false)
        defer { model.stop() }
        let call = makeCall(id: "primary", count: 3, sessions: ["old", "primary"])
        let action = deferFulfillment(model.actionsPublisher) {
            if case .showCallTasks(let selected) = $0 { return selected == call }
            return false
        }
        model.process(viewAction: .showCallTasks(call))
        try await action.fulfill()
    }

    func testCreatedTasksEncodesIDAsOnePathComponentAndUsesExisting30SecondTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedTasksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LinkedTasksURLProtocol.handler = nil }
        let requested = expectation(description: "Tasks request")
        LinkedTasksURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.percentEncodedPath, "/recording-api/api/recording/tasks/fragment%2Fwith%3Fquery%23hash%25")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "refresh", value: "1")])
            XCTAssertEqual(request.timeoutInterval, 30)
            requested.fulfill()
            return Data(#"{"tasks":[]}"#.utf8)
        }
        let service = try CallHistoryService(baseURL: XCTUnwrap(URL(string: "https://example.com/recording-api")), urlSession: session)
        let tasks = try await service.fetchCreatedTasks(egressId: "fragment/with?query#hash%", refresh: true)
        XCTAssertTrue(tasks.isEmpty)
        await fulfillment(of: [requested], timeout: 2)
    }

    func testCreatedTasksRejectsEmptyAndLiteralDotSegmentsBeforeNetworkOrTokenAccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedTasksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LinkedTasksURLProtocol.handler = nil }
        LinkedTasksURLProtocol.handler = { _ in
            XCTFail("Invalid task IDs must not reach the network")
            return Data(#"{"tasks":[]}"#.utf8)
        }
        let service = try CallHistoryService(baseURL: XCTUnwrap(URL(string: "https://example.com/recording-api")), accessTokenProvider: {
            XCTFail("Invalid task IDs must not acquire a token")
            return "token"
        }, urlSession: session)
        for id in ["", ".", ".."] {
            do {
                _ = try await service.fetchCreatedTasks(egressId: id, refresh: true)
                XCTFail("Expected invalidResponse for \(id)")
            } catch CallHistoryError.invalidResponse {
                // Validation must happen before URL normalization or network access.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCreatedTasksTreatsPercentEncodedDotsAsAnOpaqueID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedTasksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LinkedTasksURLProtocol.handler = nil }
        let requested = expectation(description: "Opaque percent characters remain escaped")
        LinkedTasksURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.percentEncodedPath, "/recording-api/api/recording/tasks/%252E%252E")
            requested.fulfill()
            return Data(#"{"tasks":[]}"#.utf8)
        }
        let service = try CallHistoryService(baseURL: XCTUnwrap(URL(string: "https://example.com/recording-api")), urlSession: session)
        _ = try await service.fetchCreatedTasks(egressId: "%2E%2E", refresh: false)
        await fulfillment(of: [requested], timeout: 2)
    }

    func testAlreadyCancelledTasksRequestDoesNotAcquireTokenOrStartNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedTasksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LinkedTasksURLProtocol.handler = nil }
        LinkedTasksURLProtocol.handler = { _ in
            XCTFail("A cancelled request must not reach the network")
            return Data(#"{"tasks":[]}"#.utf8)
        }
        let service = try CallHistoryService(baseURL: XCTUnwrap(URL(string: "https://example.com/recording-api")), accessTokenProvider: {
            XCTFail("A cancelled request must not acquire a token")
            return "token"
        }, forceTokenRefresh: {
            XCTFail("A cancelled request must not refresh a token")
        }, urlSession: session)
        // The task inherits the main actor, so cancellation happens before it starts.
        let task = Task { try await service.fetchCreatedTasks(egressId: "primary", refresh: true) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testURLCancellationIsNotRetriedOrFollowedByTokenRefresh() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedTasksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LinkedTasksURLProtocol.handler = nil }
        let requested = expectation(description: "Only one request")
        requested.assertForOverFulfill = true
        LinkedTasksURLProtocol.handler = { _ in
            requested.fulfill()
            throw URLError(.cancelled)
        }
        var tokenRequests = 0
        let service = try CallHistoryService(baseURL: XCTUnwrap(URL(string: "https://example.com/recording-api")), accessTokenProvider: {
            tokenRequests += 1
            return "token"
        }, forceTokenRefresh: {
            XCTFail("Cancellation must not refresh the token")
        }, urlSession: session)
        do {
            _ = try await service.fetchCreatedTasks(egressId: "primary", refresh: false)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(tokenRequests, 1)
    }

    func testCancellationDuringTokenRefreshPreventsAnotherAttempt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedTasksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LinkedTasksURLProtocol.handler = nil
            LinkedTasksURLProtocol.statusCode = 200
        }
        let requested = expectation(description: "Only initial unauthorized request")
        requested.assertForOverFulfill = true
        LinkedTasksURLProtocol.statusCode = 401
        LinkedTasksURLProtocol.handler = { _ in
            requested.fulfill()
            return Data("{}".utf8)
        }
        let refreshing = expectation(description: "Token refresh started before cancellation")
        var release: CheckedContinuation<Void, Never>?
        var tokenRequests = 0
        let service = try CallHistoryService(baseURL: XCTUnwrap(URL(string: "https://example.com/recording-api")), accessTokenProvider: {
            tokenRequests += 1
            return "token"
        }, forceTokenRefresh: {
            await withCheckedContinuation { release = $0; refreshing.fulfill() }
        }, urlSession: session)
        let task = Task { try await service.fetchCreatedTasks(egressId: "primary", refresh: true) }
        await fulfillment(of: [requested, refreshing], timeout: 2)
        task.cancel()
        release?.resume()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(tokenRequests, 1)
    }

    private func makeCall(id: String, count: Int?, sessions: [String]? = nil, callID: String? = nil,
                          room: String = "!room:example.com") -> CallHistoryItem {
        CallHistoryItem(id: id, contactName: "Call", contactId: room, callType: .incoming,
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000), duration: 60, isMissed: false, recordingURL: nil,
                        createdTaskCount: count, callId: callID, recordingSessionIDs: sessions)
    }

    private func withPlayback(_ call: CallHistoryItem, url: String) -> CallHistoryItem {
        CallHistoryItem(id: call.id, contactName: call.contactName, contactId: call.contactId, callType: call.callType,
                        timestamp: call.timestamp, duration: call.duration, isMissed: call.isMissed, recordingURL: URL(string: url),
                        createdTaskCount: call.createdTaskCount, callId: call.callId, recordingSessionIDs: call.recordingSessionIDs)
    }

    private func makeFixture() -> (UserSessionMock, LocalCallHistoryService, STalkCacheService) {
        let suite = "LinkedTasksHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let local = LocalCallHistoryService(userDefaults: defaults)
        local.setUserID("@history:example.com")
        let client = ClientProxyMock(.init(homeserver: "https://example.com", userID: "@history:example.com"))
        return (UserSessionMock(.init(clientProxy: client)), local, STalkCacheService(cacheDirectory: directory))
    }

    private func seed(_ calls: [CallHistoryItem], fixture: (UserSessionMock, LocalCallHistoryService, STalkCacheService)) async {
        let (session, local, cache) = fixture
        var snapshot = CallHistoryCacheSnapshot()
        snapshot.recordings = calls
        snapshot.recordingsFetchedAt = Date()
        snapshot.roomEventsFetchedAt = Date()
        snapshot.localRevision = CallHistoryCacheSnapshot.revision(local.getAllCalls())
        let key = CallHistoryCacheSnapshot.key(userID: session.clientProxy.userID, homeserver: session.clientProxy.homeserver)
        await cache.save(snapshot, forKey: key, ttl: 300)
    }

    private func postTasksChanged(userID: String, homeserver: String) {
        NotificationCenter.default.post(name: .stalkCallTasksChanged, object: nil,
                                        userInfo: ["egressIDs": ["primary"], "userID": userID, "homeserver": homeserver])
    }

    private func drainNotifications() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class LinkedTasksHistoryService: CallHistoryServiceProtocol {
    var listRequests = 0
    var taskRequests = 0
    var recordings: [CallHistoryItem] = []
    var fetch: (() async throws -> [CallHistoryItem])?

    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem] {
        listRequests += 1
        if let fetch { return try await fetch() }
        return recordings
    }

    func fetchCreatedTasks(egressId: String, refresh: Bool) async throws -> [CreatedTask] {
        taskRequests += 1
        throw URLError(.unsupportedURL)
    }

    func fetchTranscription(egressId: String) async throws -> TranscriptionData {
        throw URLError(.unsupportedURL)
    }

    func retryTranscription(egressId: String) async throws -> TranscriptionData {
        throw URLError(.unsupportedURL)
    }

    func downloadRecording(from url: URL) async throws -> Data {
        throw URLError(.unsupportedURL)
    }

    func createTask(egressId: String, topicIndex: Int, taskIndex: Int, projectId: String, overrideText: String?) async throws -> CreatedTask {
        throw URLError(.unsupportedURL)
    }

    func searchTrackItProjects(query: String) async throws -> [TrackItProject] {
        throw URLError(.unsupportedURL)
    }
}

private final class LinkedTasksURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    static var statusCode = 200
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let data = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
