// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import XCTest

@MainActor
final class StalkCompatibilityTests: XCTestCase {
    private let sticker = SharedSticker(id: "hello", label: "Привет", mxc: "mxc://example.com/hello", mimetype: "image/webp", size: 48,
                                        w: 128, h: 128, animated: true, thumbnailMxc: "mxc://example.com/thumb", animatedPreviewMxc: "mxc://example.com/preview")

    func testCatalogueRejectsInvalidPackWithoutDiscardingValidPacks() throws {
        let good = SharedStickerPack(id: "hello", title: "Hello", items: [sticker])
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let data = try JSONSerialization.data(withJSONObject: ["packs": [goodJSON, ["id": "bad"], goodJSON]])
        XCTAssertEqual(try SharedStickerPack.decodeCatalogue(data), [good])
        XCTAssertFalse(SharedSticker.isMXC("https://foreign.example/media"))
        XCTAssertFalse(SharedSticker.isMXC("mxc://example.com/a?access_token=secret"))
    }

    func testRecentStickersAreUniqueAndLimitedToTen() {
        var preferences = SharedStickerPreferences(favorites: ["hello", "hello"], recent: (0..<15).map { "mxc://example.com/\($0)" })
        preferences.record(sticker)
        preferences.record(sticker)
        XCTAssertEqual(preferences.recent.count, 10)
        XCTAssertEqual(preferences.recent.first, sticker.mxc)
        XCTAssertEqual(preferences.recent.filter { $0 == sticker.mxc }.count, 1)
        XCTAssertEqual(preferences.favorites, ["hello"])
    }

