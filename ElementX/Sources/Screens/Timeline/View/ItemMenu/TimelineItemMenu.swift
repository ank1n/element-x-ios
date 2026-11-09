//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct TimelineItemMenu: View {
    @EnvironmentObject private var context: TimelineViewModel.Context
    @Environment(\.dismiss) private var dismiss
    
    let item: EventBasedTimelineItemProtocol
    let actions: TimelineItemMenuActions
    var compact = false
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    
    var body: some View {
        if compact, context.viewState.isChannelMain {
            compactMenu
        } else {
            fullMenu
        }
    }

    private var fullMenu: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text(menuTitle)
                        .font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.actionClose)
                }
                messagePreview
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                if !actions.reactions.isEmpty {
                    reactionsSection
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                }
                channelActionGroup(actions.actions)
                channelActionGroup(actions.secondaryActions)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier(A11yIdentifiers.roomScreen.timelineItemActionMenu)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    @ViewBuilder
    private func channelActionGroup(_ values: [TimelineItemMenuAction]) -> some View {
        if !values.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.element) { index, action in
                    if index > 0 { Divider().padding(.leading, 60) }
                    Button(role: action.isDestructive ? .destructive : nil) { send(action) } label: {
                        action.label(isChannelPost: context.viewState.isChannelMain)
                            .labelStyle(TimelineMenuLabelStyle(isDestructive: action.isDestructive))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var menuTitle: String {
        context.viewState.isChannelMain
            ? NSLocalizedString("stalk_channels_post_menu", value: "Post", comment: "Channel post action sheet")
            : NSLocalizedString("stalk_message_menu", value: "Message", comment: "Message action sheet")
    }

    private var compactMenu: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text(menuTitle).font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.actionClose)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), alignment: .leading, spacing: 12) {
                    ForEach(actions.actions.filter { action in
                        switch action {
                        case .replyInThread, .forward, .copy, .copyCaption: true
                        default: false
                        }
                    }) { action in
                        Button { send(action) } label: {
                            action.label(isChannelPost: true)
                                .labelStyle(CompactPostMenuLabelStyle())
                        }.buttonStyle(.plain)
                    }
                    if !actions.reactions.isEmpty {
                        Button { send(.displayEmojiPicker(itemID: item.id)) } label: {
                            Label(StalkChannelStrings.text("react"), systemImage: "face.smiling")
                                .labelStyle(CompactPostMenuLabelStyle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier(A11yIdentifiers.roomScreen.timelineItemActionMenu)
        .presentationDetents([.height(240), .medium])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private var messagePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0.0) {
                LoadableAvatarImage(url: item.sender.avatarURL,
                                    name: item.sender.displayName,
                                    contentID: item.sender.id,
                                    avatarSize: .user(on: .timeline),
                                    mediaProvider: context.mediaProvider)
                    .accessibilityHidden(true)
                
                Spacer(minLength: 8.0)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.sender.displayName ?? item.sender.id)
                        .font(.compound.bodySMSemibold)
                        .foregroundColor(.compound.textPrimary)
                        .textSelection(.enabled)
                    
                    Text(item.timelineMenuDescription)
                        .font(.compound.bodyMD)
                        .foregroundColor(.compound.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer(minLength: 16.0)
                
                Text(item.timestamp.formattedTime())
                    .font(.compound.bodyXS)
                    .foregroundColor(.compound.textSecondary)
            }
            .accessibilityElement(children: .combine)
            
            if case let .sendingFailed(.verifiedUser(failure)) = item.properties.deliveryStatus {
                Divider()
                    .padding(.horizontal, -16)
                
                VerifiedUserSendFailureView(failure: failure,
                                            members: context.viewState.members,
                                            ownUserID: context.viewState.ownUserID) {
                    send(.itemSendInfoTapped(itemID: item.id))
                }
                .padding(.bottom, 8)
            } else if let authenticity = item.properties.encryptionAuthenticity {
                Label(authenticity.message, icon: authenticity.icon, iconSize: .small, relativeTo: .compound.bodySMSemibold)
                    .font(.compound.bodySMSemibold)
                    .foregroundStyle(authenticity.foregroundStyle)
            }
        }
    }
    
    private var reactionsSection: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: 4) {
                    ForEach(actions.reactions, id: \.key) {
                        reactionButton(for: $0.key)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            
            Button {
                dismiss()
                // Otherwise we get errors that a sheet is already presented
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    context.send(viewAction: .displayEmojiPicker(itemID: item.id))
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 20))
                    .foregroundStyle(StalkTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(StalkTheme.accent.opacity(0.08), in: Circle())
                    .padding(.trailing, 8)
            }
            .accessibilityLabel(L10n.actionReact)
        }
    }
    
    private func reactionButton(for emoji: String) -> some View {
        Button {
            feedbackGenerator.impactOccurred()
            dismiss()
            context.send(viewAction: .toggleReaction(key: emoji, itemID: item.id))
        } label: {
            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(Circle()
                    .foregroundColor(reactionBackgroundColor(for: emoji)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasReacted(to: emoji) ? L10n.a11yRemoveReaction(emoji) : L10n.a11yAddReaction(emoji))
    }
    
    private func hasReacted(to emoji: String) -> Bool {
        if let reaction = item.properties.reactions.first(where: { $0.key == emoji }),
           reaction.isHighlighted {
            return true
        }
        return false
    }
    
    private func reactionBackgroundColor(for emoji: String) -> Color {
        hasReacted(to: emoji) ? .compound.bgActionPrimaryRest : .clear
    }
    
    private func send(_ action: TimelineItemMenuAction) {
        send(.handleTimelineItemMenuAction(itemID: item.id, action: action))
    }
    
    private func send(_ action: TimelineViewAction) {
        dismiss()
        // Otherwise we might get errors that a sheet is already presented
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.send(viewAction: action)
        }
    }
}

