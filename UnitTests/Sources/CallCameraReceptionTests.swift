@testable import ElementX
import LiveKit

// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import XCTest

@MainActor
final class CallCameraReceptionTests: XCTestCase {
    final class Publication {
        let id = UUID()
        let camera: Bool
        var calls: [(enabled: Bool, retry: Bool)] = []
        var failOnce = false
        var pauseNext = false
        var onFirstCall: (() -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        init(camera: Bool = true) {
            self.camera = camera
        }

        var value: CallIncomingPublication {
            .init(id: id, isCameraVideo: camera) { enabled, retry in
                self.calls.append((enabled, retry))
                self.onFirstCall?(); self.onFirstCall = nil
                if self.pauseNext {
                    self.pauseNext = false
                    await withCheckedContinuation { self.continuation = $0 }
                }
                if self.failOnce { self.failOnce = false; throw URLError(.networkConnectionLost) }
            }
        }
    }

    func testDisablesCamerasOnlyAndRestoresWithoutTouchingAudioOrShare() async {
        let camera = Publication(), audio = Publication(camera: false), share = Publication(camera: false)
        let reception = CallCameraReception { [camera.value, audio.value, share.value] }
        XCTAssertTrue(reception.isEnabled)
        reception.setEnabled(false)
        await reception.waitForPendingChanges()
        XCTAssertEqual(camera.calls.map(\.enabled), [false])
        XCTAssertEqual(reception.status, .disabled)
        reception.setEnabled(true)
        await reception.waitForPendingChanges()
        XCTAssertEqual(camera.calls.map(\.enabled), [false, true])
        XCTAssertTrue(audio.calls.isEmpty)
        XCTAssertTrue(share.calls.isEmpty)
        XCTAssertTrue(CallCameraReception.isCamera(kind: .video, source: .camera))
        XCTAssertFalse(CallCameraReception.isCamera(kind: .audio, source: .microphone))
        XCTAssertFalse(CallCameraReception.isCamera(kind: .video, source: .screenShareVideo))
        XCTAssertFalse(CallCameraReception.isCamera(kind: .audio, source: .screenShareAudio))
    }

    func testLateCameraRepublishAndReconnectKeepOffChoice() async {
        let camera = Publication()
        var publications = [camera.value]
        let reception = CallCameraReception { publications }
        reception.setEnabled(false)
        await reception.waitForPendingChanges()
        let late = Publication()
        publications.append(late.value)
        reception.reconcile()
        await reception.waitForPendingChanges()
        XCTAssertEqual(late.calls.map(\.enabled), [false])
        let republished = Publication()
        publications = [republished.value]
        reception.reconcile(resetApplied: true)
        await reception.waitForPendingChanges()
        XCTAssertEqual(republished.calls.map(\.enabled), [false])
        reception.reconcile(resetApplied: true)
        await reception.waitForPendingChanges()
        XCTAssertEqual(republished.calls.map(\.enabled), [false, false])
        XCTAssertFalse(reception.isEnabled)
    }

    func testLatestChoiceWinsOverAnInFlightSubscription() async throws {
        let camera = Publication(); camera.pauseNext = true
        let reception = CallCameraReception { [camera.value] }
        let started = expectation(description: "Subscription command started")
        camera.onFirstCall = { started.fulfill() }
        reception.setEnabled(false)
        await fulfillment(of: [started], timeout: 2)
        let continuation = try XCTUnwrap(camera.continuation)
        reception.setEnabled(true)
        continuation.resume()
        await reception.waitForPendingChanges()
        XCTAssertEqual(camera.calls.map(\.enabled), [false, true])
        XCTAssertEqual(reception.status, .enabled)
    }

    func testFailedWriteIsVisibleAndRetryBypassesSDKPreferenceCache() async {
        let camera = Publication(); camera.failOnce = true
        let reception = CallCameraReception { [camera.value] }
        reception.setEnabled(false)
        await reception.waitForPendingChanges()
        XCTAssertEqual(reception.status, .failed)
        reception.retry()
        await reception.waitForPendingChanges()
        XCTAssertEqual(camera.calls.map(\.enabled), [false, false])
        XCTAssertTrue(camera.calls.last?.retry == true)
        XCTAssertEqual(reception.status, .disabled)
    }

    func testCallEndResetsPreferenceAndIgnoresOldPendingFailure() async throws {
        let camera = Publication(); camera.pauseNext = true; camera.failOnce = true
        var publications = [camera.value]
        let reception = CallCameraReception { publications }
        let started = expectation(description: "Old call command started")
        camera.onFirstCall = { started.fulfill() }
        reception.setEnabled(false)
        await fulfillment(of: [started], timeout: 2)
        let continuation = try XCTUnwrap(camera.continuation)
        reception.reset()
        let next = Publication(); publications = [next.value]
        reception.reconcile()
        continuation.resume()
        await reception.waitForPendingChanges()
        XCTAssertTrue(reception.isEnabled)
        XCTAssertEqual(reception.status, .enabled)
        XCTAssertEqual(next.calls.map(\.enabled), [true])
    }
}
