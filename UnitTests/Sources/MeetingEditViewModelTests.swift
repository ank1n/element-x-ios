//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import XCTest

/// STMOB-303: поиск участников встречи идёт по справочнику Synapse, а у справочника
/// лимит частоты. Раньше каждая набранная буква уходила отдельным поиском.
@MainActor
class MeetingEditViewModelTests: XCTestCase {
    private var discovery: UserDiscoveryServiceMock!
    private var viewModel: MeetingEditViewModel!

    override func setUp() {
        discovery = UserDiscoveryServiceMock()
        discovery.searchProfilesWithReturnValue = .success([.mockAlice])
        viewModel = MeetingEditViewModel(service: MeetingsService(homeserver: "https://example.com", accessToken: "token"),
                                         userDiscoveryService: discovery)
    }

    func testFastTypingSendsSingleSearchForLastQuery() async throws {
        for query in ["a", "al", "ali", "alic", "alice"] {
            viewModel.context.send(viewAction: .searchParticipants(query))
        }
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(discovery.searchProfilesWithReceivedInvocations, ["alice"])
        XCTAssertEqual(viewModel.context.viewState.searchResults.map(\.userID), [UserProfileProxy.mockAlice.userID])
    }

    func testSameQueryIsNotSearchedTwice() async throws {
        viewModel.context.send(viewAction: .searchParticipants("alice"))
        try await Task.sleep(for: .milliseconds(400))
        viewModel.context.send(viewAction: .searchParticipants("alice"))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(discovery.searchProfilesWithCallsCount, 1)
    }

    func testClearingQueryClearsResultsWithoutSearching() async throws {
        viewModel.context.send(viewAction: .searchParticipants("alice"))
        try await Task.sleep(for: .milliseconds(400))
        viewModel.context.send(viewAction: .searchParticipants(""))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(discovery.searchProfilesWithCallsCount, 1)
        XCTAssertTrue(viewModel.context.viewState.searchResults.isEmpty)
        XCTAssertFalse(viewModel.context.viewState.isSearching)
    }

    func testVenueEncodingPreservesUnchangedBookingAndSupportsExplicitRemoval() throws {
        var request = MeetingRequest(title: "Meeting", startTime: Date(), endTime: Date().addingTimeInterval(3600))
        func object() throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        XCTAssertNil(try object()["room_id"])
        request.roomID = 42
        XCTAssertEqual(try object()["room_id"] as? Int, 42)
        request.roomID = nil; request.updatesRoom = true
        XCTAssertTrue(try object()["room_id"] is NSNull)
    }

    func testOwnBookingIsExcludedButOtherConflictsRemain() throws {
        let data = Data(#"{"id":1,"name":"Room","can_book":true,"busy":[{"start":"a","end":"b","mine":true,"meeting_id":42},{"start":"a","end":"c","mine":false}]}"#.utf8)
        let room = try JSONDecoder().decode(MeetingVenueRoom.self, from: data)
        XCTAssertEqual(room.conflicts(excluding: 42).count, 1)
        XCTAssertEqual(room.conflicts(excluding: nil).count, 2)
    }
}
