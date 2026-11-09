//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@MainActor
class RoomScreenUITests: XCTestCase {
    func testOngoingCallHeaderHasOnlyJoinAction() {
        let app = Application.launchForInteraction(.roomOngoingCallHeader, language: "ru")
        XCTAssertTrue(app.buttons[A11yIdentifiers.roomScreen.joinCall].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["roomHeaderSearch"].exists)
        XCTAssertFalse(app.buttons["roomHeaderThreads"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Ongoing call header without search and threads"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testIncomingCameraVideoCanBeDisabledAndRestored() {
        let app = Application.launchForInteraction(.callVideoReceptionControls, language: "ru")
        let toggle = app.switches["callReceiveVideoToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let nativeSwitch = toggle.switches.firstMatch
        (nativeSwitch.exists ? nativeSwitch : toggle).tap()
        let restore = app.buttons["callRestoreVideoReception"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Incoming cameras disabled with restore action"; attachment.lifetime = .keepAlways; add(attachment)
        restore.tap(.center)
        XCTAssertFalse(restore.exists)
        XCTAssertEqual(toggle.value as? String, "1")
    }

    func testShortLeftSwipeStartsReply() async throws {
        let app = Application.launchForInteraction(.roomSmallTimeline, disableTimelineAccessibility: false)
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Hey there")).firstMatch
        guard message.waitForExistence(timeout: 15) else {
            XCTFail("The fixture message must be accessible before testing the swipe")
            return
        }
        let reply = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "In reply to Alice")).firstMatch
        XCTAssertFalse(reply.exists)
        let wrongDirection = message.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        wrongDirection.press(forDuration: 0.05, thenDragTo: wrongDirection.withOffset(CGVector(dx: 90, dy: 0)),
                             withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertFalse(reply.exists, "A rightward swipe must not reply")
        let start = message.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -90, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0)
        guard reply.waitForExistence(timeout: 10) else {
            XCTFail("A short left swipe should open the quoted reply in the composer")
            return
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Reply must focus the composer without tapping an icon")
        app.typeText("Swipe reply")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Swipe reply")).firstMatch.waitForExistence(timeout: 5),
                      "Typing immediately after the swipe must enter the reply composer")
        try await Task.sleep(for: .milliseconds(500))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reply and keyboard after 90pt left swipe"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPlainNoAvatar() async throws {
        let app = Application.launch(.roomPlainNoAvatar)

        XCTAssert(app.staticTexts[A11yIdentifiers.roomScreen.name].exists)
        XCTAssert(app.staticTexts[A11yIdentifiers.roomScreen.avatar].exists)

        try await app.assertScreenshot()
    }
    
    func testSmallTimelineLayout() async throws {
        let app = Application.launch(.roomSmallTimeline)
        
        // The messages should be bottom aligned.
        try await app.assertScreenshot()
    }
    
    func testSmallTimelineWithIncomingAndPagination() async throws {
        let client = try UITestsSignalling.Client(mode: .tests)
        
        let app = Application.launch(.roomSmallTimelineIncomingAndSmallPagination)
        
        await client.waitForApp()
        defer { try? client.stop() }
        
        // When a back pagination occurs and an incoming message arrives.
        try await performOperation(.incomingMessage, using: client)
        try await performOperation(.paginate, using: client)

        // Then the 4 visible messages should stay aligned to the bottom.
        try await app.assertScreenshot()
    }
    
    func testSmallTimelineWithLargePagination() async throws {
        let client = try UITestsSignalling.Client(mode: .tests)
        
        let app = Application.launch(.roomSmallTimelineLargePagination)
        
        await client.waitForApp()
        defer { try? client.stop() }
        
        // When a large back pagination occurs.
        try await performOperation(.paginate, using: client)

        // The bottom of the timeline should remain visible with more items added above.
        try await app.assertScreenshot()
    }
    
    func testTimelineLayoutAtTop() async throws {
        let client = try UITestsSignalling.Client(mode: .tests)
        
        let app = Application.launch(.roomLayoutTop)
        
        await client.waitForApp()
        defer { try? client.stop() }
        
        // Given a timeline that is scrolled to the top.
        for _ in 0...5 {
            app.swipeDown()
        }
        try await app.assertScreenshot() // Assert initial state for comparison.
        
        // When a back pagination occurs.
        try await performOperation(.paginate, using: client)

        // Then the bottom of the timeline should remain unchanged (with new items having been added above).
        try await app.assertScreenshot()
    }

    func testTimelineLayoutAtBottom() async throws {
        let client = try UITestsSignalling.Client(mode: .tests)
        
        let app = Application.launch(.roomLayoutBottom)
        
        await client.waitForApp()
        defer { try? client.stop() }
        
        // Some time for the timeline to settle
        try await Task.sleep(for: .seconds(1))
        // When an incoming message arrives.
        try await performOperation(.incomingMessage, using: client)
        // Some time for the timeline to settle
        try await Task.sleep(for: .seconds(1))
        
        // Then the timeline should scroll down to reveal the message.
        try await app.assertScreenshot(step: 0)
        
        // When the keyboard appears for the message composer.
        try await tapMessageComposer(in: app)
        
        try await app.assertScreenshot(step: 1)
    }
    
    func testTimelineLayoutHighlightExisting() async throws {
        let client = try UITestsSignalling.Client(mode: .tests)
        
        let app = Application.launch(.roomLayoutHighlight)
        
        await client.waitForApp()
        defer { try? client.stop() }
        
        // When tapping a permalink to an item in the timeline.
        try await performOperation(.focusOnEvent("$5"), using: client)
        
        // Then the item should become highlighted.
        try await app.assertScreenshot()
        
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        
        // When scrolling to the bottom and tapping the same permalink again.
        app.buttons[A11yIdentifiers.roomScreen.scrollToBottom].tap()
        try await Task.sleep(for: .seconds(1)) // Some time for the timeline to settle
        try await performOperation(.focusOnEvent("$5"), using: client)
        
        // Then the item should also be highlighted and scrolled to in the same state as before.
        try await app.assertScreenshot()
    }

    func testTimelineReadReceipts() async throws {
        let app = Application.launch(.roomSmallTimelineWithReadReceipts)

        // The messages should be bottom aligned.
        try await app.assertScreenshot()
    }

    func testTimelineDisclosedPolls() async throws {
        let app = Application.launch(.roomWithDisclosedPolls)

        try await app.assertScreenshot()
    }

    func testTimelineUndisclosedPolls() async throws {
        let app = Application.launch(.roomWithUndisclosedPolls)

        try await app.assertScreenshot()
    }

    func testTimelineOutgoingPolls() async throws {
        let app = Application.launch(.roomWithOutgoingPolls)

        try await app.assertScreenshot()
    }

    // MARK: - Helper Methods
    
    private func performOperation(_ operation: UITestsSignal.Timeline, using client: UITestsSignalling.Client) async throws {
        try client.send(.timeline(operation))
        await _ = client.signals.values.first { $0 == .success }
        try await Task.sleep(for: .seconds(2)) // Allow the timeline to update
    }
    
    private func tapMessageComposer(in app: XCUIApplication) async throws {
        app.textViews.element.tap()
        try await Task.sleep(for: .seconds(10)) // Allow the animations to complete
    }
}
