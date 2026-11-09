// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
@testable import ElementX
import SwiftUI
import UIKit
import XCTest

@MainActor
final class CallDetailPresentationTests: XCTestCase {
    func testLegacyDeviceIdentitiesAndServerPortsResolveWithoutNameGuessing() {
        XCTAssertEqual(CallSummaryMentions.userID("@stymbay:stalk.implica.ru:STALK_36E41", knownIDs: []), "@stymbay:stalk.implica.ru")
        XCTAssertEqual(CallSummaryMentions.userID("@a:host.invalid:8448:DEVICE", knownIDs: []), "@a:host.invalid:8448")
        XCTAssertEqual(CallSummaryMentions.userID("@a:[2001:db8::1]:8448:DEVICE", knownIDs: []), "@a:[2001:db8::1]:8448")
        XCTAssertNil(CallSummaryMentions.userID("Sergey", knownIDs: ["@sergey:example.invalid"]))
    }

    func testBareMentionRequiresOneExactRosterAccount() {
        XCTAssertEqual(CallSummaryMentions.userID("@ms.implica", knownIDs: ["@ms.implica:stalk.implica.ru"]), "@ms.implica:stalk.implica.ru")
        XCTAssertNil(CallSummaryMentions.userID("@alex", knownIDs: ["@alex:one.invalid", "@alex:two.invalid"]))
        XCTAssertNil(CallSummaryMentions.userID("@unknown", knownIDs: ["@alex:one.invalid"]))
    }

    func testMentionRangesPreserveUnicodePunctuationEmailsAndURLs() {
        let text = "🙂 Миша (@ms.implica), @stymbay:stalk.implica.ru:STALK_36E41. a@b.invalid https://matrix.to/#/@other:host.invalid"
        let mentions = CallSummaryMentions.mentions(in: text, knownIDs: ["@ms.implica:stalk.implica.ru"])
        XCTAssertEqual(mentions.map(\.userID), ["@ms.implica:stalk.implica.ru", "@stymbay:stalk.implica.ru"])
        XCTAssertEqual(mentions.map { (text as NSString).substring(with: $0.range) }, ["@ms.implica", "@stymbay:stalk.implica.ru:STALK_36E41"])
    }

