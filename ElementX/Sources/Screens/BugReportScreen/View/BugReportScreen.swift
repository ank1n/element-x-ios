//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import PhotosUI
import SwiftUI

struct BugReportScreen: View {
    @State private var selectedScreenshot: PhotosPickerItem?
    
    @Bindable var context: BugReportScreenViewModel.Context
    
    var canSendLogFiles: Bool {
        context.viewState.canSendLogFiles
    }

    var photosPickerTitle: String {
        context.viewState.screenshot == nil ? L10n.screenBugReportAttachScreenshot : L10n.screenBugReportEditScreenshot
    }
    
    var body: some View {
        Form {
            tabPickerSection
            if context.selectedTab == .myRequests {
                myRequestsSection
            } else {
                textFieldSection
                attachScreenshotSection
                sendLogsSection
                canContactSection
            }
        }
        .disabled(context.viewState.shouldDisableInteraction)
        .scrollDismissesKeyboard(.immediately)
        .compoundList()
        .navigationTitle(L10n.commonReportAProblem)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .interactiveDismissDisabled()
        .onChange(of: context.selectedTab) { _, tab in
            if tab == .myRequests {
                context.send(viewAction: .loadMyRequests)
            }
        }
        .sheet(isPresented: $context.isShowingRequestDetail) {
            if let detail = context.viewState.selectedRequest {
                FeedbackRequestDetailView(detail: detail)
            }
        }
        .onChange(of: selectedScreenshot) { _, newItem in
            Task {
                guard let data = try? await newItem?.loadTransferable(type: Data.self),
                      let image = UIImage(data: data)
                else {
                    return
                }
                context.send(viewAction: .attachScreenshot(image))
            }
        }
    }
    
    // MARK: STALK-1603 — обратная связь, как в вебе

    private var tabPickerSection: some View {
        Section {
            Picker("", selection: $context.selectedTab) {
                Text(NSLocalizedString("stalk_feedback_tab_bug", tableName: "Localizable", value: "Ошибка", comment: "Feedback tab: bug")).tag(BugReportScreenTab.bug)
                Text(NSLocalizedString("stalk_feedback_tab_feature", tableName: "Localizable", value: "Предложение", comment: "Feedback tab: feature request")).tag(BugReportScreenTab.feature)
                Text(NSLocalizedString("stalk_feedback_tab_mine", tableName: "Localizable", value: "Мои заявки", comment: "Feedback tab: my requests")).tag(BugReportScreenTab.myRequests)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var myRequestsSection: some View {
        Section {
            if let error = context.viewState.myRequestsError {
                Text(error)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textCriticalPrimary)
            } else if let items = context.viewState.myRequests {
                if items.isEmpty {
                    Text(NSLocalizedString("stalk_feedback_mine_empty", tableName: "Localizable", value: "Обращений пока нет", comment: "No feedback requests yet"))
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                } else {
                    ForEach(items) { item in
                        Button { context.send(viewAction: .openRequest(id: item.id)) } label: {
                            FeedbackRequestCard(item: item)
                        }
                        .disabled(item.unavailable == true)
                    }
                }
            } else if context.viewState.isLoadingMyRequests {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .refreshable { context.send(viewAction: .loadMyRequests) }
    }

    private var textFieldSection: some View {
        Section {
            ListRow(label: .plain(title: L10n.screenBugReportEditorPlaceholder),
                    kind: .textField(text: $context.reportText, axis: .vertical))
                .lineLimit(4, reservesSpace: true)
                .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.report)
        } footer: {
            Text(L10n.screenBugReportEditorDescription)
                .compoundListSectionFooter()
        }
    }
    
    private var sendLogsSection: some View {
        Section {
            if canSendLogFiles {
                ListRow(label: .plain(title: L10n.screenBugReportIncludeLogs),
                        kind: .toggle($context.sendingLogsEnabled))
                    .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.sendLogs)
            }
            ListRow(label: .plain(title: L10n.screenBugReportViewLogs),
                    kind: .navigationLink { context.send(viewAction: .viewLogs) })
                .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.sendLogs)
        } footer: {
            if canSendLogFiles {
                Text(L10n.screenBugReportLogsDescription)
                    .compoundListSectionFooter()
            } else {
                Label(L10n.screenBugReportIncludeLogsError, icon: \.errorSolid, iconSize: .xSmall, relativeTo: .compound.bodySM)
                    .foregroundStyle(.compound.textCriticalPrimary)
                    .compoundListSectionFooter()
            }
        }
    }

    private var canContactSection: some View {
        Section {
            ListRow(label: .plain(title: L10n.screenBugReportContactMeTitle),
                    kind: .toggle($context.canContact))
                .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.canContact)
        } footer: {
            Text(L10n.screenBugReportContactMe)
                .compoundListSectionFooter()
        }
    }

