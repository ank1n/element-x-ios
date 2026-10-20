// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import UIKit
import UniformTypeIdentifiers
import XCTest

final class SharedFileImportTests: XCTestCase {
    func testOriginalFilenameWinsOverSuggestion() {
        XCTAssertEqual(SharedFileImport.filename(original: "Смета проекта.docx", suggested: "copy.docx", fileExtension: "docx"), "Смета проекта.docx")
    }

    func testSystemUUIDUsesSuggestedNameAndDoesNotDoubleExtension() {
        XCTAssertEqual(SharedFileImport.filename(original: "EA417189-7340-4649-8F9F-F8859F310992.docx", suggested: "Отчёт", fileExtension: "docx"), "Отчёт.docx")
        XCTAssertEqual(SharedFileImport.filename(original: nil, suggested: "Отчёт.docx", fileExtension: "docx"), "Отчёт.docx")
    }

    func testNamesCannotEscapeTemporaryDirectory() {
        XCTAssertEqual(SharedFileImport.filename(original: nil, suggested: "../../report.docx", fileExtension: "docx"), "report.docx")
        let name = SharedFileImport.filename(original: nil, suggested: "..", fileExtension: "docx")
        XCTAssertNotNil(UUID(uuidString: (name as NSString).deletingPathExtension))
    }

    func testSameNamedAttachmentsDoNotOverwriteEachOther() throws {
        let first = try SharedFileImport.write(Data("first".utf8), suggestedName: "Смета.docx", fileExtension: "docx", withinAppGroupContainer: false)
        let second = try SharedFileImport.write(Data("second".utf8), suggestedName: "Смета.docx", fileExtension: "docx", withinAppGroupContainer: false)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()); try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testFileCopyRetainsNameAndSurvivesProviderCleanup() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("Вложение.docx")
        try Data("document".utf8).write(to: file)
        let copy = try SharedFileImport.copy(file, suggestedName: nil, fileExtension: "docx", withinAppGroupContainer: false)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(copy.lastPathComponent, "Вложение.docx")
        XCTAssertEqual(try Data(contentsOf: copy), Data("document".utf8))
    }

    func testProviderDataFallbackRetainsSuggestion() async throws {
        let provider = NSItemProvider()
        provider.suggestedName = "Документ.docx"
        provider.registerDataRepresentation(forTypeIdentifier: "org.openxmlformats.wordprocessingml.document", visibility: .all) { completion in
            completion(Data("content".utf8), nil); return nil
        }
        let stored = await provider.storeData()
        let file = try XCTUnwrap(stored)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "Документ.docx")
        XCTAssertEqual(try Data(contentsOf: file), Data("content".utf8))
    }

    func testFileRepresentationIsPreferredToBytesAndRetainsOriginalFilename() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = source.appendingPathComponent("Оригинальное имя.docx")
        try Data("file-representation".utf8).write(to: original)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: "org.openxmlformats.wordprocessingml.document", fileOptions: [], visibility: .all) { completion in
            completion(original, false, nil)
            return nil
        }
        let result = await provider.storeData()
        let file = try XCTUnwrap(result)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "Оригинальное имя.docx")
        XCTAssertEqual(try Data(contentsOf: file), Data("file-representation".utf8))
    }

    @MainActor
    func testUIImageShareStillProducesReadablePNG() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let provider = NSItemProvider(item: image, typeIdentifier: UTType.image.identifier)
        let result = await provider.storeData()
        let file = try XCTUnwrap(result)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertNotNil(UIImage(contentsOfFile: file.path))
    }

    func testRemoteURLAndDirectoryAreNotImported() throws {
        XCTAssertThrowsError(try SharedFileImport.copy(XCTUnwrap(URL(string: "https://example.invalid/doc.docx")), suggestedName: nil, fileExtension: "docx", withinAppGroupContainer: false))
        XCTAssertThrowsError(try SharedFileImport.copy(FileManager.default.temporaryDirectory, suggestedName: nil, fileExtension: "docx", withinAppGroupContainer: false))
    }
}
