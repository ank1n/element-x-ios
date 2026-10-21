// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct StalkChannelInsightsView: View {
    @ObservedObject var service: StalkChannelService
    @StateObject private var model: StalkChannelInsightsModel
    let roomID: String
    @State private var mode = "statistics"
    @State private var days = 7
    @State private var category = ""
    @Environment(\.scenePhase) private var scene
    init(service: StalkChannelService, roomID: String, initialMode: String = "statistics") {
        self.service = service; self.roomID = roomID
        _mode = State(initialValue: initialMode)
        _model = StateObject(wrappedValue: StalkChannelInsightsModel(service: service, roomID: roomID))
    }

    private var allowed: Bool {
        service.snapshots[roomID]?.canAdminister == true
    }

    private var queryID: String {
        "\(mode)-\(days)-\(category)-\(allowed)-\(scene)"
    }

    var body: some View {
        List {
            if allowed {
                Picker(StalkUpdateStrings.text("insights"), selection: $mode) {
                    Text(StalkUpdateStrings.text("statistics")).tag("statistics")
                    Text(StalkUpdateStrings.text("audit")).tag("audit")
                }.pickerStyle(.segmented)
                Picker(StalkUpdateStrings.text("period"), selection: $days) {
                    ForEach([7, 30, 90], id: \.self) { Text("\($0) " + StalkUpdateStrings.text("days")).tag($0) }
                }
                if mode == "audit" {
                    Picker(StalkUpdateStrings.text("category"), selection: $category) {
                        ForEach(["", "publications", "discussion", "members", "settings", "moderation"], id: \.self) { Text(StalkUpdateStrings.text($0.isEmpty ? "all" : $0)).tag($0) }
                    }
                }
                if let result = model.result {
                    Section {
                        Text(StalkUpdateStrings.text("coverage") + " " + stamp(result.coverage.since))
                        Text(StalkUpdateStrings.text("processed") + " " + stamp(result.coverage.processed_at))
                        Text(result.time_zone).font(.caption)
                    }
                    if mode == "statistics", let total = result.totals {
                        Section(StalkUpdateStrings.text("statistics")) {
                            counter("subscribers", result.subscribers); counter("active", total.active)
                            counter("posts", total.posts); counter("comments", total.comments); counter("reactions", total.reactions)
                            counter("joined", total.joined); counter("left", total.left); counter("unclassified", total.unclassified)
                        }
                        Section(StalkUpdateStrings.text("daily")) {
                            ForEach(result.daily ?? []) { row in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.day ?? "—").font(.headline)
                                    if let day = row.day, result.hasCoverage(day: day) {
                                        Text([("posts", row.posts), ("comments", row.comments), ("reactions", row.reactions)].map { StalkUpdateStrings.text($0.0) + ": " + ($0.1.map(String.init) ?? "—") }.joined(separator: " · ")).font(.caption)
                                    } else { Text(StalkUpdateStrings.text("before_coverage")).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    } else if mode == "audit" {
                        ForEach(model.items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(StalkUpdateStrings.text("event_" + item.action)).font(.headline)
                                Text(item.actor).textSelection(.enabled)
                                if let target = item.target, target.hasPrefix("@"), target != item.actor { Text(target).font(.caption) }
                                if let value = item.details.mode { Text(StalkUpdateStrings.text("mode_" + value)).font(.caption) }
                                ForEach(item.details.roles ?? [], id: \.user_id) { role in
                                    Text("\(role.user_id): \(role.before.map(String.init) ?? "—") → \(role.after.map(String.init) ?? "—")").font(.caption)
                                }
                                Text(stamp(item.timestamp)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if model.items.isEmpty { Text(StalkUpdateStrings.text("no_events")) }
                        if result.next != nil, !model.cursorExhausted { Button(StalkUpdateStrings.text("load_more")) { Task { await model.load(mode: mode, days: days, category: category, more: true) } }.disabled(model.busy || model.forbidden) }
                    }
                }
                if model.busy { ProgressView() }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                    if !model.forbidden { Button(L10n.actionRetry) { Task { await model.load(mode: mode, days: days, category: category) } }.disabled(model.busy) }
                }
            } else { Text(StalkUpdateStrings.text("admin_required")) }
        }
        .navigationTitle(StalkUpdateStrings.text("insights"))
        .task(id: queryID) { if scene == .active, allowed { await model.load(mode: mode, days: days, category: category) } else { model.clear() } }
        .onDisappear { model.clear() }
    }

    private func stamp(_ milliseconds: Double) -> String {
        model.result?.formattedTimestamp(milliseconds) ?? "—"
    }

    private func counter(_ key: String, _ value: Int?) -> some View {
        LabeledContent(StalkUpdateStrings.text(key), value: value.map(String.init) ?? "—")
    }
}

enum StalkUpdateStrings {
    static func text(_ key: String) -> String {
        NSLocalizedString("stalk_update_" + key, value: key.hasPrefix("event_") && key != "event_unknown" ? text("event_unknown") : key.hasPrefix("mode_") && key != "mode_unknown" ? text("mode_unknown") : key.replacingOccurrences(of: "_", with: " "), comment: "Native sTalk update")
    }
}
