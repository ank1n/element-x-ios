// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// STALK-1601: альбом — одно событие MSC4274 (msgtype `dm.filament.gallery`) с несколькими
/// вложениями. Ответ, реакция и удаление относятся ко всему событию, как у любого сообщения.
struct GalleryRoomTimelineItem: EventBasedMessageTimelineItemProtocol, Equatable {
    let id: TimelineItemIdentifier
    let timestamp: Date
    let isOutgoing: Bool
    let isEditable: Bool
    let canBeRepliedTo: Bool
    var shouldBoost = false

    let sender: TimelineItemSender

    let content: GalleryRoomTimelineItemContent

    var properties = RoomTimelineItemProperties()

    var body: String {
        content.caption ?? SL10n.galleryAlbum
    }

    var contentType: EventBasedMessageTimelineItemContentType {
        .gallery(content)
    }

    /// Нужен ли пузырю фон и отступы: подпись, ответ, тред или файлы в альбоме.
    /// Без них сетка рисуется без пузыря, как одиночная картинка.
    var hasBubbleChrome: Bool {
        !content.isMediaOnly || content.caption != nil || properties.replyDetails != nil || properties.isThreaded
    }

    /// Вложения альбома как отдельные элементы ленты — их понимает существующий просмотрщик
    /// (TimelineMediaPreview). Идентификатор события общий: «Удалить» и «Показать в чате»
    /// из просмотрщика работают со всем альбомом.
    var previewItems: [EventBasedMessageTimelineItemProtocol] {
        content.items.map { item in
            switch item {
            case .image(let content):
                ImageRoomTimelineItem(id: id, timestamp: timestamp, isOutgoing: isOutgoing, isEditable: false,
                                      canBeRepliedTo: canBeRepliedTo, sender: sender, content: content, properties: properties)
            case .video(let content):
                VideoRoomTimelineItem(id: id, timestamp: timestamp, isOutgoing: isOutgoing, isEditable: false,
                                      canBeRepliedTo: canBeRepliedTo, sender: sender, content: content, properties: properties)
            case .audio(let content):
                AudioRoomTimelineItem(id: id, timestamp: timestamp, isOutgoing: isOutgoing, isEditable: false,
                                      canBeRepliedTo: canBeRepliedTo, sender: sender, content: content, properties: properties)
            case .file(let content):
                FileRoomTimelineItem(id: id, timestamp: timestamp, isOutgoing: isOutgoing, isEditable: false,
                                     canBeRepliedTo: canBeRepliedTo, sender: sender, content: content, properties: properties)
            }
        }
    }
}

struct GalleryRoomTimelineItemContent: Hashable {
    enum Item: Hashable {
        case image(ImageRoomTimelineItemContent)
        case video(VideoRoomTimelineItemContent)
        case audio(AudioRoomTimelineItemContent)
        case file(FileRoomTimelineItemContent)

        /// Картинки и видео идут в сетку, файлы и аудио — строками под ней.
        var isVisualMedia: Bool {
            switch self {
            case .image, .video: true
            case .audio, .file: false
            }
        }

        var thumbnailInfo: ImageInfoProxy? {
            switch self {
            case .image(let content): content.thumbnailInfo ?? content.imageInfo
            case .video(let content): content.thumbnailInfo
            case .audio, .file: nil
            }
        }
    }

    /// Подпись альбома (`body` события). Пустая подпись — `nil`.
    var caption: String?
    var formattedCaption: AttributedString?
    /// Исходный HTML подписи из события.
    var formattedCaptionHTMLString: String?

    let items: [Item]

    /// Индексы (в `items`) вложений, которые рисуются сеткой.
    var visualMediaIndices: [Int] {
        items.indices.filter { items[$0].isVisualMedia }
    }

    /// Индексы файлов и аудио — строки под сеткой.
    var fileIndices: [Int] {
        items.indices.filter { !items[$0].isVisualMedia }
    }

    var isMediaOnly: Bool {
        !items.isEmpty && fileIndices.isEmpty
    }
}

/// STALK-1601: раскладка сетки альбома, как на вебе и Android: 1 — одно медиа, 2 — в ряд,
/// 3 — одно большое + 2, 4 — 2×2, 5–10 — по 3 в ряд (последний ряд — остаток).
enum GalleryGridLayout {
    /// Количество ячеек в каждом ряду.
    static func rows(for count: Int) -> [Int] {
        switch count {
        case ..<1: []
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [2, 2]
        default: stride(from: 0, to: count, by: 3).map { min(3, count - $0) }
        }
    }
}
