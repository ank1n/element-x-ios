//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// sTalk: determine if this outgoing message is read by checking whether
/// any message at or after this one has read receipts from others.
/// In Matrix, a read receipt on message N means everything up to N is read.
@MainActor
private func isMessageReadByOthers(timelineItem: EventBasedTimelineItemProtocol,
                                   context: TimelineViewModel.Context) -> Bool {
    guard timelineItem.isOutgoing else { return false }
    let ownUserID = context.viewState.ownUserID
    if timelineItem.properties.orderedReadReceipts.contains(where: { $0.userID != ownUserID }) {
        return true
    }
    let viewStates = context.viewState.timelineState.itemViewStates
    guard let myIndex = viewStates.firstIndex(where: { $0.identifier == timelineItem.id }) else { return false }
    for i in (myIndex + 1)..<viewStates.count {
        if let eventItem = viewStates[i].type.eventBasedItem,
           eventItem.properties.orderedReadReceipts.contains(where: { $0.userID != ownUserID }) {
            return true
        }
    }
    return false
}

extension View {
    /// Adds the send info (timestamp along indicators for edits and delivery/encryption issues) for the given timeline item to this view.
    func timelineItemSendInfo(timelineItem: EventBasedTimelineItemProtocol,
                              adjustedDeliveryStatus: TimelineItemDeliveryStatus?,
                              context: TimelineViewModel.Context) -> some View {
        modifier(TimelineItemSendInfoModifier(sendInfo: .init(timelineItem: timelineItem,
                                                              adjustedDeliveryStatus: adjustedDeliveryStatus,
                                                              enableKeyShareOnInvite: context.viewState.enableKeyShareOnInvite,
                                                              ownUserID: context.viewState.ownUserID,
                                                              isReadByOthers: isMessageReadByOthers(timelineItem: timelineItem, context: context)),
                                              context: context))
    }
}

/// Adds the send info to a view with the correct layout.
private struct TimelineItemSendInfoModifier: ViewModifier {
    let sendInfo: TimelineItemSendInfo
    let context: TimelineViewModel.Context
    
    var layout: AnyLayout {
        switch sendInfo.layoutType {
        case .horizontal(let spacing):
            AnyLayout(HStackLayout(alignment: .bottom, spacing: spacing))
        case .vertical(let spacing):
            AnyLayout(GridLayout(alignment: .leading, verticalSpacing: spacing))
        case .overlay:
            AnyLayout(ZStackLayout(alignment: .bottomTrailing))
        }
    }
    
    func body(content: Content) -> some View {
        layout {
            content
            
            TimelineItemSendInfoLabel(sendInfo: sendInfo)
                .contentShape(.rect)
                // Tap gesture to avoid the message being detected as a button by VoiceOver
                // (and the action shows a description that is already read to the user).
                .onTapGesture {
                    guard sendInfo.status != nil else { return }
                    context.send(viewAction: .itemSendInfoTapped(itemID: sendInfo.itemID))
                }
        }
    }
}

/// The label shown for a timeline item with info about it's timestamp and various other indicators.
private struct TimelineItemSendInfoLabel: View {
    let sendInfo: TimelineItemSendInfo
    
    var statusIcon: KeyPath<CompoundIcons, Image>? {
        switch sendInfo.status {
        case .sendingFailed: \.errorSolid
        case .encryptionAuthenticity(let authenticity): authenticity.icon
        case .encryptionForwarder: \.info
        case .none: nil
        }
    }
    
    var statusIconAccessibilityLabel: String? {
        switch sendInfo.status {
        case .sendingFailed: L10n.commonSendingFailed
        case .encryptionAuthenticity(let authenticity): authenticity.message
        case .encryptionForwarder(let forwarder): forwarder.message
        case .none: nil
        }
    }
    
    var body: some View {
        switch sendInfo.layoutType {
        case .overlay(capsuleStyle: true):
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.compound.bgSubtleSecondary)
                .cornerRadius(10)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
        case .horizontal, .overlay(capsuleStyle: false):
            content
                .padding(.bottom, -4)
        case .vertical:
            GridRow {
                content
                    .gridColumnAlignment(.trailing)
            }
        }
    }
    
    var content: some View {
        HStack(spacing: 4) {
            Text(sendInfo.localizedString)

            if let statusIcon {
                CompoundIcon(statusIcon, size: .xSmall, relativeTo: .compound.bodyXS)
                    .accessibilityLabel(statusIconAccessibilityLabel ?? "")
                    .accessibilityHidden(statusIconAccessibilityLabel == nil)
            }

            // sTalk: inline delivery checkmarks (Telegram-style)
            if let checkmark = sendInfo.deliveryCheckmark {
                switch checkmark {
                case .sending:
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.compound.iconSecondary)
                case .sent:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.compound.iconSecondary)
                case .read:
                    HStack(spacing: -3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(.compound.iconAccentTertiary)
                }
            }
        }
        .font(.compound.bodyXS)
        .foregroundStyle(sendInfo.foregroundStyle)
    }
}

