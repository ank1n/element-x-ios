//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import UserNotifications
import XCTest

/// STALK-951 / STMOB-309: любой тап по уведомлению ведёт в комнату и ждёт, пока синк её привезёт, —
/// а не только тап по приглашению. Иначе чат, созданный, пока приложение спало, открывался
/// экраном «нужно приглашение».
@MainActor
final class NotificationTapHandlingTests: XCTestCase {
    private let roomID = "!room:example.com"

    func testMessageTapAwaitsTheRoom() {
        let tap = AppCoordinator.notificationTapHandling(for: content(), focusEventOnTap: false, threadsEnabled: false)

        XCTAssertEqual(tap?.route, .room(roomID: roomID, via: []))
        XCTAssertEqual(tap?.roomToAwait, roomID)
    }

    func testFocusedEventTapAwaitsTheRoom() {
        let tap = AppCoordinator.notificationTapHandling(for: content(eventID: "$event"), focusEventOnTap: true, threadsEnabled: false)

        XCTAssertEqual(tap?.route, .event(eventID: "$event", roomID: roomID, via: []))
        XCTAssertEqual(tap?.roomToAwait, roomID)
    }

    func testThreadTapAwaitsTheRoom() {
        let tap = AppCoordinator.notificationTapHandling(for: content(eventID: "$event", threadRootEventID: "$root"), focusEventOnTap: true, threadsEnabled: true)

        XCTAssertEqual(tap?.route, .thread(roomID: roomID, threadRootEventID: "$root", focusEventID: "$event"))
        XCTAssertEqual(tap?.roomToAwait, roomID)
    }

    func testInviteTapAwaitsTheRoom() {
        let tap = AppCoordinator.notificationTapHandling(for: content(category: NotificationConstants.Category.invite), focusEventOnTap: true, threadsEnabled: false)

        XCTAssertEqual(tap?.route, .room(roomID: roomID, via: []))
        XCTAssertEqual(tap?.roomToAwait, roomID)
    }

    func testCallNoticeTapOpensTheRoomAndAwaitsIt() {
        let tap = AppCoordinator.notificationTapHandling(for: content(eventID: "$event", isCallNotice: true), focusEventOnTap: true, threadsEnabled: false)

        XCTAssertEqual(tap?.route, .room(roomID: roomID, via: []), "A call banner leads to the room, not straight into a call.")
        XCTAssertEqual(tap?.roomToAwait, roomID)
    }

    func testTapWithoutRoomIsIgnored() {
        let content = UNMutableNotificationContent()

        XCTAssertNil(AppCoordinator.notificationTapHandling(for: content, focusEventOnTap: true, threadsEnabled: true))
    }

    // MARK: - Кому отдать комнату
    
    func testRoomIsHandedToTheClientWhenThereIsASession() {
        let clientProxy = ClientProxyMock(.init())
        var stored: Set<String>?
        
        AppCoordinator.awaitRoom(roomID, clientProxy: clientProxy, stored: &stored)
        
        XCTAssertEqual(clientProxy.addRoomsToAwaitReceivedRoomIDs, [roomID])
        XCTAssertNil(stored)
    }
    
    /// Холодный старт по тапу: сессии ещё нет — запоминаем, и второй тап не стирает первый.
    func testRoomsAreKeptUntilTheSessionAppears() {
        var stored: Set<String>?
        
        AppCoordinator.awaitRoom(roomID, clientProxy: nil, stored: &stored)
        AppCoordinator.awaitRoom("!other:example.com", clientProxy: nil, stored: &stored)
        
        XCTAssertEqual(stored, [roomID, "!other:example.com"])
    }
    
    // MARK: - STMOB-307: ответ прямо из уведомления
    
    func testInlineReplyWaitsForTheRoomAndSends() async {
        let clientProxy = ClientProxyMock(.init())
        let notificationManager = NotificationManagerMock()
        let roomProxy = JoinedRoomProxyMock(.init(id: roomID))
        let timeline = TimelineProxyMock(.init())
        timeline.sendMessageHtmlInReplyToEventIDIntentionalMentionsReturnValue = .success(())
        roomProxy.timeline = timeline
        var awaitedBeforeLookup: Set<String>?
        clientProxy.roomForIdentifierClosure = { [clientProxy] _ in
            awaitedBeforeLookup = clientProxy.addRoomsToAwaitReceivedRoomIDs
            return .joined(roomProxy)
        }
        
        await AppCoordinator.sendInlineReply(roomID: roomID, replyText: "Привет", clientProxy: clientProxy, notificationManager: notificationManager)
        
        XCTAssertEqual(awaitedBeforeLookup, [roomID], "The room must be awaited before it is looked up.")
        XCTAssertTrue(timeline.sendMessageHtmlInReplyToEventIDIntentionalMentionsCalled)
        XCTAssertFalse(notificationManager.showLocalNotificationWithSubtitleCalled)
    }
    
    /// Чат так и не доехал: раньше ответ молча пропадал, теперь человек видит «не отправлено».
    func testInlineReplyToAMissingRoomTellsTheUser() async {
        let clientProxy = ClientProxyMock(.init())
        let notificationManager = NotificationManagerMock()
        clientProxy.roomForIdentifierClosure = { _ in nil }
        
        await AppCoordinator.sendInlineReply(roomID: roomID, replyText: "Привет", clientProxy: clientProxy, notificationManager: notificationManager)
        
        XCTAssertTrue(notificationManager.showLocalNotificationWithSubtitleCalled)
    }
    
    // MARK: - Helpers

    private func content(eventID: String? = nil,
                         threadRootEventID: String? = nil,
                         category: String = "",
                         isCallNotice: Bool = false) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.roomID = roomID
        content.eventID = eventID
        content.threadRootEventID = threadRootEventID
        content.categoryIdentifier = category
        if isCallNotice {
            content.userInfo[NotificationConstants.UserInfoKey.callNotice] = true
        }
        return content
    }
}
