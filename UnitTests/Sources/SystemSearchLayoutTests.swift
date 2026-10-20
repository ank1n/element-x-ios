// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SystemSearchLayoutTests: XCTestCase {
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

    func testSearchLayoutAtPhoneWidthsAndLargeText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchLayoutProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ClientProxyMock(.init(homeserver: "https://search-layout.invalid", userID: "@qa:example.invalid"))
        let name = "search-layout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SystemSearchViewModel(client: client, session: session, defaults: defaults)
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
