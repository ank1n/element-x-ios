import Combine

// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import UIKit
import XCTest

@MainActor
final class DiskPhotoParityTests: XCTestCase {
    private let folders: [DiskPhotoFolder] = [
        .init(id: 1, name: "Проекты"),
        .init(id: 2, name: "Сайт", parentId: 1),
        .init(id: 3, name: "Черновики", parentId: 2),
        .init(id: 4, name: "Другие")
    ]

    func testSelectedFolderIncludesDescendantsAndExclusionWinsRecursively() {
        let criteria = DiskPhotoFilterConditions(folder: 1, excludedFolders: [2])
        XCTAssertTrue(criteria.matchesFolder(1, folders: folders))
        XCTAssertFalse(criteria.matchesFolder(2, folders: folders))
        XCTAssertFalse(criteria.matchesFolder(3, folders: folders))
        XCTAssertFalse(criteria.matchesFolder(4, folders: folders))
        XCTAssertFalse(criteria.matchesFolder(nil, folders: folders))
        let all = DiskPhotoFilterConditions(folder: 0, excludedFolders: [2])
        XCTAssertTrue(all.matchesFolder(nil, folders: folders))
        XCTAssertTrue(all.matchesFolder(4, folders: folders))
        XCTAssertFalse(all.matchesFolder(3, folders: folders))
        XCTAssertFalse(DiskPhotoFilterConditions(folder: 1, excludedFolders: [1]).matchesFolder(1, folders: folders))
    }

    func testFolderTreeHandlesCyclesAndUnknownRootsWithoutDroppingExactMatch() {
        let cyclic: [DiskPhotoFolder] = [.init(id: 8, name: "A", parentId: 9), .init(id: 9, name: "B", parentId: 8)]
        XCTAssertEqual(DiskPhotoFolder.descendants(of: [8], in: cyclic), [8, 9])
        XCTAssertEqual(cyclic[0].path(in: cyclic), "B / A")
        XCTAssertTrue(DiskPhotoFilterConditions(folder: 99).matchesFolder(99, folders: folders))
        XCTAssertFalse(DiskPhotoFilterConditions(excludedFolders: [99]).matchesFolder(99, folders: folders))
        XCTAssertEqual(folders[2].path(in: folders), "Проекты / Сайт / Черновики")
    }

