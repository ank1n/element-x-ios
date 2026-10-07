//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class CallsListScreenTests: XCTestCase {
    // MARK: - CallHistoryItem Tests

    func testCallHistoryItemHasRecording() {
        let withRecording = makeCall(recordingURL: URL(string: "https://example.com/rec.ogg"))
        XCTAssertTrue(withRecording.hasRecording)

        let withoutRecording = makeCall(recordingURL: nil)
        XCTAssertFalse(withoutRecording.hasRecording)
    }

    func testCallHistoryItemIsGroupCall() {
        let group = makeCall(participantCount: 5)
        XCTAssertTrue(group.isGroupCall)

        let direct = makeCall(participantCount: 2)
        XCTAssertFalse(direct.isGroupCall)

        let solo = makeCall(participantCount: 1)
        XCTAssertFalse(solo.isGroupCall)
    }

    // MARK: - RecordingStatus Tests

    func testRecordingStatusIsCompleted() {
        XCTAssertTrue(RecordingStatus.complete.isCompleted)
        XCTAssertFalse(RecordingStatus.active.isCompleted)
        XCTAssertFalse(RecordingStatus.failed.isCompleted)
    }

    func testRecordingStatusIsInProgress() {
        XCTAssertTrue(RecordingStatus.starting.isInProgress)
        XCTAssertTrue(RecordingStatus.active.isInProgress)
        XCTAssertTrue(RecordingStatus.ending.isInProgress)
        XCTAssertFalse(RecordingStatus.complete.isInProgress)
        XCTAssertFalse(RecordingStatus.failed.isInProgress)
        XCTAssertFalse(RecordingStatus.aborted.isInProgress)
    }

    func testRecordingStatusDisplayName() {
        XCTAssertFalse(RecordingStatus.complete.displayName.isEmpty)
        XCTAssertFalse(RecordingStatus.active.displayName.isEmpty)
        XCTAssertFalse(RecordingStatus.failed.displayName.isEmpty)
    }

    func testRecordingStatusRawValues() {
        XCTAssertEqual(RecordingStatus.starting.rawValue, 0)
        XCTAssertEqual(RecordingStatus.active.rawValue, 1)
        XCTAssertEqual(RecordingStatus.complete.rawValue, 3)
        XCTAssertEqual(RecordingStatus.failed.rawValue, 4)
    }

    // MARK: - Cached history loading

    private func makeHistoryFixture(userID: String = "@history:example.com", homeserver: String = "https://example.com") -> (UserSessionMock, LocalCallHistoryService, STalkCacheService) {
        let suite = "CallsHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let local = LocalCallHistoryService(userDefaults: defaults)
        local.setUserID(userID)
        let client = ClientProxyMock(.init(homeserver: homeserver, userID: userID))
        return (UserSessionMock(.init(clientProxy: client)), local, STalkCacheService(cacheDirectory: directory))
    }

    private func seedHistory(_ recordings: [CallHistoryItem], fixture: (UserSessionMock, LocalCallHistoryService, STalkCacheService), at date: Date) async {
        let (session, local, cache) = fixture
        var snapshot = CallHistoryCacheSnapshot()
        snapshot.recordings = recordings
        snapshot.recordingsFetchedAt = date
        snapshot.roomEventsFetchedAt = date
        snapshot.localRevision = CallHistoryCacheSnapshot.revision(local.getAllCalls())
        let key = CallHistoryCacheSnapshot.key(userID: session.clientProxy.userID, homeserver: session.clientProxy.homeserver)
        await cache.save(snapshot, forKey: key, ttl: 300)
    }

    func testLocalHistoryIsVisibleWhileFirstRequestIsBlocked() async {
        let (session, local, cache) = makeHistoryFixture()
        let id = local.startCall(roomID: "!local:example.com", direction: .outgoing)
        local.endCall(id: id, missed: false)
        let service = CallsHistoryTestService()
        let started = expectation(description: "Network request started")
        var release: CheckedContinuation<[CallHistoryItem], Error>?
        service.fetch = {
            try await withCheckedThrowingContinuation { continuation in release = continuation; started.fulfill() }
        }
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { true })
        defer { model.stop() }
        XCTAssertEqual(model.context.viewState.callHistory.first?.id, id)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.context.viewState.callHistory.first?.id, id)
        XCTAssertFalse(model.context.viewState.isLoading)
        release?.resume(returning: [])
    }

    func testStaleCachedHistorySurvivesARefreshFailure() async throws {
        let fixture = makeHistoryFixture()
        let (session, local, cache) = fixture
        let cachedCall = makeCall()
        await seedHistory([cachedCall], fixture: fixture, at: .distantPast)
        let service = CallsHistoryTestService()
        let started = expectation(description: "Refresh started")
        var release: CheckedContinuation<[CallHistoryItem], Error>?
        service.fetch = { try await withCheckedThrowingContinuation { release = $0; started.fulfill() } }
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { true })
        defer { model.stop() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.context.viewState.callHistory.map(\.id), [cachedCall.id])
        XCTAssertFalse(model.context.viewState.isLoading)
        let finished = deferFulfillment(model.context.$viewState.map(\.isRefreshingHistory)) { !$0 }
        release?.resume(throwing: URLError(.notConnectedToInternet))
        try await finished.fulfill()
        XCTAssertEqual(model.context.viewState.callHistory.map(\.id), [cachedCall.id])
    }

    func testFreshCacheAvoidsRequestsOnReopeningAndManualRefreshFetchesOnce() async throws {
        let fixture = makeHistoryFixture()
        let (session, local, cache) = fixture
        let date = Date()
        let cachedCall = makeCall()
        await seedHistory([cachedCall], fixture: fixture, at: date)
        let service = CallsHistoryTestService()
        service.recordings = [cachedCall]
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, isActive: false, now: { date }, applicationIsActive: { true })
        defer { model.stop() }
        let cached = deferFulfillment(model.context.$viewState.map(\.callHistory)) { $0.contains { $0.id == cachedCall.id } }
        try await cached.fulfill()
        model.setActive(true)
        model.setActive(false)
        model.setActive(true)
        XCTAssertEqual(service.requests, 0)
        let finished = deferFulfillment(model.context.$viewState.map(\.isRefreshingHistory)) { !$0 && service.requests == 1 }
        model.process(viewAction: .refresh)
        try await finished.fulfill()
        XCTAssertEqual(service.requests, 1)
    }

    func testHiddenTabDoesNotStartHistoryRequests() async throws {
        let (session, local, cache) = makeHistoryFixture()
        let service = CallsHistoryTestService()
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, isActive: false, applicationIsActive: { true })
        defer { model.stop() }
        let ready = deferFulfillment(model.context.$viewState.map(\.isLoading)) { !$0 }
        try await ready.fulfill()
        XCTAssertEqual(service.requests, 0)
        let finished = deferFulfillment(model.context.$viewState.map(\.isRefreshingHistory)) { !$0 && service.requests == 1 }
        model.setActive(true)
        try await finished.fulfill()
    }

    func testRecordingResultsDoNotWaitForRoomScan() async throws {
        let (session, local, cache) = makeHistoryFixture()
        let service = CallsHistoryTestService()
        let recording = makeCall()
        service.recordings = [recording]
        let scanStarted = expectation(description: "Room scan started")
        var scanRelease: CheckedContinuation<[String: [CallHistoryItem]], Error>?
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { true }, roomHistoryLoader: {
                                                 try await withCheckedThrowingContinuation { scanRelease = $0; scanStarted.fulfill() }
                                             })
        defer { model.stop() }
        let shown = deferFulfillment(model.context.$viewState.map(\.callHistory)) { $0.contains { $0.id == recording.id } }
        await fulfillment(of: [scanStarted], timeout: 2)
        try await shown.fulfill()
        XCTAssertTrue(model.context.viewState.isRefreshingHistory)
        scanRelease?.resume(returning: [:])
    }

    func testRefreshGesturesCoalesceWhileRequestIsInFlight() async throws {
        let (session, local, cache) = makeHistoryFixture()
        let service = CallsHistoryTestService()
        let started = expectation(description: "One request started")
        var release: CheckedContinuation<[CallHistoryItem], Error>?
        service.fetch = { try await withCheckedThrowingContinuation { release = $0; started.fulfill() } }
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { true })
        defer { model.stop() }
        await fulfillment(of: [started], timeout: 2)
        model.process(viewAction: .refresh)
        model.process(viewAction: .refresh)
        XCTAssertEqual(service.requests, 1)
        let finished = deferFulfillment(model.context.$viewState.map(\.isRefreshingHistory)) { !$0 }
        release?.resume(returning: [])
        try await finished.fulfill()
        XCTAssertEqual(service.requests, 1)
    }

    func testLocalCallDurationUpdatesEvenWhenRowIDIsUnchanged() async throws {
        let (session, local, cache) = makeHistoryFixture()
        let id = local.startCall(roomID: "!same:example.com", direction: .outgoing)
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local,
                                             cacheService: cache, isActive: false, applicationIsActive: { true })
        defer { model.stop() }
        let updated = deferFulfillment(model.context.$viewState.map(\.callHistory)) { calls in calls.contains { $0.id == id && $0.duration != nil } }
        local.endCall(id: id, missed: false)
        try await updated.fulfill()
        XCTAssertEqual(model.context.viewState.callHistory.first?.id, id)
    }

    func testCacheIsPartitionedByBothAccountAndHomeserver() async throws {
        let fixture = makeHistoryFixture()
        let (session, local, cache) = fixture
        let foreign = makeCall()
        let otherKey = CallHistoryCacheSnapshot.key(userID: "@other:example.com", homeserver: session.clientProxy.homeserver)
        var snapshot = CallHistoryCacheSnapshot()
        snapshot.recordings = [foreign]
        snapshot.localRevision = CallHistoryCacheSnapshot.revision([])
        await cache.save(snapshot, forKey: otherKey, ttl: 300)
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, cacheService: cache,
                                             isActive: false, applicationIsActive: { true })
        defer { model.stop() }
        let ready = deferFulfillment(model.context.$viewState.map(\.isLoading)) { !$0 }
        try await ready.fulfill()
        XCTAssertFalse(model.context.viewState.callHistory.contains { $0.id == foreign.id })
        XCTAssertNotEqual(otherKey, CallHistoryCacheSnapshot.key(userID: session.clientProxy.userID, homeserver: session.clientProxy.homeserver))
        XCTAssertNotEqual(otherKey, CallHistoryCacheSnapshot.key(userID: "@other:example.com", homeserver: "https://another.example.com"))
    }

    func testRoomHistoryPersistsAcrossCacheServiceRecreation() async throws {
        let (session, local, _) = makeHistoryFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CallsDisk.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let date = Date()
        let call = makeCall()
        let service = CallsHistoryTestService()
        var scans = 0
        let first = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: STalkCacheService(cacheDirectory: directory), now: { date }, applicationIsActive: { true }, roomHistoryLoader: {
                                                 scans += 1
                                                 return ["!cached:example.com": [call]]
                                             })
        let finished = deferFulfillment(first.context.$viewState) { !$0.isRefreshingHistory && $0.callHistory.contains { $0.id == call.id } }
        try await finished.fulfill()
        first.stop()
        let second = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                              cacheService: STalkCacheService(cacheDirectory: directory), now: { date }, applicationIsActive: { true }, roomHistoryLoader: {
                                                  scans += 1
                                                  return [:]
                                              })
        defer { second.stop() }
        let restored = deferFulfillment(second.context.$viewState) { $0.callHistory.contains { $0.id == call.id } }
        try await restored.fulfill()
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(service.requests, 1)
    }

    func testBackgroundDoesNotStartRequestsEvenForSelectedCallsTab() async throws {
        let (session, local, cache) = makeHistoryFixture()
        let service = CallsHistoryTestService()
        let model = CallsListScreenViewModel(userSession: session, localCallHistoryService: local, callHistoryService: service,
                                             cacheService: cache, applicationIsActive: { false })
        defer { model.stop() }
        let ready = deferFulfillment(model.context.$viewState.map(\.isLoading)) { !$0 }
        try await ready.fulfill()
        model.process(viewAction: .refresh)
        XCTAssertEqual(service.requests, 0)
    }

    // MARK: - Helpers

    private func makeCall(callType: CallHistoryItem.CallType = .incoming,
                          isMissed: Bool = false,
                          recordingURL: URL? = nil,
                          participantCount: Int = 2) -> CallHistoryItem {
        CallHistoryItem(id: UUID().uuidString,
                        contactName: "Test",
                        contactId: "@test:example.com",
                        callType: callType,
                        timestamp: Date(),
                        duration: 120,
                        isMissed: isMissed,
                        recordingURL: recordingURL,
                        participantCount: participantCount)
    }
}

@MainActor
private final class CallsHistoryTestService: CallHistoryServiceProtocol {
    var requests = 0
    var recordings: [CallHistoryItem] = []
    var fetch: (() async throws -> [CallHistoryItem])?
    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem] {
        requests += 1
        if let fetch { return try await fetch() }
        return recordings
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

    func fetchCreatedTasks(egressId: String, refresh: Bool) async throws -> [CreatedTask] {
        throw URLError(.unsupportedURL)
    }

    func createTask(egressId: String, topicIndex: Int, taskIndex: Int, projectId: String, overrideText: String?) async throws -> CreatedTask {
        throw URLError(.unsupportedURL)
    }

    func searchTrackItProjects(query: String) async throws -> [TrackItProject] {
        throw URLError(.unsupportedURL)
    }
}
