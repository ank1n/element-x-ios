// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
@testable import ElementX
import MatrixRustSDK
import XCTest

/// STALK-1601: альбомы — раскладка сетки и сборка элемента ленты из события MSC4274.
@MainActor
final class GalleryTimelineItemTests: XCTestCase {
    func testGridRowsForEveryAlbumSize() {
        let expected: [Int: [Int]] = [
            1: [1],
            2: [2],
            3: [1, 2],
            4: [2, 2],
            5: [3, 2],
            6: [3, 3],
            7: [3, 3, 1],
            8: [3, 3, 2],
            9: [3, 3, 3],
            10: [3, 3, 3, 1]
        ]
        for count in 1...10 {
            let rows = GalleryGridLayout.rows(for: count)
            XCTAssertEqual(rows, expected[count], "раскладка для \(count)")
            XCTAssertEqual(rows.reduce(0, +), count, "все вложения на месте для \(count)")
        }
        XCTAssertEqual(GalleryGridLayout.rows(for: 0), [])
    }

    func testFactoryMapsGalleryItemsAndCaption() throws {
        let content = try GalleryMessageContent(body: "Отпуск",
                                                formatted: nil,
                                                itemtypes: [.image(content: image("a.jpg")),
                                                            .file(content: file("отчёт.pdf")),
                                                            .video(content: video("b.mp4")),
                                                            .other(itemtype: "org.example.unknown", body: "?")])

        let gallery = makeFactory().buildGalleryTimelineItemContent(content)

        XCTAssertEqual(gallery.caption, "Отпуск")
        XCTAssertEqual(gallery.items.count, 3, "неизвестный тип пропускается")
        XCTAssertEqual(gallery.visualMediaIndices, [0, 2])
        XCTAssertEqual(gallery.fileIndices, [1])
        XCTAssertFalse(gallery.isMediaOnly)
        guard case .image(let first) = gallery.items[0], case .file(let second) = gallery.items[1], case .video(let third) = gallery.items[2] else {
            return XCTFail("порядок и типы вложений должны сохраняться")
        }
        XCTAssertEqual(first.filename, "a.jpg")
        XCTAssertEqual(first.imageInfo.size, CGSize(width: 40, height: 30))
        XCTAssertEqual(second.filename, "отчёт.pdf")
        XCTAssertEqual(third.filename, "b.mp4")
    }

    func testEmptyBodyMeansNoCaptionAndPreviewItemsShareEventID() throws {
        let content = try GalleryMessageContent(body: "  ",
                                                formatted: nil,
                                                itemtypes: [.image(content: image("a.jpg")), .image(content: image("b.jpg"))])
        let galleryContent = makeFactory().buildGalleryTimelineItemContent(content)
        XCTAssertNil(galleryContent.caption)
        XCTAssertNil(galleryContent.formattedCaption)
        XCTAssertTrue(galleryContent.isMediaOnly)

        let item = GalleryRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: true, isEditable: false,
                                           canBeRepliedTo: true, sender: .init(id: "@alice:example.invalid"), content: galleryContent)
        XCTAssertEqual(item.body, SL10n.galleryAlbum)
        XCTAssertFalse(item.hasBubbleChrome)
        let previews = item.previewItems
        XCTAssertEqual(previews.count, 2)
        XCTAssertTrue(previews.allSatisfy { $0.id == item.id && $0 is ImageRoomTimelineItem && !$0.isEditable })
    }

    func testAlbumPreviewDataSourceStartsAtTappedItem() throws {
        let content = try GalleryMessageContent(body: "",
                                                formatted: nil,
                                                itemtypes: [.image(content: image("a.jpg")), .video(content: video("b.mp4")), .image(content: image("c.jpg"))])
        let item = GalleryRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false,
                                           canBeRepliedTo: true, sender: .init(id: "@bob:example.invalid"),
                                           content: makeFactory().buildGalleryTimelineItemContent(content))
        let dataSource = TimelineMediaPreviewDataSource(albumItems: item.previewItems, initialIndex: 1)

        XCTAssertEqual(dataSource.initialItemIndex, 1)
        XCTAssertEqual(dataSource.previewItems.count, 3)
        XCTAssertEqual(dataSource.firstPreviewItemIndex, 0)
        XCTAssertEqual(dataSource.lastPreviewItemIndex, 2)
        guard case .media(let current) = dataSource.currentItem else { return XCTFail("текущий элемент — медиа") }
        XCTAssertEqual(current.filename, "b.mp4")

        // Обновления ленты не должны подменять вложения альбома.
        dataSource.updatePreviewItems(itemViewStates: [])
        XCTAssertEqual(dataSource.previewItems.count, 3)
    }

    func testUploadsAreSplitIntoAlbumsOfTen() {
        let infos = (0..<23).map { MediaInfo.file(fileURL: URL(fileURLWithPath: "/tmp/\($0)"), fileInfo: .init(mimetype: nil, size: nil, thumbnailInfo: nil, thumbnailSource: nil)) }
        XCTAssertEqual(MediaUploadPreviewScreenViewModel.galleryChunks(infos).map(\.count), [10, 10, 3])
        XCTAssertEqual(MediaUploadPreviewScreenViewModel.galleryChunks(Array(infos.prefix(1))).map(\.count), [1])
        XCTAssertEqual(MediaUploadPreviewScreenViewModel.galleryChunks([]).count, 0)
    }

    // MARK: - Helpers

    private func makeFactory() -> RoomTimelineItemFactory {
        RoomTimelineItemFactory(userID: "@alice:example.invalid",
                                attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:example.invalid"))
    }

    private func source(_ name: String) throws -> MediaSource {
        // Идентификатор медиа — только буквы и цифры.
        try MediaSource.fromUrl(url: "mxc://example.invalid/media\(abs(name.hashValue))")
    }

    private func image(_ filename: String) throws -> ImageMessageContent {
        try ImageMessageContent(filename: filename, caption: nil, formattedCaption: nil, source: source(filename),
                                info: .init(height: 30, width: 40, mimetype: "image/jpeg", size: 100,
                                            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil))
    }

    private func video(_ filename: String) throws -> VideoMessageContent {
        try VideoMessageContent(filename: filename, caption: nil, formattedCaption: nil, source: source(filename),
                                info: .init(duration: 3, height: 30, width: 40, mimetype: "video/mp4", size: 100,
                                            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil))
    }

    private func file(_ filename: String) throws -> FileMessageContent {
        try FileMessageContent(filename: filename, caption: nil, formattedCaption: nil, source: source(filename),
                               info: .init(mimetype: "application/pdf", size: 100, thumbnailInfo: nil, thumbnailSource: nil))
    }
}