    func testCreatedTaskShowsHumanNumberAndServerStateWithoutUsingUUIDAsNumber() throws {
        let data = Data(#"{"id":1,"egress_id":"session","topic_index":0,"task_index":0,"task_text":"Do it","trackit_issue_id":"opaque-uuid","trackit_project_identifier":"STMOB","trackit_sequence_id":319,"trackit_state_name":"Проверка","trackit_state_group":"started"}"#.utf8)
        let task = try JSONDecoder().decode(CreatedTask.self, from: data)
        XCTAssertEqual(task.callDisplayIdentifier, "STMOB-319")
        XCTAssertEqual(task.callDisplayStatus, "Проверка")
        let missing = try JSONDecoder().decode(CreatedTask.self, from: Data(#"{"id":2,"egress_id":"session","topic_index":0,"task_index":1,"task_text":"Do it","trackit_issue_id":"opaque-uuid"}"#.utf8))
        XCTAssertFalse(missing.callDisplayIdentifier.contains("opaque-uuid"))
        XCTAssertFalse(missing.callDisplayIdentifier.isEmpty)
        XCTAssertFalse(missing.callDisplayStatus.isEmpty)
    }

    func testFilterOrderMatchesPublishedWebAndStoredIDsDoNotChange() {
        XCTAssertEqual(RoomListFilter.primaryDisplayOrder, [.people, .rooms, .channels, .meetings])
        XCTAssertEqual(RoomListFilter.channels.rawValue, 7)
        XCTAssertEqual(RoomListFilter.meetings.rawValue, 4)
    }

    func testRenderedCallDetailsMentionsTasksAndCompactFilters() async throws {
        let service = try PresentationHistoryService()
        let call = CallHistoryItem(id: "session-preview", contactName: "Пресейл и маркетинговые материалы", contactId: "!room:example.invalid",
                                   callType: .incoming, timestamp: Date(), duration: 805, isMissed: false,
                                   recordingURL: nil, recordingSessionIDs: ["session-preview"])
        let player = AudioPlayerMock()
        player.actions = Empty<AudioPlayerAction, Never>().eraseToAnyPublisher()
        player.state = .stopped; player.duration = 805; player.currentTime = 0
        let model = CallDetailScreenViewModel(call: call, callHistoryService: service, mediaProvider: MediaProviderMock(), audioPlayer: player)
        defer { model.process(viewAction: .disappeared) }
        model.state.transcriptionData = service.data
        model.state.participantProfiles = ["@ms.implica:stalk.implica.ru": .init(displayName: "Михаил Самусенко", avatarURL: nil), "@stymbay:stalk.implica.ru": .init(displayName: "Сергей Тымбай", avatarURL: nil)]
        for tab in [CallDetailTab.summary, .details, .transcription, .tasks] {
            model.process(viewAction: .selectTab(tab))
            try await capture(NavigationStack { CallDetailScreen(context: model.context) }, name: "Call \(tab) 320", width: 320)
        }
        try await capture(RoomListFiltersView(state: .constant(.init(appSettings: AppSettings()))), name: "Web four filters 320", width: 320)
        try await capture(RoomListFiltersView(state: .constant(.init(activeFilters: [.rooms], appSettings: AppSettings()))), name: "Web filters active groups", width: 320)
    }

    func testChannelPostFooterOnNarrowScreen() async throws {
        let model = TimelineViewModel.mock(timelineKind: .live)
        // Let the mock room's initial asynchronous snapshot settle before
        // installing channel access, otherwise it replaces the test fixture.
        try await Task.sleep(for: .milliseconds(350))
        var access = StalkChannelSnapshot()
        access.isChannel = true; access.joined = true; access.comments = true
        model.state.channelAccess = access
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.context.viewState.isChannelMain)
        var post = TextRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false,
                                        isEditable: false, canBeRepliedTo: false,
                                        sender: .init(id: "@ivan:example.invalid", displayName: "Иван Жилин"),
                                        content: .init(body: "Публикация в канале"))
        post.properties.threadSummary = .loaded(senderID: "@anna:example.invalid", sender: .init(id: "@anna:example.invalid", displayName: "Анна"),
                                                latestEventContent: .message(.text(.init(body: "Комментарий"))), numberOfReplies: 12)
        try await capture(TextRoomTimelineView(timelineItem: post)
            .environmentObject(model.context).environment(\.timelineContext, model.context), name: "Channel post comments 320", width: 320)
        XCTAssertTrue(model.context.viewState.isChannelMain)
        let actions = try XCTUnwrap(TimelineItemMenuActionProvider(timelineItem: post,
                                                                   canCurrentUserSendMessage: false, canCurrentUserRedactSelf: false, canCurrentUserRedactOthers: false,
                                                                   canCurrentUserPin: false, pinnedEventIDs: [], isDM: false, isViewSourceEnabled: false,
                                                                   areThreadsEnabled: true, timelineKind: .live, emojiProvider: EmojiProvider(appSettings: AppSettings()),
                                                                   bookmarkService: nil, channel: access).makeActions())
        try await capture(TimelineItemMenu(item: post, actions: actions, compact: true).environmentObject(model.context), name: "Post tap icon menu 320", width: 320)
        try await capture(TimelineItemMenu(item: post, actions: actions).environmentObject(model.context), name: "Post full menu 320", width: 320)
        model.state.channelAccess = nil
        try await Task.sleep(for: .milliseconds(100))
        let chatPost = TextRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false,
                                            isEditable: false, canBeRepliedTo: true,
                                            sender: post.sender, content: .init(body: "Сообщение в чате"))
        let chatActions = try XCTUnwrap(TimelineItemMenuActionProvider(timelineItem: chatPost,
                                                                       canCurrentUserSendMessage: true, canCurrentUserRedactSelf: true, canCurrentUserRedactOthers: true,
                                                                       canCurrentUserPin: true, pinnedEventIDs: [], isDM: false, isViewSourceEnabled: false,
                                                                       areThreadsEnabled: true, timelineKind: .live, emojiProvider: EmojiProvider(appSettings: AppSettings()),
                                                                       bookmarkService: nil).makeActions())
        try await capture(TimelineItemMenu(item: chatPost, actions: chatActions).environmentObject(model.context), name: "Chat full menu 320", width: 320)
    }

    func testReplySwipeRequiresLeftMovementAndNeverRepliesAfterCancellation() {
        var swipe = SwipeReplyActionState()
        XCTAssertFalse(swipe.update(.init(width: -20, height: 2), enabled: true))
        XCTAssertFalse(swipe.finish(cancelled: false, enabled: true))
        XCTAssertTrue(swipe.update(.init(width: -60, height: 2), enabled: true))
        XCTAssertTrue(swipe.finish(cancelled: false, enabled: true))
        XCTAssertEqual(swipe.offset, 0)
        _ = swipe.update(.init(width: -80, height: 1), enabled: true)
        XCTAssertFalse(swipe.finish(cancelled: true, enabled: true))
        _ = swipe.update(.init(width: -80, height: 1), enabled: true)
        XCTAssertFalse(swipe.finish(cancelled: false, enabled: false))
        for translation in [CGSize(width: 90, height: 0), .init(width: -40, height: 90), .init(width: 90, height: 1)] {
            XCTAssertFalse(swipe.update(translation, enabled: false))
            XCTAssertFalse(swipe.finish(cancelled: false, enabled: false))
        }
        XCTAssertFalse(swipe.update(.init(width: 90, height: 0), enabled: true))
        XCTAssertFalse(swipe.update(.init(width: -40, height: 90), enabled: true))
        XCTAssertFalse(swipe.finish(cancelled: false, enabled: true))
    }