    func testSystemSuggestionsUseNumericIDsAndKeepEvidenceWithoutConfirmingThem() throws {
        let data = Data(#"{"item":{"source":"disk","blobId":"one"},"systems":[7],"suggestions":[{"id":9,"evidence":"OCR: example.org"}],"categorySuggestions":[{"id":"errors","evidence":"ошибка"}],"organized":false}"#.utf8)
        let assignment = try JSONDecoder().decode(DiskPhotoAssignment.self, from: data)
        XCTAssertTrue(assignment.includes(system: 7))
        XCTAssertTrue(assignment.includes(system: 9))
        XCTAssertFalse(assignment.includes(system: 1))
        XCTAssertEqual(assignment.systems, [7])
        XCTAssertEqual(assignment.suggestions?.first?.evidence, "OCR: example.org")
        XCTAssertEqual(assignment.categorySuggestions?.first?.id, "errors")
        let legacy = try JSONDecoder().decode(DiskPhotoAssignment.self, from: Data(#"{"item":{"source":"disk","blobId":"one"},"systems":[]}"#.utf8))
        XCTAssertNil(legacy.suggestions)
    }

    func testFilterUpdatePreservesIDAndPresetKindAndLegacyDefault() async throws {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        var bodies: [[String: Any]] = []
        DiskPhotoParityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/files/photo-filters")
            XCTAssertEqual(request.httpMethod, "POST")
            try bodies.append(Self.body(request))
            return "{}"
        }
        let criteria = DiskPhotoFilterConditions(query: "OCR", folder: 1, excludedFolders: [2], dateBasis: "taken")
        try await service.saveFilter(name: "Preset", criteria: criteria, id: 42, album: false)
        try await service.saveFilter(name: "Album", criteria: criteria, id: 43, album: true)
        try await service.saveFilter(name: "Legacy", criteria: .init())
        XCTAssertEqual(bodies[0]["id"] as? Int, 42)
        XCTAssertEqual(bodies[0]["album"] as? Bool, false)
        XCTAssertEqual((bodies[0]["criteria"] as? [String: Any])?["excludedFolders"] as? [Int], [2])
        XCTAssertEqual(bodies[1]["id"] as? Int, 43)
        XCTAssertEqual(bodies[1]["album"] as? Bool, true)
        XCTAssertNil(bodies[2]["id"])
        XCTAssertEqual(bodies[2]["album"] as? Bool, true)
        XCTAssertEqual((bodies[2]["criteria"] as? [String: Any])?["dateBasis"] as? String, "taken")
    }

    func testSystemReplacementRemovalAndBatchConfirmationUseExactContract() async throws {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        var bodies: [[String: Any]] = []
        DiskPhotoParityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/files/photo-systems")
            try bodies.append(Self.body(request)); return "{}"
        }
        let matrix = DiskPhotoReference(source: "matrix", roomId: "!room:test", eventId: "$event")
        try await service.assignSystems([matrix], systems: [7, 9], mode: "set")
        try await service.assignSystems([matrix], systems: [], mode: "set")
        let batch = (0..<205).map { DiskPhotoReference(source: "disk", blobId: String($0)) }
        try await service.assignSystems(batch, systems: [9], mode: "add")
        try await service.assignSystems([matrix], systems: [9], mode: "reject")
        XCTAssertEqual(bodies.count, 6)
        XCTAssertEqual(bodies[0]["systems"] as? [Int], [7, 9])
        XCTAssertEqual(bodies[1]["systems"] as? [Int], [])
        XCTAssertEqual(bodies[1]["mode"] as? String, "set")
        XCTAssertEqual((bodies[2]["items"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual((bodies[3]["items"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual((bodies[4]["items"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(bodies[5]["mode"] as? String, "reject")
        let item = try XCTUnwrap((bodies[0]["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["source", "roomId", "eventId"])
        XCTAssertEqual(item["eventId"] as? String, "$event")
    }

    func testPhotoFeedPreservesServerSnippetAndFolderTreeMetadata() async throws {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        DiskPhotoParityURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("folders") == true {
                return #"{"folders":[{"id":3,"name":"Дочерняя","parentId":2,"kind":"album","updatedAt":3000}]}"#
            }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "ошибка")
            return #"{"docs":[{"blobId":"one","name":"screen.png","ts":2000,"snippet":"Текст: ошибка <script>","snippetMatch":"ошибка","canDownload":false}],"hasMore":false}"#
        }
        let page = try await service.photos(offset: 0, query: "ошибка")
        let photo = try XCTUnwrap(page.photos.first)
        XCTAssertEqual(photo.snippet, "Текст: ошибка <script>")
        XCTAssertEqual(photo.snippetMatch, "ошибка")
        XCTAssertFalse(photo.canDownload)
        let tree = try await service.folders()
        XCTAssertEqual(tree.first?.parentId, 2)
        XCTAssertEqual(tree.first?.kind, "album")
    }

    func testInvalidCriteriaNeverIssueSaveRequest() async {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        DiskPhotoParityURLProtocol.handler = { _ in XCTFail("Invalid criteria must not be sent"); return "{}" }
        do { try await service.saveFilter(name: "Bad", criteria: .init(excludedFolders: [0])); XCTFail("Expected validation failure") }
        catch { }
    }

    func testGalleryLoadsSuggestionsRecursiveFiltersMonthGroupsAndAlbumOrdering() async {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        DiskPhotoParityURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/files/folders": return #"{"folders":[{"id":1,"name":"Root"},{"id":2,"name":"Child","parentId":1}]}"#
            case "/api/files/photo-albums": return #"{"albums":[{"id":1,"name":"Alpha","updatedAt":100},{"id":2,"name":"Beta","updatedAt":200}]}"#
            case "/api/files/photo-filters": return #"{"filters":[]}"#
            case "/api/files/photo-systems":
                if request.httpMethod == "GET" { return #"{"systems":[{"id":7,"name":"System","aliases":[]}],"initialized":true}"# }
                return #"{"files":[{"item":{"source":"disk","blobId":"one"},"systems":[],"suggestions":[{"id":7,"evidence":"OCR evidence"}]}]}"#
            case "/api/files/disk-docs":
                let scope = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
                if scope == "starred" { return #"{"docs":[],"hasMore":false}"# }
                return #"{"docs":[{"blobId":"one","name":"a.jpg","folderId":2,"ts":1,"photo":{"takenAt":"2026-09-15T12:00:00Z"}},{"blobId":"two","name":"b.jpg","folderId":1,"ts":2,"photo":{"takenAt":"2026-10-15T12:00:00Z"}}],"hasMore":false}"#
            case "/api/files", "/api/files/shared-with-me": return #"{"files":[]}"#
            default: XCTFail("Unexpected endpoint"); return "{}"
            }
        }
        let model = DiskPhotosViewModel(service: service)
        let loaded = expectation(description: "Photo catalog loaded")
        let subscription = model.$complete.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel(); model.stop() }
        model.load()
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.monthGroups.count, 2)
        XCTAssertEqual(model.monthGroups.first?.photos.first?.id, "disk:two")
        XCTAssertEqual(model.visibleAlbums.map(\.id), [2, 1])
        model.albumSort = "name"
        XCTAssertEqual(model.visibleAlbums.map(\.id), [1, 2])
        model.albumQuery = "BETA"
        XCTAssertEqual(model.visibleAlbums.map(\.id), [2])
        model.criteria.folder = 1
        XCTAssertEqual(model.displayed.count, 2)
        model.choose("system:7")
        XCTAssertEqual(model.displayed.map(\.id), ["disk:one"])
        XCTAssertEqual(model.suggestedPhotos.map(\.id), ["disk:one"])
        model.criteria.excludedFolders = [2]
        XCTAssertTrue(model.displayed.isEmpty)
        model.choose("all"); model.criteria.excludedFolders = []
        model.criteria.dateBasis = "added"
        XCTAssertEqual(model.monthGroups.count, 1)
    }

    func testSystemAliasUpdateKeepsExistingIDAndWebsiteAliases() async throws {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        DiskPhotoParityURLProtocol.handler = { request in
            let body = try Self.body(request)
            XCTAssertEqual(body["action"] as? String, "save")
            XCTAssertEqual(body["id"] as? Int, 7)
            XCTAssertEqual(body["aliases"] as? [String], ["Example", "example.org"])
            return "{}"
        }
        try await service.systemChange(action: "save", extra: ["id": 7, "name": "Renamed", "aliases": ["Example", "example.org"]])
    }

    func testEncryptedMatrixImageUsesOnlyResolvedSourceForPreviewAndThumbnail() async throws {
        let file = try matrixFile(encrypted: true)
        // Stand-in for the opaque source supplied by the SDK resolver; its URL differs from the index.
        let resolved = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/resolved")), mimeType: "image/png")
        let provider = MediaProviderMock()
        let image = UIImage()
        var resolutions = 0
        provider.loadImageFromSourceSizeClosure = { source, _ in
            XCTAssertEqual(source.url, resolved.url)
            XCTAssertNotEqual(source.url.absoluteString, file.mxcURL)
            return .success(image)
        }
        let resolver: (DiskFile) async -> MediaSourceProxy? = { received in
            XCTAssertEqual(received.eventID, file.eventID)
            XCTAssertEqual(received.roomID, file.roomID)
            resolutions += 1
            return resolved
        }
        let full = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: resolver)
        XCTAssertTrue(full === image)
        let thumb = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: resolver, size: CGSize(width: 160, height: 160))
        XCTAssertTrue(thumb === image)
        XCTAssertEqual(resolutions, 2)
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 2)
        XCTAssertEqual(provider.loadImageFromSourceSizeReceivedArguments?.size, CGSize(width: 160, height: 160))
    }

    func testEncryptedMatrixUnavailableKeysNeverUseRawURLAndCanBeRetried() async throws {
        let file = try matrixFile(encrypted: true)
        let provider = MediaProviderMock()
        let image = UIImage()
        provider.loadImageFromSourceSizeReturnValue = .success(image)
        do {
            _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: nil)
            XCTFail("Encrypted index URL must not be used without an SDK source")
        } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
        do {
            _ = try await DiskPhotoMatrixMedia.original(for: file, mediaProvider: provider, resolveMatrixSource: { _ in nil })
            XCTFail("Missing keys must not fetch the original index URL")
        } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 0)
        XCTAssertEqual(provider.loadFileFromSourceFilenameCallsCount, 0)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/available-after-retry")), mimeType: file.mimetype)
        let retried = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source })
        XCTAssertTrue(retried === image)
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 1)
    }

    func testMatrixOriginalReturnsExactSDKHandleWithOriginalFilename() async throws {
        let file = try matrixFile(encrypted: true)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/resolved")), mimeType: file.mimetype)
        let provider = MediaProviderMock()
        // No file is created. Identity verifies that the gallery doesn't wrap or copy the SDK handle.
        let handle = MediaFileHandleProxy.unmanaged(url: URL(fileURLWithPath: "/tmp/disk-photo-sdk-handle-test.png"))
        provider.loadFileFromSourceFilenameClosure = { received, filename in
            XCTAssertEqual(received.url, source.url)
            XCTAssertEqual(filename, file.filename)
            return .success(handle)
        }
        let result = try await DiskPhotoMatrixMedia.original(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source })
        XCTAssertTrue(result === handle)
        XCTAssertEqual(provider.loadFileFromSourceFilenameCallsCount, 1)
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 0)
    }

    func testMatrixProviderFailureDoesNotFallbackToIndexURL() async throws {
        let file = try matrixFile(encrypted: true)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/resolved")), mimeType: file.mimetype)
        let provider = MediaProviderMock()
        provider.loadImageFromSourceSizeReturnValue = .failure(.failedRetrievingImage)
        do {
            _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source })
            XCTFail("Expected the provider failure")
        } catch { XCTAssertTrue(error is MediaProviderError) }
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 1)
        XCTAssertEqual(provider.loadImageFromSourceSizeReceivedArguments?.source.url, source.url)
    }

    func testMatrixCancellationAfterResolutionDoesNotStartMediaDownload() async throws {
        let file = try matrixFile(encrypted: true)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/resolved")), mimeType: file.mimetype)
        let provider = MediaProviderMock()
        let task = Task {
            try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return source
            })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 0)
    }

    func testUnencryptedMatrixCallerWithoutResolverNeverFetchesIndexMXC() async throws {
        let file = try matrixFile(encrypted: false)
        let provider = MediaProviderMock()
        do {
            _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: nil)
            XCTFail("Even unencrypted previews require verified current event access")
        } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 0)
    }

    func testMatrixEditorCopiesOriginalIntoOwnedDirectoryWithoutChangingSDKFile() async throws {
        let file = try matrixFile(encrypted: true)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/editor-source")), mimeType: file.mimetype)
        let provider = MediaProviderMock()
        let sdkDirectory = URL.temporaryDirectory.appending(path: "sdk-handle-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sdkDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sdkDirectory) }
        let sdkURL = sdkDirectory.appending(path: "managed.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try bytes.write(to: sdkURL)
        let handle = MediaFileHandleProxy.unmanaged(url: sdkURL)
        provider.loadFileFromSourceFilenameClosure = { received, filename in
            XCTAssertEqual(received.url, source.url)
            XCTAssertEqual(filename, file.filename)
            return .success(handle)
        }
        let copy = try await DiskPhotoMatrixMedia.editableOriginal(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source })
        let directory = copy.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNotEqual(copy, sdkURL)
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("disk-original-"))
        XCTAssertNotNil(UUID(uuidString: String(directory.lastPathComponent.dropFirst("disk-original-".count))))
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL, URL.temporaryDirectory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try Data(contentsOf: sdkURL), bytes)
        try Data([1, 2, 3]).write(to: copy)
        XCTAssertEqual(try Data(contentsOf: sdkURL), bytes)
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sdkURL.path))
    }

    func testMatrixEditorVerifierResolvesAgainAndRejectsRevokedAccess() async throws {
        let file = try matrixFile(encrypted: true)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/editor-source")), mimeType: file.mimetype)
        var calls = 0
        var allowed = true
        let resolver: (DiskFile) async -> MediaSourceProxy? = { received in
            XCTAssertEqual(received.roomID, file.roomID)
            XCTAssertEqual(received.eventID, file.eventID)
            calls += 1
            return allowed ? source : nil
        }
        let first = await DiskPhotoMatrixMedia.verifySourceAccess(for: file, resolveMatrixSource: resolver)
        XCTAssertTrue(first)
        allowed = false
        let revoked = await DiskPhotoMatrixMedia.verifySourceAccess(for: file, resolveMatrixSource: resolver)
        XCTAssertFalse(revoked)
        XCTAssertEqual(calls, 2)
        let missing = await DiskPhotoMatrixMedia.verifySourceAccess(for: file, resolveMatrixSource: nil)
        XCTAssertFalse(missing)
    }

    func testMatrixEditorNeverUsesUnencryptedRawURLWhenAccessResolutionFails() async throws {
        let file = try matrixFile(encrypted: false)
        let provider = MediaProviderMock()
        do {
            _ = try await DiskPhotoMatrixMedia.editableOriginal(for: file, mediaProvider: provider, resolveMatrixSource: { _ in nil })
            XCTFail("Editor must resolve current room/event access")
        } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
        XCTAssertEqual(provider.loadFileFromSourceFilenameCallsCount, 0)
    }

    func testCopyEditorAllowsOnlyWebSupportedImageMIMEs() {
        for mime in ["image/jpeg", "image/png", "image/webp"] {
            XCTAssertTrue(DiskPhotoMatrixMedia.supportsEditing(mimetype: mime))
        }
        for mime in ["image/heic", "image/gif", "image/svg+xml", "video/mp4", "application/octet-stream", "image/jpeg; charset=utf-8"] {
            XCTAssertFalse(DiskPhotoMatrixMedia.supportsEditing(mimetype: mime))
        }
    }

    func testMatrixGalleryRequestsBoundedImagesAndKeepsThumbnailSizeSeparate() async throws {
        let file = try matrixFile(encrypted: true)
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/bounded-gallery")), mimeType: file.mimetype)
        let provider = MediaProviderMock()
        var sizes: [CGSize?] = []
        provider.loadImageFromSourceSizeClosure = { _, size in sizes.append(size); return .success(UIImage()) }
        _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source })
        _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source }, size: CGSize(width: 160, height: 160))
        _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in source }, size: CGSize(width: 8000, height: 4000))
        XCTAssertEqual(sizes[0], CGSize(width: 2560, height: 2560))
        XCTAssertEqual(sizes[1], CGSize(width: 160, height: 160))
        XCTAssertEqual(sizes[2], CGSize(width: 2560, height: 1280))
        XCTAssertEqual(provider.loadFileFromSourceFilenameCallsCount, 0)
    }

    func testSlideshowWaitsForEachSuccessfulLoadAndStopsOnFailure() {
        var playback = DiskPhotoSlideshow()
        playback.playing = true
        playback.beginLoading("one")
        XCTAssertFalse(playback.canAdvance("one"), "A slow load must not start its display timer")
        playback.loaded("one")
        XCTAssertTrue(playback.canAdvance("one"))
        playback.beginLoading("two")
        XCTAssertFalse(playback.canAdvance("one"))
        XCTAssertFalse(playback.canAdvance("two"))
        playback.loaded("one")
        XCTAssertFalse(playback.canAdvance("two"), "A stale completion must not unlock the next slide")
        playback.failed("one")
        XCTAssertTrue(playback.playing, "A stale failure must not stop a different photo")
        playback.failed("two")
        XCTAssertFalse(playback.playing)
        XCTAssertFalse(playback.canAdvance("two"))
        playback.beginLoading("two")
        playback.loaded("two")
        XCTAssertFalse(playback.canAdvance("two"), "Retry must not silently restart a stopped slideshow")
        playback.playing = true
        XCTAssertTrue(playback.canAdvance("two"))
    }

    func testEditingActivePresetReappliesSavedQueryAndCriteriaToServerSearch() async throws {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        let updated = DiskPhotoSavedFilter(id: 42, name: "Updated", criteria: .init(query: "new OCR", folder: 2, dateBasis: "added"), album: false)
        DiskPhotoParityURLProtocol.handler = { request in
            if request.url?.path == "/api/files/photo-filters", request.httpMethod == "POST" {
                let body = try Self.body(request)
                XCTAssertEqual(body["id"] as? Int, 42)
                XCTAssertEqual(body["album"] as? Bool, false)
                return "{}"
            }
            if request.url?.path == "/api/files/photo-filters" {
                return try String(decoding: JSONEncoder().encode(["filters": [updated]]), as: UTF8.self)
            }
            if request.url?.path == "/api/files/disk-docs" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
                XCTAssertEqual(query, "new OCR")
            }
            return Self.emptyPhotoCatalogResponse(request)
        }
        let model = DiskPhotosViewModel(service: service)
        model.activeFilterID = 42; model.query = "old"; model.criteria = .init(folder: 99, dateBasis: "taken")
        let loaded = expectation(description: "Updated preset search completed")
        let subscription = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel(); model.stop() }
        try await service.saveFilter(name: updated.name, criteria: updated.criteria, id: updated.id, album: false)
        model.savedFilterDidChange(updated)
        XCTAssertEqual(model.query, "new OCR")
        XCTAssertEqual(model.criteria, updated.criteria)
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertFalse(model.complete)
        XCTAssertNotNil(model.error, "The accepted empty catalogue boundary remains a partial-listing warning")
        XCTAssertEqual(model.activeFilterID, 42)
        XCTAssertEqual(model.savedFilters.first?.criteria, updated.criteria)
    }

    func testEditingInactivePresetPreservesCurrentSearchConditions() async {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        DiskPhotoParityURLProtocol.handler = { Self.emptyPhotoCatalogResponse($0) }
        let model = DiskPhotosViewModel(service: service)
        model.activeFilterID = 7; model.query = "current"; model.criteria = .init(folder: 9)
        let loaded = expectation(description: "Inactive preset reload completed")
        let subscription = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel(); model.stop() }
        model.savedFilterDidChange(.init(id: 42, name: "Other", criteria: .init(query: "other", folder: 2), album: true))
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertFalse(model.complete)
        XCTAssertNotNil(model.error, "The accepted empty catalogue boundary remains a partial-listing warning")
        XCTAssertEqual(model.query, "current")
        XCTAssertEqual(model.criteria.folder, 9)
        XCTAssertEqual(model.activeFilterID, 7)
    }

    func testUnfiledExcludesAlbumFolderDescendantsButKeepsOrdinaryAndTrashedAlbumFolders() async {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        DiskPhotoParityURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/files/folders":
                return #"{"folders":[{"id":1,"name":"Album","kind":"album"},{"id":2,"name":"Child","parentId":1},{"id":3,"name":"Grandchild","parentId":2},{"id":4,"name":"Ordinary"},{"id":5,"name":"Trashed album","kind":"album","trashed":true},{"id":6,"name":"Child of trashed","parentId":5}]}"#
            case "/api/files/disk-docs":
                let scope = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
                if scope == "starred" { return #"{"docs":[],"hasMore":false}"# }
                let docs: [[String: Any]] = (1...7).map { id in
                    var doc: [String: Any] = ["blobId": String(id), "name": "photo.jpg", "ts": id]
                    if id < 7 { doc["folderId"] = id }
                    return doc
                }
                return try String(decoding: JSONSerialization.data(withJSONObject: ["docs": docs, "hasMore": false]), as: UTF8.self)
            case "/api/files/photo-systems" where request.httpMethod == "POST":
                let files: [[String: Any]] = (1...7).map { ["item": ["source": "disk", "blobId": String($0)], "systems": [], "organized": false] }
                return try String(decoding: JSONSerialization.data(withJSONObject: ["files": files]), as: UTF8.self)
            default: return Self.emptyPhotoCatalogResponse(request)
            }
        }
        let model = DiskPhotosViewModel(service: service)
        let loaded = expectation(description: "Unfiled catalog completed")
        let subscription = model.$complete.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel(); model.stop() }
        model.load()
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertNil(model.error)
        model.choose("unfiled")
        XCTAssertEqual(Set(model.displayed.map(\.id)), ["disk:4", "disk:5", "disk:6", "disk:7"])
    }

    private nonisolated static func emptyPhotoCatalogResponse(_ request: URLRequest) -> String {
        switch request.url?.path {
        case "/api/search": return #"{"total":0,"results":[]}"#
        case "/api/files/folders": return #"{"folders":[]}"#
        case "/api/files/photo-albums": return #"{"albums":[]}"#
        case "/api/files/photo-filters": return #"{"filters":[]}"#
        case "/api/files/photo-systems": return #"{"systems":[],"initialized":true}"#
        case "/api/files/disk-docs": return #"{"docs":[],"hasMore":false}"#
        case "/api/files", "/api/files/shared-with-me": return #"{"files":[]}"#
        default: XCTFail("Unexpected endpoint"); return "{}"
        }
    }

    func testRejectedMatrixPreviewNeverRendersAndRetryCanResolveSDKSource() async throws {
        let file = try matrixFile(encrypted: false)
        let provider = MediaProviderMock()
        provider.loadImageFromSourceSizeReturnValue = .success(UIImage())
        var sourceAvailable = false
        var resolutions = 0
        let source = try MediaSourceProxy(url: XCTUnwrap(URL(string: "mxc://sdk.invalid/confirmed")), mimeType: file.mimetype)
        let resolver: (DiskFile) async -> MediaSourceProxy? = { _ in
            resolutions += 1
            return sourceAvailable ? source : nil
        }
        do {
            _ = try await DiskPhotoMatrixMedia.preview(for: file, mediaProvider: provider, resolveMatrixSource: resolver)
            XCTFail("A failed current SDK resolution must not render the index MXC")
        } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
        XCTAssertEqual(resolutions, 1, "Preflight and preview must use the same resolution attempt")
        XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 0)
        let denied = await DiskPhotoMatrixMedia.verifySourceAccess(for: file, resolveMatrixSource: resolver)
        XCTAssertFalse(denied)
        sourceAvailable = true
        let retried = try await DiskPhotoMatrixMedia.preview(for: file, mediaProvider: provider, resolveMatrixSource: resolver)
        XCTAssertTrue(retried.sdkSourceAvailable)
        XCTAssertEqual(provider.loadImageFromSourceSizeReceivedArguments?.source.url, source.url)
        XCTAssertEqual(provider.loadImageFromSourceSizeReceivedArguments?.size, CGSize(width: 2560, height: 2560))
        sourceAvailable = false
        let revokedBeforeSave = await DiskPhotoMatrixMedia.verifySourceAccess(for: file, resolveMatrixSource: resolver)
        XCTAssertFalse(revokedBeforeSave, "A prior preview cannot replace a fresh SDK access check")
    }

    func testRejectedMatrixSourcesNeverFetchPreviewThumbnailOrOriginal() async throws {
        for encrypted in [false, true] {
            let file = try matrixFile(encrypted: encrypted)
            let provider = MediaProviderMock()
            do {
                _ = try await DiskPhotoMatrixMedia.preview(for: file, mediaProvider: provider, resolveMatrixSource: { _ in nil })
                XCTFail("Preview requires an actual resolved source")
            } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
            do {
                _ = try await DiskPhotoMatrixMedia.image(for: file, mediaProvider: provider, resolveMatrixSource: { _ in nil }, size: CGSize(width: 160, height: 160))
                XCTFail("Thumbnail requires an actual resolved source")
            } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
            do {
                _ = try await DiskPhotoMatrixMedia.original(for: file, mediaProvider: provider, resolveMatrixSource: { _ in nil })
                XCTFail("Original requires an actual resolved source")
            } catch { XCTAssertTrue(error is DiskPhotoMatrixMedia.Failure) }
            XCTAssertEqual(provider.loadImageFromSourceSizeCallsCount, 0)
            XCTAssertEqual(provider.loadFileFromSourceFilenameCallsCount, 0)
        }
    }

    func testSDKResolverDiagnosticsAreBoundedAndContainNoSourceIdentifiers() async throws {
        let file = try matrixFile(encrypted: true)
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        let room = JoinedRoomProxyMock(.init(id: "!room:test"))
        let event = TimelineEventSDKMock(); event.eventIdReturnValue = "$photo"
        event.contentReturnValue = .messageLike(content: .roomEncrypted)
        room.loadOrFetchEventDetailsForReturnValue = .success(event)
        client.roomForIdentifierClosure = { _ in .joined(room) }
        var diagnostics: [String] = []
        let resolver = DiskMatrixMediaResolver(client: client, diagnostic: { diagnostics.append($0) })
        for _ in 0..<8 {
            let source = await resolver.source(for: file)
            XCTAssertNil(source)
        }
        XCTAssertEqual(diagnostics, Array(repeating: "room=joined event=matched content=encrypted_unresolved", count: 3))
        room.loadOrFetchEventDetailsForReturnValue = .failure(.eventNotFound)
        _ = await resolver.source(for: file)
        XCTAssertEqual(diagnostics.last, "room=joined event=not_found content=unavailable")
        client.roomForIdentifierClosure = { _ in .left }
        _ = await resolver.source(for: file)
        XCTAssertEqual(diagnostics.last, "room=left event=not_requested content=unavailable")
        XCTAssertTrue(diagnostics.allSatisfy { !$0.contains(file.mxcURL) && !$0.contains(file.roomID!) && !$0.contains(file.eventID!) })
    }

    func testPhotoLoadKeepsWarningPagesFiltersSharedSearchAndPreservesBlobACL() async {
        let (service, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        var rawPages = 0
        var resolvedAssignments = false
        DiskPhotoParityURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/search":
                // A valid empty index still proceeds to the authoritative catalogue.
                return #"{"total":0,"results":[]}"#
            case "/api/files":
                rawPages += 1
                let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
                if before == nil {
                    return #"{"files":[{"eventId":"$one","roomId":"!room:test","filename":"needle-one.png","mimetype":"image/png","category":"images","ts":3000},{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","filename":"needle-native.png","mimetype":"image/png","category":"images","canDownload":false,"readonly":true,"ts":2900},{"eventId":123}],"nextBefore":"2000","nextBeforeId":"$boundary"}"#
                }
                if before == "2000" {
                    return #"{"files":[{"eventId":"$two","roomId":"!room:test","filename":"needle-two.png","mimetype":"image/png","category":"images","ts":1000}],"nextBefore":null}"#
                }
                return #"{"files":[],"nextBefore":null}"#
            case "/api/files/shared-with-me":
                return #"{"files":[{"blobId":"content","name":"unrelated-name.png","mimetype":"image/png","contentHit":true},{"blobId":"name","name":"NEEDLE.png","mimetype":"image/png"},{"blobId":"tag","name":"tag.png","mimetype":"image/png","tags":["needle"]},{"blobId":"path","name":"path.png","mimetype":"image/png","fromPath":"needle/project"},{"blobId":"unrelated","name":"other.png","mimetype":"image/png"},{"blobId":"keys","name":"needle-keys.png","mimetype":"image/png","canDownload":true,"needsKeys":true}]}"#
            case "/api/files/photo-systems" where request.httpMethod == "POST":
                resolvedAssignments = true
                return #"{"files":[]}"#
            default: return Self.emptyPhotoCatalogResponse(request)
            }
        }
        let model = DiskPhotosViewModel(service: service)
        model.query = "needle"
        let finished = expectation(description: "Partial photo load completed")
        let subscription = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        defer { subscription.cancel(); model.stop() }
        model.load()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(rawPages, 4, "Initial catalogue preview is revisited after the index; warnings must not stop continuation pages")
        XCTAssertTrue(resolvedAssignments, "A partial source must not prevent remaining metadata loads")
        XCTAssertFalse(model.complete)
        XCTAssertNotNil(model.error)
        let ids = Set(model.photos.map(\.id))
        XCTAssertTrue(ids.contains("matrix:!room:test|$one"))
        XCTAssertTrue(ids.contains("matrix:!room:test|$two"))
        for id in ["content", "name", "tag", "path", "keys"] {
            XCTAssertTrue(ids.contains("disk:" + id))
        }
        XCTAssertFalse(ids.contains("disk:unrelated"))
        XCTAssertEqual(model.photos.first { $0.id == "disk:031577da-65ec-4bfe-8126-5500d17392ae" }?.canDownload, false)
        XCTAssertEqual(model.photos.first { $0.id == "disk:keys" }?.canDownload, false)
    }

    func testMatrixRepeatedCursorAndPageBudgetKeepPhotosButMarkCatalogueIncomplete() async {
        for repeatsCursor in [true, false] {
            let (service, session) = makeService()
            var requests = 0
            DiskPhotoParityURLProtocol.handler = { request in
                if request.url?.path == "/api/files" {
                    requests += 1
                    let cursor = repeatsCursor ? "1" : String(1000 - requests)
                    return "{\"files\":[{\"eventId\":\"$photo\(requests)\",\"roomId\":\"!room:test\",\"filename\":\"photo.png\",\"mimetype\":\"image/png\",\"category\":\"images\"}],\"nextBefore\":\"\(cursor)\",\"nextBeforeId\":\"$tail\"}"
                }
                if request.url?.path == "/api/files/photo-systems", request.httpMethod == "POST" { return #"{"files":[]}"# }
                return Self.emptyPhotoCatalogResponse(request)
            }
            let model = DiskPhotosViewModel(service: service, matrixPageLimit: repeatsCursor ? 500 : 2)
            let finished = expectation(description: repeatsCursor ? "Repeated cursor stopped" : "Page budget stopped")
            let subscription = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
            model.load()
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(model.photos.count, 2)
            XCTAssertFalse(model.complete)
            XCTAssertNotNil(model.error)
            subscription.cancel(); model.stop(); session.invalidateAndCancel()
        }
        DiskPhotoParityURLProtocol.handler = nil
    }

    func testVerifiedPlainEventFallbackIgnoresMalformedOptionalThumbnail() throws {
        let raw = Data(#"{"event_id":"$photo","room_id":"!room:test","type":"m.room.message","content":{"msgtype":"m.image","body":"photo.png","url":"mxc://test/verified-original","info":{"mimetype":"image/png","w":0,"h":-1,"thumbnail_url":"https://invalid.example/thumbnail","thumbnail_info":{"w":"invalid","h":-3}}}}"#.utf8)
        let source = try XCTUnwrap(DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(raw, roomID: "!room:test", eventID: "$photo"))
        XCTAssertEqual(source.url.absoluteString, "mxc://test/verified-original")
        XCTAssertEqual(source.mimeType, "image/png")
        XCTAssertNil(DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(raw, roomID: "!other:test", eventID: "$photo"))
        XCTAssertNil(DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(raw, roomID: "!room:test", eventID: "$different"))
    }

    func testVerifiedEventFallbackRejectsEncryptedRedactedAndNonMediaSources() throws {
        let rejected = [
            #"{"type":"m.room.encrypted","content":{"url":"mxc://test/ciphertext","msgtype":"m.image"}}"#,
            #"{"type":"m.room.message","content":{"msgtype":"m.image","url":"mxc://test/ciphertext","file":{"url":"mxc://test/ciphertext"}}}"#,
            #"{"type":"m.room.message","unsigned":{"redacted_because":{}},"content":{"msgtype":"m.image","url":"mxc://test/original"}}"#,
            #"{"type":"m.room.message","state_key":"","content":{"msgtype":"m.image","url":"mxc://test/original"}}"#,
            #"{"type":"m.room.message","content":{"msgtype":"m.text","url":"mxc://test/original"}}"#,
            #"{"type":"m.room.message","content":{"msgtype":"m.image","url":"https://test/original"}}"#,
            #"{"type":"m.room.message","content":{"msgtype":"m.file","url":"mxc://test/original","info":{"mimetype":"application/pdf"}}}"#
        ]
        for raw in rejected {
            var event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            event["event_id"] = "$photo"; event["room_id"] = "!room:test"
            let data = try JSONSerialization.data(withJSONObject: event)
            XCTAssertNil(DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(data, roomID: "!room:test", eventID: "$photo"))
        }
    }

    func testSDKConversionFailureUsesAuthenticatedExactEventAndPreservesFreshMembershipChecks() async throws {
        let (_, session) = makeService()
        defer { session.invalidateAndCancel(); DiskPhotoParityURLProtocol.handler = nil }
        let file = try matrixFile(encrypted: false)
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        client.matrixAccessTokenReturnValue = "test"
        let room = JoinedRoomProxyMock(.init(id: "!room:test"))
        room.loadOrFetchEventDetailsForReturnValue = .success(DiskPhotoUnconvertibleSDKEvent(noHandle: .init()))
        var joined = true
        client.roomForIdentifierClosure = { _ in joined ? .joined(room) : .left }
        var requests = 0
        DiskPhotoParityURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "test")
            XCTAssertEqual(request.url?.path.removingPercentEncoding, "/_matrix/client/v3/rooms/!room:test/event/$photo")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            XCTAssertEqual(request.timeoutInterval, 8)
            return #"{"event_id":"$photo","room_id":"!room:test","type":"m.room.message","content":{"msgtype":"m.image","url":"mxc://test/verified-original","info":{"mimetype":"image/png","thumbnail_url":"https://broken.example/thumb"}}}"#
        }
        var diagnostics: [String] = []
        let resolver = DiskMatrixMediaResolver(client: client, session: session, diagnostic: { diagnostics.append($0) })
        let resolved = await resolver.source(for: file)
        XCTAssertEqual(resolved?.url?.absoluteString, "mxc://test/verified-original")
        XCTAssertTrue(diagnostics.contains("room=joined event=matched content=decode_failed"))
        XCTAssertTrue(diagnostics.contains("raw_fallback=verified_plain_image"))
        XCTAssertEqual(requests, 1)
        // Current membership is checked again after fetching JSON, before returning a usable source.
        DiskPhotoParityURLProtocol.handler = { _ in
            requests += 1; joined = false
            return #"{"event_id":"$photo","room_id":"!room:test","type":"m.room.message","content":{"msgtype":"m.image","url":"mxc://test/verified-original"}}"#
        }
        let revoked = await resolver.source(for: file)
        XCTAssertNil(revoked)
        XCTAssertTrue(diagnostics.contains("raw_fallback=room_no_longer_joined"))
        XCTAssertEqual(requests, 2)
        joined = true
        let encrypted = try matrixFile(encrypted: true)
        let protected = await resolver.source(for: encrypted)
        XCTAssertNil(protected)
        XCTAssertEqual(requests, 2, "Undecoded encrypted events must never start the plaintext fallback")
    }

    func testVerifiedEventJSONAllowsMissingContextRoomButRejectsAnExplicitDifferentRoom() throws {
        let raw = Data(#"{"event_id":"$photo","type":"m.room.message","content":{"msgtype":"m.image","url":"mxc://test/original"}}"#.utf8)
        XCTAssertNotNil(DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(raw, roomID: "!room:test", eventID: "$photo"))
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        event["room_id"] = "!different:test"
        XCTAssertNil(try DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(JSONSerialization.data(withJSONObject: event), roomID: "!room:test", eventID: "$photo"))
    }

    func testEventFallbackURLAndRedirectPolicyRejectOriginPathAndSchemeChanges() throws {
        let url = try XCTUnwrap(DiskMatrixMediaResolver.eventURL(homeserver: "https://test/base", roomID: "!room:test", eventID: "$id/with+slash"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.percentEncodedPath.hasSuffix("/event/$id%2Fwith+slash"))
        XCTAssertTrue(DiskMatrixMediaResolver.isExpectedEventURL(url, expected: url))
        for wrong in ["http://test/base/_matrix/client/v3/rooms/x/event/y", "https://other.test/event", "https://user:pass@test/event", "https://test/other"] {
            XCTAssertFalse(DiskMatrixMediaResolver.isExpectedEventURL(URL(string: wrong), expected: url))
        }
        XCTAssertNil(DiskMatrixMediaResolver.eventURL(homeserver: "file:///tmp", roomID: "!room:test", eventID: "$photo"))
        XCTAssertNil(DiskMatrixMediaResolver.eventURL(homeserver: "https://user:pass@test", roomID: "!room:test", eventID: "$photo"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url) // Deliberately never resumed.
        let redirect = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://other.test/event"]))
        var called = false
        try DiskPhotoEventNoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: XCTUnwrap(URL(string: "http://other.test/event")))) { redirected in
            called = true; XCTAssertNil(redirected)
        }
        XCTAssertTrue(called)
    }

    func testSDKFileImageWithMissingInfoPreservesAuthorizedSourceAndRejectsGenericFile() async throws {
        let file = try matrixFile(encrypted: true)
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        let room = JoinedRoomProxyMock(.init(id: "!room:test"))
        let event = TimelineEventSDKMock(); event.eventIdReturnValue = "$photo"
        let source = try MediaSource.fromUrl(url: "mxc://test/sdk-file")
        event.contentReturnValue = .messageLike(content: .roomMessage(messageType: .file(content: .init(filename: "photo.png", caption: nil, formattedCaption: nil, source: source, info: nil)), inReplyToEventId: nil))
        room.loadOrFetchEventDetailsForReturnValue = .success(event)
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let resolved = await DiskMatrixMediaResolver(client: client, diagnostic: { _ in }).source(for: file)
        XCTAssertTrue(resolved?.underlyingSource === source)
        XCTAssertNil(DiskMatrixMediaResolver.imageFileMIME(sdkMIME: nil, filename: "report.pdf", indexedMIME: "image/png"))
        XCTAssertNil(DiskMatrixMediaResolver.imageFileMIME(sdkMIME: "application/pdf", filename: "photo.png", indexedMIME: "image/png"))
    }

    func testRawEventFallbackRetries401AndRejectsWrongFinalOrigin() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiskPhotoEventURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); DiskPhotoEventURLProtocol.handler = nil }
        let file = try matrixFile(encrypted: false)
        let client = ClientProxyMock(.init(homeserver: "https://test"))
        let room = JoinedRoomProxyMock(.init(id: "!room:test"))
        room.loadOrFetchEventDetailsForReturnValue = .success(DiskPhotoUnconvertibleSDKEvent(noHandle: .init()))
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let raw = #"{"event_id":"$photo","type":"m.room.message","content":{"msgtype":"m.image","url":"mxc://test/original","info":{"thumbnail_url":"invalid"}}}"#
        var requests = 0
        DiskPhotoEventURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "test")
            return (requests == 1 ? 401 : 200, raw, request.url!)
        }
        let resolver = DiskMatrixMediaResolver(client: client, session: session, diagnostic: { _ in })
        let resolved = await resolver.source(for: file)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(requests, 2)
        DiskPhotoEventURLProtocol.handler = { _ in (200, raw, URL(string: "http://other.test/event")!) }
        let wrongOrigin = await resolver.source(for: file)
        XCTAssertNil(wrongOrigin)
        DiskPhotoEventURLProtocol.handler = { request in (403, raw, request.url!) }
        let forbidden = await resolver.source(for: file)
        XCTAssertNil(forbidden)
    }

    func testRawEventOptionalNullFieldsAreAbsentButEncryptedPayloadRemainsRejected() throws {
        let raw = Data(#"{"event_id":"$photo","type":"m.room.message","state_key":null,"content":{"msgtype":"m.image","url":"mxc://test/original","file":null,"info":{"thumbnail_url":null}}}"#.utf8)
        XCTAssertNotNil(DiskMatrixMediaResolver.sourceFromVerifiedEventJSON(raw, roomID: "!room:test", eventID: "$photo"))
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var content = try XCTUnwrap(event["content"] as? [String: Any])
        content["file"] = ["url": "mxc://test/ciphertext"]
        event["content"] = content
        let encryptedFile = try DiskMatrixMediaResolver.parseVerifiedEventJSON(JSONSerialization.data(withJSONObject: event), roomID: "!room:test", eventID: "$photo")
        guard case .failure(.encryptedFile) = encryptedFile else { return XCTFail("An encrypted-file object must remain rejected") }
        content["file"] = NSNull(); event["content"] = content; event["type"] = "m.room.encrypted"
        let encryptedEvent = try DiskMatrixMediaResolver.parseVerifiedEventJSON(JSONSerialization.data(withJSONObject: event), roomID: "!room:test", eventID: "$photo")
        guard case .failure(.encryptedEvent) = encryptedEvent else { return XCTFail("An encrypted event must remain rejected") }
    }

    func testRawEventRejectionReasonsIdentifyGuardGroupsWithoutPayloadValues() {
        let samples: [(String, DiskMatrixMediaResolver.RawEventRejection)] = [
            (#"{"event_id":"wrong","type":"m.room.message"}"#, .identityEvent),
            (#"{"event_id":"$photo","room_id":"wrong","type":"m.room.message"}"#, .identityRoom),
            (#"{"event_id":"$photo","type":"m.notice"}"#, .eventType),
            (#"{"event_id":"$photo","type":"m.room.message","content":null}"#, .contentShape),
            (#"{"event_id":"$photo","type":"m.room.message","state_key":""}"#, .contentState),
            (#"{"event_id":"$photo","type":"m.room.message","unsigned":{"redacted_because":{}}}"#, .contentRedacted),
            (#"{"event_id":"$photo","type":"m.room.message","content":{"msgtype":"m.text"}}"#, .contentMediaType),
            (#"{"event_id":"$photo","type":"m.room.message","content":{"msgtype":"m.image"}}"#, .urlMissing),
            (#"{"event_id":"$photo","type":"m.room.message","content":{"msgtype":"m.image","url":"https://test/original"}}"#, .urlInvalid),
            (#"{"event_id":"$photo","type":"m.room.message","content":{"msgtype":"m.file","url":"mxc://test/original","info":{"mimetype":"application/pdf"}}}"#, .mime)
        ]
        for (raw, expected) in samples {
            let parsed = DiskMatrixMediaResolver.parseVerifiedEventJSON(Data(raw.utf8), roomID: "!room:test", eventID: "$photo")
            guard case .failure(let reason) = parsed else { XCTFail("Expected rejection"); continue }
            XCTAssertEqual(reason, expected)
            XCTAssertTrue(reason.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }

    private func matrixFile(encrypted: Bool) throws -> DiskFile {
        try JSONDecoder().decode(DiskFile.self, from: Data("""
        {"eventId":"$photo","roomId":"!room:test","sender":"@user:test","filename":"photo.png","mimetype":"image/png","size":1,"msgtype":"m.image","category":"images","mxcUrl":"mxc://index.invalid/ciphertext","ts":1,"isEncrypted":\(encrypted)}
        """.utf8))
    }

    private func makeService() -> (DiskPhotoService, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiskPhotoParityURLProtocol.self]
        let session = URLSession(configuration: config)
        return (DiskPhotoService(disk: DiskService(baseURL: "https://photos.invalid", accessTokenProvider: { "test" }, session: session)), session)
    }

    private nonisolated static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class DiskPhotoParityURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let body = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { }
}

private final class DiskPhotoUnconvertibleSDKEvent: TimelineEvent, @unchecked Sendable {
    override func eventId() -> String {
        "$photo"
    }

    override func content() throws -> MatrixRustSDK.TimelineEventContent {
        throw DiskServiceError.http(415)
    }
}

private final class DiskPhotoEventURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, URL))?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (status, body, responseURL) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
