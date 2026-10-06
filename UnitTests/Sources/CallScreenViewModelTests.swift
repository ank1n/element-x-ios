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
        // STMOB-310: isSpeakerOn — зеркало реального аудиомаршрута; до подключения он не выбран (false, 75388192f).
        // «Динамик по умолчанию» (604e3401f) ставится при connect: connectNativeLiveKit → state.isSpeakerOn = useSpeaker.
        XCTAssertFalse(state.isSpeakerOn)
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

    // STMOB-313: display choices must not change camera, audio, or participation.
    func testVideoFiltersAreLocalAndKeepScreenSharingVisible() {
        var state = makeState()
        state.isMuted = true
        state.videoVisibility.hideOwnVideo = true
        state.videoVisibility.hideParticipantsWithoutVideo = true
        XCTAssertFalse(state.videoVisibility.shows(isLocal: true, hasVideo: true))
        XCTAssertFalse(state.videoVisibility.shows(isLocal: false, hasVideo: false))
        XCTAssertTrue(state.videoVisibility.shows(isLocal: false, hasVideo: true))
        XCTAssertTrue(state.videoVisibility.shows(isLocal: false, hasVideo: false, isScreenShare: true))
        XCTAssertTrue(state.isVideoEnabled)
        XCTAssertTrue(state.isMuted)
    }

    func testManualPresenterModeAndPinSurviveViewChoice() {
        var state = makeState()
        state.pinnedParticipantSID = "alice"
        state.layoutOverride = .presenter
        XCTAssertEqual(state.effectiveLayoutMode, .presenter)
        state.layoutOverride = .grid
        XCTAssertEqual(state.pinnedParticipantSID, "alice")
        state.reconcilePinnedParticipant(available: ["bob"])
        XCTAssertNil(state.pinnedParticipantSID)
        XCTAssertEqual(state.effectiveLayoutMode, .grid)
    }

    func testFocusReturnsToPinAfterScreenShareAndToSpeakerAfterDeparture() {
        let ids = ["alice", "bob", "carol"]
        XCTAssertEqual(CallParticipantSelection.focus(available: ids, screenShare: "carol", pinned: "alice", speakers: ["bob"]), "carol")
        XCTAssertEqual(CallParticipantSelection.focus(available: ids, screenShare: nil, pinned: "alice", speakers: ["bob"]), "alice")
        XCTAssertEqual(CallParticipantSelection.focus(available: ["bob", "carol"], screenShare: nil, pinned: "alice", speakers: ["bob"]), "bob")
        XCTAssertNil(CallParticipantSelection.focus(available: [], screenShare: "carol", pinned: "alice", speakers: ["bob"]))
    }

    func testParticipantContactUsesKnownMXIDAndRejectsGuestOrPartialMatch() {
        let known = CallParticipantInfo(userID: "@alice:test", displayName: "Alice", avatarURL: nil)
        let guest = CallParticipantInfo(userID: "@meet-guest:test", displayName: "Guest", avatarURL: nil)
        XCTAssertEqual(CallParticipantSelection.contact(identity: "@alice:test:DEVICE", participants: [known])?.userID, known.userID)
        XCTAssertNil(CallParticipantSelection.contact(identity: "@alice:test.other:DEVICE", participants: [known]))
        XCTAssertNil(CallParticipantSelection.contact(identity: guest.userID, participants: [guest]))
        XCTAssertNil(CallParticipantSelection.contact(identity: "@unknown:test", participants: [known]))
    }
}

// MARK: - Mock

private struct CertificateValidatorMock: CertificateValidatorHookProtocol {
    func respondTo(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}
