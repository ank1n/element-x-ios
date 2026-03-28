//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI
import WysiwygComposer

struct RoomAttachmentPicker: View {
    @ObservedObject var context: ComposerToolbarViewModel.Context

    @Environment(\.isEnabled) private var isEnabled
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            CompoundIcon(asset: Asset.Images.composerAttachment, size: .custom(30), relativeTo: .compound.headingLG)
                .scaledPadding(7, relativeTo: .compound.headingLG)
                .foregroundColor(isEnabled ? .compound.iconPrimary : .compound.iconDisabled)
        }
        .buttonStyle(RoomAttachmentPickerButtonStyle())
        .accessibilityLabel(L10n.actionAddToTimeline)
        .accessibilityIdentifier(A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions)
        .sheet(isPresented: $showingPicker) {
            AttachmentPickerSheet(context: context, isPresented: $showingPicker)
                .presentationDetents([.height(200)])
                .presentationCornerRadius(20)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(UIColor.systemBackground))
        }
    }
}

// MARK: - Custom Sheet

private struct AttachmentPickerSheet: View {
    @ObservedObject var context: ComposerToolbarViewModel.Context
    @Binding var isPresented: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            attachmentButton(icon: "camera.fill",
                             color: .orange,
                             title: SL10n.attachCamera) {
                isPresented = false
                context.send(viewAction: .attach(.camera))
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerCamera)

            attachmentButton(icon: "photo.fill",
                             color: .purple,
                             title: SL10n.attachGallery) {
                isPresented = false
                context.send(viewAction: .attach(.photoLibrary))
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerPhotoLibrary)

            attachmentButton(icon: "doc.fill",
                             color: StalkTheme.accent,
                             title: SL10n.attachFile) {
                isPresented = false
                context.send(viewAction: .attach(.file))
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerDocuments)

            if context.viewState.isLocationSharingEnabled {
                attachmentButton(icon: "location.fill",
                                 color: .green,
                                 title: SL10n.attachLocation) {
                    isPresented = false
                    context.send(viewAction: .attach(.location))
                }
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerLocation)
            }

            attachmentButton(icon: "chart.bar.fill",
                             color: .cyan,
                             title: SL10n.attachPoll) {
                isPresented = false
                context.send(viewAction: .attach(.poll))
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerPoll)

            attachmentButton(icon: "textformat",
                             color: .pink,
                             title: SL10n.attachFormat) {
                isPresented = false
                context.send(viewAction: .enableTextFormatting)
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerTextFormatting)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func attachmentButton(icon: String, color: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 50, height: 50)

                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(color)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RoomAttachmentPickerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? .compound.bgActionPrimaryPressed : .compound.bgActionPrimaryRest)
    }
}

struct RoomAttachmentPicker_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ComposerToolbarViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                                    wysiwygViewModel: WysiwygComposerViewModel(),
                                                    completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init()),
                                                    mediaProvider: MediaProviderMock(configuration: .init()),
                                                    mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                                    appSettings: ServiceLocator.shared.settings,
                                                    analyticsService: ServiceLocator.shared.analytics,
                                                    composerDraftService: ComposerDraftServiceMock(.init()))

    static var previews: some View {
        RoomAttachmentPicker(context: viewModel.context)
    }
}