/// All the data needed to render a timeline item's send info label.
private struct TimelineItemSendInfo {
    enum Status {
        case sendingFailed
        case encryptionAuthenticity(EncryptionAuthenticity)
        case encryptionForwarder(TimelineItemKeyForwarder)
    }

    /// sTalk: delivery checkmark status shown inline with timestamp
    enum DeliveryCheckmark {
        case sending // circle
        case sent // single gray ✓
        case read // double blue ✓✓
    }

    /// Describes how the content and the send info should be arranged inside a bubble
    enum LayoutType {
        case horizontal(spacing: CGFloat = 4)
        case vertical(spacing: CGFloat = 4)
        case overlay(capsuleStyle: Bool)
    }

    let itemID: TimelineItemIdentifier
    let localizedString: String
    var status: Status?
    var deliveryCheckmark: DeliveryCheckmark?
    let layoutType: LayoutType
    
    var foregroundStyle: Color {
        switch status {
        case .sendingFailed:
            .compound.textCriticalPrimary
        case .encryptionAuthenticity(let authenticity):
            authenticity.foregroundStyle
        case .encryptionForwarder:
            .compound.textSecondary
        case .none:
            .compound.textSecondary
        }
    }
}

private extension TimelineItemSendInfo {
    init(timelineItem: EventBasedTimelineItemProtocol, adjustedDeliveryStatus: TimelineItemDeliveryStatus?, enableKeyShareOnInvite: Bool, ownUserID: String? = nil, isReadByOthers: Bool = false) {
        itemID = timelineItem.id
        localizedString = timelineItem.localizedSendInfo

        status = if case .sendingFailed = adjustedDeliveryStatus {
            .sendingFailed
        } else if let authenticity = timelineItem.properties.encryptionAuthenticity {
            .encryptionAuthenticity(authenticity)
        } else if enableKeyShareOnInvite, let forwarder = timelineItem.properties.encryptionForwarder {
            .encryptionForwarder(forwarder)
        } else {
            nil
        }

        // sTalk: compute delivery checkmark for outgoing messages
        if timelineItem.isOutgoing {
            switch adjustedDeliveryStatus {
            case .sending:
                deliveryCheckmark = .sending
            case .sendingFailed:
                deliveryCheckmark = nil
            case .sent, .none:
                deliveryCheckmark = isReadByOthers ? .read : .sent
            }
        } else {
            deliveryCheckmark = nil
        }
        
        layoutType = switch timelineItem {
        case is TextBasedRoomTimelineItem:
            .overlay(capsuleStyle: false)
        case let message as EventBasedMessageTimelineItemProtocol:
            switch message {
            case is ImageRoomTimelineItem, is VideoRoomTimelineItem:
                .overlay(capsuleStyle: !message.hasMediaCaption)
            case is AudioRoomTimelineItem, is FileRoomTimelineItem:
                // swiftlint:disable:next void_function_in_ternary
                message.hasMediaCaption ? .overlay(capsuleStyle: false) : .horizontal(spacing: 0) // No spacing as the content already contains it.
            case let locationTimelineItem as LocationRoomTimelineItem:
                .overlay(capsuleStyle: locationTimelineItem.content.geoURI != nil)
            default:
                .horizontal()
            }
        case is StickerRoomTimelineItem:
            .overlay(capsuleStyle: true)
        case is PollRoomTimelineItem:
            .vertical(spacing: 16)
        default:
            .horizontal()
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

private extension TimelineItemKeyForwarder {
    static var test: TimelineItemKeyForwarder {
        TimelineItemKeyForwarder(id: "@alice:matrix.org", displayName: "alice")
    }
}

// MARK: - Previews

struct TimelineItemSendInfoLabel_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 16) {
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .sendingFailed,
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionAuthenticity(.unsignedDevice(color: .red)),
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionAuthenticity(.notGuaranteed(color: .gray)),
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionAuthenticity(.sentInClear(color: .red)),
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionForwarder(.test),
                                                      layoutType: .horizontal()))
        }
    }
}
