// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import XCTest

@MainActor
final class StalkUpdateContentTests: XCTestCase {
    private let conversation = "031577da-65ec-4bfe-8126-5500d17392ae"

    func testOwnerScopedAttachmentRejectsOtherOriginsTraversalAndQueryTokens() {
        let path = "/api/v1/conversations/\(conversation)/attachments/file-1"
        XCTAssertNotNil(AilockAttachmentReference(path: path))
        for value in ["https://foreign.example" + path, path + "?token=secret", path + "%2fother", path + "/other", path.replacingOccurrences(of: "file-1", with: ".."), "/api/v1/uploads/file-1"] {
            XCTAssertNil(AilockAttachmentReference(path: value))
        }
    }

    func testToolAttachmentsRestoreWithoutToolCallAndWithoutDuplicates() {
        let file: [String: Any] = ["id": "file-1", "filename": "report.xlsx", "content_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]
        let messages = AilockHistoryParser.parse(rows: [["id": "one", "role": "tool", "content": "", "attachments": [file]],
                                                        ["id": "two", "role": "tool", "content": "", "attachments": [file]]], conversationID: conversation)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.files.count, 1)
        XCTAssertEqual(messages.first?.files.first?.url, "/api/v1/conversations/\(conversation)/attachments/file-1")
    }

    func testOtherConversationAttachmentIsNotRestoredIntoThisConversation() {
        let file: [String: Any] = ["id": "one", "url": "/api/v1/conversations/00000000-0000-0000-0000-000000000000/attachments/one", "filename": "report.txt"]
        XCTAssertTrue(AilockHistoryParser.parseAttachments([file], conversationID: conversation).isEmpty)
    }

    func testCustomEmojiFormattingDoesNotRewriteCodeLinksOrAttributes() throws {
        let html = "<p>:capybara:</p><code>:capybara:</code><a href='https://example.com/:capybara:'>:capybara:</a>"
        let result = try XCTUnwrap(StalkCustomEmoji.formatted(plain: ":capybara:", html: html))
        XCTAssertEqual(result.components(separatedBy: "data-mx-emoticon").count - 1, 1)
        XCTAssertTrue(result.contains("<code>:capybara:</code>"))
        XCTAssertTrue(result.contains("https://example.com/:capybara:"))
    }

    func testCustomEmojiBackspaceExpandsToWholeTokenAndCodeRemainsText() {
        XCTAssertEqual(StalkCustomEmoji.atomicRange(in: "Hi :capybara:", at: NSRange(location: 11, length: 1)), NSRange(location: 3, length: 10))
        XCTAssertNil(StalkCustomEmoji.atomicRange(in: "`:capybara:`", at: NSRange(location: 6, length: 1)))
    }

    func testSearchPlanPreservesManualFiltersAndReportsUnsupportedRestrictions() throws {
        var original = SystemSearchConditions(); original.query = "Документы за неделю"; original.types = ["disk_doc"]; original.period = "week"
        let valid = #"{"q":"договор","types":["message"],"from":"2026-01-01","to":null,"room":null,"sender":null,"sort":null,"format":null,"has":[],"expand":[],"unsupported":[]}"#
        let plan = try SystemSearchService.decodePlan(valid, preserving: original)
        XCTAssertEqual(plan.types, ["disk_doc"])
        XCTAssertEqual(plan.period, "week")
        XCTAssertEqual(plan.query, original.query)
        XCTAssertEqual(plan.mode, "smart")
        let partial = try SystemSearchService.decodePlan(valid.replacingOccurrences(of: "\"unsupported\":[]", with: "\"unsupported\":[\"owner\"]"), preserving: original)
        XCTAssertEqual(partial.unsupported, ["owner"])
        XCTAssertEqual(partial.types, original.types)
        XCTAssertEqual(partial.period, original.period)
    }

    func testSearchPaginationAndSourceFiltersAreSentToServer() throws {
        var conditions = SystemSearchConditions(); conditions.query = "a&b"; conditions.types = ["task", "disk_doc"]; conditions.sender = "@one:example.com"; conditions.mode = "basic"; conditions.expand = ["must not go out"]
        let items = try conditions.queryItems(offset: 20)
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "20")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "task,disk_doc")
        XCTAssertEqual(items.first { $0.name == "sender" }?.value, "@one:example.com")
        XCTAssertFalse(items.contains { $0.name == "qx" })
    }

    func testBuiltinPackAndEmojiUseSameWebIdentitiesAndBundledArtwork() {
        XCTAssertEqual(SharedStickerPack.capybaras.id, "builtin-capybara")
        XCTAssertEqual(SharedStickerPack.capybaras.items.count, 4)
        XCTAssertTrue(SharedStickerPack.capybaras.items.allSatisfy(\.isValid))
        XCTAssertEqual(StalkCustomEmoji.lookup(":капибара:")?.shortcode, ":capybara:")
        for emoji in StalkCustomEmoji.all {
            XCTAssertNotNil(UIImage(named: emoji.asset))
        }
    }
}
