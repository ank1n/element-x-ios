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
}
