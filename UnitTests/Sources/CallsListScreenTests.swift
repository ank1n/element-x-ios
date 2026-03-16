//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import ElementX

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

    // MARK: - Helpers

    private func makeCall(
        callType: CallHistoryItem.CallType = .incoming,
        isMissed: Bool = false,
        recordingURL: URL? = nil,
        participantCount: Int = 2
    ) -> CallHistoryItem {
        CallHistoryItem(
            id: UUID().uuidString,
            contactName: "Test",
            contactId: "@test:example.com",
            callType: callType,
            timestamp: Date(),
            duration: 120,
            isMissed: isMissed,
            recordingURL: recordingURL,
            participantCount: participantCount
        )
    }
}
