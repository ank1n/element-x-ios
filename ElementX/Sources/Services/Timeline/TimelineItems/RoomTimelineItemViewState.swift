//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

final class RoomTimelineItemViewState: Identifiable, Equatable, ObservableObject {
    @Published var type: RoomTimelineItemType
    @Published var groupStyle: TimelineGroupStyle

    /// Contains all the identification info of the item, `uniqueID`, `eventID` and `transactionID`
    var identifier: TimelineItemIdentifier {
        type.id
    }

    init(type: RoomTimelineItemType, groupStyle: TimelineGroupStyle) {
        self.type = type
        self.groupStyle = groupStyle
    }

    convenience init(item: RoomTimelineItemProtocol, groupStyle: TimelineGroupStyle) {
        self.init(type: .init(item: item), groupStyle: groupStyle)
    }
    
    // MARK: - Equatable
    
    static func == (lhs: RoomTimelineItemViewState, rhs: RoomTimelineItemViewState) -> Bool {
        lhs.type == rhs.type && lhs.groupStyle == rhs.groupStyle
    }
    
    // MARK: Identifiable
    
    /// The `timelineID` of the item, used for the timeline view level identification, do not use for any business logic use `identifier` instead
    var id: TimelineItemIdentifier.UniqueID {
        identifier.uniqueID
    }
}

enum RoomTimelineItemType: Equatable {
    case text(TextRoomTimelineItem)
    case separator(SeparatorRoomTimelineItem)
    case image(ImageRoomTimelineItem)
    case video(VideoRoomTimelineItem)
    case audio(AudioRoomTimelineItem)
    case file(FileRoomTimelineItem)
    case emote(EmoteRoomTimelineItem)
    case notice(NoticeRoomTimelineItem)
    case redacted(RedactedRoomTimelineItem)
    case encrypted(EncryptedRoomTimelineItem)
    case readMarker(ReadMarkerRoomTimelineItem)
    case paginationIndicator(PaginationIndicatorRoomTimelineItem)
    case sticker(StickerRoomTimelineItem)
    case unsupported(UnsupportedRoomTimelineItem)
    case timelineStart(TimelineStartRoomTimelineItem)
    case state(StateRoomTimelineItem)
    case group(CollapsibleTimelineItem)
    case location(LocationRoomTimelineItem)
    case poll(PollRoomTimelineItem)
    case voice(VoiceMessageRoomTimelineItem)
    case callInvite(CallInviteRoomTimelineItem)
    case callNotification(CallNotificationRoomTimelineItem)

    init(item: RoomTimelineItemProtocol) {
        switch item {
        case let item as TextRoomTimelineItem:
            self = .text(item)
        case let item as ImageRoomTimelineItem:
            self = .image(item)
        case let item as VideoRoomTimelineItem:
            self = .video(item)
        case let item as AudioRoomTimelineItem:
            self = .audio(item)
        case let item as FileRoomTimelineItem:
            self = .file(item)
        case let item as SeparatorRoomTimelineItem:
            self = .separator(item)
        case let item as NoticeRoomTimelineItem:
            self = .notice(item)
        case let item as EmoteRoomTimelineItem:
            self = .emote(item)
        case let item as RedactedRoomTimelineItem:
            self = .redacted(item)
        case let item as EncryptedRoomTimelineItem:
            self = .encrypted(item)
        case let item as ReadMarkerRoomTimelineItem:
            self = .readMarker(item)
        case let item as PaginationIndicatorRoomTimelineItem:
            self = .paginationIndicator(item)
        case let item as StickerRoomTimelineItem:
            self = .sticker(item)
        case let item as UnsupportedRoomTimelineItem:
            self = .unsupported(item)
        case let item as TimelineStartRoomTimelineItem:
            self = .timelineStart(item)
        case let item as StateRoomTimelineItem:
            self = .state(item)
        case let item as CollapsibleTimelineItem:
            self = .group(item)
        case let item as LocationRoomTimelineItem:
            self = .location(item)
        case let item as PollRoomTimelineItem:
            self = .poll(item)
        case let item as VoiceMessageRoomTimelineItem:
            self = .voice(item)
        case let item as CallInviteRoomTimelineItem:
            self = .callInvite(item)
        case let item as CallNotificationRoomTimelineItem:
            self = .callNotification(item)
        default:
            fatalError("Unknown timeline item")
        }
    }

    /// sTalk: Extract EventBasedTimelineItemProtocol if this is an event-based item
    var eventBasedItem: EventBasedTimelineItemProtocol? {
        switch self {
        case .text(let item): item
        case .image(let item): item
        case .video(let item): item
        case .audio(let item): item
        case .file(let item): item
        case .emote(let item): item
        case .notice(let item): item
        case .redacted(let item): item
        case .encrypted(let item): item
        case .sticker(let item): item
        case .unsupported(let item): item
        case .location(let item): item
        case .poll(let item): item
        case .voice(let item): item
        case .state(let item): item
        default: nil
        }
    }

    var id: TimelineItemIdentifier {
        switch self {
        case .text(let item as RoomTimelineItemProtocol),
             .separator(let item as RoomTimelineItemProtocol),
             .image(let item as RoomTimelineItemProtocol),
             .video(let item as RoomTimelineItemProtocol),
             .audio(let item as RoomTimelineItemProtocol),
             .file(let item as RoomTimelineItemProtocol),
             .emote(let item as RoomTimelineItemProtocol),
             .notice(let item as RoomTimelineItemProtocol),
             .redacted(let item as RoomTimelineItemProtocol),
             .encrypted(let item as RoomTimelineItemProtocol),
             .readMarker(let item as RoomTimelineItemProtocol),
             .paginationIndicator(let item as RoomTimelineItemProtocol),
             .sticker(let item as RoomTimelineItemProtocol),
             .unsupported(let item as RoomTimelineItemProtocol),
             .timelineStart(let item as RoomTimelineItemProtocol),
             .state(let item as RoomTimelineItemProtocol),
             .group(let item as RoomTimelineItemProtocol),
             .location(let item as RoomTimelineItemProtocol),
             .poll(let item as RoomTimelineItemProtocol),
             .voice(let item as RoomTimelineItemProtocol),
             .callInvite(let item as RoomTimelineItemProtocol),
             .callNotification(let item as RoomTimelineItemProtocol):
            return item.id
        }
    }
}