    func testSentStickerPreservesAnimationAndThreadMetadata() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sticker.content(threadRoot: "$thread").utf8)) as? [String: Any])
        let info = try XCTUnwrap(json["info"] as? [String: Any])
        XCTAssertEqual(json["url"] as? String, sticker.mxc)
        XCTAssertEqual(info["org.matrix.msc4230.is_animated"] as? Bool, true)
        XCTAssertEqual(info["im.stalk.animated_preview_url"] as? String, sticker.animatedPreviewMxc)
        XCTAssertEqual((json["m.relates_to"] as? [String: Any])?["event_id"] as? String, "$thread")
    }

    func testFailedStickerSendDoesNotEnterRecents() async {
        let client = ClientProxyMock(.init(homeserver: "https://sticker.invalid", userID: "@one:example.com"))
        let service = SharedStickerService(client: client) { _ in throw URLError(.notConnectedToInternet) }
        let sent = await service.send(sticker)
        XCTAssertFalse(sent)
        XCTAssertTrue(service.preferences.recent.isEmpty)
        XCTAssertNotNil(service.error)
    }

    func testSystemSearchUsesTypedRoomTargetAndUnmodifiedPagingCount() throws {
        let body = #"{"total":3,"results":[{"entity_type":"message","target":{"kind":"room","room_id":"!room:test","event_id":"$event"},"title":null,"snippet":"hello\u0002world\u0003","created_at":"2026-10-16T10:00:00.123Z","meta":{"room":"Team","author":"Alice"}},{"entity_type":"message","target":null,"title":"unavailable","snippet":null,"created_at":"2026-10-16T10:00:00Z","meta":null}]}"#
        let response = try MessageSearchService.parseSystemResponse(Data(body.utf8), offset: 0, limit: 2)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results.first?.body, "helloworld")
        XCTAssertEqual(response.results.first?.roomName, "Team")
        XCTAssertEqual(response.nextBatch, "stalk-offset:2")
        XCTAssertEqual(response.totalCount, 3)
    }

    func testSearchRefreshesTokenOnceWithoutLegacyFallbackOn403() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var token = "old"
        var paths: [String] = []
        CompatibilityURLProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return (401, "{}") }
            return (403, "{}")
        }
        let service = MessageSearchService(homeserverURL: "https://search.invalid", accessTokenProvider: { token }, forceTokenRefresh: { token = "new" }, session: session)
        do { _ = try await service.searchMessages(query: "hello"); XCTFail("Forbidden is not an empty result") }
        catch MessageSearchError.serverError(let code) { XCTAssertEqual(code, 403) }
        XCTAssertEqual(paths, ["/api/search", "/api/search"])
    }

    func testAbsentSystemSearchUsesLegacyWithSafeCursorAndLimit() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var requests: [URLRequest] = []
        CompatibilityURLProtocol.handler = { request in
            requests.append(request)
            return request.url!.path == "/api/search" ? (404, "{}") : (200, #"{"search_categories":{"room_events":{"count":0,"results":[]}}}"#)
        }
        let service = MessageSearchService(homeserverURL: "https://search.invalid", accessTokenProvider: { "test" }, session: session)
        _ = try await service.searchMessages(query: "hello", limit: 7)
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/search", "/_matrix/client/v3/search"])
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        let categories = try XCTUnwrap(body["search_categories"] as? [String: Any])
        let room = try XCTUnwrap(categories["room_events"] as? [String: Any])
        XCTAssertEqual((room["filter"] as? [String: Any])?["limit"] as? Int, 7)
    }

    func testDiskCompositeCursorPreservesSameTimestampBoundary() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var requested: URL?
        CompatibilityURLProtocol.handler = { request in
            requested = request.url
            return (200, #"{"files":[],"nextBefore":1780000000000,"nextBeforeId":"$next"}"#)
        }
        let service = DiskService(baseURL: "https://disk.invalid", accessTokenProvider: { "test" }, session: session)
        let page = try await service.fetchFiles(before: "1780000000000", beforeId: "$boundary&part")
        let query = try XCTUnwrap(try URLComponents(url: XCTUnwrap(requested), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "before_id" }?.value, "$boundary&part")
        XCTAssertEqual(page.nextBefore, "1780000000000")
        XCTAssertEqual(page.nextBeforeId, "$next")
    }

    func testPreferencesUseSameAccountDataAsWebAndRecordOnlyAfterSend() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let saved = expectation(description: "Preferences uploaded")
        let catalogue = try JSONEncoder().encode(["packs": [SharedStickerPack(id: "hello", title: "Hello", items: [sticker])]])
        var uploaded: SharedStickerPreferences?
        CompatibilityURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock_access_token")
            XCTAssertNil(request.url?.query)
            if request.url!.path == "/_stalk/stickers/catalog" { return (200, String(decoding: catalogue, as: UTF8.self)) }
            XCTAssertTrue(request.url!.path.hasSuffix("/account_data/im.stalk.sticker_preferences"))
            if request.httpMethod == "PUT" {
                uploaded = try? JSONDecoder().decode(SharedStickerPreferences.self, from: request.httpBody!)
                saved.fulfill()
                return (200, "{}")
            }
            return (200, #"{"favorites":["hello"],"recent":[]}"#)
        }
        let client = ClientProxyMock(.init(homeserver: "https://sticker.invalid", userID: "@one:example.com"))
        let cache = STalkCacheService(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = SharedStickerService(client: client, session: session, cache: cache) { _ in }
        await service.load()
        XCTAssertTrue(service.packs.contains { $0.id == "hello" })
        XCTAssertEqual(service.preferences.favorites, ["hello"])
        let success = await service.send(sticker)
        XCTAssertTrue(success)
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(uploaded?.recent, [sticker.mxc])
        XCTAssertEqual(uploaded?.favorites, ["hello"])
    }

    func testCompactAnimationDoesNotReplaceEncryptedOrUnrelatedStickerMedia() throws {
        let content = try JSONSerialization.jsonObject(with: Data(sticker.content().utf8))
        let plain = try JSONSerialization.data(withJSONObject: ["type": "m.sticker", "content": content])
        let encrypted = try JSONSerialization.data(withJSONObject: ["type": "m.room.encrypted", "content": content])
        XCTAssertEqual(SharedSticker.animatedPreview(from: String(decoding: plain, as: UTF8.self), originalMXC: sticker.mxc)?.url.absoluteString,
                       sticker.animatedPreviewMxc)
        XCTAssertNil(SharedSticker.animatedPreview(from: String(decoding: encrypted, as: UTF8.self), originalMXC: sticker.mxc))
        XCTAssertNil(SharedSticker.animatedPreview(from: String(decoding: plain, as: UTF8.self), originalMXC: "mxc://example.com/other"))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibilityURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CompatibilityURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            captured.httpBody = data
        }
        let (status, body) = Self.handler!(captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