private struct CompactPostMenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 21))
                .foregroundStyle(StalkTheme.accent)
                .frame(width: 44, height: 44)
                .background(StalkTheme.accent.opacity(0.08), in: Circle())
            configuration.title
                .font(.caption).foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .top)
        .contentShape(Rectangle())
    }
}

private struct TimelineMenuLabelStyle: LabelStyle {
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 18))
                .foregroundStyle(isDestructive ? Color.red : StalkTheme.accent)
                .frame(width: 36, height: 36)
                .background((isDestructive ? Color.red : StalkTheme.accent).opacity(0.08), in: Circle())
            configuration.title
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

private struct VerifiedUserSendFailureView: View {
    let failure: TimelineItemSendFailure.VerifiedUser
    let action: () -> Void
    
    private let memberDisplayName: String
    private let isYou: Bool
    
    init(failure: TimelineItemSendFailure.VerifiedUser,
         members: [String: RoomMemberState],
         ownUserID: String,
         action: @escaping () -> Void) {
        self.failure = failure
        self.action = action
        
        let userIDs = failure.affectedUserIDs
        memberDisplayName = userIDs.first.map { members[$0]?.displayName ?? $0 } ?? ""
        isYou = ownUserID == userIDs.first
    }
    
    var title: String {
        switch failure {
        case .hasUnsignedDevice:
            isYou ? L10n.screenTimelineItemMenuSendFailureYouUnsignedDevice : L10n.screenTimelineItemMenuSendFailureUnsignedDevice(memberDisplayName)
        case .changedIdentity:
            L10n.screenTimelineItemMenuSendFailureChangedIdentity(memberDisplayName)
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, icon: \.errorSolid, iconSize: .small, relativeTo: .compound.bodySMSemibold)
                    .font(.compound.bodySMSemibold)
                    .foregroundStyle(.compound.textCriticalPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ListRowAccessory.navigationLink
            }
        }
    }
}

private extension EncryptionAuthenticity {
    var foregroundStyle: SwiftUI.Color {
        switch color {
        case .red: .compound.textCriticalPrimary
        case .gray: .compound.textSecondary
        }
    }
}

// MARK: - Previews

struct TimelineItemMenu_Previews: PreviewProvider, TestablePreview {
    enum ItemType { case incomingText, outgoingMedia, outgoingMediaWithCaption }
    
