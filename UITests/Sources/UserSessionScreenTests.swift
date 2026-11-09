//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@MainActor
class UserSessionScreenTests: XCTestCase {
    func testSharedFilePresentsRoomPickerAndPreview() async throws {
        try await verifySharedFile(.userSessionShare)
    }

    func testSharedFilePresentsRoomPickerWhileRoomAlreadyOpen() async throws {
        try await verifySharedFile(.userSessionShareFromRoom)
    }

    private func verifySharedFile(_ fixture: UITestsScreenIdentifier) async throws {
        let app = Application.launchForInteraction(fixture)
        let choose = app.switches["room_selection_2"]
        guard choose.waitForExistence(timeout: 20) else { return XCTFail("The shared file must present a room picker") }
        let confirm = app.buttons["room_selection_confirm"]
        XCTAssertFalse(confirm.isEnabled)
        choose.tap(.center)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap(.center)
        let send = app.buttons["shared_media_send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15), "Choosing a room must open the attachment preview")
        try await Task.sleep(for: .seconds(1))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Shared file after room selection"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFourChatFiltersMatchPublishedWeb() {
        let app = Application.launchForInteraction(.userSessionScroll)
        let groups = app.buttons["room_filter_2"]
        XCTAssertTrue(groups.waitForExistence(timeout: 15))
        for value in [1, 2, 7, 4] {
            XCTAssertTrue(app.buttons["room_filter_\(value)"].exists)
        }
        for value in [0, 3, 5, 6, 8] {
            XCTAssertFalse(app.buttons["room_filter_\(value)"].exists)
        }
        groups.tap(.center)
        XCTAssertTrue(groups.isSelected)
        groups.tap(.center)
        XCTAssertFalse(groups.isSelected)
        let favourite = app.buttons[A11yIdentifiers.homeScreen.roomName("Scroll room 01")]
        let ordinary = app.buttons[A11yIdentifiers.homeScreen.roomName("Scroll room 00")]
        XCTAssertTrue(favourite.exists && ordinary.exists)
        XCTAssertLessThan(favourite.frame.minY, ordinary.frame.minY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Four web filters and favourites first"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testChatListScrollsAfterReturningFromRoom() async throws {
        let app = Application.launchForInteraction(.userSessionScroll)
        let first = app.buttons[A11yIdentifiers.homeScreen.roomName("Scroll room 00")]
        guard first.waitForExistence(timeout: 15) else { XCTFail("Scroll fixture did not open"); return }
        first.tap(.center)
        let composer = app.buttons[A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions]
        guard composer.waitForExistence(timeout: 10) else { XCTFail("Room did not open"); return }
        app.navigationBars.buttons["Chats"].firstMatch.tap(.center)
        guard first.waitForExistence(timeout: 10) else { XCTFail("Did not return to list"); return }
        let initialY = first.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(!first.exists || first.frame.minY < initialY - 60, "Vertical dragging over rows must scroll the room list")
        let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        back.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(first.exists && abs(first.frame.minY - initialY) < 60, "The list must also scroll back down")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Chat list after room return and vertical swipes"; attachment.lifetime = .keepAlways; add(attachment)
    }

    let firstRoomName = "Foundation 🔭🪐🌌"
    let firstSpaceName = "The Foundation"
    let unjoinedSpaceRoomName = "Company Room"
    let joinedSubspaceName = "Joined Space"
    let joinedSubspaceRoomName = "Management"
    let spaceInviteName = "First space"
    
    enum Step {
        static let homeScreen = 1
        static let roomScreen = 2
        static let composerAttachments = 3
        static let homeScreenWithTabBar = 4
        static let spacesScreen = 5
        static let spaceScreen = 6
        static let subspaceScreen = 7
        static let subspaceRoomScreen = 8
        static let spaceJoinRoomScreen = 9
    }
    
    func testUserSessionFlows() async throws {
        let app = Application.launch(.userSessionScreen)
        
        app.swipeDown() // Make sure the header shows a large title
        
        try await app.assertScreenshot(step: Step.homeScreen)

        app.buttons[A11yIdentifiers.homeScreen.roomName(firstRoomName)].tap()
        XCTAssert(app.staticTexts[firstRoomName].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.roomScreen)

        app.buttons[A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions].tap(.center)
        try await app.assertScreenshot(step: Step.composerAttachments)
    }

    func testUserSessionReply() async throws {
        let app = Application.launch(.userSessionScreenReply, disableTimelineAccessibility: false)
        app.buttons[A11yIdentifiers.homeScreen.roomName(firstRoomName)].tap()
        XCTAssert(app.staticTexts[firstRoomName].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))

        let cell = app.cells.element(boundBy: 1) // Skip the typing indicator cell
        cell.swipeLeft(velocity: .slow) // The iOS 26 simulator doesn't like a fast swipe.

        try await app.assertScreenshot()
    }

    func testElementCall() {
        let app = Application.launch(.userSessionScreen)

        app.buttons[A11yIdentifiers.homeScreen.roomName(firstRoomName)].tap()
        XCTAssert(app.staticTexts[firstRoomName].waitForExistence(timeout: 5.0))

        app.buttons[A11yIdentifiers.roomScreen.joinCall].tap()
        
        let textField = app.textFields["Display name"]
        XCTAssert(textField.waitForExistence(timeout: 10))
        
        let joinButton = app.buttons["Continue"]
        XCTAssert(joinButton.waitForExistence(timeout: 10))
    }
    
    func testSpaceExploration() async throws {
        let app = Application.launch(.userSessionSpacesFlow)
        
        app.swipeDown() // Make sure the header shows a large title
        
        try await app.assertScreenshot(step: Step.homeScreenWithTabBar)
        
        // app.tabBars doesn't work on iPadOS 18 😐
        app.buttons["Spaces"].firstMatch.tap(.center)
        
        try await app.assertScreenshot(step: Step.spacesScreen)
        
        app.buttons[A11yIdentifiers.spacesScreen.spaceRoomName(firstSpaceName)].tap()
        XCTAssert(app.staticTexts[firstSpaceName].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.spaceScreen)
        
        app.buttons[A11yIdentifiers.spacesScreen.spaceRoomName(joinedSubspaceName)].tap()
        XCTAssert(app.staticTexts[joinedSubspaceName].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.subspaceScreen)
        
        app.buttons[A11yIdentifiers.spacesScreen.spaceRoomName(joinedSubspaceRoomName)].tap()
        XCTAssert(app.staticTexts[joinedSubspaceRoomName].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.subspaceRoomScreen)
        
        app.navigationBars.buttons[joinedSubspaceName].firstMatch.tap(.center)
        XCTAssert(app.staticTexts[joinedSubspaceName].waitForExistence(timeout: 5.0))
        
        app.navigationBars.buttons[firstSpaceName].firstMatch.tap(.center)
        XCTAssert(app.staticTexts[firstSpaceName].waitForExistence(timeout: 5.0))
        
        app.buttons[A11yIdentifiers.spacesScreen.spaceRoomName(unjoinedSpaceRoomName)].tap()
        XCTAssert(app.staticTexts[unjoinedSpaceRoomName].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.spaceJoinRoomScreen)
    }
    
    func testAcceptSpaceInvite() async throws {
        let app = Application.launch(.userSessionSpacesFlow)
        
        app.swipeDown() // Make sure the header shows a large title
        
        try await app.assertScreenshot(step: Step.homeScreenWithTabBar)
        
        // Tap the space invite cell.
        app.staticTexts[A11yIdentifiers.homeScreen.roomName(spaceInviteName)].tap()
        XCTAssert(app.buttons[A11yIdentifiers.joinRoomScreen.join].waitForExistence(timeout: 5.0))
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.spaceJoinRoomScreen)
        
        // Tap join on the join room screen.
        app.buttons[A11yIdentifiers.joinRoomScreen.join].tap()
        XCTAssert(app.staticTexts[A11yIdentifiers.roomScreen.name].waitForExistence(timeout: 5.0)) // The space screen reuses the room screen header
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.spaceScreen)
        
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Go back to the room list on iPhone.
            app.navigationBars.buttons["Chats"].firstMatch.tap(.center)
            XCTAssert(app.staticTexts["Chats"].waitForExistence(timeout: 5.0))
        } else {
            // Select a different room on iPad (otherwise nothing changes when the join button is tapped below).
            app.buttons[A11yIdentifiers.homeScreen.roomName(firstRoomName)].tap()
            XCTAssert(app.staticTexts[firstRoomName].waitForExistence(timeout: 5.0))
        }
        
        // Tap the join button in the space invite cell.
        app.buttons.matching(NSPredicate(format: "identifier == %@ && label == %@",
                                         A11yIdentifiers.homeScreen.roomName(spaceInviteName),
                                         "Accept")).firstMatch.tap()
        XCTAssert(app.staticTexts[A11yIdentifiers.roomScreen.name].waitForExistence(timeout: 5.0)) // The space screen reuses the room screen header
        try await Task.sleep(for: .seconds(1))
        try await app.assertScreenshot(step: Step.spaceScreen)
    }
}
