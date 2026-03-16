//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import ElementX

@MainActor
class MeetingsScreenTests: XCTestCase {
    // MARK: - WidgetCategory Tests

    func testWidgetCategoryDisplayNames() {
        XCTAssertEqual(WidgetCategory.productivity.displayName, SL10n.appsProductivity)
        XCTAssertEqual(WidgetCategory.communication.displayName, SL10n.appsCommunication)
        XCTAssertEqual(WidgetCategory.tools.displayName, SL10n.appsTools)
    }

    func testWidgetCategoryFromAPI() {
        XCTAssertEqual(WidgetCategory(apiCategory: "productivity"), .productivity)
        XCTAssertEqual(WidgetCategory(apiCategory: "communication"), .communication)
        XCTAssertEqual(WidgetCategory(apiCategory: "tools"), .tools)
        XCTAssertEqual(WidgetCategory(apiCategory: "Productivity"), .productivity)
        XCTAssertEqual(WidgetCategory(apiCategory: "unknown"), .tools) // default
    }

    // MARK: - WidgetItem Tests

    func testWidgetItemIdentifiable() {
        let item = WidgetItem(id: "stats", name: "Statistics", description: "System stats", url: "https://example.com")
        XCTAssertEqual(item.id, "stats")
        XCTAssertEqual(item.name, "Statistics")
        XCTAssertFalse(item.isBuiltin)
    }

    func testWidgetItemIsBuiltin() {
        let builtin = WidgetItem(id: "calendar", name: "Calendar", description: "Meetings", url: "", type: "builtin")
        XCTAssertTrue(builtin.isBuiltin)

        let widget = WidgetItem(id: "stats", name: "Stats", description: "Stats", url: "https://example.com", type: "widget")
        XCTAssertFalse(widget.isBuiltin)
    }

    func testWidgetItemEquality() {
        let a = WidgetItem(id: "test", name: "A", description: "a", url: "https://a.com")
        let b = WidgetItem(id: "test", name: "A", description: "a", url: "https://a.com")
        XCTAssertEqual(a, b)
    }

    func testWidgetItemDefaultCategory() {
        let item = WidgetItem(id: "test", name: "Test", description: "test", url: "")
        XCTAssertEqual(item.category, .tools)
    }

    // MARK: - WidgetsListScreenViewState Tests

    func testWidgetsViewStateInitial() {
        let state = WidgetsListScreenViewState()
        XCTAssertTrue(state.widgets.isEmpty)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }
}
