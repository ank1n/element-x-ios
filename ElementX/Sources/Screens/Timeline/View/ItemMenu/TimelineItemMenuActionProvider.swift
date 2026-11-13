//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

@MainActor
struct TimelineItemMenuActionProvider {
    let timelineItem: RoomTimelineItemProtocol
    let canCurrentUserSendMessage: Bool
    let canCurrentUserRedactSelf: Bool
    let canCurrentUserRedactOthers: Bool
    let canCurrentUserPin: Bool
    let pinnedEventIDs: Set<String>
    let isDM: Bool
    let isViewSourceEnabled: Bool
    let areThreadsEnabled: Bool
    let timelineKind: TimelineKind
    let emojiProvider: EmojiProviderProtocol
    var bookmarkService: BookmarkServiceProtocol? = ServiceLocator.shared.bookmarkService
    var channel: StalkChannelSnapshot?
    /// STMOB-333: показывать «Сохранить» (копия в «Сохранённые», общая с вебом).
    var canSaveToSavedMessages = false
    /// События этой комнаты, у которых есть копия в «Сохранённых».
    var savedEventIDs: Set<String> = []
    /// STMOB-333: показывать «Создать задачу из сообщения».
    var canCreateRoomTask = false
    
    // swiftlint:disable:next cyclomatic_complexity
    func makeActions() -> TimelineItemMenuActions? {
        guard let item = timelineItem as? EventBasedTimelineItemProtocol else {
            // Don't show a context menu for non-event based items.
            return nil
        }

        if timelineItem is StateRoomTimelineItem {
            // Don't show a context menu for state events.
            return nil
        }

        if let encryptedItem = timelineItem as? EncryptedRoomTimelineItem {
            return makeEncryptedItemActions(encryptedItem)
        }
        
        var actions: [TimelineItemMenuAction] = []
        var secondaryActions: [TimelineItemMenuAction] = []
        
        if timelineKind == .pinned || timelineKind == .media(.mediaFilesScreen) || timelineKind == .media(.pinnedEventsScreen) {
            actions.append(.viewInRoomTimeline)
        }
        
        if canRedactItem(item), let poll = item.pollIfAvailable, !poll.hasEnded, let eventID = item.id.eventID {
            actions.append(.endPoll(pollStartID: eventID))
        }

        if item.canBeRepliedTo {
            if canCurrentUserSendMessage, channel?.isChannel != true || timelineKind.isThread {
                if let messageItem = item as? EventBasedMessageTimelineItemProtocol {
                    // If threads are enabled we will have the dedicated `replyInThread` action
                    // so there is no need to make the normal reply use the thread.
                    actions.append(.reply(isThread: !isDM && !areThreadsEnabled && messageItem.properties.isThreaded))
                } else {
                    actions.append(.reply(isThread: false))
                }
            }
        }
        // A channel discussion is independent of permission to reply in its main feed.
        let supportedChannelRoot = item is EventBasedMessageTimelineItemProtocol || item is StickerRoomTimelineItem
        let canOpenComments = channel?.isChannel == true ? supportedChannelRoot && channel?.joined == true && ((channel?.comments == true && channel?.archived != true) || item.properties.threadSummary != nil) : item.canBeRepliedTo && canCurrentUserSendMessage
        if areThreadsEnabled, !isDM, canOpenComments, !timelineKind.isThread, !item.properties.isThreaded,
           !(item is UnsupportedRoomTimelineItem) {
            actions.append(.replyInThread)
        }
        
        if item.isForwardable {
            actions.append(.forward(itemID: item.id))
        }
        
        if item.isEditable, canCurrentUserSendMessage {
            if item.supportsMediaCaption {
                if item.hasMediaCaption {
                    actions.append(.editCaption)
                } else {
                    actions.append(.addCaption)
                }
            } else if item is PollRoomTimelineItem {
                actions.append(.editPoll)
            } else if !(item is VoiceMessageRoomTimelineItem) {
                actions.append(.edit)
            }
        }
        
        if canCurrentUserPin, channel?.archived != true, let eventID = item.id.eventID {
            actions.append(pinnedEventIDs.contains(eventID) ? .unpin : .pin)
        }

        if item.isCopyable {
            actions.append(.copy)
            
        } else if item.hasMediaCaption {
            actions.append(.copyCaption)
        }
        
        if item.isEditable, item.hasMediaCaption {
            actions.append(.removeCaption)
        }

        // STMOB-333: локальное «Избранное» заменено «Сохранёнными» (общими с вебом);
        // снять старую отметку по-прежнему можно.
        if channel?.isChannel != true, let eventID = item.id.eventID, let bookmarkService, bookmarkService.isBookmarked(eventID: eventID) {
            actions.append(.removeBookmark)
        }
        if canSaveToSavedMessages, channel?.isChannel != true, item.isForwardable, let eventID = item.id.eventID {
            actions.append(savedEventIDs.contains(eventID) ? .removeFromSavedMessages : .saveToSavedMessages)
        }
        // Как на вебе: текст, уведомление, действие, файл и картинка.
        let canBeTaskBasis = item is TextRoomTimelineItem || item is NoticeRoomTimelineItem || item is EmoteRoomTimelineItem
            || item is FileRoomTimelineItem || item is ImageRoomTimelineItem
        if canCreateRoomTask, channel?.isChannel != true, canBeTaskBasis, item.id.eventID != nil {
            actions.append(.createRoomTask)
        }

        if canRedactItem(item) {
            secondaryActions.append(.redact)
        }
        
        switch timelineKind {
        case .pinned:
            actions = actions.filter(\.canAppearInPinnedEventsTimeline)
            secondaryActions = secondaryActions.filter(\.canAppearInPinnedEventsTimeline)
        case .media:
            actions.append(.share)
            actions.append(.save)
            actions = actions.filter(\.canAppearInMediaDetails)
            secondaryActions = secondaryActions.filter(\.canAppearInMediaDetails)
        case .live, .detached, .thread:
            break // viewInRoomTimeline is the only non-room item and was added conditionally.
        }
        
        if item.hasFailedToSend {
            actions = actions.filter(\.canAppearInFailedEcho)
            secondaryActions = secondaryActions.filter(\.canAppearInFailedEcho)
        }
        
        if item.isRedacted {
            actions = actions.filter(\.canAppearInRedacted)
            secondaryActions = secondaryActions.filter(\.canAppearInRedacted)
        }
        
        let isReactable = channel?.archived == true || channel?.blocked == true || (channel?.isChannel == true && channel?.joined != true) ? false : (timelineKind == .live || timelineKind == .detached || timelineKind.isThread ? item.isReactable : false)

        return .init(isReactable: isReactable, actions: actions, secondaryActions: secondaryActions, emojiProvider: emojiProvider)
    }
    
    private func makeEncryptedItemActions(_ encryptedItem: EncryptedRoomTimelineItem) -> TimelineItemMenuActions? {
        let actions: [TimelineItemMenuAction] = []
                
        return .init(isReactable: false,
                     actions: actions,
                     secondaryActions: [],
                     emojiProvider: emojiProvider)
    }
    
    private func canRedactItem(_ item: EventBasedTimelineItemProtocol) -> Bool {
        if let channel, channel.isChannel, !item.isOutgoing {
            return channel.joined && (channel.level >= 100 || (channel.canModerate && item.properties.isThreaded))
        }
        return item.isOutgoing ? canCurrentUserRedactSelf : canCurrentUserRedactOthers && !isDM
    }
}
