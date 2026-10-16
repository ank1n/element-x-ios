// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import XCTest

@MainActor
final class StalkUpdatePhotoTests: XCTestCase {
    func testEditedCopyIsBoundedAndOriginalIsUnchanged() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        }
        var edits = DiskPhotoEdits(); edits.turns = 1; edits.crop = 1; edits.caption = "Копия"
        let output = try edits.image(from: original, maxEdge: 80)
        XCTAssertEqual(output.cgImage?.width, 80)
        XCTAssertEqual(output.cgImage?.height, 80)
        XCTAssertEqual(original.cgImage?.width, 300)
        XCTAssertEqual(original.cgImage?.height, 100)
    }

    func testPhotoFeedPreservesEXIFDateAddedDateAndDownloadPermission() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdatePhotoURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        UpdatePhotoURLProtocol.handler = { request in
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(params.first(where: { $0.name == "cat" })?.value, "photos")
            XCTAssertEqual(params.first(where: { $0.name == "order" })?.value, "id")
            XCTAssertEqual(params.first(where: { $0.name == "offset" })?.value, "100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            return #"{"docs":[{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","name":"photo.jpg","mimetype":"image/jpeg","ts":2000,"addedTs":1000,"photo":{"takenAt":"2020-01-01T00:00:00Z"},"canDownload":false,"owner":"@one:test","folderId":7,"tags":["work"]}],"hasMore":true}"#
        }
        let service = DiskPhotoService(disk: DiskService(baseURL: "https://photos.invalid", accessTokenProvider: { "test" }, session: session))
        let page = try await service.photos(offset: 100, query: "работа")
        let photo = try XCTUnwrap(page.photos.first)
        XCTAssertTrue(page.more)
        XCTAssertFalse(photo.canDownload)
        XCTAssertEqual(photo.added, Date(timeIntervalSince1970: 1))
        XCTAssertLessThan(photo.taken, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(photo.folderID, 7)
        XCTAssertEqual(photo.tags, ["work"])
    }

    func testSharedPhotoKeepsAvailableCaptureAndAddedMetadata() throws {
        let data = Data(#"{"owner":"@one:test","name":"photo.jpg","mimetype":"image/jpeg","ts":2000,"addedTs":1000,"photo":{"takenAt":"2020-02-29T10:00:00"},"tags":["work"],"folderId":7,"canDownload":false}"#.utf8)
        let file = try JSONDecoder().decode(DiskSharedFile.self, from: data)
        XCTAssertEqual(file.addedTs, 1000)
        XCTAssertEqual(file.photo?.takenAt, "2020-02-29T10:00:00")
        XCTAssertEqual(file.tags, ["work"])
        XCTAssertEqual(file.folderId, 7)
        XCTAssertFalse(file.canDownload)
    }

    func testTimezoneFreeEXIFRemainsCaptureDayInsteadOfUploadDay() {
        let photo = DiskPhoto(reference: .init(source: "disk", blobId: "one"), name: "photo.jpg", mimetype: "image/jpeg", added: Date(), exif: .init(takenAt: "2020-02-29T10:00:00"), starred: false, canDownload: true)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(day.string(from: photo.taken), "2020-02-29")
    }

    func testAlbumReferencesAndRolesDoNotGrantOriginalWrite() {
        let ref = DiskPhotoReference(source: "matrix", roomId: "!room:test", eventId: "$event")
        XCTAssertEqual(ref.json["source"] as? String, "matrix")
        XCTAssertEqual(ref.json["roomId"] as? String, "!room:test")
        XCTAssertNil(ref.json["blobId"])
        let read = DiskPhotoAlbum(id: 1, name: "Album", role: "read")
        let add = DiskPhotoAlbum(id: 1, name: "Album", role: "add")
        let manage = DiskPhotoAlbum(id: 1, name: "Album", role: "manage")
        XCTAssertFalse(read.canAdd); XCTAssertFalse(read.canManage)
        XCTAssertTrue(add.canAdd); XCTAssertFalse(add.canManage)
        XCTAssertTrue(manage.canManage); XCTAssertFalse(manage.isOwner)
    }

    func testOnlyExplicitDocumentIDLabelsProduceOpenActions() {
        let id = "031577da-65ec-4bfe-8126-5500d17392ae"
        XCTAssertEqual(StalkDiskLink.labelledDocumentIDs(in: "ID документа:\n\(id)"), [id])
        XCTAssertTrue(StalkDiskLink.labelledDocumentIDs(in: "ID задачи: \(id)").isEmpty)
        XCTAssertTrue(StalkDiskLink.labelledDocumentIDs(in: id).isEmpty)
    }
}

private final class UpdatePhotoURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> String)?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