    static let viewModel = TimelineViewModel.mock
    static let (item, actions) = makeActions()
    static let (backupItem, _) = makeActions(authenticity: .notGuaranteed(color: .gray))
    static let (unsignedItem, _) = makeActions(authenticity: .unsignedDevice(color: .red))
    static let (unencryptedItem, _) = makeActions(authenticity: .sentInClear(color: .red))
    static let (unknownFailureItem, _) = makeActions(deliveryStatus: .sendingFailed(.unknown))
    static let (identityChangedItem, _) = makeActions(deliveryStatus: .sendingFailed(.verifiedUser(.changedIdentity(users: [
        "@alice:matrix.org"
    ]))))
    static let (unsignedDevicesItem, _) = makeActions(deliveryStatus: .sendingFailed(.verifiedUser(.hasUnsignedDevice(devices: [
        "@alice:matrix.org": ["DEVICE1", "DEVICE2"]
    ]))))
    static let (ownUnsignedDevicesItem, _) = makeActions(deliveryStatus: .sendingFailed(.verifiedUser(.hasUnsignedDevice(devices: [
        RoomMemberProxyMock.mockMe.userID: ["DEVICE1"]
    ]))))
    
    // Media
    
    static let (mediaItem, mediaItemActions) = makeActions(itemType: .outgoingMedia)
    static let (mediaItemWithCaption, mediaItemWithCaptionActions) = makeActions(itemType: .outgoingMediaWithCaption)

    static var previews: some View {
        TimelineItemMenu(item: item, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Normal")
        
        TimelineItemMenu(item: item, actions: actions)
            .environmentObject(viewModel.context)
            .environment(\._accessibilityShowButtonShapes, true)
            .previewDisplayName("Button shapes")
        
        TimelineItemMenu(item: backupItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Authenticity")
        
        TimelineItemMenu(item: unsignedItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Unsigned")
        
        TimelineItemMenu(item: unencryptedItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Unencrypted")
        
        TimelineItemMenu(item: unknownFailureItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Unknown failure")
        
        TimelineItemMenu(item: unsignedDevicesItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Unsigned Devices")
        
        TimelineItemMenu(item: ownUnsignedDevicesItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Own Unsigned Devices")
        
        TimelineItemMenu(item: identityChangedItem, actions: actions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Identity Changed")
        
        // Media
        
        TimelineItemMenu(item: mediaItem, actions: mediaItemActions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Media")
        
        TimelineItemMenu(item: mediaItemWithCaption, actions: mediaItemWithCaptionActions)
            .environmentObject(viewModel.context)
            .previewDisplayName("Media with Caption")
    }
    
    static func makeActions(itemType: ItemType = .incomingText,
                            authenticity: EncryptionAuthenticity? = nil,
                            deliveryStatus: TimelineItemDeliveryStatus? = nil) -> (EventBasedTimelineItemProtocol, TimelineItemMenuActions)! {
        guard var item = makeItem(itemType: itemType) else { return nil }
        let provider = TimelineItemMenuActionProvider(timelineItem: item,
                                                      canCurrentUserSendMessage: true,
                                                      canCurrentUserRedactSelf: true,
                                                      canCurrentUserRedactOthers: false,
                                                      canCurrentUserPin: true,
                                                      pinnedEventIDs: [],
                                                      isDM: true,
                                                      isViewSourceEnabled: true,
                                                      areThreadsEnabled: true,
                                                      timelineKind: .live,
                                                      emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings))
        guard let actions = provider.makeActions() else { return nil }
        
        if var textItem = item as? TextRoomTimelineItem {
            if let authenticity {
                textItem.properties.encryptionAuthenticity = authenticity
            }
            
            if let deliveryStatus {
                textItem.properties.deliveryStatus = deliveryStatus
            }
            item = textItem
        }
        
        return (item, actions)
    }
    
    static func makeItem(itemType: ItemType) -> EventBasedTimelineItemProtocol? {
        switch itemType {
        case .incomingText:
            RoomTimelineItemFixtures.singleMessageChunk.first as? EventBasedTimelineItemProtocol
        case .outgoingMedia:
            RoomTimelineItemFixtures.mediaChunk[1] as? EventBasedTimelineItemProtocol
        case .outgoingMediaWithCaption:
            RoomTimelineItemFixtures.mediaChunk[5] as? EventBasedTimelineItemProtocol
        }
    }
}
