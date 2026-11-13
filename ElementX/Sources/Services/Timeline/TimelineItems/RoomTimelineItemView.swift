//
import OrderedCollections

// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//
import SwiftUI

struct RoomTimelineItemView: View {
    @Environment(\.timelineContext) var context
    @ObservedObject var viewState: RoomTimelineItemViewState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hideChannelServiceItem {
                if context?.viewState.isSavedMessagesRoom == true, let item = viewState.type.eventBasedItem, let savedFrom = item.properties.savedFrom {
                    SavedFromHeader(savedFrom: savedFrom)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: item.isOutgoing ? .trailing : .leading)
                }
                timelineView
                if let source = viewState.type.eventBasedItem?.properties.channelForwardSource, let service = context?.viewState.channelService {
                    StalkChannelLinkCard(url: source, service: service)
                }
                if let eventID = viewState.identifier.eventID, let store = context?.viewState.roomTaskBasis {
                    RoomTaskBasisBadgeHost(store: store, eventID: eventID) { taskID in
                        context?.send(viewAction: .roomTaskBadgeTapped(taskID: taskID))
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: viewState.type.eventBasedItem?.isOutgoing == true ? .trailing : .leading)
                }
            }
        }
        .animation(.elementDefault, value: viewState.groupStyle)
        .animation(.elementDefault, value: viewState.type)
        .environment(\.timelineGroupStyle, viewState.groupStyle)
        .onAppear {
            context?.send(viewAction: .itemAppeared(itemID: viewState.identifier))
        }
        .onDisappear {
            context?.send(viewAction: .itemDisappeared(itemID: viewState.identifier))
        }
    }

    private var hideChannelServiceItem: Bool {
        guard context?.viewState.isChannelMain == true else { return false }
        switch viewState.type {
        case .state, .group, .redacted, .readMarker: return true
        default: return false
        }
    }

    @ViewBuilder private var timelineView: some View {
        switch viewState.type {
        case .text(let item):
            VStack(alignment: .leading, spacing: 8) {
                TextRoomTimelineView(timelineItem: item, linkMetadata: linkMetadataForItem(item))
                if let service = context?.viewState.channelService {
                    ForEach(StalkChannelLinkCard.candidates(in: item.body), id: \.self) { url in
                        StalkChannelLinkCard(url: url, service: service)
                    }
                }
            }
        case .separator(let item):
            SeparatorRoomTimelineView(timelineItem: item)
        case .image(let item):
            ImageRoomTimelineView(timelineItem: item)
        case .video(let item):
            VideoRoomTimelineView(timelineItem: item)
        case .audio(let item):
            AudioRoomTimelineView(timelineItem: item)
        case .file(let item):
            FileRoomTimelineView(timelineItem: item)
        case .emote(let item):
            EmoteRoomTimelineView(timelineItem: item)
        case .notice(let item):
            NoticeRoomTimelineView(timelineItem: item)
        case .redacted(let item):
            RedactedRoomTimelineView(timelineItem: item)
        case .encrypted(let item):
            EncryptedRoomTimelineView(timelineItem: item)
        case .readMarker(let item):
            ReadMarkerRoomTimelineView(timelineItem: item)
        case .paginationIndicator(let item):
            PaginationIndicatorRoomTimelineView(timelineItem: item)
        case .sticker(let item):
            StickerRoomTimelineView(timelineItem: item)
        case .unsupported(let item):
            UnsupportedRoomTimelineView(timelineItem: item)
        case .timelineStart(let item):
            TimelineStartRoomTimelineView(timelineItem: item)
        case .state(let item):
            VStack(spacing: 0) {
                StateRoomTimelineView(timelineItem: item)
                if let marker = item.callInitiate, let service = context?.viewState.callSummaryService {
                    CallTimelineSummaryView(marker: marker, service: service)
                }
            }
        case .group(let item):
            CollapsibleRoomTimelineView(timelineItem: item)
        case .location(let item):
            LocationRoomTimelineView(timelineItem: item)
        case .poll(let item):
            PollRoomTimelineView(timelineItem: item)
        case .voice(let item):
            let playerState = context?.viewState.audioPlayerStateProvider?(item.id) ?? AudioPlayerState(id: .timelineItemIdentifier(item.id),
                                                                                                        title: L10n.commonVoiceMessage,
                                                                                                        duration: 0)
            // STMOB-265: кнопка расшифровки — только когда комната ТОЧНО не шифрована.
            let transcriptionState = context?.viewState.isRoomEncrypted == false
                ? item.id.eventID.flatMap { context?.viewState.voiceTranscriptionStateProvider?($0) }
                : nil
            VoiceMessageRoomTimelineView(timelineItem: item,
                                         playerState: playerState,
                                         transcriptionState: transcriptionState)
        case .callInvite(let item):
            CallInviteRoomTimelineView(timelineItem: item)
        case .callNotification(let item):
            CallNotificationRoomTimelineView(timelineItem: item)
        }
    }
    
    private func linkMetadataForItem(_ item: TextRoomTimelineItem) -> OrderedDictionary<URL, LinkMetadataProviderItem> {
        var linkMetadata = OrderedDictionary<URL, LinkMetadataProviderItem>()
        for url in item.links.prefix(TextRoomTimelineView.maxLinkPreviewsToRender) {
            if let item = context?.viewState.linkMetadataProvider?.metadataItems[url] {
                linkMetadata[url] = item
            } else {
                linkMetadata[url] = LinkMetadataProviderItem(url: url, metadata: nil)
            }
        }
        return linkMetadata
    }
}
