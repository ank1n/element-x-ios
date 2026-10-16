// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import XCTest

@MainActor
final class StalkUpdateTransportTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateTransportURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testAttachmentRetries401WithFreshTokenAndScopedPath() async throws {
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let conversation = "031577da-65ec-4bfe-8126-5500d17392ae"
        var token = "expired"
        var requests = 0
        UpdateTransportURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "files.invalid")
            XCTAssertEqual(request.url?.path, "/api/ailock/v1/api/v1/conversations/\(conversation)/attachments/file-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), requests == 1 ? "Bearer expired" : "Bearer fresh")
            return (requests == 1 ? 401 : 200, "report")
        }
        let service = AilockService(homeserver: "https://files.invalid", accessTokenProvider: { token }, forceTokenRefresh: { token = "fresh" }, session: transport)
        let file = AilockFile(id: "file-1", filename: "report.txt", mimeType: "text/plain", url: nil, attachmentID: "file-1")
        let url = try await service.download(file: file, conversationID: conversation)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "report")
        XCTAssertEqual(requests, 2)
    }

    func testForeignAttachmentIsRejectedBeforeTokenOrNetworkAccess() async {
        let transport = session()
        defer { transport.invalidateAndCancel() }
        UpdateTransportURLProtocol.handler = { _ in XCTFail("Foreign URL must never be requested"); return (200, "") }
        let service = AilockService(homeserver: "https://files.invalid", accessTokenProvider: { XCTFail("Token must not be read"); return "secret" }, session: transport)
        let file = AilockFile(id: "one", filename: "file.txt", mimeType: "text/plain", url: "https://foreign.invalid/api/v1/conversations/031577da-65ec-4bfe-8126-5500d17392ae/attachments/one", attachmentID: "one")
        do {
            _ = try await service.download(file: file, conversationID: "031577da-65ec-4bfe-8126-5500d17392ae")
            XCTFail("Expected rejection")
        } catch { }
    }

    func testSearchKeepsFacetSemanticTailAndTruncationMetadata() async throws {
        let transport = session()
        defer { transport.invalidateAndCancel() }
        UpdateTransportURLProtocol.handler = { _ in
            (200, #"{"total":1,"results":[{"id":1,"entity_type":"attachment","facet_type":"disk_doc","entity_id":"file","target":{"kind":"file","file_id":"031577da-65ec-4bfe-8126-5500d17392ae"}}],"semantic":{"tail":2},"facets":[{"entity_type":"disk_doc","n":1,"n_sense":2}],"truncated":true,"words_used":8}"#)
        }
        let service = SystemSearchService(client: ClientProxyMock(.init(homeserver: "https://search.invalid")), session: transport)
        var conditions = SystemSearchConditions(); conditions.query = "report"
        let response = try await service.search(conditions)
        XCTAssertEqual(response.results.first?.facetKind, "disk_doc")
        XCTAssertEqual(response.facets?.first?.count, 3)
        XCTAssertEqual(response.semantic?.tail, 2)
        XCTAssertEqual(response.queryTruncated, true)
        XCTAssertEqual(response.wordsUsed, 8)
    }

    func testSearchAcceptsPostgresBigserialStringIDsWithoutPrecisionLoss() throws {
        let data = Data(#"{"total":1,"results":[{"id":"9223372036854775807","entity_type":"message","entity_id":"$one","target":{"kind":"room","room_id":"!one:test","event_id":"$one"}}]}"#.utf8)
        let response = try JSONDecoder().decode(SystemSearchResponse.self, from: data)
        XCTAssertEqual(try String(describing: XCTUnwrap(response.results.first?.id)), "9223372036854775807")
    }

    func testPinnedSearchRestoresAllConditionsAndIsAccountScoped() throws {
        let suite = "UpdateSearch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ClientProxyMock(.init(homeserver: "https://search.invalid", userID: "@one:search.invalid"))
        let model = SystemSearchViewModel(client: client, defaults: defaults)
        model.conditions.query = "report"
        model.conditions.types = ["disk_doc"]
        model.conditions.period = "week"
        model.conditions.sender = "@two:search.invalid"
        model.pin()
        XCTAssertEqual(SystemSearchViewModel(client: client, defaults: defaults).pinned.first, model.conditions)
        let other = ClientProxyMock(.init(homeserver: "https://search.invalid", userID: "@other:search.invalid"))
        XCTAssertTrue(SystemSearchViewModel(client: other, defaults: defaults).pinned.isEmpty)
    }

    func testEditingSmartQueryClearsPreviousPlannedTopic() {
        let model = SystemSearchViewModel(client: ClientProxyMock(.init(homeserver: "https://search.invalid")))
        model.conditions.query = "old question"
        model.conditions.topic = "old derived topic"
        model.conditions.expand = ["old expansion"]
        model.conditions.mode = "smart"
        model.conditions.types = ["disk_doc"]
        model.updateQuery("new question")
        XCTAssertNil(model.conditions.topic)
        XCTAssertTrue(model.conditions.expand.isEmpty)
        XCTAssertEqual(model.conditions.mode, "basic")
        XCTAssertEqual(model.conditions.types, ["disk_doc"])
    }

    func testPhotoFilterRejectsInvalidDatesAndUnknownCategory() {
        var filter = DiskPhotoFilterConditions()
        filter.from = "2026-02-30"
        XCTAssertFalse(filter.valid)
        filter.from = "2026-02-28"; filter.to = "2026-02-01"
        XCTAssertFalse(filter.valid)
        filter.to = "2026-03-01"; filter.category = "future-unsupported"
        XCTAssertFalse(filter.valid)
        filter.category = "images"
        XCTAssertTrue(filter.valid)
    }
}

private final class UpdateTransportURLProtocol: URLProtocol {
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
