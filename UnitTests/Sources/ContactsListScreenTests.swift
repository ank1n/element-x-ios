//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import ElementX

@MainActor
class ContactsListScreenTests: XCTestCase {
    // MARK: - ContactFilter Tests

    func testContactFilterTitles() {
        XCTAssertEqual(ContactFilter.all.title, SL10n.contactsAll)
        XCTAssertEqual(ContactFilter.online.title, SL10n.contactsOnline)
        XCTAssertEqual(ContactFilter.favorites.title, SL10n.contactsFavorites)
    }

    func testContactFilterAllCases() {
        XCTAssertEqual(ContactFilter.allCases.count, 3)
    }

    // MARK: - ContactItem Tests

    func testContactItemIdentifiable() {
        let contact = makeContact(id: "test-1", name: "Alice")
        XCTAssertEqual(contact.id, "test-1")
        XCTAssertEqual(contact.displayName, "Alice")
    }

    func testContactItemEquality() {
        let a = makeContact(id: "1", name: "Alice")
        let b = makeContact(id: "1", name: "Alice")
        XCTAssertEqual(a, b)
    }

    func testContactItemInequality() {
        let a = makeContact(id: "1", name: "Alice")
        let b = makeContact(id: "2", name: "Bob")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - ContactsListScreenViewState Tests

    func testViewStateInitialValues() {
        let state = ContactsListScreenViewState()
        XCTAssertTrue(state.contacts.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.selectedFilter, .all)
        XCTAssertEqual(state.onlineCount, 0)
        XCTAssertEqual(state.favoritesCount, 0)
    }

    func testViewStateOnlineCount() {
        var state = ContactsListScreenViewState()
        state.contacts = [
            makeContact(id: "1", name: "Alice", isOnline: true),
            makeContact(id: "2", name: "Bob", isOnline: false),
            makeContact(id: "3", name: "Carol", isOnline: true),
        ]
        XCTAssertEqual(state.onlineCount, 2)
    }

    func testViewStateFavoritesCount() {
        var state = ContactsListScreenViewState()
        state.contacts = [
            makeContact(id: "1", name: "Alice", isFavorite: true),
            makeContact(id: "2", name: "Bob", isFavorite: false),
            makeContact(id: "3", name: "Carol", isFavorite: true),
            makeContact(id: "4", name: "Dave", isFavorite: true),
        ]
        XCTAssertEqual(state.favoritesCount, 3)
    }

    // MARK: - Helpers

    private func makeContact(
        id: String,
        name: String,
        isOnline: Bool = false,
        isFavorite: Bool = false
    ) -> ContactItem {
        ContactItem(
            id: id,
            displayName: name,
            avatarURL: nil,
            matrixUserID: "@\(name.lowercased()):example.com",
            isOnline: isOnline,
            lastSeenDate: nil,
            isFavorite: isFavorite
        )
    }
}