    func testHorizontalGestureRejectsVerticalMotionBeforeBeginning() {
        final class Pan: UIPanGestureRecognizer {
            var speed = CGPoint.zero
            override func velocity(in view: UIView?) -> CGPoint {
                speed
            }
        }
        let coordinator = HorizontalPanGesture.Coordinator(shouldBegin: { true }, allowsLeftward: true)
        let pan = Pan()
        pan.speed = .init(x: 10, y: 200)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
        pan.speed = .init(x: 200, y: 10)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(pan))
        pan.speed = .init(x: -200, y: 10)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.allowsLeftward = false
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
        pan.speed = .init(x: 200, y: 0)
        coordinator.allowsLeftward = true
        coordinator.allowsRightward = false
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
        pan.speed = .init(x: -200, y: 0)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.shouldBegin = { false }
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
        let scrollView = UIScrollView()
        withExtendedLifetime(scrollView) {
            XCTAssertTrue(coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer))
        }
        XCTAssertFalse(coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()))
    }

    func testFileSearchCardAndVideoReceptionNoticeOnNarrowScreen() async throws {
        let hit = try JSONDecoder().decode(SystemSearchHit.self, from: Data(#"{"id":"file1","entity_type":"file","facet_type":"attachment","entity_id":"$event","title":"rosseti-reserve-v2.pptx","snippet":"<!-- Slide number: 1 --> ![logo.png](Picture1.jpg)","meta":{"filename":"rosseti-reserve-v2.pptx","size":2700000,"author":"Михаил Самусенко","room":"Пресейл и маркетинговые материалы"},"target":{"kind":"room","room_id":"!room:example.com","event_id":"$event"}}"#.utf8))
        try await capture(SystemSearchResultRow(hit: hit), name: "Search file without extraction artifacts", width: 320)
        let reception = CallCameraReception { [] }
        reception.setEnabled(false)
        await reception.waitForPendingChanges()
        try await capture(CallIncomingVideoNotice(reception: reception).background(.black), name: "Incoming camera video disabled", width: 320)
    }

    private func capture<V: View>(_ view: V, name: String, width: CGFloat) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view.background(Color(.systemBackground)))
        window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.makeKeyAndVisible(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private final class PresentationHistoryService: CallHistoryServiceProtocol {
    let data: TranscriptionData
    let task: CreatedTask
    init() throws {
        let topic = SummaryTopic(title: "Методика расчёта резерва мощности", mentions: ["@ms.implica:stalk.implica.ru"],
                                 discussed: "Миша (@ms.implica) уточняет методику. Сергей (@stymbay) проверяет расчёты.", agreed: "Проверить расчёты", timestamp: 0, suggestedTasks: nil)
        data = TranscriptionData(available: true, status: .completed, transcription: .init(language: "ru", segments: [
            .init(speaker: "@stymbay:stalk.implica.ru:STALK_36E41", speakerLabel: nil, start: 0, end: 10, text: "Михаил (@ms.implica) проверяет расчёты.", confidence: 1, channel: 0)
        ], fullText: "Проверить расчёты"), summary: .init(text: nil, keyPoints: nil, actionItems: nil, topics: [topic]), error: nil)
        task = try JSONDecoder().decode(CreatedTask.self, from: Data(#"{"id":1,"egress_id":"session-preview","topic_index":0,"task_index":0,"task_text":"Проверить расчёты резерва мощности","trackit_issue_id":"issue","trackit_project_identifier":"STMOB","trackit_sequence_id":319,"trackit_state_name":"В работе","trackit_state_group":"started"}"#.utf8))
    }

    func fetchRecordings(currentUserID: String?) async throws -> [CallHistoryItem] {
        []
    }

    func fetchTranscription(egressId: String) async throws -> TranscriptionData {
        data
    }

    func fetchCallAttendees(egressId: String) async throws -> [CallAttendee] {
        [.init(id: "@ms.implica:stalk.implica.ru", name: "Михаил Самусенко"), .init(id: "@stymbay:stalk.implica.ru", name: "Сергей Тымбай")]
    }

    func retryTranscription(egressId: String) async throws -> TranscriptionData {
        data
    }

    func downloadRecording(from url: URL) async throws -> Data {
        throw URLError(.cancelled)
    }

    func fetchCreatedTasks(egressId: String, refresh: Bool) async throws -> [CreatedTask] {
        [task]
    }

    func createTask(egressId: String, topicIndex: Int, taskIndex: Int, projectId: String, overrideText: String?) async throws -> CreatedTask {
        task
    }

    func searchTrackItProjects(query: String) async throws -> [TrackItProject] {
        []
    }
}
