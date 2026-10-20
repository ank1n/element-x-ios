//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ThreadTimelineScreen: View {
    @State private var showChannelControls = false
    @ObservedObject private var context: ThreadTimelineScreenViewModelType.Context
    @ObservedObject private var timelineContext: TimelineViewModelType.Context
    @Environment(\.scenePhase) private var scenePhase
    private let composerToolbar: ComposerToolbar
    
    init(context: ThreadTimelineScreenViewModelType.Context,
         timelineContext: TimelineViewModelType.Context,
         composerToolbar: ComposerToolbar) {
        self.context = context
        self.timelineContext = timelineContext
        self.composerToolbar = composerToolbar
    }
        
    var body: some View {
        TimelineView(timelineContext: timelineContext)
            .background(.compound.bgCanvasDefault)
            .toolbarRole(RoomHeaderView.toolbarRole)
            .navigationTitle(L10n.commonThread)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    context.send(viewAction: .refreshChannelAccess)
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                } while !Task.isCancelled
            }
            .toolbarBackground(.visible, for: .navigationBar) // Fix the toolbar's background.
            .task(id: "\(scenePhase)-\(context.viewState.isChannel)-\(timelineContext.viewState.channelAccess?.joined == true)") {
                if scenePhase == .active, context.viewState.isChannel { await context.viewState.channelService?.watch(roomID: context.viewState.roomID) }
            }
            .sheet(isPresented: $showChannelControls) {
                if let service = context.viewState.channelService {
                    StalkChannelControlsView(service: service, roomID: context.viewState.roomID, rootID: context.viewState.threadRootID)
                }
            }
            .timelineMediaPreview(viewModel: $context.mediaPreviewViewModel)
            .overlay(alignment: .bottomTrailing) {
                TimelineScrollToBottomButton(isVisible: isAtBottomAndLive) {
                    timelineContext.send(viewAction: .scrollToBottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .padding(.top, 8)
                    .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
                    .environmentObject(timelineContext)
                    .environment(\.timelineContext, timelineContext)
                    // Make sure the reply header honours the hideTimelineMedia setting too.
                    .environment(\.shouldAutomaticallyLoadImages, !timelineContext.viewState.hideTimelineMedia)
            }
    }
    
    @ViewBuilder
    private var composer: some View {
        if context.viewState.canSendMessage {
            composerToolbar
        } else {
            ComposerDisabledView()
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // .principal + .primaryAction works better than .navigation leading + trailing
        // as the latter disables interaction in the action button for rooms with long names
        ToolbarItem(placement: .primaryAction) {
            if context.viewState.isChannel {
                Button { showChannelControls = true } label: { Image(systemName: "bell.badge") }
                    .accessibilityLabel(StalkChannelStrings.text("notifications"))
            }
        }
        ToolbarItem(placement: .principal) {
            RoomHeaderView(roomName: L10n.commonThread,
                           roomSubtitle: context.viewState.roomTitle,
                           roomAvatar: context.viewState.roomAvatar,
                           dmRecipientVerificationState: context.viewState.dmRecipientVerificationState,
                           mediaProvider: context.mediaProvider) {
                // There is no action but the iOS 26 designs have it looking like a button.
            }
        }
    }
    
    private var isAtBottomAndLive: Bool {
        timelineContext.isScrolledToBottom && timelineContext.viewState.timelineState.isLive
    }
}
