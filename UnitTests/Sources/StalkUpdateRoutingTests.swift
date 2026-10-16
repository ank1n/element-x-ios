// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import XCTest

@MainActor
final class StalkUpdateRoutingTests: XCTestCase {
    private let id = "031577da-65ec-4bfe-8126-5500d17392ae"

    func testDiskRouteMatchesWebAndPreservesAccountOrigin() throws {
        let url = try XCTUnwrap(URL(string: "https://stalk.implica.ru/?go=1#/files/open?blob=\(id)&disk=1&name=report.md"))
        let link = try XCTUnwrap(StalkDiskLink(url: url))
        XCTAssertEqual(link.blobID, id)
        XCTAssertEqual(link.name, "report.md")
        XCTAssertTrue(link.isDiskDocument)
        let origin = try XCTUnwrap(StalkServerLink(url: url))
        XCTAssertFalse(origin.shouldOpenInBrowser(knownHosts: ["stalk.implica.ru"], homeserver: "https://stalk.implica.ru", mayRestoreSession: false))
        XCTAssertTrue(origin.shouldOpenInBrowser(knownHosts: ["stalk.implica.ru"], homeserver: "https://market.implica.ru", mayRestoreSession: false))
        XCTAssertTrue(origin.shouldOpenInBrowser(knownHosts: ["stalk.implica.ru"], homeserver: nil, mayRestoreSession: false))
    }

    func testDiskIDsMustNotBecomeArbitraryPathsOrExternalRoutes() throws {
        for raw in ["https://stalk.implica.ru/#/files/open?blob=../secret", "https://user:password@stalk.implica.ru/#/files/open?blob=\(id)",
                    "http://stalk.implica.ru/#/files/open?blob=\(id)", "https://stalk.implica.ru/#/files/open?blob=\(id)&blob=\(id)"] {
            XCTAssertNil(try StalkDiskLink(url: XCTUnwrap(URL(string: raw))))
        }
        let link = try StalkDiskLink(url: XCTUnwrap(URL(string: "https://stalk.implica.ru/#/files/open?blob=\(id)&name=../../report.md")))
        XCTAssertEqual(link?.name, "report.md")
    }

    func testManagedAvailabilityDoesNotRestoreHiddenBuiltinOrOtherPlatform() {
        let policy = ApplicationAvailability(schemaVersion: 1, managed: true, revision: "v1", apps: [
            .init(id: "files", enabled: false), .init(id: "ailock", enabled: true, clients: ["web"]), .init(id: "calendar", enabled: true, clients: ["ios"])
        ])
        XCTAssertFalse(policy.allows("files"))
        XCTAssertFalse(policy.allows("ailock"))
        XCTAssertFalse(policy.allows("unknown"))
        XCTAssertTrue(policy.allows("calendar"))
    }

    func testManagedInstallationCannotFailOpenOn404OrDowngrade() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UpdatePolicy.\(UUID().uuidString)"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdatePolicyURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var status = 200
        var body = #"{"schemaVersion":1,"managed":true,"revision":"v1","apps":[{"id":"files","enabled":false}]}"#
        UpdatePolicyURLProtocol.handler = { _ in (status, body) }
        let client = ClientProxyMock(.init(homeserver: "https://apps.invalid", userID: "@one:apps.invalid"))
        let service = ApplicationAvailabilityService(client: client, session: session, defaults: defaults)
        await service.refresh()
        XCTAssertFalse(service.allows("files"))
        status = 404
        await service.refresh(force: true)
        XCTAssertTrue(service.failed)
        XCTAssertFalse(service.allows("files"))
        status = 200
        body = #"{"schemaVersion":1,"managed":false,"revision":"legacy","apps":[]}"#
        await service.refresh(force: true)
        XCTAssertTrue(service.failed)
        let restored = ApplicationAvailabilityService(client: client, session: session, defaults: defaults)
        status = 404
        await restored.refresh()
        XCTAssertTrue(restored.failed)
    }

    func testLegacyAvailability404IsScopedAndDoesNotRequireCredentials() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdatePolicyURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        UpdatePolicyURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/apps-api/availability")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (404, "{}")
        }
        let service = try ApplicationAvailabilityService(client: ClientProxyMock(.init(homeserver: "https://legacy.invalid")), session: session,
                                                         defaults: XCTUnwrap(UserDefaults(suiteName: "Legacy.\(UUID().uuidString)")))
        await service.refresh()
        XCTAssertTrue(service.allows("files"))
    }
}

private final class UpdatePolicyURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (status, body) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
