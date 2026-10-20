// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum StalkChannelStrings {
    static var title: String {
        NSLocalizedString("stalk_channels_title", comment: "Channels")
    }

    static var archived: String {
        NSLocalizedString("stalk_channels_archived", comment: "Archived channel")
    }

    static func text(_ key: String) -> String {
        NSLocalizedString("stalk_channels_" + key, comment: "Channel UI")
    }

    static func role(_ level: Int) -> String {
        if level >= 100 { return text("admin") }
        if level >= 50 { return text("editor") }
        if level == 25 { return text("moderator") }
        return text("reader")
    }
}

struct StalkChannelDirectoryView: View {
    @ObservedObject var service: StalkChannelService
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [StalkChannelDirectoryEntry] = []
    @State private var next: String?
    @State private var loading = false
    @State private var error: String?
    @State private var lookup: StalkChannelDirectoryEntry?
    @State private var showArchives = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(StalkChannelStrings.text("address"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(StalkChannelStrings.text("find")) { Task { await lookupAddress() } }.disabled(loading || query.isEmpty)
                    if let lookup { row(lookup) }
                }
                Section(StalkChannelStrings.text("subscriptions")) {
                    Toggle(StalkChannelStrings.archived, isOn: $showArchives)
                    if service.discoveryFailed {
                        Text(L10n.commonSomethingWentWrong).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.actionRetry) { Task { await service.discover() } }
                    }
                    ForEach(service.joinedChannels.filter { showArchives == service.archivedIDs.contains($0.id) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { row($0) }
                }
                if !showArchives {
                    Section(StalkChannelStrings.text("catalog")) {
                        ForEach(entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.topic.localizedCaseInsensitiveContains(query) }) { row($0) }
                        if next != nil { Button(L10n.actionLoadMore) { Task { await load(reset: false) } }.disabled(loading) }
                    }
                }
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary); Button(L10n.actionRetry) { Task { await load(reset: true) } } }
            }
            .navigationTitle(StalkChannelStrings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
            .task { await service.discover(); await load(reset: true) }
        }
    }

    private func row(_ entry: StalkChannelDirectoryEntry) -> some View {
        Button { dismiss(); open(entry.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "megaphone.fill").foregroundStyle(StalkTheme.accent)
                    .frame(width: 40, height: 40).background(StalkTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).foregroundStyle(.primary)
                    if !entry.topic.isEmpty { Text(entry.topic).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if !entry.joined { Text(StalkChannelStrings.text(entry.requiresApproval ? "request" : "subscribe")).font(.caption) }
                }
            }
        }.buttonStyle(.plain)
    }

    private func lookupAddress() async {
        loading = true; error = nil; lookup = nil
        defer { loading = false }
        do { lookup = try await service.lookup(query) } catch { self.error = L10n.commonSomethingWentWrong }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let response = try await service.directory(since: reset ? nil : next)
            var seen = Set<String>()
            entries = ((reset ? [] : entries) + response.entries).filter { seen.insert($0.id).inserted }
            next = response.next == next && !reset ? nil : response.next
        } catch { self.error = L10n.commonSomethingWentWrong }
    }
}

struct StalkChannelControlsView: View {
    @ObservedObject var service: StalkChannelService
    let roomID: String
    var rootID: String?
    @State private var mode: String?
    @State private var busy = false
    @State private var error: String?
    @State private var userID = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                if let access = service.snapshots[roomID], access.isChannel {
                    Section(StalkChannelStrings.title) {
                        Text(access.roomName)
                        Text(StalkChannelStrings.role(access.level))
                        if access.archived { Text(StalkChannelStrings.archived) }
                    }
                    if let rootID {
                        Section(StalkChannelStrings.text("notifications")) {
                            ForEach(["following", "mentions", "muted"], id: \.self) { value in
                                Button {
                                    Task { await perform { mode = try await service.subscription(roomID: roomID, root: rootID, set: value) } }
                                } label: { HStack { Text(StalkChannelStrings.text(value)); Spacer(); if mode == value { Image(systemName: "checkmark") } } }
                                    .disabled(busy || mode == nil || !access.joined || !access.verified)
                            }
                        }
                        if access.canModerate {
                            Section(StalkChannelStrings.text("moderation")) {
                                Button(StalkChannelStrings.text(access.closed.contains(rootID) ? "reopen" : "close")) {
                                    Task { await perform { try await service.moderate(roomID: roomID, root: rootID, closed: !access.closed.contains(rootID)) } }
                                }.disabled(busy)
                                TextField("@user:server", text: $userID).textInputAutocapitalization(.never).autocorrectionDisabled()
                                VStack(alignment: .leading, spacing: 12) {
                                    Button(StalkChannelStrings.text("block")) { Task { await perform { try await service.blockCommenter(roomID: roomID, userID: userID, blocked: true) } } }
                                    Button(StalkChannelStrings.text("unblock")) { Task { await perform { try await service.blockCommenter(roomID: roomID, userID: userID, blocked: false) } } }
                                }.disabled(busy || !CallSummaryPeople.isUserID(userID))
                            }
                        }
                    } else if access.level >= 100 {
                        StalkChannelAdministrationSections(service: service, roomID: roomID, access: access)
                        if !access.archived { Section(StalkChannelStrings.text("comments")) {
                            Button(StalkChannelStrings.text(access.comments ? "disable_comments" : "enable_comments")) {
                                Task { await perform { try await service.setComments(roomID: roomID, enabled: !access.comments) } }
                            }.disabled(busy)
                        } }
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle(StalkChannelStrings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() } } }
            .task(id: "\(scenePhase)-\(service.subscriptionRevision)") {
                guard scenePhase == .active else { return }
                repeat {
                    _ = await service.refresh(roomID: roomID)
                    if let rootID { do { mode = try await service.subscription(roomID: roomID, root: rootID) } catch { self.error = L10n.commonSomethingWentWrong } }
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                } while !Task.isCancelled
            }
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }
}
