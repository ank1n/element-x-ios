// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import MatrixRustSDKMocks
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SystemSearchLayoutTests: XCTestCase {
    func testFileResultsNeverShowExtractedMarkdownAndKeepRealFilenameAndType() throws {
        let hit = try JSONDecoder().decode(SystemSearchHit.self, from: Data(#"{"id":"file1","entity_type":"file","facet_type":"attachment","entity_id":"$event","title":"Slide heading","snippet":"<!-- Slide number: 1 --> ![logo.png](Picture1.jpg)","meta":{"filename":"rosseti-reserve-v2.pptx","mimetype":"application/vnd.openxmlformats-officedocument.presentationml.presentation","size":2700000,"author":"Михаил Самусенко"}}"#.utf8))
        XCTAssertTrue(hit.isFileResult)
        XCTAssertNil(hit.displayedSnippet)
        XCTAssertEqual(hit.fileDisplayName, "rosseti-reserve-v2.pptx")
        XCTAssertEqual(hit.meta?.size, 2_700_000)
        let message = try JSONDecoder().decode(SystemSearchHit.self, from: Data(#"{"id":"msg1","entity_type":"message","entity_id":"$message","snippet":"Привет"}"#.utf8))
        XCTAssertEqual(message.displayedSnippet, "Привет")
    }

    func testFileAuthorUsesExactEventSenderAndNeverGuessesByName() async throws {
        let suite = "file-author-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ClientProxyMock(.init())
        let room = JoinedRoomProxyMock(.init(id: "!r:example.com"))
        let event = TimelineEventSDKMock(); event.senderIdReturnValue = "@ms:example.com"
        room.loadOrFetchEventDetailsForReturnValue = .success(event)
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let expected = UserProfileProxy(userID: "@ms:example.com", displayName: "Михаил Самусенко", avatarURL: URL(string: "mxc://example.com/avatar"))
        client.profileForReturnValue = .success(expected)
        let model = SystemSearchViewModel(client: client, defaults: defaults)
        defer { model.stop() }
        let hit = try JSONDecoder().decode(SystemSearchHit.self, from: Data(#"{"id":"1","entity_type":"file","entity_id":"$event","meta":{"author":"@not-the-sender:example.com"},"target":{"kind":"room","room_id":"!r:example.com","event_id":"$event"}}"#.utf8))
        let profile = await model.authorProfile(for: hit)
        XCTAssertEqual(profile, expected)
        let unknown = try JSONDecoder().decode(SystemSearchHit.self, from: Data(#"{"id":"2","entity_type":"disk_doc","entity_id":"file-id","meta":{"author":"@ms:example.com"}}"#.utf8))
        let unresolved = await model.authorProfile(for: unknown)
        XCTAssertNil(unresolved)
    }

    func testHistoryGroupsLocalDatesAndKeepsUnknownDatesHonest() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
            calendar.date(from: .init(year: 2026, month: month, day: day, hour: hour))!
        }
        let now = day(10, 23)
        let dates = [day(10, 23), day(10, 22), day(10, 21), day(10, 14), day(10, 2), day(9, 30), day(8, 1)]
        let queries = (0..<8).map { index in var value = SystemSearchConditions(); value.query = String(index); return value }
        let byQuery = Dictionary(uniqueKeysWithValues: zip(queries.map(\.query), dates))
        let groups = SystemSearchHistorySection.grouped(Array(queries.reversed()), date: { byQuery[$0.query] }, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.period), [.today, .yesterday, .thisWeek, .lastWeek, .thisMonth, .lastMonth, .month(day(8, 1, hour: 0)), .undated])
        XCTAssertEqual(groups.flatMap(\.queries).map(\.query), queries.map(\.query))
        XCTAssertEqual(SystemSearchHistoryPeriod.period(for: day(10, 23, hour: 23), now: day(10, 24, hour: 0), calendar: calendar), .yesterday)
    }

    func testHistoryYesterdayUsesCalendarAcrossDaylightSavingAndYearBoundary() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 3, day: 9, hour: 0, minute: 30)))
        let yesterday = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 3, day: 8, hour: 0, minute: 15)))
        XCTAssertEqual(SystemSearchHistoryPeriod.period(for: yesterday, now: now, calendar: calendar), .yesterday)
        let january = try XCTUnwrap(calendar.date(from: .init(year: 2027, month: 1, day: 2)))
        let december = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 12, day: 10)))
        XCTAssertEqual(SystemSearchHistoryPeriod.period(for: december, now: january, calendar: calendar), .lastMonth)
    }

    func testHistoryPersistsServerCountsPerFilterAndMigratesOldEntries() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchLayoutProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let suite = "history-counts-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ClientProxyMock(.init(homeserver: "https://search-layout.invalid", userID: "@qa:example.invalid"))
        let model = SystemSearchViewModel(client: client, session: session, defaults: defaults)
        defer { model.stop() }
        model.updateQuery("Привет"); model.search()
        for _ in 0..<100 where model.loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        let query = model.conditions
        let summary = try XCTUnwrap(model.historySummary(for: query))
        XCTAssertEqual(summary.total, 156)
        XCTAssertEqual(summary.facets.first { $0.type == "message" }?.count, 70)
        XCTAssertEqual(summary.facets.first { $0.type == "transcript" }?.count, 26)
        XCTAssertEqual(model.hits.count, 3, "Counts must come from facets, not the loaded page")
        var filtered = query; filtered.format = "pdf"
        XCTAssertNil(model.historySummary(for: filtered))
        let savedKey = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("stalk.search.saved.v1.") })
        let saved = try XCTUnwrap(defaults.data(forKey: savedKey))
        let restored = SystemSearchViewModel(client: client, session: session, defaults: defaults)
        defer { restored.stop() }
        XCTAssertEqual(restored.historySummary(for: query), summary)
        model.pin(); model.forgetRecent()
        XCTAssertEqual(model.historySummary(for: query), summary)
        model.pin()
        XCTAssertTrue(model.historySummaries.isEmpty)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy.removeValue(forKey: "summaries")
        try defaults.set(JSONSerialization.data(withJSONObject: legacy), forKey: savedKey)
        let old = SystemSearchViewModel(client: client, session: session, defaults: defaults)
        defer { old.stop() }
        XCTAssertEqual(old.recent.first?.query, "Привет")
        XCTAssertNil(old.historySummary(for: query), "Missing statistics are unknown, never zero")
        let otherClient = ClientProxyMock(.init(homeserver: "https://search-layout.invalid", userID: "@other:example.invalid"))
        let other = SystemSearchViewModel(client: otherClient, session: session, defaults: defaults)
        defer { other.stop() }
        XCTAssertTrue(other.recent.isEmpty)
        XCTAssertTrue(other.historySummaries.isEmpty)
    }

    func testSearchIsNativeApplicationAndExplicitAvailabilityWins() {
        let app = WidgetItem.search
        XCTAssertTrue(app.isBuiltin)
        XCTAssertEqual(app.icon, "magnifyingglass")
        let absent = ApplicationAvailability(schemaVersion: 1, managed: true, revision: "test", apps: [])
        XCTAssertTrue(absent.allows(app.id))
        XCTAssertFalse(absent.allows("arbitrary-app"))
        let disabled = ApplicationAvailability(schemaVersion: 1, managed: true, revision: "test", apps: [.init(id: app.id, enabled: false)])
        XCTAssertFalse(disabled.allows(app.id))
        let webOnly = ApplicationAvailability(schemaVersion: 1, managed: true, revision: "test", apps: [.init(id: app.id, enabled: true, clients: ["web"])])
        XCTAssertFalse(webOnly.allows(app.id))
    }

    func testSearchTileIsNotDuplicatedOrLostWithStaleRegistryData() {
        let stale = WidgetItem(id: WidgetItem.searchAppID, name: "Old", description: "", url: "https://old.invalid", type: "widget")
        let widgets = WidgetItem.includingSearch(in: [stale, .files, stale], allowed: true)
        XCTAssertEqual(widgets.map(\.id), [WidgetItem.searchAppID, WidgetItem.filesAppID])
        XCTAssertTrue(widgets[0].isBuiltin)
        XCTAssertEqual(WidgetItem.includingSearch(in: widgets, allowed: false).map(\.id), [WidgetItem.filesAppID])
    }

    func testHistoryIsInitialAndDictationDoesNotSubmitUntilExplicitSearch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchLayoutProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let name = "search-history-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SystemSearchViewModel(client: ClientProxyMock(.init(homeserver: "https://search-layout.invalid", userID: "@qa:example.invalid")), session: session, defaults: defaults)
        defer { model.stop() }
        XCTAssertFalse(model.hasSubmittedSearch)
        model.insertDictation("Привет")
        XCTAssertEqual(model.conditions.query, "Привет")
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.hasSubmittedSearch)
        XCTAssertTrue(model.hits.isEmpty)
        model.search()
        for _ in 0..<100 where model.hits.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.hasSubmittedSearch)
        XCTAssertEqual(model.hits.count, 3)
        XCTAssertEqual(model.recent.first?.query, "Привет")
        model.showHistory()
        XCTAssertFalse(model.hasSubmittedSearch)
        model.resume()
        XCTAssertFalse(model.hasSubmittedSearch)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
        let host = UIHostingController(rootView: NavigationStack { SystemSearchScreen(model: model, open: { _, _ in }) })
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for: .milliseconds(250))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Search initial history 320"; attachment.lifetime = .keepAlways; add(attachment)
        try model.restore(XCTUnwrap(model.recent.first))
        XCTAssertTrue(model.hasSubmittedSearch)
        model.stop()
        model.insertDictation("Late result")
        XCTAssertEqual(model.conditions.query, "Привет")
    }

    func testSearchLayoutAtPhoneWidthsAndLargeText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchLayoutProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ClientProxyMock(.init(homeserver: "https://search-layout.invalid", userID: "@qa:example.invalid"))
        let name = "search-layout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SystemSearchViewModel(client: client, session: session, defaults: defaults, planner: { _ in
            try await Task.sleep(for: .seconds(10))
            throw SystemSearchError.plannerFailed
        })
        defer { model.stop() }
        model.conditions.query = "Привет"
        model.search()
        for _ in 0..<100 where model.hits.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.hits.count, 3)
        for (width, size) in [(CGFloat(320), DynamicTypeSize.large), (390, .large), (390, .xxxLarge)] {
            let view = NavigationStack {
                SystemSearchScreen(model: model) { _, _ in }
            }.environment(\.dynamicTypeSize, size)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let oldKey = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Search \(Int(width)) \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            oldKey?.makeKey()
            model.resume()
        }
        model.search(smart: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
        let host = UIHostingController(rootView: NavigationStack { SystemSearchScreen(model: model, open: { _, _ in }) })
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil; oldKey?.makeKey() }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(model.smartSearchRunning)
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.hits.isEmpty)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Ailock progress 320"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private final class SearchLayoutProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let payload = #"{"total":156,"facets":[{"entity_type":"message","n":70},{"entity_type":"transcript","n":26},{"entity_type":"task","n":60}],"results":[{"id":1,"entity_id":"task-1","entity_type":"task","title":"VOX-67 Тестирование fuzzy-поиска контактов — 20 диктовок","snippet":"Полное ФИО: Письмо Кому Соколов Андрей. Андрей привет. Проверка длинного текста и нескольких строк результата.","target":{"kind":"issue","issue_id":"test"}},{"id":2,"entity_id":"msg-1","entity_type":"message","snippet":"Привет привет","meta":{"room":"Пресейл и маркетинговые материалы","author":"Иван Жилин"},"target":{"kind":"room","room_id":"!test:example.invalid","event_id":"$test"}},{"id":3,"entity_id":"task-2","entity_type":"task","title":"TRKIT-198 Привет","snippet":"Привет","target":{"kind":"issue","issue_id":"test2"}}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
