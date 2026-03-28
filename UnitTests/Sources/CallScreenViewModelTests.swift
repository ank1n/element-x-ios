//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class CallScreenViewModelTests: XCTestCase {
    // MARK: - CallScreenViewState Tests

    private func makeState() -> CallScreenViewState {
        CallScreenViewState(script: nil, isGenericCallLink: false, certificateValidator: CertificateValidatorMock())
    }

    func testCallStatusTextConnecting() {
        var state = makeState()
        state.callStatus = .connecting
        XCTAssertEqual(state.callStatusText, SL10n.callCalling)
    }

    func testCallStatusTextReconnecting() {
        var state = makeState()
        state.callStatus = .reconnecting
        XCTAssertEqual(state.callStatusText, SL10n.callReconnecting)
    }

    func testCallStatusTextConnectedDirect() {
        var state = makeState()
        state.callStatus = .connected
        state.isDirect = true
        state.callElapsedTime = 65 // 1:05
        XCTAssertEqual(state.callStatusText, "1:05")
    }

    func testCallStatusTextConnectedGroup() {
        var state = makeState()
        state.callStatus = .connected
        state.isDirect = false
        state.callElapsedTime = 130 // 2:10
        state.callParticipantsCount = 3
        state.totalMembersCount = 5
        let text = state.callStatusText
        XCTAssertTrue(text.contains("2:10"))
        XCTAssertTrue(text.contains("3"))
        XCTAssertTrue(text.contains("5"))
    }

    func testInitialStateDefaults() {
        let state = makeState()
        XCTAssertFalse(state.isMuted)
        XCTAssertTrue(state.isVideoEnabled)
        XCTAssertTrue(state.isSpeakerOn)
        XCTAssertFalse(state.isHandRaised)
        XCTAssertFalse(state.isScreenSharing)
        XCTAssertFalse(state.isMinimized)
        XCTAssertFalse(state.wasConnected)
        XCTAssertEqual(state.callParticipantsCount, 0)
        XCTAssertTrue(state.participants.isEmpty)
        XCTAssertTrue(state.activeCallParticipantIDs.isEmpty)
    }

    // MARK: - CallParticipantInfo Tests

    func testCallParticipantInfoIdentifiable() {
        let info = CallParticipantInfo(userID: "@alice:example.com", displayName: "Alice", avatarURL: nil)
        XCTAssertEqual(info.id, "@alice:example.com")
        XCTAssertEqual(info.displayName, "Alice")
    }

    func testCallParticipantInfoNilDisplayName() {
        let info = CallParticipantInfo(userID: "@bob:example.com", displayName: nil, avatarURL: nil)
        XCTAssertNil(info.displayName)
        XCTAssertEqual(info.id, "@bob:example.com")
    }
}

// MARK: - Mock

private struct CertificateValidatorMock: CertificateValidatorHookProtocol {
    func respondTo(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}
