// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import SwiftUI
import XCTest

final class CallTaskStatusSummaryTests: XCTestCase {
    func testEmptyInputHasZeroCountsAndNoTasks() {
        let statistics = CallTaskStatistics(tasks: [])
        XCTAssertEqual(statistics.counts, .init())
        XCTAssertTrue(statistics.uniqueTasks.isEmpty)
    }

    func testDuplicatesAcrossRecordingSessionsUseProjectAndIssueIdentity() throws {
        let tasks = try [
            task(1, session: "recording-a", issue: "same", project: "project-a", group: "backlog"),
            task(2, session: "recording-b", issue: "same", project: "project-a", group: "completed"),
            task(3, session: "recording-b", issue: "same", project: "project-b", group: "started"),
            task(4, session: "recording-c", issue: "other", project: "project-a", group: "completed")
        ]
        let statistics = CallTaskStatistics(tasks: tasks)
        XCTAssertEqual(statistics.total, 3)
        XCTAssertEqual(statistics.uniqueTasks.map(\.id), [1, 3, 4])
        XCTAssertEqual(statistics.backlog, 1)
        XCTAssertEqual(statistics.started, 1)
        XCTAssertEqual(statistics.completed, 1)
    }

    func testNewestSnapshotReplacesWholeTaskAndPreservesFirstSeenOrder() throws {
        let tasks = try [
            task(1, issue: "a", group: "backlog", syncedAt: "2026-10-18T09:00:00Z"),
            task(2, issue: "b", group: "started"),
            task(3, session: "another-session", issue: "a", group: "completed", syncedAt: "2026-10-18T09:00:02Z"),
            task(4, issue: "a", group: "cancelled", syncedAt: "2026-10-18T09:00:01Z")
        ]
        let statistics = CallTaskStatistics(tasks: tasks)
        XCTAssertEqual(statistics.uniqueTasks, [tasks[2], tasks[1]])
        XCTAssertEqual(statistics.total, 2)
        XCTAssertEqual(statistics.backlog, 0)
        XCTAssertEqual(statistics.completed, 1)
        XCTAssertEqual(statistics.cancelled, 0)
    }

    func testAllGroupsAreCaseInsensitiveAndUnstartedBelongsToBacklog() throws {
        let groups = ["BACKLOG", "UnStarted", "StArTeD", "COMPLETED", "Cancelled"]
        let tasks = try groups.enumerated().map { try task($0.offset, issue: "issue-\($0.offset)", group: $0.element) }
        let statistics = CallTaskStatistics(tasks: tasks)
        XCTAssertEqual(statistics.total, 5)
        XCTAssertEqual(statistics.backlog, 2)
        XCTAssertEqual(statistics.started, 1)
        XCTAssertEqual(statistics.completed, 1)
        XCTAssertEqual(statistics.cancelled, 1)
        XCTAssertEqual(statistics.unknown, 0)
    }

    func testUnknownGroupsNeverInferFromLocalizedStateNameOrTrimGroup() throws {
        let groups: [String?] = [nil, "", "done", " completed ", "canceled", "готово"]
        let tasks = try groups.enumerated().map {
            try task($0.offset, issue: "issue-\($0.offset)", group: $0.element, stateName: "Completed / Готово")
        }
        let statistics = CallTaskStatistics(tasks: tasks)
        XCTAssertEqual(statistics.total, groups.count)
        XCTAssertEqual(statistics.unknown, groups.count)
        XCTAssertEqual(statistics.completed, 0)
    }

    func testMissingAndEmptyIssueIDsAreIgnoredButWhitespaceIsNotEmpty() throws {
        let tasks = try [task(1, issue: nil), task(2, issue: ""), task(3, issue: " ")]
        let statistics = CallTaskStatistics(tasks: tasks)
        XCTAssertEqual(statistics.total, 1)
        XCTAssertEqual(statistics.uniqueTasks.map(\.id), [3])
    }

    func testMissingProjectIDsDeduplicateAndRemainDistinctFromEmptyProject() throws {
        let tasks = try [
            task(1, issue: "a", project: nil),
            task(2, issue: "a", project: nil),
            task(3, issue: "a", project: ""),
            task(4, issue: "b", project: nil)
        ]
        XCTAssertEqual(CallTaskStatistics(tasks: tasks).uniqueTasks.map(\.id), [1, 3, 4])
    }

