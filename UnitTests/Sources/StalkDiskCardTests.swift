// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import SwiftUI
import XCTest

@MainActor
final class StalkDiskCardTests: XCTestCase {
    private let blob = "031577da-65ec-4bfe-8126-5500d17392ae"
    private let server = URL(string: "https://stalk.implica.ru")!

    func testInternalFileLinkKeepsNameAndExactTarget() throws {
        let url = try XCTUnwrap(URL(string: "https://stalk.implica.ru/?go=1#/files/open?blob=\(blob)&disk=1&name=report.pdf"))
        let card = try XCTUnwrap(StalkDiskCard(url: url))
        XCTAssertEqual(card.kind, .document)
        XCTAssertEqual(card.name, "report.pdf")
        XCTAssertEqual(card.url, url)
        XCTAssertEqual(StalkDiskCard.links(in: url.absoluteString, homeserver: server).count, 1)
    }

    func testRelativeHTMLAnchorUsesCurrentServerAndDeduplicatesTextURL() throws {
        let relative = try XCTUnwrap(URL(string: "/#/files/open?blob=\(blob)&disk=0&name=report.pdf"))
        var formatted = AttributedString("Read the report")
        formatted.link = relative
        let cards = StalkDiskCard.links(in: "Read the report", formattedBody: formatted, homeserver: server)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.url.host, server.host)
        XCTAssertFalse(try XCTUnwrap(cards.first.flatMap { StalkDiskLink(url: $0.url) }).isDiskDocument)
        let full = try XCTUnwrap(cards.first?.url)
        formatted.link = full
        XCTAssertEqual(StalkDiskCard.links(in: full.absoluteString, formattedBody: formatted, homeserver: server).count, 1)
    }

    func testStandaloneDiskDocumentAndPublicLinkStayOnTheirOwnOrigin() throws {
        let standalone = try XCTUnwrap(URL(string: "https://disk.implica.ru/#doc/\(blob)"))
        XCTAssertEqual(StalkDiskCard(url: standalone)?.kind, .standaloneDocument)
        let external = try XCTUnwrap(URL(string: "https://disk.implica.ru/s/example_opaque-token?download=0"))
        let card = try XCTUnwrap(StalkDiskCard(url: external))
        XCTAssertEqual(card.kind, .publicShare)
        XCTAssertEqual(card.url, external)
        XCTAssertTrue(card.name.isEmpty) // Do not invent a filename or access permission.
        XCTAssertNil(StalkDiskLink(url: external)) // Never send this public token to the authenticated blob API.
    }

    func testOtherServersFoldersMeetingsAndUnsafeLinksAreNotFileCards() throws {
        for raw in ["https://example.org/s/opaque", "https://disk.implica.ru.attacker.example/s/opaque", "https://disk.implica.ru/#folder/7",
                    "https://stalk.implica.ru/meet/s/meeting", "http://disk.implica.ru/s/token", "https://user:password@disk.implica.ru/s/token",
                    "https://stalk.implica.ru/#/files/open?blob=../secret"] {
            XCTAssertNil(try StalkDiskCard(url: XCTUnwrap(URL(string: raw)), homeserver: server), raw)
        }
    }

    func testPublicLinkOnCustomHomeserverAndCustomSchemePrivateLink() throws {
        let custom = try XCTUnwrap(URL(string: "https://files.example"))
        XCTAssertEqual(try StalkDiskCard(url: XCTUnwrap(URL(string: "https://files.example/s/token")), homeserver: custom)?.kind, .publicShare)
        let body = "ru.implica.stalk://stalk.implica.ru/#/files/open?blob=\(blob)&disk=1"
        XCTAssertEqual(StalkDiskCard.links(in: body, homeserver: server).first?.kind, .document)
        XCTAssertEqual(StalkDiskCard.links(in: body, homeserver: server).count, 1)
    }

    func testPublicPreviewUsesOnlyPublicEndpointWithoutCredentials() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiskCardURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DiskCardURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/public/test-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (200, #"{"kind":"file","name":"report.pdf","size":2048,"mimetype":"application/pdf","canDownload":false}"#)
        }
        let service = StalkDiskPublicPreview(session: session)
        let card = try XCTUnwrap(StalkDiskCard(url: XCTUnwrap(URL(string: "https://disk.implica.ru/s/test-token"))))
        let metadata = await service.metadata(for: card)
        XCTAssertEqual(metadata?.name, "report.pdf")
        XCTAssertEqual(metadata?.size, 2048)
    }

    func testPasswordProtectedPublicPreviewNeverDisclosesFilename() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiskCardURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DiskCardURLProtocol.handler = { _ in (401, #"{"needPassword":true,"name":"must-not-be-displayed.pdf"}"#) }
        let card = try XCTUnwrap(StalkDiskCard(url: XCTUnwrap(URL(string: "https://disk.implica.ru/s/test-token"))))
        let metadata = await StalkDiskPublicPreview(session: session).metadata(for: card)
        XCTAssertNil(metadata)
    }

    func testFileCardsRenderAtPhoneWidthIncludingLargeType() throws {
        let share = StalkFileShare(blobID: blob, name: "Очень длинное название общего документа — отчёт по проектам TrackIT.pdf", size: 16011, mimetype: "application/pdf", isDiskDocument: true, permission: .read, sharedWith: [])
        let internalCard = try XCTUnwrap(StalkDiskCard(url: XCTUnwrap(URL(string: "https://stalk.implica.ru/#/files/open?blob=\(blob)&name=report.pdf"))))
        let publicCard = try XCTUnwrap(StalkDiskCard(url: XCTUnwrap(URL(string: "https://disk.implica.ru/s/test-token"))))
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let view = VStack(alignment: .leading, spacing: 16) {
                StalkFileShareView(fileShare: share, onTap: { })
                StalkDiskLinkCardView(card: internalCard, open: { })
                StalkDiskLinkCardView(card: publicCard, open: { })
            }.padding(16).frame(width: 390).background(Color.white).environment(\.dynamicTypeSize, size).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 390)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Disk cards phone width \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSharedMetadataSurvivesBothTextAndNoticeMessageTypes() throws {
        for type in ["m.text", "m.notice"] {
            let json = try JSONSerialization.data(withJSONObject: ["content": ["msgtype": type, "body": "Report", "io.stalk.file_share": ["blobId": blob, "name": "report.pdf", "size": 2048, "mimetype": "application/pdf", "disk": false, "permission": "write"]]])
            let share = try XCTUnwrap(StalkFileShare.parse(originalJSON: String(decoding: json, as: UTF8.self)))
            XCTAssertEqual(share.name, "report.pdf")
            XCTAssertEqual(share.permission, .write)
            XCTAssertFalse(share.isDiskDocument)
            XCTAssertEqual(share.size, 2048)
        }
    }
}

private final class DiskCardURLProtocol: URLProtocol {
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
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
