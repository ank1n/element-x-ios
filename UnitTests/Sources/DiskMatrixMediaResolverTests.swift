// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import XCTest

@MainActor
final class DiskMatrixMediaResolverTests: XCTestCase {
    private var file: DiskFile {
        DiskFile(eventID: "$photo", roomID: "!room:test", blobID: nil, sender: "@one:test", filename: "private.png", mimetype: "image/png", size: 10,
                 msgtype: "m.image", category: .images, mxcURL: "mxc://untrusted/index-only", ts: 0, isEncrypted: true, folderID: nil, starred: false, sharedWith: nil)
    }

    func testSDKMediaSourceIsPreservedInsteadOfUsingIndexURL() async throws {
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        let room = JoinedRoomProxyMock(.init(id: "!room:test"))
        let event = TimelineEventSDKMock(); event.eventIdReturnValue = "$photo"
        let source = try MediaSource.fromUrl(url: "mxc://test/sdk-source")
        event.contentReturnValue = .messageLike(content: .roomMessage(messageType: .image(content: .init(filename: "private.png", caption: nil, formattedCaption: nil, source: source, info: nil)), inReplyToEventId: nil))
        room.loadOrFetchEventDetailsForReturnValue = .success(event)
        client.roomForIdentifierClosure = { id in XCTAssertEqual(id, "!room:test"); return .joined(room) }
        let resolved = await DiskMatrixMediaResolver(client: client).source(for: file)
        XCTAssertTrue(resolved?.underlyingSource === source)
        XCTAssertNotEqual(resolved?.url?.absoluteString, file.mxcURL)
        XCTAssertEqual(room.loadOrFetchEventDetailsForReceivedInvocations, ["$photo"])
    }

    func testMissingDecryptionKeysNeverManufacturePlaintextMXCSource() async {
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        let room = JoinedRoomProxyMock(.init(id: "!room:test"))
        let event = TimelineEventSDKMock(); event.eventIdReturnValue = "$photo"
        event.contentReturnValue = .messageLike(content: .roomEncrypted)
        room.loadOrFetchEventDetailsForReturnValue = .success(event)
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let resolved = await DiskMatrixMediaResolver(client: client).source(for: file)
        XCTAssertNil(resolved)
    }

    func testNonJoinedRoomCannotResolvePhotoSource() async {
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        client.roomForIdentifierClosure = { _ in nil }
        let resolved = await DiskMatrixMediaResolver(client: client).source(for: file)
        XCTAssertNil(resolved)
    }
}
