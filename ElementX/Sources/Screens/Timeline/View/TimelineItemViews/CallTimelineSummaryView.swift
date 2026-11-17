import Combine

// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct CallTimelineSummaryView: View {
    @State private var detailTask: Task<Void, Never>?
    @State private var detail: CallTimelineRecord?
    @State private var loading = false
    @State private var error: String?
    let marker: CallInitiateMarker
    @ObservedObject var service: CallTimelineSummaryService
    /// Не `scenePhase`: в ячейке ленты (UIHostingConfiguration) он не приходит и всегда не `.active` —
    /// запрос итогов не уходил ни разу, карточки не было. Берём состояние самого приложения.
    @State private var appActive = UIApplication.shared.applicationState == .active
    var body: some View {
        Group {
            if let record = service.summary(for: marker) {
                VStack(alignment: .leading, spacing: 8) {
                    CallTimelineRecordFields(record: record, names: service.names, profiles: service.profiles, mediaProvider: service.userSession?.mediaProvider)
                    Button {
                        guard !loading else { return }
                        loading = true; error = nil
                        detailTask = Task {
                            defer { loading = false }
                            do {
                                let result = try await service.detail(record.call_key)
                                guard !Task.isCancelled else { return }
                                detail = result
                            } catch { if !Task.isCancelled { self.error = L10n.commonSomethingWentWrong } }
                        }
                    } label: {
                        Label(StalkChannelStrings.text("open_call"), systemImage: "info.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(loading)
                    if loading { ProgressView() }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            } else {
                // Пустой Group внутри VStack под плашкой звонка не даёт SwiftUI ни одного вида, и .task
                // ниже не запускается: итоги не запрашивались, карточка не появлялась никогда.
                Color.clear.frame(height: 0)
            }
        }
        .onDisappear { detailTask?.cancel(); detailTask = nil }
        .onChange(of: service.accessRevision) { detailTask?.cancel(); detail = nil; loading = false }
        .onChange(of: marker) { detailTask?.cancel(); detailTask = nil; detail = nil; loading = false }
        .sheet(item: $detail) { record in CallTimelineDetailSheet(record: record, service: service, video: marker.video) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in appActive = false }
        .task(id: "\(appActive)-\(service.reconnectRevision)") {
            if appActive { await service.observe(marker) }
        }
    }
}

struct CallTimelineRecordFields: View {
    let record: CallTimelineRecord
    let names: [String: String]
    var profiles: [String: UserProfileProxy] = [:]
    var mediaProvider: MediaProviderProtocol?
    @State private var selectedPeople = ""
    @State private var showingPeople = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let duration = record.duration_s, duration.isFinite, duration > 0 {
                Label(String(format: "%d:%02d", Int(min(duration, 31_536_000)) / 60, Int(min(duration, 31_536_000)) % 60), systemImage: "clock")
            }
            let people = record.uniqueParticipants
            if !people.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(people.prefix(12)), id: \.self) { id in
                            Button {
                                selectedPeople = names[id] ?? id; showingPeople = true
                            } label: {
                                LoadableAvatarImage(url: mediaProvider == nil ? nil : profiles[id]?.avatarURL,
                                                    name: names[id] ?? id, contentID: id,
                                                    avatarSize: .custom(30), mediaProvider: mediaProvider)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(names[id] ?? id)
                        }
                        if people.count > 12 {
                            Button("+" + String(people.count - 12)) {
                                selectedPeople = people.map { names[$0] ?? $0 }.joined(separator: ", "); showingPeople = true
                            }
                        }
                    }.padding(.vertical, 4)
                }
                .accessibilityLabel(StalkCallCardStrings.people)
                .accessibilityValue(people.map { names[$0] ?? $0 }.joined(separator: ", "))
            }
            if record.recording?.present == true { Label(StalkCallCardStrings.recording, systemImage: "record.circle") }
            if let state = record.transcription?.state, state == "ready" || state == "pending" {
                Label(state == "ready" ? StalkCallCardStrings.ready : StalkCallCardStrings.pending, systemImage: "text.alignleft")
            }
            if let tasks = record.tasks, let total = tasks.total, total >= 0 {
                Label(String(format: StalkCallCardStrings.tasks, total), systemImage: "checklist")
                let groups = tasks.by_group ?? [:]
                let present = ["backlog", "unstarted", "started", "completed", "cancelled", "unknown"].filter { (groups[$0] ?? 0) > 0 }
                if !present.isEmpty {
                    // Статусы заведённых задач — цветными плашками в ряд, как на вебе.
                    CallStatusFlowLayout(spacing: 6) {
                        ForEach(present, id: \.self) { group in
                            let color = StalkCallCardStrings.color(group)
                            HStack(spacing: 5) {
                                Circle().fill(color).frame(width: 8, height: 8)
                                Text(StalkCallCardStrings.group(group) + " " + String(groups[group] ?? 0))
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(color.opacity(0.15), in: Capsule())
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .alert(StalkCallCardStrings.people, isPresented: $showingPeople) {
            Button(L10n.actionClose, role: .cancel) { }
        } message: { Text(selectedPeople) }
    }
}

/// Плашки статусов задач: в ряд, лишние переносятся на следующую строку.
private struct CallStatusFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

enum StalkCallCardStrings {
    static var people: String {
        NSLocalizedString("stalk_call_card_people", comment: "Call participants")
    }

    static func color(_ group: String) -> Color {
        switch group {
        case "backlog": .gray
        case "unstarted": .blue
        case "started": .orange
        case "completed": .green
        case "cancelled": .red
        default: .secondary
        }
    }

    static var recording: String {
        NSLocalizedString("stalk_call_card_recording", comment: "Call recording present")
    }

    static var ready: String {
        NSLocalizedString("stalk_call_card_transcript_ready", comment: "Transcript ready")
    }

    static var pending: String {
        NSLocalizedString("stalk_call_card_transcript_pending", comment: "Transcript pending")
    }

    static var tasks: String {
        NSLocalizedString("stalk_call_card_tasks", comment: "Call task count")
    }

    static func group(_ value: String) -> String {
        NSLocalizedString("stalk_call_card_group_" + value, comment: "Call task status group")
    }
}

private struct CallTimelineDetailSheet: View {
    let record: CallTimelineRecord
    let service: CallTimelineSummaryService
    @StateObject private var model: CallTimelineDetailModel
    @Environment(\.dismiss) private var dismiss
    init(record: CallTimelineRecord, service: CallTimelineSummaryService, video: Bool) {
        self.record = record
        self.service = service
        _model = StateObject(wrappedValue: CallTimelineDetailModel(record: record, service: service, video: video))
    }

    var body: some View {
        Group {
            if CallHistoryItem.uniqueRecordingIDs(record.egress_ids ?? []).isEmpty {
                NavigationStack {
                    ScrollView {
                        CallTimelineRecordFields(record: record, names: service.names, profiles: service.profiles, mediaProvider: service.userSession?.mediaProvider)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(record.title ?? SL10n.callDefault)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
                }
            } else {
                model.navigation.toPresentable()
            }
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
        .onDisappear { model.detail?.process(viewAction: .disappeared) }
    }
}

@MainActor
private final class CallTimelineDetailModel: ObservableObject {
    let navigation = NavigationStackCoordinator()
    let detail: CallDetailScreenViewModel?
    private var token: AnyCancellable?
    init(record: CallTimelineRecord, service: CallTimelineSummaryService, video: Bool) {
        var base = URLComponents(string: service.api.client.homeserver)!
        base.path = "/recording-api"; base.query = nil; base.fragment = nil
        let ids = CallHistoryItem.uniqueRecordingIDs(record.egress_ids ?? [])
        guard !ids.isEmpty else { detail = nil; return }
        var play = base
        play.percentEncodedPath += "/api/recording/play/" + (ids.first?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let call = CallHistoryItem(id: ids.first ?? record.call_key, contactName: record.title ?? SL10n.callDefault,
                                   contactId: record.room_id, callType: video ? .video : .incoming,
                                   timestamp: record.started_at.date ?? Date(), duration: record.duration_s, isMissed: false,
                                   recordingURL: record.recording?.present == true && !ids.isEmpty ? play.url : nil,
                                   attendeeIDs: record.participants, createdTaskCount: record.tasks?.total, callId: record.call_key,
                                   recordingSessionIDs: ids)
        let api = CallHistoryService(baseURL: base.url!, accessTokenProvider: { try service.api.client.matrixAccessToken() },
                                     forceTokenRefresh: { await service.api.client.forceTokenRefresh() })
        let detail = CallDetailScreenViewModel(call: call, callHistoryService: api, mediaProvider: service.userSession?.mediaProvider,
                                               clientProxy: service.api.client)
        self.detail = detail
        navigation.setRootCoordinator(CallTimelineDetailCoordinator(model: detail))
        token = detail.actionsPublisher.sink { [weak self, weak service] action in
            guard let self, let session = service?.userSession else { return }
            if case .openParticipant(let id) = action { CallParticipantPresenter.present(id, session: session, navigation: navigation) }
        }
    }
}

private final class CallTimelineDetailCoordinator: CoordinatorProtocol {
    let model: CallDetailScreenViewModel
    init(model: CallDetailScreenViewModel) {
        self.model = model
    }

    func toPresentable() -> AnyView {
        AnyView(CallDetailScreen(context: model.context, showsCallBack: false))
    }

    func stop() {
        model.process(viewAction: .disappeared)
    }
}
