//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// A bookmarked message stored locally on device
struct BookmarkedMessage: Codable, Identifiable, Equatable {
    let id: String // eventID
    let roomID: String
    let senderID: String
    let senderName: String
    let body: String // text preview
    let timestamp: Date
    let bookmarkedAt: Date

    init(eventID: String, roomID: String, senderID: String, senderName: String, body: String, timestamp: Date) {
        self.id = eventID
        self.roomID = roomID
        self.senderID = senderID
        self.senderName = senderName
        self.body = body
        self.timestamp = timestamp
        self.bookmarkedAt = Date()
    }
}

/// Protocol for bookmark storage
protocol BookmarkServiceProtocol: AnyObject {
    var bookmarksPublisher: AnyPublisher<[BookmarkedMessage], Never> { get }

    func addBookmark(_ message: BookmarkedMessage)
    func removeBookmark(eventID: String)
    func isBookmarked(eventID: String) -> Bool
    func getAllBookmarks() -> [BookmarkedMessage]
    func clearBookmarks()
}

/// Local storage for bookmarked messages using UserDefaults
class BookmarkService: BookmarkServiceProtocol {
    private let storageKey = "ru.implica.stalk.bookmarkedMessages"
    private let userDefaults: UserDefaults
    private let maxBookmarks = 500

    private var bookmarks: [BookmarkedMessage] = []
    private let bookmarksSubject = CurrentValueSubject<[BookmarkedMessage], Never>([])

    var bookmarksPublisher: AnyPublisher<[BookmarkedMessage], Never> {
        bookmarksSubject.eraseToAnyPublisher()
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadBookmarks()
    }

    // MARK: - Public Methods

    func addBookmark(_ message: BookmarkedMessage) {
        // Don't add duplicates
        guard !bookmarks.contains(where: { $0.id == message.id }) else {
            MXLog.info("Bookmark already exists for event: \(message.id)")
            return
        }

        bookmarks.insert(message, at: 0)
        trimBookmarks()
        saveBookmarks()
        notifyChange()

        MXLog.info("Bookmark added: \(message.id) in room \(message.roomID)")
    }

    func removeBookmark(eventID: String) {
        bookmarks.removeAll { $0.id == eventID }
        saveBookmarks()
        notifyChange()

        MXLog.info("Bookmark removed: \(eventID)")
    }

    func isBookmarked(eventID: String) -> Bool {
        bookmarks.contains { $0.id == eventID }
    }

    func getAllBookmarks() -> [BookmarkedMessage] {
        bookmarks
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        saveBookmarks()
        notifyChange()
    }

    // MARK: - Private Methods

    private func loadBookmarks() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            bookmarks = []
            return
        }

        do {
            bookmarks = try JSONDecoder().decode([BookmarkedMessage].self, from: data)
            notifyChange()
            MXLog.info("Loaded \(bookmarks.count) bookmarks")
        } catch {
            MXLog.error("Failed to load bookmarks: \(error)")
            bookmarks = []
        }
    }

    private func saveBookmarks() {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            MXLog.error("Failed to save bookmarks: \(error)")
        }
    }

    private func trimBookmarks() {
        if bookmarks.count > maxBookmarks {
            bookmarks = Array(bookmarks.prefix(maxBookmarks))
        }
    }

    private func notifyChange() {
        bookmarksSubject.send(bookmarks)
    }
}
