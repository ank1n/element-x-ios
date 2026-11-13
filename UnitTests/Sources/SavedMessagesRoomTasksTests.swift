// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import XCTest

/// STMOB-333: форматы «Сохранённых» и задач комнаты должны совпадать с вебом (STALK-1383, STALK-1374).
@MainActor
final class SavedMessagesRoomTasksTests: XCTestCase {
    private let source = StalkSavedFrom(sender: "@a:example.invalid", senderName: "Аня", roomID: "!room:example.invalid",
                                        roomName: "Команда", eventID: "$event123456789", ts: 1_794_500_000_000)

    private func event(_ content: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["type": "m.room.message", "content": content]), encoding: .utf8)!
    }

    private func object(_ json: String?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(json?.data(using: .utf8))) as? [String: Any])
    }

    func testSavedContentCopiesMessageAndAddsSource() throws {
        let original = event(["msgtype": "m.text", "body": "Привет", "m.mentions": ["user_ids": ["@b:example.invalid"]],
                              "m.relates_to": ["m.in_reply_to": ["event_id": "$x"]]])
        let content = try object(StalkSavedMessagesService.savedContent(originalJSON: original, latestEditJSON: nil, source: source))
        XCTAssertEqual(content["body"] as? String, "Привет")
        XCTAssertNil(content["m.mentions"], "копия не должна заново упоминать людей")
        XCTAssertNil(content["m.relates_to"], "копия — самостоятельное сообщение")
        let saved = try XCTUnwrap(content[StalkSavedFrom.key] as? [String: Any])
        XCTAssertEqual(saved["room_id"] as? String, "!room:example.invalid")
        XCTAssertEqual(saved["event_id"] as? String, "$event123456789")
        XCTAssertEqual(saved["sender_name"] as? String, "Аня")
        XCTAssertEqual((saved["ts"] as? NSNumber)?.int64Value, 1_794_500_000_000)
    }

    func testSavedContentUsesLatestEditAndKeepsOriginalSource() throws {
        let earlier = StalkSavedFrom(sender: "@c:example.invalid", senderName: nil, roomID: "!old:example.invalid", roomName: nil, eventID: nil, ts: 1)
        let original = event(["msgtype": "m.text", "body": "черновик", StalkSavedFrom.key: earlier.json])
        let edit = event(["msgtype": "m.text", "body": "* итог", "m.new_content": ["msgtype": "m.text", "body": "итог"]])
        let content = try object(StalkSavedMessagesService.savedContent(originalJSON: original, latestEditJSON: edit, source: source))
        XCTAssertEqual(content["body"] as? String, "итог")
        XCTAssertEqual((content[StalkSavedFrom.key] as? [String: Any])?["room_id"] as? String, "!old:example.invalid")
    }

    func testSavedContentRejectsUnsupportedEvents() {
        XCTAssertNil(StalkSavedMessagesService.savedContent(originalJSON: event(["msgtype": "m.server_notice", "body": "x"]), latestEditJSON: nil, source: source))
        XCTAssertNil(StalkSavedMessagesService.savedContent(originalJSON: nil, latestEditJSON: nil, source: source))
    }

    func testSavedFromParsesWebFormat() throws {
        let raw = event(["msgtype": "m.text", "body": "x",
                         StalkSavedFrom.key: ["sender": "@a:example.invalid", "sender_name": "Аня", "room_id": "!room:example.invalid",
                                              "room_name": "Команда", "event_id": "$event123456789", "ts": 1_794_500_000_000]])
        let parsed = try XCTUnwrap(StalkSavedFrom.parse(originalJSON: raw))
        XCTAssertEqual(parsed, source)
        XCTAssertEqual(parsed.title, "Аня · Команда")
        XCTAssertNotNil(parsed.permalink)
        XCTAssertNil(StalkSavedFrom.parse(originalJSON: event(["msgtype": "m.text", "body": "x"])))
        XCTAssertNil(StalkSavedFrom.parse(originalJSON: event([StalkSavedFrom.key: ["sender": "@a:example.invalid"]])), "без room_id и ts поле неполное")
    }

    func testRoomTaskParsesServerRow() throws {
        let task = try XCTUnwrap(RoomTask(json: [
            "id": 42, "title": "Подготовить отчёт", "description": "", "assignee": "@a:example.invalid", "status": "in_progress",
            "version": 3, "created_by": "@b:example.invalid", "due_date": "2026-11-20",
            "basis": [["eventId": "$event123456789", "sender": "@a:example.invalid", "ts": 1_794_500_000_000, "quote": NSNull()]],
            "trackit_issue_id": NSNull()
        ]))
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.version, 3)
        XCTAssertEqual(task.dueDate, "2026-11-20")
        XCTAssertEqual(task.basis.map(\.eventID), ["$event123456789"])
        XCTAssertNil(task.basis.first?.quote)
        XCTAssertFalse(task.isLinked)

        let linked = try XCTUnwrap(RoomTask(json: ["id": 7, "title": "T", "trackit_issue_id": "uuid", "trackit_project_identifier": "STMOB",
                                                   "trackit_sequence_id": 333, "trackit_url": "javascript:alert(1)"]))
        XCTAssertTrue(linked.isLinked)
        XCTAssertEqual(linked.trackitKey, "STMOB-333")
        XCTAssertNil(linked.trackitURL, "открываем только http(s)")
        XCTAssertNil(RoomTask(json: ["title": "без id"]))
    }

    func testDueDateRoundTripsAsLocalDay() throws {
        let date = try XCTUnwrap(RoomTasksAPI.dayFormatter.date(from: "2026-12-31"))
        XCTAssertEqual(RoomTasksAPI.dayFormatter.string(from: date), "2026-12-31")
    }
}
