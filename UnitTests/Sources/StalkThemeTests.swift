//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import ElementX

@MainActor
class StalkThemeTests: XCTestCase {
    // MARK: - SL10n Tests

    func testTabStringsNotEmpty() {
        XCTAssertFalse(SL10n.tabContacts.isEmpty)
        XCTAssertFalse(SL10n.tabCalls.isEmpty)
        XCTAssertFalse(SL10n.tabChats.isEmpty)
        XCTAssertFalse(SL10n.tabApps.isEmpty)
        XCTAssertFalse(SL10n.tabSettings.isEmpty)
    }

    func testAttachmentStringsNotEmpty() {
        XCTAssertFalse(SL10n.attachCamera.isEmpty)
        XCTAssertFalse(SL10n.attachGallery.isEmpty)
        XCTAssertFalse(SL10n.attachFile.isEmpty)
        XCTAssertFalse(SL10n.attachLocation.isEmpty)
        XCTAssertFalse(SL10n.attachPoll.isEmpty)
        XCTAssertFalse(SL10n.attachFormat.isEmpty)
    }

    func testCallStringsNotEmpty() {
        XCTAssertFalse(SL10n.callHand.isEmpty)
        XCTAssertFalse(SL10n.callCamera.isEmpty)
        XCTAssertFalse(SL10n.callMic.isEmpty)
        XCTAssertFalse(SL10n.callEnd.isEmpty)
        XCTAssertFalse(SL10n.callScreenShare.isEmpty)
        XCTAssertFalse(SL10n.callCalling.isEmpty)
        XCTAssertFalse(SL10n.callReconnecting.isEmpty)
    }

    func testContactsFormatFunctions() {
        let minutesAgo = SL10n.contactsMinutesAgo(5)
        XCTAssertTrue(minutesAgo.contains("5"))

        let hoursAgo = SL10n.contactsHoursAgo(3)
        XCTAssertTrue(hoursAgo.contains("3"))

        let allCount = SL10n.contactsAllCount(42)
        XCTAssertTrue(allCount.contains("42"))

        let onlineCount = SL10n.contactsOnlineCount(7)
        XCTAssertTrue(onlineCount.contains("7"))

        let favCount = SL10n.contactsFavoritesCount(12)
        XCTAssertTrue(favCount.contains("12"))
    }

    func testMeetingFormatFunctions() {
        let participants = SL10n.meetingParticipants(5)
        XCTAssertTrue(participants.contains("5"))

        let free = SL10n.meetingFree("30 мин")
        XCTAssertFalse(free.isEmpty)

        let until = SL10n.meetingUntil("Standup", "15 мин")
        XCTAssertTrue(until.contains("Standup"))
        XCTAssertTrue(until.contains("15"))
    }

    func testCallsFormatFunctions() {
        let group = SL10n.callsGroup(8)
        XCTAssertTrue(group.contains("8"))

        let callButton = SL10n.callsCallButton("John")
        XCTAssertTrue(callButton.contains("John"))

        let callCount = SL10n.callsCallButtonCount(3)
        XCTAssertTrue(callCount.contains("3"))
    }

    func testAuthFormatFunctions() {
        let version = SL10n.authVersion("2.1.0")
        XCTAssertTrue(version.contains("2.1.0"))

        let loginFailed = SL10n.authLoginFailed("timeout")
        XCTAssertTrue(loginFailed.contains("timeout"))
    }

    func testCalendarWeekdaysCount() {
        XCTAssertEqual(SL10n.calendarWeekdays.count, 7)
        for day in SL10n.calendarWeekdays {
            XCTAssertFalse(day.isEmpty)
        }
    }

    // MARK: - StalkTheme Tests

    func testAccentColorExists() {
        XCTAssertNotNil(StalkTheme.accent)
        XCTAssertNotNil(StalkTheme.accentUIColor)
    }
}
