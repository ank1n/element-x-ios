// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import XCTest

@MainActor
final class ClientSyncRecoveryTests: XCTestCase {
    func testRetriesRepeatedFailuresUntilHealthyWithoutStartingParallelLoops() async {
        let recovery = ClientSyncRecovery(delay: .milliseconds(5))
        let done = expectation(description: "Three failed connection attempts")
        var attempts = 0
        let shouldRetry = { attempts < 3 }
        let retry = { attempts += 1; if attempts == 3 { done.fulfill() } }
        recovery.start(shouldRetry: shouldRetry, retry: retry)
        recovery.start(shouldRetry: shouldRetry, retry: retry)
        await fulfillment(of: [done], timeout: 2)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attempts, 3)
        recovery.stop()
    }

    func testStopCancelsPendingRetryAndOldTaskCannotClearNextLoop() async {
        let recovery = ClientSyncRecovery(delay: .milliseconds(20))
        var oldAttempts = 0, newAttempts = 0
        let done = expectation(description: "New lifecycle retry")
        recovery.start(shouldRetry: { true }, retry: { oldAttempts += 1 })
        recovery.stop()
        recovery.start(shouldRetry: { newAttempts < 1 }, retry: { newAttempts += 1; done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        recovery.stop()
        XCTAssertEqual(oldAttempts, 0)
        XCTAssertEqual(newAttempts, 1)
    }

    func testNetworkRecoveryOrLogoutBeforeTimeoutPreventsConnectionAttempt() async {
        let recovery = ClientSyncRecovery(delay: .milliseconds(20))
        var intended = true, attempts = 0
        recovery.start(shouldRetry: { intended }, retry: { attempts += 1 })
        intended = false
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(attempts, 0)
        recovery.stop()
    }

    func testCancellationWhileWaitingForLifecycleDoesNotResumeSync() async {
        let recovery = ClientSyncRecovery(delay: .milliseconds(1))
        let entered = expectation(description: "Awaiting SDK transition")
        var attempts = 0
        recovery.start(shouldRetry: { true }, retry: {
            entered.fulfill()
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            attempts += 1
        })
        await fulfillment(of: [entered], timeout: 2)
        recovery.stop()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(attempts, 0)
    }
}