    private var attachScreenshotSection: some View {
        Section {
            ListRow(kind: .custom {
                PhotosPicker(selection: $selectedScreenshot,
                             matching: .screenshots,
                             photoLibrary: .shared()) {
                    ListRowLabel.plain(title: photosPickerTitle)
                }
            })
            .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.attachScreenshot)
        } footer: {
            if let screenshot = context.viewState.screenshot {
                Image(uiImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100)
                    .cornerRadius(4)
                    .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.screenshot)
                    .accessibilityLabel(L10n.screenBugReportA11yScreenshot)
                    .overlay(alignment: .topTrailing) {
                        Button { context.send(viewAction: .removeScreenshot) } label: {
                            CompoundIcon(\.close, size: .small, relativeTo: .compound.bodyMD)
                                .foregroundStyle(.compound.iconSecondary)
                                .background {
                                    Circle().fill(.compound.bgCanvasDefaultLevel1)
                                }
                        }
                        .offset(x: 10, y: -10)
                        .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.removeScreenshot)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
            }
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if context.viewState.isModallyPresented {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.actionCancel) {
                    context.send(viewAction: .cancel)
                }
                .accessibilityIdentifier(A11yIdentifiers.bugReportScreen.cancel)
            }
        }
        
        ToolbarItem(placement: .confirmationAction) {
            Button(L10n.actionSend) {
                context.send(viewAction: .submit)
            }
            .disabled(context.reportText.count < 5)
            .disabled(context.viewState.shouldDisableInteraction)
            .opacity(context.selectedTab == .myRequests ? 0 : 1)
        }
    }
}

// MARK: - STALK-1603: «Мои заявки»

/// Статус обращения по группе состояния TrackIT — как в вебе.
private func feedbackStateColor(_ group: String?) -> Color {
    switch group {
    case "completed": .compound.textSuccessPrimary
    case "cancelled": .compound.textSecondary
    case "started": .compound.textActionAccent
    default: .compound.textPrimary
    }
}

private func feedbackKindTitle(_ kind: String?) -> String {
    kind == "feature"
        ? NSLocalizedString("stalk_feedback_tab_feature", tableName: "Localizable", value: "Предложение", comment: "Feedback tab: feature request")
        : NSLocalizedString("stalk_feedback_tab_bug", tableName: "Localizable", value: "Ошибка", comment: "Feedback tab: bug")
}

/// Дата из ISO 8601 сервера — коротко, в локали устройства.
private func feedbackDate(_ string: String?) -> String? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: string) ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }()
    return date?.formatted(date: .abbreviated, time: .shortened) ?? string
}

private struct FeedbackRequestCard: View {
    let item: FeedbackRequestsService.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text([item.key, feedbackKindTitle(item.kind)].compactMap { $0 }.joined(separator: " · "))
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textSecondary)
                Spacer()
                if let stateName = item.state?.name {
                    Text(stateName)
                        .font(.compound.bodySMSemibold)
                        .foregroundStyle(feedbackStateColor(item.state?.group))
                }
            }
            Text(item.title ?? "—")
                .font(.compound.bodyLGSemibold)
                .foregroundStyle(.compound.textPrimary)
                .multilineTextAlignment(.leading)
            if let reply = item.lastReply, let text = reply.text {
                Text("\(reply.author ?? ""): \(text)")
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textSecondary)
                    .lineLimit(2)
            }
            if let date = feedbackDate(item.updatedAt ?? item.createdAt) {
                Text(date)
                    .font(.compound.bodyXS)
                    .foregroundStyle(.compound.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FeedbackRequestDetailView: View {
    let detail: FeedbackRequestsService.Detail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(feedbackKindTitle(detail.kind))
                                .font(.compound.bodySM)
                                .foregroundStyle(.compound.textSecondary)
                            Spacer()
                            if let stateName = detail.state?.name {
                                Text(stateName)
                                    .font(.compound.bodySMSemibold)
                                    .foregroundStyle(feedbackStateColor(detail.state?.group))
                            }
                        }
                        if let text = detail.text, !text.isEmpty {
                            Text(text)
                                .font(.compound.bodyMD)
                                .foregroundStyle(.compound.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let comments = detail.comments, !comments.isEmpty {
                    Section(NSLocalizedString("stalk_feedback_replies", tableName: "Localizable", value: "Ответы", comment: "Feedback request replies section")) {
                        ForEach(comments) { comment in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(comment.author ?? "")
                                        .font(.compound.bodySMSemibold)
                                        .foregroundStyle(comment.mine == true ? .compound.textActionAccent : .compound.textPrimary)
                                    Spacer()
                                    if let date = feedbackDate(comment.createdAt) {
                                        Text(date)
                                            .font(.compound.bodyXS)
                                            .foregroundStyle(.compound.textSecondary)
                                    }
                                }
                                Text(comment.text ?? "")
                                    .font(.compound.bodyMD)
                                    .foregroundStyle(.compound.textPrimary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .compoundList()
            .navigationTitle(detail.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Previews

struct BugReportScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        NavigationStack {
            let clientProxy = ClientProxyMock(.init(userID: "@mock:client.com", roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
            BugReportScreen(context: BugReportScreenViewModel(bugReportService: BugReportServiceMock(.init()),
                                                              clientProxy: clientProxy,
                                                              screenshot: nil,
                                                              isModallyPresented: false).context)
        }
        .previewDisplayName("Without Screenshot")
        
        NavigationStack {
            let clientProxy = ClientProxyMock(.init(userID: "@mock:client.com", roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
            BugReportScreen(context: BugReportScreenViewModel(bugReportService: BugReportServiceMock(.init()),
                                                              clientProxy: clientProxy,
                                                              screenshot: Asset.Images.appLogo.image,
                                                              isModallyPresented: false).context)
        }
        .previewDisplayName("With Screenshot")
    }
}
