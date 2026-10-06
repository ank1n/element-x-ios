//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import XCTest

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

    // STALK-968: a successful HTTP response can still deny a meeting link.
    func testMeetingRoomResponseRejectsCancelledAndExpiredLinks() {
        for (body, expected) in [("{\"cancelled\":true,\"roomId\":\"!stale:test\"}", MeetingLinkError.cancelled), ("{\"expired\":true}", MeetingLinkError.expired)] {
            XCTAssertThrowsError(try MeetingsService.meetingRoomID(from: Data(body.utf8))) { error in
                XCTAssertEqual(error as? MeetingLinkError, expected)
            }
        }
        XCTAssertEqual(try MeetingsService.meetingRoomID(from: Data("{\"roomId\":\"!meeting:test\"}".utf8)), "!meeting:test")
        XCTAssertThrowsError(try MeetingsService.meetingRoomID(from: Data("{\"roomId\":\"\"}".utf8)))
    }

    func testMeetingAccessDeniedIsReportedInsteadOfGenericError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingLinkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MeetingsService(homeserver: "https://meeting.invalid", accessTokenProvider: { "test-token" }, session: session)
        do {
            _ = try await service.ensureRoom(code: "code", userId: "@user:test")
            XCTFail("A forbidden meeting must not open a call")
        } catch {
            XCTAssertEqual(error as? MeetingLinkError, .forbidden)
        }
    }
}

private class MeetingLinkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"forbidden\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