    func testTupleIdentityDoesNotCollideWhenIDsContainSeparators() throws {
        let tasks = try [task(1, issue: "b:c", project: "a"), task(2, issue: "c", project: "a:b")]
        XCTAssertEqual(CallTaskStatistics(tasks: tasks).total, 2)
    }

    func testTiedInstantsWithDifferentOffsetsKeepFirst() throws {
        let first = try task(1, group: "started", syncedAt: "2026-10-18T12:00:00+03:00")
        let tied = try task(2, group: "completed", syncedAt: "2026-10-18T09:00:00.000Z")
        let statistics = CallTaskStatistics(tasks: [first, tied])
        XCTAssertEqual(statistics.uniqueTasks, [first])
        XCTAssertEqual(statistics.started, 1)
    }

    func testJavaScriptMillisecondPrecisionKeepsSubMillisecondTie() throws {
        let first = try task(1, syncedAt: "2026-10-18T09:00:00.1231Z")
        let tied = try task(2, syncedAt: "2026-10-18T09:00:00.1239Z")
        XCTAssertEqual(CallTaskStatistics(tasks: [first, tied]).uniqueTasks, [first])
        let newer = try task(3, syncedAt: "2026-10-18T09:00:00.124Z")
        XCTAssertEqual(CallTaskStatistics(tasks: [first, newer]).uniqueTasks, [newer])
    }

    func testInvalidComparisonAlwaysKeepsFirstIncludingValidCandidateAfterInvalidFirst() throws {
        let invalidDates: [String?] = [nil, "", "not-a-date", "2026-99-99T25:99:99Z",
                                       "2026-10-18", "Sun, 18 Oct 2026 09:00:00 GMT",
                                       "2026-10-18T09:00:00", "2026-10-18T09:00:00Z trailing"]
        for invalid in invalidDates {
            let invalidFirst = try task(1, group: "backlog", syncedAt: invalid)
            let valid = try task(2, group: "completed", syncedAt: "2026-10-18T09:00:00Z")
            XCTAssertEqual(CallTaskStatistics(tasks: [invalidFirst, valid]).uniqueTasks, [invalidFirst])
            XCTAssertEqual(CallTaskStatistics(tasks: [valid, invalidFirst]).uniqueTasks, [valid])
            let invalidSecond = try task(3, syncedAt: invalid)
            XCTAssertEqual(CallTaskStatistics(tasks: [invalidFirst, invalidSecond]).uniqueTasks, [invalidFirst])
        }
    }

    func testBackendFractionalAndNonFractionalOffsetsCompareAtMillisecondPrecision() throws {
        for (earlier, later) in [
            ("2026-10-18T09:00:00Z", "2026-10-18T12:00:00.001+03:00"),
            ("2026-10-18T09:00:00.999999Z", "2026-10-18T09:00:01Z"),
            ("2026-10-18T09:00:00.1Z", "2026-10-18T06:00:00.101-03:00")
        ] {
            let first = try task(1, syncedAt: earlier)
            let newer = try task(2, syncedAt: later)
            XCTAssertEqual(CallTaskStatistics(tasks: [first, newer]).uniqueTasks, [newer])
            XCTAssertEqual(CallTaskStatistics(tasks: [newer, first]).uniqueTasks, [newer])
        }
    }

    @MainActor
    func testActualSummaryRendersAtPhoneWidthAndLargeType() throws {
        let tasks = try ["backlog", "started", "completed", "cancelled", "unknown"].enumerated().map {
            try task($0.offset, issue: "issue-\($0.offset)", group: $0.element)
        }
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let view = CallTaskStatusSummary(statistics: CallTaskStatistics(tasks: tasks))
                .padding(16)
                .frame(width: 320)
                .background(Color.white)
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 320)
            XCTAssertGreaterThan(image.size.height, 100)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Call task summary phone width \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func task(_ id: Int,
                      session: String = "recording-a",
                      issue: String? = "issue-a",
                      project: String? = "project-a",
                      group: String? = nil,
                      stateName: String? = nil,
                      syncedAt: String? = "2026-10-18T09:00:00Z") throws -> CreatedTask {
        var json: [String: Any] = [
            "id": id,
            "egress_id": session,
            "topic_index": 0,
            "task_index": id,
            "task_text": "Task \(id)"
        ]
        // Omitted keys exercise the actual API model's missing-field decoding.
        json["trackit_issue_id"] = issue
        json["trackit_project_id"] = project
        json["trackit_state_group"] = group
        json["trackit_state_name"] = stateName
        json["status_synced_at"] = syncedAt
        return try JSONDecoder().decode(CreatedTask.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
