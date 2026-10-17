// Copyright 2026 New Vector Ltd.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
@testable import ElementX
import Foundation
import XCTest

@MainActor
final class CallDetailLinkedTasksTests: XCTestCase {
    func testPendingSuggestionIsSuppressedByCurrentSessionRowEvenWhenDeduplicatedCardUsesAnotherSession() throws {
        let suggested = try JSONDecoder().decode(SuggestedTask.self, from: Data(#"{"topicIndex":0,"taskIndex":0,"text":"Follow up"}"#.utf8))
        let call = CallHistoryItem(id: UUID().uuidString, contactName: "Call", contactId: "!room:example.invalid",
                                   callType: .incoming, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                   duration: 60, isMissed: false,
                                   recordingURL: URL(string: "https://example.invalid/recording-api/api/recording/play/session-A"),
                                   recordingSessionIDs: ["session-B", "session-A"])
        var state = CallDetailScreenViewState(call: call)
        state.transcriptionData = TranscriptionData(available: true, status: .completed, transcription: nil,
                                                    summary: TranscriptionSummary(text: nil, keyPoints: nil, actionItems: nil,
                                                                                  topics: [SummaryTopic(title: "Follow up", discussed: nil,
                                                                                                        agreed: nil, timestamp: nil,
                                                                                                        suggestedTasks: [suggested])]), error: nil)
        state.createdTasks = try [
            task(id: 1, session: "session-A", issue: "shared", group: "started", synced: "2026-10-18T09:00:00Z"),
            task(id: 2, session: "session-B", issue: "shared", group: "completed", synced: "2026-10-18T10:00:00Z")
        ]
        state.taskStatistics = CallTaskStatistics(tasks: state.createdTasks)

        XCTAssertEqual(state.allSuggestedTasks, [suggested])
        XCTAssertEqual(state.taskStatistics.uniqueTasks.map(\.egressId), ["session-B"])
        XCTAssertTrue(state.pendingSuggestedTasks.isEmpty,
                      "The raw session-A creation still suppresses its suggestion after session-B replaces the displayed card")
    }

    func testOtherSessionIssueAndCurrentSessionRowWithoutIssueIDKeepSuggestionPending() throws {
        let suggested = try JSONDecoder().decode(SuggestedTask.self, from: Data(#"{"topicIndex":0,"taskIndex":0,"text":"Follow up"}"#.utf8))
        let call = CallHistoryItem(id: UUID().uuidString, contactName: "Call", contactId: "!room:example.invalid",
                                   callType: .incoming, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                   duration: 60, isMissed: false, recordingURL: nil,
                                   recordingSessionIDs: ["session-A", "session-B"])
        var state = CallDetailScreenViewState(call: call)
        state.transcriptionData = TranscriptionData(available: true, status: .completed, transcription: nil,
                                                    summary: TranscriptionSummary(text: nil, keyPoints: nil, actionItems: nil,
                                                                                  topics: [SummaryTopic(title: "Follow up", discussed: nil,
                                                                                                        agreed: nil, timestamp: nil,
                                                                                                        suggestedTasks: [suggested])]), error: nil)
        let otherSession = try task(id: 2, session: "session-B", issue: "different-issue", group: "completed")
        state.createdTasks = [otherSession]
        state.taskStatistics = CallTaskStatistics(tasks: state.createdTasks)
        XCTAssertEqual(state.pendingSuggestedTasks, [suggested],
                       "Matching topic/task indices in another session do not mean session-A's suggestion was created")

        let missingIssue = try JSONDecoder().decode(CreatedTask.self, from: Data(#"{"id":1,"egress_id":"session-A","topic_index":0,"task_index":0,"task_text":"Follow up","trackit_issue_id":null}"#.utf8))
        XCTAssertNil(missingIssue.trackitIssueId)
        state.createdTasks.append(missingIssue)
        state.taskStatistics = CallTaskStatistics(tasks: state.createdTasks)

        XCTAssertEqual(state.taskStatistics.total, 1)
        XCTAssertEqual(state.pendingSuggestedTasks, [suggested],
                       "A row without a linked issue is not a successful creation and must leave the suggestion actionable")
    }

    func testHeaderAggregatesAllSessionsAndUsesNewestStatusForSharedIssue() async throws {
        let recent = try task(id: 1, session: "primary", issue: "shared", group: "completed", synced: "2026-10-18T10:00:00Z")
        let older = try task(id: 2, session: "reconnected", issue: "shared", group: "started", synced: "2026-10-18T09:00:00Z")
        let backlog = try task(id: 3, session: "reconnected", issue: "other", group: "unstarted")
        let service = DetailTasksService(fetch: { session, _, _ in
            session == "primary" ? [recent] : [older, backlog]
        })
        let model = makeModel(service: service, sessions: ["primary", "reconnected", "primary"])
        defer { model.process(viewAction: .disappeared) }

        try await deferFulfillment(model.context.$viewState) { $0.tasksHaveLoaded && !$0.isTasksLoading }.fulfill()

        let state = model.context.viewState
        XCTAssertEqual(Set(service.taskRequests.map(\.session)), ["primary", "reconnected"])
        XCTAssertEqual(service.taskRequests.count, 2)
        XCTAssertTrue(service.taskRequests.allSatisfy(\.refresh))
        XCTAssertEqual(state.createdTasks.count, 3, "Keep source rows; deduplicate the displayed statistics across sessions")
        XCTAssertEqual(state.taskStatistics.total, 2)
        XCTAssertEqual(state.taskStatistics.completed, 1)
        XCTAssertEqual(state.taskStatistics.backlog, 1)
        XCTAssertEqual(state.taskStatistics.started, 0, "An older snapshot must not resurrect an in-progress status")
        XCTAssertEqual(state.taskStatistics.uniqueTasks.first?.id, recent.id)
        XCTAssertNil(state.tasksError)
        XCTAssertEqual(service.transcriptionRequests, [])
        XCTAssertEqual(service.downloadRequests, 0)
    }

    func testNonPlayableRecordingLoadsTasksUsingSessionMetadataInsteadOfLocalUUID() async throws {
        let row = try task(id: 1, session: "failed-recording", issue: "issue", group: "started")
        let service = DetailTasksService(fetch: { _, _, _ in [row] })
        let model = makeModel(service: service, sessions: ["failed-recording"])
        defer { model.process(viewAction: .disappeared) }

        try await deferFulfillment(model.context.$viewState) { $0.tasksHaveLoaded && !$0.isTasksLoading }.fulfill()

        XCTAssertNotNil(UUID(uuidString: model.context.viewState.call.id))
        XCTAssertNil(model.context.viewState.call.recordingURL)
        XCTAssertEqual(service.taskRequests.map(\.session), ["failed-recording"])
        XCTAssertEqual(model.context.viewState.taskStatistics.started, 1)
        XCTAssertTrue(model.context.viewState.availableTabs.contains(.tasks))
        XCTAssertFalse(model.context.viewState.isTranscriptionLoading)
        XCTAssertEqual(service.transcriptionRequests, [])
        XCTAssertEqual(service.downloadRequests, 0)
    }

    func testFailedTranscriptionDoesNotPreventLinkedTasksLoading() async throws {
        let session = "failed-\(UUID().uuidString)"
        let row = try task(id: 1, session: session, issue: "issue", group: "completed")
        let service = DetailTasksService(fetch: { _, _, _ in [row] }, transcription: { _ in
            TranscriptionData(available: false, status: .failed, transcription: nil, summary: nil,
                              error: TranscriptionError(code: "failed", message: "No transcript", retryable: false))
        })
        let model = makeModel(service: service, sessions: [session], playable: true)
        defer { model.process(viewAction: .disappeared) }

        try await deferFulfillment(model.context.$viewState) {
            $0.tasksHaveLoaded && !$0.isTasksLoading && $0.transcriptionData?.status == .failed
        }.fulfill()

        XCTAssertEqual(model.context.viewState.taskStatistics.completed, 1)
        XCTAssertTrue(model.context.viewState.availableTabs.contains(.tasks))
        XCTAssertNil(model.context.viewState.tasksError)
        XCTAssertEqual(service.transcriptionRequests.count, 1)
    }

    func testExplicitTasksInitialTabSurvivesLateCompletedTranscription() async throws {
        let transcript = DetailResponse<TranscriptionData>()
        defer { transcript.finish(.failure(CancellationError())) }
        let service = DetailTasksService(fetch: { _, _, _ in [] }, transcription: { _ in try await transcript.value() })
        let model = makeModel(service: service, sessions: ["late-\(UUID().uuidString)"], playable: true, initialTab: .tasks)
        defer { model.process(viewAction: .disappeared) }

        XCTAssertEqual(model.context.viewState.selectedTab, .tasks)
        try await deferFulfillment(model.context.$viewState) { $0.tasksHaveLoaded && !$0.isTasksLoading }.fulfill()
        XCTAssertEqual(model.context.viewState.selectedTab, .tasks, "An explicitly requested empty Tasks tab stays visible")

        let completed = deferFulfillment(model.context.$viewState) { $0.transcriptionData?.status == .completed }
        transcript.finish(.success(TranscriptionData(available: true, status: .completed, transcription: nil,
                                                     summary: TranscriptionSummary(text: "A completed call summary", keyPoints: nil,
                                                                                   actionItems: nil, topics: nil), error: nil)))
        try await completed.fulfill()

        XCTAssertTrue(model.context.viewState.availableTabs.contains(.summary))
        XCTAssertTrue(model.context.viewState.availableTabs.contains(.tasks))
        XCTAssertEqual(model.context.viewState.selectedTab, .tasks)
        XCTAssertEqual(service.taskRequests.count, 1)
    }

    func testPartialRefreshFailurePreservesPriorRowsAndRetryClearsError() async throws {
        let prior = try task(id: 1, session: "primary", issue: "prior", group: "started")
        let partial = try task(id: 2, session: "primary", issue: "partial", group: "completed")
        let refreshed = try task(id: 1, session: "primary", issue: "prior", group: "completed")
        let failingPage = DetailResponse<[CreatedTask]>()
        let partialReturned = expectation(description: "Successful half of refresh returned")
        defer { failingPage.finish(.failure(CancellationError())) }
        let service = DetailTasksService(fetch: { session, _, attempt in
            switch (attempt, session) {
            case (1, "primary"): return [prior]
            case (1, _): return []
            case (2, "primary"):
                partialReturned.fulfill()
                return [partial]
            case (2, _): return try await failingPage.value()
            case (_, "primary"): return [refreshed]
            default: return []
            }
        })
        let model = makeModel(service: service, sessions: ["primary", "reconnected"])
        defer { model.process(viewAction: .disappeared) }
        try await deferFulfillment(model.context.$viewState) { $0.tasksHaveLoaded && !$0.isTasksLoading }.fulfill()

        model.process(viewAction: .refreshTasks)
        await fulfillment(of: [partialReturned], timeout: 2)
        XCTAssertEqual(model.context.viewState.createdTasks, [prior])
        let failed = deferFulfillment(model.context.$viewState) { $0.tasksError != nil && !$0.isTasksLoading }
        failingPage.finish(.failure(URLError(.notConnectedToInternet)))
        try await failed.fulfill()
        XCTAssertEqual(model.context.viewState.createdTasks, [prior])
        XCTAssertEqual(model.context.viewState.taskStatistics.started, 1)
        XCTAssertTrue(model.context.viewState.tasksHaveLoaded)

        let retryStarted = deferFulfillment(model.context.$viewState) { $0.isTasksLoading && $0.tasksError == nil }
        let recovered = deferFulfillment(model.context.$viewState) {
            !$0.isTasksLoading && $0.tasksError == nil && $0.taskStatistics.completed == 1
        }
        model.process(viewAction: .refreshTasks)
        try await retryStarted.fulfill()
        try await recovered.fulfill()
        XCTAssertEqual(model.context.viewState.createdTasks, [refreshed])
        XCTAssertEqual(model.context.viewState.taskStatistics.total, 1)
        XCTAssertEqual(model.context.viewState.taskStatistics.started, 0)
        XCTAssertEqual(service.taskRequests.count, 6)
    }

    func testHeaderAndTasksTabActionsCoalesceWhileInitialRequestIsInFlight() async throws {
        let response = DetailResponse<[CreatedTask]>()
        defer { response.finish(.failure(CancellationError())) }
        let started = expectation(description: "Automatic header request started")
        let service = DetailTasksService(fetch: { _, _, attempt in
            if attempt == 1 { started.fulfill() }
            return try await response.value()
        })
        let model = makeModel(service: service, sessions: ["primary"])
        defer { model.process(viewAction: .disappeared) }
        await fulfillment(of: [started], timeout: 2)

        model.process(viewAction: .appeared)
        model.process(viewAction: .refreshTasks)
        model.process(viewAction: .selectTab(.tasks))
        model.process(viewAction: .refreshTasks)
        await drainMainQueue()
        XCTAssertTrue(model.context.viewState.isTasksLoading)
        XCTAssertFalse(model.context.viewState.tasksHaveLoaded)
        XCTAssertEqual(service.taskRequests.count, 1)

        let loaded = deferFulfillment(model.context.$viewState) { $0.tasksHaveLoaded && !$0.isTasksLoading }
        response.finish(.success([]))
        try await loaded.fulfill()
        XCTAssertEqual(service.taskRequests.count, 1)
        XCTAssertEqual(model.context.viewState.selectedTab, .tasks)
        XCTAssertEqual(model.context.viewState.taskStatistics.total, 0)
        XCTAssertNil(model.context.viewState.tasksError)
    }

    func testDisappearAndReturnRejectsLateOldResponseWithoutFinishingNewRequest() async throws {
        let old = DetailResponse<[CreatedTask]>()
        let current = DetailResponse<[CreatedTask]>()
        defer {
            old.finish(.failure(CancellationError()))
            current.finish(.failure(CancellationError()))
        }
        let oldStarted = expectation(description: "Old request started")
        let newStarted = expectation(description: "Return request started")
        let oldReturned = expectation(description: "Cancelled service call returned late")
        let staleRow = try task(id: 1, session: "primary", issue: "stale", group: "started")
        let currentRow = try task(id: 2, session: "primary", issue: "current", group: "completed")
        let service = DetailTasksService(fetch: { _, _, attempt in
            if attempt == 1 {
                oldStarted.fulfill()
                let rows = try await old.value()
                oldReturned.fulfill()
                return rows
            }
            newStarted.fulfill()
            return try await current.value()
        })
        let model = makeModel(service: service, sessions: ["primary"])
        defer { model.process(viewAction: .disappeared) }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.process(viewAction: .disappeared)
        XCTAssertFalse(model.context.viewState.isTasksLoading)
        model.process(viewAction: .appeared)
        await fulfillment(of: [newStarted], timeout: 2)

        // Release the cancelled request BEFORE awaiting anything that depends on its task group finishing.
        old.finish(.success([staleRow]))
        await fulfillment(of: [oldReturned], timeout: 2)
        await drainMainQueue()
        XCTAssertTrue(model.context.viewState.isTasksLoading, "The old completion cannot clear the new request's spinner")
        XCTAssertFalse(model.context.viewState.tasksHaveLoaded)
        XCTAssertTrue(model.context.viewState.createdTasks.isEmpty)

        let loaded = deferFulfillment(model.context.$viewState) { $0.tasksHaveLoaded && !$0.isTasksLoading }
        current.finish(.success([currentRow]))
        try await loaded.fulfill()
        XCTAssertEqual(model.context.viewState.createdTasks, [currentRow])
        XCTAssertEqual(model.context.viewState.taskStatistics.completed, 1)
        XCTAssertEqual(service.taskRequests.count, 2)
    }

    func testIdempotentCreationDoesNotDuplicateAndOldLoadCannotOverwriteCreatedTask() async throws {
        let stale = DetailResponse<[CreatedTask]>()
        defer { stale.finish(.failure(CancellationError())) }
        let started = expectation(description: "Initial load started")
        let oldReturned = expectation(description: "Pre-creation load returned late")
        let created = try task(id: 10, session: "primary", issue: "created", group: "backlog")
        let suggested = try JSONDecoder().decode(SuggestedTask.self, from: Data(#"{"topicIndex":0,"taskIndex":0,"text":"Follow up"}"#.utf8))
        let service = DetailTasksService(fetch: { _, _, attempt in
            if attempt == 1 {
                started.fulfill()
                let rows = try await stale.value()
                oldReturned.fulfill()
                return rows
            }
            return [created]
        }, create: { session, topic, task, project, text in
            XCTAssertEqual(session, "primary")
            XCTAssertEqual(topic, 0)
            XCTAssertEqual(task, 0)
            XCTAssertEqual(project, "project")
            XCTAssertEqual(text, "Edited follow up")
            return created
        })
        let model = makeModel(service: service, sessions: ["primary"])
        defer { model.process(viewAction: .disappeared) }
        await fulfillment(of: [started], timeout: 2)

        var publishedDuplicate = false
        let observation = model.context.$viewState.sink { state in
            if state.createdTasks.filter({ $0.trackitIssueId == "created" }).count > 1 {
                publishedDuplicate = true
            }
        }
        defer { observation.cancel() }
        let createdAndRevalidated = deferFulfillment(model.context.$viewState) {
            $0.tasksHaveLoaded && !$0.isTasksLoading && service.taskRequests.count == 2 && $0.createdTasks == [created]
        }
        model.process(viewAction: .createTask(suggested, projectId: "project", overrideText: "Edited follow up"))
        try await createdAndRevalidated.fulfill()
        XCTAssertEqual(service.taskRequests.count, 2)

        stale.finish(.success([]))
        await fulfillment(of: [oldReturned], timeout: 2)
        await drainMainQueue()
        XCTAssertEqual(model.context.viewState.createdTasks, [created])
        XCTAssertEqual(model.context.viewState.taskStatistics.total, 1)

        let revalidatedAgain = deferFulfillment(model.context.$viewState) {
            !$0.isTasksLoading && service.taskRequests.count == 3 && $0.createdTasks == [created]
        }
        model.process(viewAction: .createTask(suggested, projectId: "project", overrideText: "Edited follow up"))
        try await revalidatedAgain.fulfill()
        XCTAssertEqual(service.creationRequests, 2, "The server may return the same issue for repeated creation")
        XCTAssertEqual(model.context.viewState.createdTasks, [created])
        XCTAssertEqual(model.context.viewState.taskStatistics.total, 1)
        XCTAssertEqual(model.context.viewState.taskStatistics.backlog, 1)
        XCTAssertNil(model.context.viewState.tasksError)
        XCTAssertFalse(publishedDuplicate, "Idempotent creation must not briefly duplicate a card before revalidation fixes it")
    }

    private func makeModel(service: DetailTasksService, sessions: [String], playable: Bool = false,
                           initialTab: CallDetailTab? = nil) -> CallDetailScreenViewModel {
        // Playable tests supply a unique session to avoid existing audio cache entries. Downloads always cancel.
        let session = sessions.first ?? UUID().uuidString
        let url = playable ? URL(string: "https://example.invalid/recording-api/api/recording/play/\(session)") : nil
        let call = CallHistoryItem(id: UUID().uuidString, contactName: "Call", contactId: "!room:example.invalid",
                                   callType: .incoming, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                   duration: 60, isMissed: false, recordingURL: url, recordingSessionIDs: sessions)
        let player = AudioPlayerMock()
        player.actions = Empty<AudioPlayerAction, Never>().eraseToAnyPublisher()
        player.state = .stopped
        player.duration = 0
        player.currentTime = 0
        player.loadSourceURLPlaybackURLAutoplayClosure = { _, _, _ in
            XCTFail("Loading task statistics must not load audio")
        }
        player.playClosure = { XCTFail("Loading task statistics must not start playback") }
        return CallDetailScreenViewModel(call: call, callHistoryService: service, mediaProvider: MediaProviderMock(),
                                         initialTab: initialTab, audioPlayer: player)
    }

    private func task(id: Int, session: String, issue: String, group: String,
                      synced: String = "2026-10-18T08:00:00Z") throws -> CreatedTask {
        let json: [String: Any] = ["id": id, "egress_id": session, "topic_index": 0, "task_index": 0,
                                   "task_text": "Follow up", "trackit_issue_id": issue, "trackit_project_id": "project",
                                   "trackit_state_group": group, "status_synced_at": synced]
        return try JSONDecoder().decode(CreatedTask.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func drainMainQueue() async {
        // Scheduling barriers, not sleeps: allow already-enqueued action/completion work to run.
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Session requests run concurrently in the VM's task group. All bookkeeping is protected by one lock;
/// handlers run outside it and are fixed at initialization, so a suspended request never holds the lock.
private final class DetailTasksService: CallHistoryServiceProtocol, @unchecked Sendable {
    struct Request {
        let session: String
        let refresh: Bool
    }

    private let lock = NSLock()
    private var requests: [Request] = []
    private var transcriptions: [String] = []
    private var downloads = 0
    private var creations = 0
    private let fetch: (String, Bool, Int) async throws -> [CreatedTask]
    private let transcription: (String) async throws -> TranscriptionData
    private let create: (String, Int, Int, String, String?) async throws -> CreatedTask

    init(fetch: @escaping (String, Bool, Int) async throws -> [CreatedTask],
         transcription: @escaping (String) async throws -> TranscriptionData = { _ in throw URLError(.cancelled) },
         create: @escaping (String, Int, Int, String, String?) async throws -> CreatedTask = { _, _, _, _, _ in throw URLError(.unsupportedURL) }) {
        self.fetch = fetch
        self.transcription = transcription
        self.create = create
    }

    var taskRequests: [Request] {
        locked { requests }
    }

    var transcriptionRequests: [String] {
        locked { transcriptions }
    }

    var downloadRequests: Int {
        locked { downloads }
    }

    var creationRequests: Int {
        locked { creations }
    }

    func fetchCreatedTasks(egressId: String, refresh: Bool) async throws -> [CreatedTask] {
        let attempt = locked {
            requests.append(Request(session: egressId, refresh: refresh))
            return requests.filter { $0.session == egressId }.count
        }
        return try await fetch(egressId, refresh, attempt)
    }

    func fetchTranscription(egressId: String) async throws -> TranscriptionData {
        locked { transcriptions.append(egressId) }
        return try await transcription(egressId)
    }

    func downloadRecording(from url: URL) async throws -> Data {
        locked { downloads += 1 }
        throw URLError(.cancelled)
    }

    func createTask(egressId: String, topicIndex: Int, taskIndex: Int, projectId: String, overrideText: String?) async throws -> CreatedTask {
        locked { creations += 1 }
        return try await create(egressId, topicIndex, taskIndex, projectId, overrideText)
    }

    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem] {
        XCTFail("Call detail must not load the recording list")
        throw URLError(.unsupportedURL)
    }

    func retryTranscription(egressId: String) async throws -> TranscriptionData {
        XCTFail("Task actions must not retry transcription")
        throw URLError(.unsupportedURL)
    }

    func searchTrackItProjects(query: String) async throws -> [TrackItProject] {
        XCTFail("These task actions must not search projects")
        throw URLError(.unsupportedURL)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Deliberately ignores cancellation to model a service response arriving after navigation or creation.
/// Resolving before registration is supported, and deferred cleanup releases every waiter on test failure.
private final class DetailResponse<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(with: result)
        }
    }
}
