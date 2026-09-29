//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class TextBasedRoomTimelineTests: XCTestCase {
    /// STMOB-310: sTalk резервирует место под галочки доставки (✓/✓✓) у исходящих —
    /// `additionalWhitespaces()` добавляет 3 пробела (f8bb0149b, комментарий «sTalk: extra space for delivery checkmarks»).
    private let outgoingCheckmarksWhitespaces = 3

    func testTextRoomTimelineItemWhitespaceEnd() {
        let timestamp = Calendar.current.startOfDay(for: .now).addingTimeInterval(60 * 60) // 1:00 am
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        XCTAssertEqual(timelineItem.additionalWhitespaces(), timestamp.formattedTime().count + 1 + outgoingCheckmarksWhitespaces)
    }

    func testTextRoomTimelineItemWhitespaceEndLonger() {
        let timestamp = Calendar.current.startOfDay(for: .now).addingTimeInterval(-60) // 11:59 pm
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        XCTAssertEqual(timelineItem.additionalWhitespaces(), timestamp.formattedTime().count + 1 + outgoingCheckmarksWhitespaces)
    }

    func testTextRoomTimelineItemWhitespaceEndWithEdit() {
        let timestamp = Date.mock
        var timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        timelineItem.properties.isEdited = true
        let editedCount = L10n.commonEditedSuffix.count
        XCTAssertEqual(timelineItem.additionalWhitespaces(), timestamp.formattedTime().count + editedCount + 2 + outgoingCheckmarksWhitespaces)
    }

    func testTextRoomTimelineItemWhitespaceEndWithEditAndAlert() {
        let timestamp = Date.mock
        var timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        timelineItem.properties.isEdited = true
        timelineItem.properties.deliveryStatus = .sendingFailed(.unknown)
        let editedCount = L10n.commonEditedSuffix.count
        XCTAssertEqual(timelineItem.additionalWhitespaces(), timestamp.formattedTime().count + editedCount + 5 + outgoingCheckmarksWhitespaces)
    }

    /// STMOB-310: у входящих галочек нет — и запаса под них быть не должно.
    func testTextRoomTimelineItemWhitespaceEndIncoming() {
        let timestamp = Date.mock
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: false,
                                                isEditable: false,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        XCTAssertEqual(timelineItem.additionalWhitespaces(), timestamp.formattedTime().count + 1)
    }
}
