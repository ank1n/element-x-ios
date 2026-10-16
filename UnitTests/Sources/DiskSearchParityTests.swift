// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import XCTest

@MainActor
final class DiskSearchParityTests: XCTestCase {
    private func service() -> (DiskService, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiskSearchParityProtocol.self]
        let session = URLSession(configuration: config)
        return (DiskService(baseURL: "https://disk.invalid", accessTokenProvider: { "test" }, session: session), session)
    }

    func testServerContentMatchesRemainVisibleEvenWhenFilenameDoesNotMatch() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let recorded = DiskSearchRequests()
        DiskSearchParityProtocol.handler = { request in
            recorded.record(request)
            switch request.url!.path {
            case "/api/search": return (200, #"{"total":1,"results":[{"entity_type":"attachment","target":{"kind":"room","room_id":"!room:test","event_id":"$one"},"created_at":"1970-01-01T00:00:01Z","snippet":"\u0002needle\u0003"}]}"#, 0)
            case "/api/files": return (200, #"{"files":[{"eventId":"$one","roomId":"!room:test","filename":"photo.png","ts":1000}],"nextBefore":null}"#, 0)
            case "/api/files/disk-docs": return (200, #"{"docs":[{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","name":"report.pdf","ts":900}],"hasMore":false}"#, 0)
            case "/api/files/shared-with-me": return (200, #"{"files":[{"blobId":"00000000-0000-0000-0000-000000000002","name":"table.xlsx","owner":"@other:test","contentHit":true,"ts":800},{"blobId":"00000000-0000-0000-0000-000000000003","name":"unrelated.xlsx","owner":"@other:test","ts":700}]}"#, 0)
            case "/api/files/stats": return (200, #"{"all":3,"documents":2,"images":1,"media":0}"#, 0)
            default: return (200, #"{"folders":[]}"#, 0)
            }
        }
        let model = DiskScreenViewModel(service: service, mediaProvider: nil)
        model.searchQuery = "needle & OCR"
        await model.searchNow()
        XCTAssertEqual(model.displayedEntries.count, 3)
        for path in ["/api/search", "/api/files/disk-docs", "/api/files/shared-with-me"] {
            let request = try XCTUnwrap(recorded.values.first { $0.url?.path == path })
            XCTAssertEqual(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "needle & OCR")
        }
        let raw = try XCTUnwrap(recorded.values.first { $0.url?.path == "/api/files" })
        XCTAssertNil(try URLComponents(url: XCTUnwrap(raw.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" })
        XCTAssertEqual(model.displayedSharedFiles.map(\.name), ["table.xlsx"])
        model.showingShared = true
        await model.loadShared()
        XCTAssertEqual(model.displayedEntries.count, 1, "The Shared tab must also exclude unrelated rows")
    }

    func testNativeDocumentsContinuePastEmptyACLFilteredPage() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let recorded = DiskSearchRequests()
        DiskSearchParityProtocol.handler = { request in
            recorded.record(request)
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value
            if offset == "0" { return (200, #"{"docs":[],"hasMore":true}"#, 0) }
            return (200, #"{"docs":[{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","name":"match.pdf","folderId":7}],"hasMore":false}"#, 0)
        }
        let files = try await service.fetchDiskDocs(query: "contract")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.folderID, "7")
        XCTAssertEqual(recorded.values.count, 2)
        XCTAssertTrue(recorded.values.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value == "shelf" })
    }

    func testLateOldSearchDoesNotReplaceNewResults() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            switch request.url!.path {
            case "/api/search":
                return (200, "{\"total\":1,\"results\":[{\"entity_type\":\"attachment\",\"target\":{\"kind\":\"room\",\"room_id\":\"!room:test\",\"event_id\":\"$\(query)\"},\"created_at\":\"1970-01-01T00:00:01Z\"}]}", query == "old" ? 0.2 : 0)
            case "/api/files":
                let event = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before_id" }?.value?.dropFirst().dropLast() ?? ""
                return (200, "{\"files\":[{\"eventId\":\"$\(event)\",\"roomId\":\"!room:test\",\"filename\":\"\(event).pdf\"}]}", 0)
            case "/api/files/disk-docs": return (200, #"{"docs":[],"hasMore":false}"#, 0)
            case "/api/files/shared-with-me": return (200, #"{"files":[]}"#, 0)
            case "/api/files/stats": return (200, #"{"all":1,"documents":1,"images":0,"media":0}"#, 0)
            default: return (200, #"{"folders":[]}"#, 0)
            }
        }
        let model = DiskScreenViewModel(service: service, mediaProvider: nil)
        model.searchQuery = "old"
        let old = Task { await model.searchNow() }
        try await Task.sleep(for: .milliseconds(30))
        model.searchQuery = "new"
        await model.searchNow()
        await old.value
        XCTAssertEqual(model.displayedFiles.map(\.filename), ["new.pdf"])
    }

    func testFoldersPreserveParentAndPhotoCopyUploadPreservesDestination() async throws {
        let folder = try JSONDecoder().decode(DiskFolder.self, from: Data(#"{"id":7,"name":"Child","parentId":2,"kind":"album"}"#.utf8))
        XCTAssertEqual(folder.parentID, "2")
        XCTAssertEqual(folder.kind, "album")
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "folderId" }?.value, "7")
            XCTAssertEqual(items?.first { $0.name == "filename" }?.value, "C++ copy.png")
            XCTAssertEqual(items?.first { $0.name == "mimetype" }?.value, "image/png")
            return (200, "{}", 0)
        }
        try await service.uploadDiskDoc(filename: "C++ copy.png", mimetype: "image/png", data: Data([1]), folderID: "7")
    }

    func testSparseOldAttachmentHitsUseFullIndexAndAuthoritativeFolderCategory() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }
            if request.url?.path == "/api/search" {
                XCTAssertEqual(value("q"), "needle")
                XCTAssertEqual(value("type"), "attachment")
                let event = value("offset") == "0" ? "image" : "old"
                return (200, "{\"total\":2,\"results\":[{\"entity_type\":\"attachment\",\"target\":{\"kind\":\"room\",\"room_id\":\"!room:test\",\"event_id\":\"$\(event)\"},\"created_at\":\"1970-01-01T00:00:01Z\"}]}", 0)
            }
            XCTAssertEqual(request.url?.path, "/api/files")
            XCTAssertNil(value("q")); XCTAssertNil(value("filter")); XCTAssertNil(value("folder"))
            XCTAssertEqual(value("before"), "1000")
            XCTAssertEqual(value("room_id"), "!room:test")
            if value("before_id") == "$image~" {
                return (200, #"{"files":[{"eventId":"$image","roomId":"!room:test","filename":"needle-image.png","category":"images","folderId":7}]}"#, 0)
            }
            return (200, #"{"files":[{"eventId":"$old","roomId":"!room:test","filename":"needle-older.pdf","category":"documents","folderId":7,"sharedWith":[{"user":"@reader:test"}]}]}"#, 0)
        }
        let first = try await service.fetchFiles(category: .documents, before: "search:0", folder: "7", query: "needle")
        XCTAssertTrue(first.files.isEmpty)
        XCTAssertEqual(first.nextBefore, "search:1")
        let second = try await service.fetchFiles(category: .documents, before: first.nextBefore, folder: "7", query: "needle")
        XCTAssertEqual(second.files.map(\.eventID), ["$old"])
        XCTAssertEqual(second.files.first?.folderID, "7")
        XCTAssertEqual(second.files.first?.sharedWith, ["@reader:test"])
        XCTAssertEqual(second.nextBefore, "catalogue:")
        XCTAssertNil(second.warning)
    }

    func testNoFolderPagingUsesVisibleTailAndAdvancesAcrossEmptyPages() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            switch request.url!.path {
            case "/api/files":
                switch before {
                case nil: return (200, #"{"files":[{"eventId":"$visible","filename":"one.pdf","ts":400},{"eventId":"$hidden","folderId":7,"ts":300}],"nextBefore":300,"nextBeforeId":"$hidden"}"#, 0)
                case "300": return (200, #"{"files":[],"nextBefore":200,"nextBeforeId":"$filtered"}"#, 0)
                case "200": return (200, #"{"files":[{"eventId":"$second","filename":"two.pdf","ts":150},{"eventId":"$hidden2","folderId":7,"ts":100}],"nextBefore":100,"nextBeforeId":"$hidden2"}"#, 0)
                default: return (200, #"{"files":[],"nextBefore":null}"#, 0)
                }
            case "/api/files/disk-docs": return (200, #"{"docs":[],"hasMore":false}"#, 0)
            case "/api/files/shared-with-me": return (200, #"{"files":[]}"#, 0)
            case "/api/files/stats": return (200, #"{"all":4,"documents":4,"images":0,"media":0}"#, 0)
            default: return (200, #"{"folders":[]}"#, 0)
            }
        }
        let model = DiskScreenViewModel(service: service, mediaProvider: nil)
        model.showingNoFolder = true
        await model.reload()
        XCTAssertEqual(model.displayedFiles.map(\.id), ["$visible"])
        await model.loadMoreIfNeeded(currentEntry: model.displayedEntries[0])
        XCTAssertEqual(model.displayedFiles.map(\.id), ["$visible", "$second"])
        XCTAssertTrue(model.hasMoreFiles)
        try await model.loadMoreIfNeeded(currentEntry: XCTUnwrap(model.displayedEntries.last))
        XCTAssertFalse(model.hasMoreFiles)
        XCTAssertNil(model.errorText)
    }

    func testPartialSourceFailureRetainsValidRowsAndShelfACLWinsDeduplication() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let requests = DiskSearchRequests()
        DiskSearchParityProtocol.handler = { request in
            requests.record(request)
            switch request.url!.path {
            case "/api/files": return (200, #"{"files":[{"eventId":"$chat","filename":"chat.pdf"}]}"#, 0)
            case "/api/files/disk-docs":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value, "shelf")
                return (200, #"{"docs":[{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","name":"foreign.pdf","owner":"@owner:test","readonly":true,"canDownload":false,"folderId":7}],"hasMore":false}"#, 0)
            case "/api/files/shared-with-me": return (503, "{}", 0)
            case "/api/files/stats": return (200, #"{"all":2,"documents":2,"images":0,"media":0}"#, 0)
            default: return (200, #"{"folders":[]}"#, 0)
            }
        }
        let model = DiskScreenViewModel(service: service, mediaProvider: nil)
        await model.reload()
        XCTAssertEqual(model.displayedEntries.count, 2)
        XCTAssertNotNil(model.errorText)
        let file = try XCTUnwrap(model.diskDocs.first)
        XCTAssertEqual(file.owner, "@owner:test")
        XCTAssertEqual(file.sender, "@owner:test")
        XCTAssertTrue(file.readOnly)
        XCTAssertFalse(file.canDownload)
        model.selectFile(file); model.share(file); model.forwardAsFile(file)
        XCTAssertNil(model.previewItem); XCTAssertNil(model.shareItem)
        XCTAssertFalse(requests.values.contains { $0.url?.path.contains("/blob/") == true })

        DiskSearchParityProtocol.handler = { request in
            switch request.url!.path {
            case "/api/files/disk-docs": return (200, #"{"docs":[{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","name":"foreign.pdf","owner":"@owner:test","readonly":true,"canDownload":false,"folderId":7,"ts":1}],"hasMore":false}"#, 0)
            case "/api/files/shared-with-me": return (200, #"{"files":[{"blobId":"031577da-65ec-4bfe-8126-5500d17392ae","name":"foreign.pdf","owner":"@owner:test","permission":"write","canDownload":true,"ts":900}]}"#, 0)
            case "/api/files/stats": return (200, #"{"all":1,"documents":1,"images":0,"media":0}"#, 0)
            case "/api/files": return (200, #"{"files":[]}"#, 0)
            default: return (200, #"{"folders":[]}"#, 0)
            }
        }
        await model.reload()
        XCTAssertEqual(model.displayedEntries.count, 1)
        guard case let .own(merged) = model.displayedEntries[0] else { return XCTFail("Shelf placement must survive deduplication") }
        XCTAssertFalse(merged.canDownload)
        XCTAssertTrue(merged.readOnly)
        XCTAssertEqual(merged.folderID, "7")
    }

    func testRepeatedCursorRetainsRowsAndReportsIncompleteInsteadOfClaimingEnd() async {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            switch request.url!.path {
            case "/api/files": return (200, #"{"files":[{"eventId":"$one","filename":"one.pdf"}],"nextBefore":100,"nextBeforeId":"$one"}"#, 0)
            case "/api/files/disk-docs": return (200, #"{"docs":[],"hasMore":false}"#, 0)
            case "/api/files/shared-with-me": return (200, #"{"files":[]}"#, 0)
            case "/api/files/stats": return (200, #"{"all":2,"documents":2,"images":0,"media":0}"#, 0)
            default: return (200, #"{"folders":[]}"#, 0)
            }
        }
        let model = DiskScreenViewModel(service: service, mediaProvider: nil)
        await model.reload()
        await model.loadMore()
        XCTAssertEqual(model.displayedEntries.count, 1)
        XCTAssertTrue(model.hasMoreFiles)
        XCTAssertNotNil(model.errorText)
    }

    func testIndexContractInt64IDsFractionalTimestampAndMatchProof() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        // Same shape as SystemSearchResponse: BIGSERIAL ID, ISO created_at, room target,
        // and control-character snippet highlights. Identity is verified after hydration.
        let fixture = #"{"total":3,"results":[{"id":9223372036854775807,"entity_type":"attachment","entity_id":"$plain","created_at":"1970-01-01T00:00:01.123Z","snippet":"unrelated","target":{"kind":"room","room_id":"!room:test","event_id":"$plain"}},{"id":"9223372036854775806","entity_type":"attachment","entity_id":"$highlight","created_at":"1970-01-01T00:00:01.123Z","snippet":"text \u0002и\u0003 match","target":{"kind":"room","room_id":"!room:test","event_id":"$highlight"}},{"id":3,"entity_type":"attachment","entity_id":"$name","created_at":"1970-01-01T00:00:01.123Z","target":{"kind":"room","room_id":"!room:test","event_id":"$name"}}]}"#
        let decoded = try JSONDecoder().decode(SystemSearchResponse.self, from: Data(fixture.utf8))
        XCTAssertEqual(decoded.results[0].id, String(Int64.max))
        DiskSearchParityProtocol.handler = { request in
            if request.url?.path == "/api/search" { return (200, fixture, 0) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "before" }?.value, "1123")
            let event = String((items?.first { $0.name == "before_id" }?.value ?? "").dropLast())
            let name = event == "$name" ? "итог.pdf" : "other.pdf"
            return (200, "{\"files\":[{\"eventId\":\"\(event)\",\"roomId\":\"!room:test\",\"filename\":\"\(name)\",\"ts\":1123}]}", event == "$highlight" ? 0.03 : 0)
        }
        let page = try await service.fetchFiles(before: "search:0", query: "и")
        XCTAssertEqual(page.files.map(\.id), ["$highlight", "$name"])
        XCTAssertNil(page.warning)
        XCTAssertEqual(page.nextBefore, "catalogue:")
    }

    func testIndexHydrationCancellationStopsChildrenAndDoesNotRestartCatalogue() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let requests = DiskSearchRequests()
        let hydrated = expectation(description: "First four hydrations started")
        hydrated.expectedFulfillmentCount = 4
        let rows = (0..<8).map { n in
            "{\"id\":\(n),\"entity_type\":\"attachment\",\"entity_id\":\"$e\(n)\",\"created_at\":\"1970-01-01T00:00:01Z\",\"target\":{\"kind\":\"room\",\"room_id\":\"!room:test\",\"event_id\":\"$e\(n)\"}}"
        }.joined(separator: ",")
        DiskSearchParityProtocol.handler = { request in
            requests.record(request)
            if request.url?.path == "/api/search" { return (200, "{\"total\":8,\"results\":[\(rows)]}", 0) }
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before_id" }?.value
            if cursor == nil { return (200, #"{"files":[]}"#, 0) } // Explicit initial parallel catalogue read.
            hydrated.fulfill()
            return (200, #"{"files":[]}"#, 0.5)
        }
        let task = Task { try await service.fetchFiles(query: "needle") }
        await fulfillment(of: [hydrated], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled hydration must not return a completed page") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let catalogueRequests = requests.values.filter { $0.url?.path == "/api/files" }
        XCTAssertEqual(catalogueRequests.count, 5, "Only the initial catalogue request and four hydrations may start")
        XCTAssertEqual(catalogueRequests.filter { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "before_id" } != true }.count, 1)
    }

    func testOffsetCapReturnsRowsAndWarningWithoutUnusableContinuation() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            if request.url?.path == "/api/search" {
                return (200, #"{"total":10050,"results":[{"id":1,"entity_type":"attachment","entity_id":"$one","created_at":"1970-01-01T00:00:01Z","target":{"kind":"room","room_id":"!room:test","event_id":"$one"}}]}"#, 0)
            }
            return (200, #"{"files":[{"eventId":"$one","roomId":"!room:test","filename":"needle.pdf","ts":1000}]}"#, 0)
        }
        let page = try await service.fetchFiles(before: "search:10000", query: "needle")
        XCTAssertEqual(page.files.map(\.id), ["$one"])
        XCTAssertNil(page.nextBefore)
        XCTAssertNotNil(page.warning)
    }

    func testUnavailableIndexStillFindsUnindexedFilenameAndWarnsAtCatalogueBoundary() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        DiskSearchParityProtocol.handler = { request in
            if request.url?.path == "/api/search" { return (503, "{}", 0) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if items?.contains(where: { $0.name == "before" }) == true { return (200, #"{"files":[]}"#, 0) }
            return (200, #"{"files":[{"eventId":"$encrypted","roomId":"!room:test","filename":"C++ needle.pdf","isEncrypted":true,"ts":1000}]}"#, 0)
        }
        let page = try await service.fetchFiles(query: "C++")
        XCTAssertEqual(page.files.map(\.id), ["$encrypted"])
        XCTAssertTrue(page.files[0].isEncrypted)
        XCTAssertNotNil(page.warning)
        let cursor = try XCTUnwrap(page.nextBefore)
        let boundary = try await service.fetchFiles(before: cursor, query: "C++")
        XCTAssertTrue(boundary.files.isEmpty)
        XCTAssertNil(boundary.nextBefore)
        XCTAssertNotNil(boundary.warning, "An exhausted bounded DB window cannot prove complete catalogue coverage")
    }

    func testInitialSearchUnionsRecentCatalogueNamesWithIndexBeforeOlderPages() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let catalogueStarted = expectation(description: "Catalogue starts without waiting for index response")
        let requests = DiskSearchRequests()
        DiskSearchParityProtocol.handler = { request in
            requests.record(request)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if request.url?.path == "/api/search" {
                XCTAssertEqual(items.first { $0.name == "q" }?.value, "Implica")
                return (200, #"{"total":40,"results":[{"id":9223372036854775807,"entity_type":"attachment","entity_id":"$unsupported","target":{"kind":"room","room_id":"!room:test","event_id":"$unsupported"}},{"id":2,"entity_type":"attachment","entity_id":"$ppt","created_at":"1970-01-01T00:00:03Z","target":{"kind":"room","room_id":"!room:test","event_id":"$ppt"}}]}"#, 0.15)
            }
            XCTAssertEqual(request.url?.path, "/api/files")
            XCTAssertNil(items.first { $0.name == "q" })
            XCTAssertNil(items.first { $0.name == "filter" })
            if items.contains(where: { $0.name == "before_id" }) {
                return (200, #"{"files":[{"eventId":"$ppt","roomId":"!room:test","filename":"Implica.pptx","category":"documents","ts":3000,"canDownload":true}]}"#, 0)
            }
            catalogueStarted.fulfill()
            return (200, #"{"files":[{"eventId":"$ppt","roomId":"!room:test","filename":"Implica.pptx","category":"documents","ts":3000,"canDownload":false},{"eventId":"$pdf","roomId":"!room:test","filename":"implica.pdf","category":"documents","ts":2000},{"eventId":"$unrelated","filename":"unrelated.pdf","ts":1000}],"nextBefore":1000,"nextBeforeId":"$unrelated"}"#, 0)
        }
        let query = Task { try await service.fetchFiles(query: "Implica") }
        await fulfillment(of: [catalogueStarted], timeout: 1)
        let page = try await query.value
        XCTAssertEqual(page.files.map(\.id), ["$ppt", "$pdf"])
        XCTAssertFalse(page.files[0].canDownload, "Union must preserve the restrictive authoritative ACL")
        XCTAssertEqual(page.nextBefore, "search:2", "Do not skip the remaining index pages")
        XCTAssertNotNil(page.warning, "Unsupported older index metadata must not masquerade as full coverage")
        XCTAssertEqual(requests.values.filter { $0.url?.path == "/api/search" }.count, 1)
    }

    func testAttachmentFacetSkipsKnownNativeFilesWithoutMaskingUnknownOrMalformedHits() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let scenarios: [(String, Bool)] = [
            (#"{"id":1,"entity_type":"disk_doc","facet_type":"attachment","entity_id":"native","target":{"kind":"file","file_id":"031577da-65ec-4bfe-8126-5500d17392ae"}}"#, false),
            (#"{"id":1,"entity_type":"attachment","facet_type":"attachment","entity_id":"native","target":{"kind":"file","file_id":"031577da-65ec-4bfe-8126-5500d17392ae"}}"#, false),
            (#"{"id":1,"entity_type":"disk_doc","facet_type":"attachment","entity_id":"native","target":{"kind":"file"}}"#, true),
            (#"{"id":1,"entity_type":"disk_doc","facet_type":"attachment","entity_id":"native","target":{"kind":"file","file_id":""}}"#, true),
            (#"{"id":1,"entity_type":"unknown","facet_type":"attachment","entity_id":"native","target":{"kind":"file","file_id":"031577da-65ec-4bfe-8126-5500d17392ae"}}"#, true)
        ]
        for (native, warningExpected) in scenarios {
            let recorded = DiskSearchRequests()
            let roomHit = #"{"id":2,"entity_type":"attachment","facet_type":"attachment","entity_id":"$room","created_at":"1970-01-01T00:00:01Z","target":{"kind":"room","room_id":"!room:test","event_id":"$room"}}"#
            let fixture = "{\"total\":2,\"results\":[\(native),\(roomHit)]}"
            // Match the real app's facet/entity/target contract, including numeric IDs.
            let decoded = try JSONDecoder().decode(SystemSearchResponse.self, from: Data(fixture.utf8))
            XCTAssertEqual(decoded.results[0].facetKind, "attachment")
            DiskSearchParityProtocol.handler = { request in
                recorded.record(request)
                if request.url?.path == "/api/search" { return (200, fixture, 0) }
                XCTAssertEqual(request.url?.path, "/api/files", "Native hits must never initiate blob download or construct a card from index rights")
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(items?.first { $0.name == "before_id" }?.value, "$room~")
                return (200, #"{"files":[{"eventId":"$room","roomId":"!room:test","filename":"Implica.pdf","ts":1000,"canDownload":false}]}"#, 0)
            }
            let page = try await service.fetchFiles(before: "search:0", query: "Implica")
            XCTAssertEqual(page.files.map(\.id), ["$room"])
            XCTAssertFalse(page.files[0].canDownload)
            XCTAssertEqual(page.warning != nil, warningExpected)
            XCTAssertEqual(page.nextBefore, "catalogue:", "Skipped native rows still advance the index offset")
            XCTAssertEqual(recorded.values.filter { $0.url?.path == "/api/files" }.count, 1)
        }
    }
}

private final class DiskSearchRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var values: [URLRequest] {
        lock.withLock { requests }
    }
}

private final class DiskSearchParityProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, TimeInterval))?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (status, body, delay) = Self.handler!(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }
}
