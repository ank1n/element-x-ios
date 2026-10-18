// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import Foundation
import MatrixRustSDK
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ThreadsCalendarParityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testCallOnAnotherDayDoesNotAttachToRecurringRoom() throws {
        let planned = try meeting()
        let entries = CalendarAgendaEntry.make(meetings: [planned], calls: [call(id: "later", offset: 86400)], showUnplanned: true)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.meeting != nil }?.calls.isEmpty))
    }

    func testOverlappingCallAugmentsMeetingWithoutDuplicateEvent() throws {
        let entries = try CalendarAgendaEntry.make(meetings: [meeting()], calls: [call(id: "overlap", offset: 10)], showUnplanned: true)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].calls.map(\.id), ["overlap"])
        XCTAssertEqual(entries[0].taskCount, 3)
    }

    func testMeetingWithoutEndUsesTheSameOneHourWindowAsWeb() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data: [String: Any] = ["id": 2, "title": "No end", "matrix_room_id": "!room:example.invalid",
                                   "start_time": ISO8601DateFormatter().string(from: start), "end_time": NSNull(), "is_indefinite": true]
        let planned = try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: data))
        let entries = CalendarAgendaEntry.make(meetings: [planned], calls: [call(id: "inside", offset: 60), call(id: "outside", offset: 3700)], showUnplanned: true)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.meeting != nil }?.calls.map(\.id), ["inside"])
    }

    func testDifferentRoomStaysSeparateAndToggleOnlyHidesUnplanned() throws {
        var other = call(id: "other", offset: 10)
        other = CallHistoryItem(id: other.id, contactName: "Other", contactId: "!other:example.invalid", callType: .incoming,
                                timestamp: other.timestamp, duration: 30, isMissed: false, recordingURL: nil)
        let calls = [call(id: "planned", offset: 20), other]
        let visible = try CalendarAgendaEntry.make(meetings: [meeting()], calls: calls, showUnplanned: true)
        let hidden = try CalendarAgendaEntry.make(meetings: [meeting()], calls: calls, showUnplanned: false)
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(hidden.count, 1)
        XCTAssertEqual(hidden[0].calls.map(\.id), ["planned"])
    }

    func testSameLogicalCallDoesNotDoubleTaskCount() {
        var first = call(id: "part-1", offset: 0)
        first.callId = "logical"
        var second = call(id: "part-2", offset: 20)
        second.callId = "logical"
        let entries = CalendarAgendaEntry.make(meetings: [], calls: [first, second], showUnplanned: true)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].taskCount, 3)
    }

    func testCancelledMeetingDoesNotConsumeCall() throws {
        var cancelled = try meeting()
        cancelled.status = .cancelled
        let entries = CalendarAgendaEntry.make(meetings: [cancelled], calls: [call(id: "actual", offset: 10)], showUnplanned: true)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].meeting)
    }

    func testV3AttributionPreservesTwoPeopleWithSameName() throws {
        let json = #"{"available":true,"status":"completed","transcription":{"language":"ru","fullText":"Привет","segments":[{"speaker":"Миша","speaker_id":"@misha.g:example.invalid","start":0,"end":2,"text":"Привет"}]},"summary":{"topics":[{"title":"Смета","mentions":["@misha.p:example.invalid","@misha.g:example.invalid"],"suggestedTasks":[{"topicIndex":0,"taskIndex":1,"text":"Миша — смета","assignee":{"matrix_id":"@misha.g:example.invalid","display_name":"Миша"}}]}]}}"#
        let data = try JSONDecoder().decode(TranscriptionData.self, from: Data(json.utf8))
        XCTAssertEqual(data.transcription?.segments.first?.speakerID, "@misha.g:example.invalid")
        XCTAssertEqual(data.summary?.topics?.first?.suggestedTasks?.first?.assignee?.matrixID, "@misha.g:example.invalid")
        XCTAssertEqual(try CallSummaryPeople.uniqueIDs(XCTUnwrap(data.summary?.topics?[0].mentions)), ["@misha.p:example.invalid", "@misha.g:example.invalid"])
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionData.self, from: JSONEncoder().encode(data)), data)
    }

    func testLegacySummaryAndNullAssigneeStillDecode() throws {
        let task = try JSONDecoder().decode(SuggestedTask.self, from: Data(#"{"topic_index":2,"task_index":3,"text":"Task","assignee":null}"#.utf8))
        XCTAssertNil(task.assignee)
        XCTAssertEqual(task.topicIndex, 2)
        let segment = try JSONDecoder().decode(TranscriptionSegment.self, from: Data(#"{"speaker":"Old speaker","start":0,"end":1,"text":"Old"}"#.utf8))
        XCTAssertNil(segment.speakerID)
        XCTAssertEqual(CallSummaryPeople.uniqueIDs(["Миша", "@p:example.invalid", "@p:example.invalid", "@bad:has space"]), ["@p:example.invalid"])
    }

    func testRecordedAttendeesStripDeviceWithoutLosingPortOrGuest() {
        let tracks = [
            CallParticipantTrack(participantIdentity: "@misha:example.invalid:DEVICE", participantName: "Миша"),
            CallParticipantTrack(participantIdentity: "@misha:example.invalid:OTHER", participantName: "Миша"),
            CallParticipantTrack(participantIdentity: "@misha:example.invalid:8448:DEVICE", participantName: "Миша"),
            CallParticipantTrack(participantIdentity: "guest-1", participantName: "Гость"),
            CallParticipantTrack(participantIdentity: "EG_recorder", participantName: "Recorder")
        ]
        XCTAssertEqual(CallAttendee.from(tracks: tracks).map(\.id), ["@misha:example.invalid", "@misha:example.invalid:8448", "guest-1"])
        XCTAssertFalse(CallSummaryPeople.isUserID("guest-1"))
    }

    func testThreadsRolloutUpgradesSavedFalseOnlyOnce() throws {
        let name = "threads-rollout-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "threadsEnabled")
        AppSettings.enableNativeThreadsIfNeeded(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "threadsEnabled"))
        defaults.set(false, forKey: "threadsEnabled")
        AppSettings.enableNativeThreadsIfNeeded(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: "threadsEnabled"), "Later explicit setting is preserved")
    }

    func testThreadListFailurePreservesSnapshotAndRetryWorks() async {
        let service = ThreadListFake()
        service.rows = [thread("$root")]
        service.fail = true
        let model = RoomThreadListModel(service: service)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.endReached)
        service.fail = false
        service.rows.append(thread("$second"))
        await model.loadMore()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(model.endReached)
    }

    func testThreadListDeduplicatesRootAndRefreshResetsPagination() async {
        let service = ThreadListFake()
        service.rows = [thread("$root"), thread("$root")]
        let model = RoomThreadListModel(service: service)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        let before = service.pages
        await model.loadMore()
        XCTAssertEqual(service.pages, before)
        await model.refresh()
        XCTAssertEqual(service.resets, 1)
        XCTAssertEqual(service.pages, before + 1)
    }

    func testThreadMenuHonoursPermissionsAndDoesNotOfferNestedThreads() {
        var message = TextRoomTimelineItem(id: .randomEvent, timestamp: start, isOutgoing: false, isEditable: false,
                                           canBeRepliedTo: true, sender: .init(id: "@qa:example.invalid", displayName: "QA"),
                                           content: .init(body: "A message"))
        func actions(_ item: EventBasedTimelineItemProtocol, canSend: Bool = true, kind: TimelineKind = .live) -> [TimelineItemMenuAction] {
            TimelineItemMenuActionProvider(timelineItem: item, canCurrentUserSendMessage: canSend,
                                           canCurrentUserRedactSelf: false, canCurrentUserRedactOthers: false, canCurrentUserPin: false,
                                           pinnedEventIDs: [], isDM: false, isViewSourceEnabled: false, areThreadsEnabled: true,
                                           timelineKind: kind, emojiProvider: EmojiProvider(appSettings: AppSettings()), bookmarkService: nil)
                .makeActions()?.actions ?? []
        }
        XCTAssertTrue(actions(message).contains(.replyInThread))
        XCTAssertFalse(actions(message, canSend: false).contains(.replyInThread))
        XCTAssertFalse(actions(message, kind: .thread(rootEventID: "$root")).contains(.replyInThread))
        message.properties.isThreaded = true
        XCTAssertFalse(actions(message, kind: .detached).contains(.replyInThread))
        let unsupported = UnsupportedRoomTimelineItem(id: .randomEvent, body: "Unknown", eventType: "io.unsupported",
                                                      error: "Unsupported", timestamp: start, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                                      sender: .init(id: "@qa:example.invalid"))
        XCTAssertFalse(actions(unsupported).contains(.replyInThread))
        var sticker = StickerRoomTimelineItem(id: .randomEvent, body: "Sticker", timestamp: start, isOutgoing: false,
                                              isEditable: false, canBeRepliedTo: true, sender: .init(id: "@qa:example.invalid"), imageInfo: .mockImage)
        sticker.properties.isThreaded = true
        XCTAssertFalse(actions(sticker, kind: .detached).contains(.replyInThread))
    }

    func testNativeViewsRenderAtPhoneWidthWithLargeText() async throws {
        for size in [DynamicTypeSize.large, .xxxLarge] {
            var event = thread("$root").rootEvent
            event.senderProfile = .ready(displayName: "Участник обсуждения с длинным именем", displayNameAmbiguous: false, avatarUrl: nil)
            let item = ThreadListItem(rootEvent: event, latestEvent: event, numReplies: 120)
            try await attach(RoomThreadListRow(item: item).padding(16).frame(width: 320)
                .environment(\.dynamicTypeSize, size), name: "Thread row \(size)")

            var calendarState = MeetingsScreenViewState()
            calendarState.isLoading = false
            calendarState.selectedDate = start
            calendarState.meetings = try [meeting()]
            calendarState.calls = [call(id: "planned", offset: 10), call(id: "unplanned", offset: 4000)]
            let calendarStore = MeetingsScreenViewModelType(initialViewState: calendarState)
            try await attach(MeetingsListScreen(context: calendarStore.context).frame(width: 390, height: 844)
                .environment(\.dynamicTypeSize, size), name: "Calendar calls \(size)")

            var detail = CallDetailScreenViewState(call: call(id: "details", offset: 0))
            detail.isTranscriptionLoading = false
            detail.actualAttendees = [.init(id: "@misha.p:example.invalid", name: "Миша"),
                                      .init(id: "@misha.g:example.invalid", name: "Миша")]
            let detailStore = CallDetailScreenViewModelType(initialViewState: detail)
            try await attach(CallDetailScreen(context: detailStore.context).frame(width: 390, height: 600)
                .environment(\.dynamicTypeSize, size), name: "Same-name attendees \(size)")
        }
    }

    private func attach<V: View>(_ view: V, name: String) async throws {
        // List/ScrollView/native controls cannot be captured by SwiftUI ImageRenderer.
        // Host the actual view hierarchy in a temporary simulator window instead.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view.background(Color.white).environment(\.colorScheme, .light))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: name.hasPrefix("Thread") ? 320 : 390,
                              height: name.hasPrefix("Thread") ? 350 : 844)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; oldKey?.makeKey() }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertGreaterThan(image.size.width, 300)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func call(id: String, offset: TimeInterval) -> CallHistoryItem {
        CallHistoryItem(id: id, contactName: "Call", contactId: "!room:example.invalid", callType: .incoming,
                        timestamp: start.addingTimeInterval(offset), duration: 30, isMissed: false, recordingURL: nil, createdTaskCount: 3)
    }

    private func meeting() throws -> Meeting {
        let json: [String: Any] = ["id": 1, "title": "Planned", "start_time": ISO8601DateFormatter().string(from: start),
                                   "end_time": ISO8601DateFormatter().string(from: start.addingTimeInterval(3600)),
                                   "matrix_room_id": "!room:example.invalid", "status": "scheduled"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func thread(_ id: String) -> ThreadListItem {
        ThreadListItem(rootEvent: .init(eventId: id, timestamp: 1000, sender: "@qa:example.invalid", senderProfile: .unavailable,
                                        isOwn: false, content: nil), latestEvent: nil, numReplies: 1)
    }
}

private final class ThreadListFake: ThreadListServiceProtocol, @unchecked Sendable {
    var rows: [ThreadListItem] = []
    var fail = false
    var pages = 0
    var resets = 0
    func items() -> [ThreadListItem] {
        rows
    }

    func paginationState() -> ThreadListPaginationState {
        .idle(endReached: true)
    }

    func paginate() async throws {
        pages += 1; if fail { throw URLError(.notConnectedToInternet) }
    }

    func reset() async {
        resets += 1
    }

    func subscribeToItemsUpdates(listener: ThreadListEntriesListener) -> TaskHandle {
        TestHandle(noHandle: .init())
    }

    func subscribeToPaginationStateUpdates(listener: ThreadListPaginationStateListener) -> TaskHandle {
        TestHandle(noHandle: .init())
    }
}

private final class TestHandle: TaskHandle, @unchecked Sendable {
    override func cancel() { }
}
