// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct StalkMeetingRoomSummaryView: View {
    let service: StalkMeetingRoomSummaryService
    let roomID: String
    var mediaProvider: MediaProviderProtocol?
    @State private var summary: StalkMeetingRoomSummary?
    @State private var loaded = false
    @State private var failed = false
    @State private var denied = false
    @Environment(\.scenePhase) private var scene
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary { details(summary) }
            else { Text(placeholder).font(.subheadline).foregroundStyle(.secondary) }
        }
        .task(id: "\(roomID):\(scene)") { await refreshVisible() }
        .onChange(of: roomID) { summary = nil; loaded = false; failed = false; denied = false }
    }

    private var placeholder: String {
        StalkUpdateStrings.text(failed ? "history_unavailable" : loaded ? "start_not_saved" : "loading_meeting")
    }

    @ViewBuilder private func details(_ value: StalkMeetingRoomSummary) -> some View {
        Text(timeLabel(value)).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
        if value.historyPartial { Text(StalkUpdateStrings.text("history_partial")).font(.caption).foregroundStyle(.secondary) }
        if value.people.isEmpty {
            Text(StalkUpdateStrings.text(value.partial ? "people_unavailable" : "people_not_saved")).font(.caption).foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { people(value); names(value) }
                names(value)
            }
            .accessibilityLabel(value.people.map(\.name).joined(separator: ", "))
        }
    }

    private func timeLabel(_ value: StalkMeetingRoomSummary) -> String {
        var result = value.recordingOnly ? StalkUpdateStrings.text("recording") + " · " : ""
        result += value.started.formatted(date: .abbreviated, time: .shortened)
        if let seconds = value.duration { result += " · " + duration(seconds) }
        return result
    }

    @MainActor private func refreshVisible() async {
        guard scene == .active, !denied else { return }
        repeat {
            do { summary = try await service.latest(roomID: roomID); loaded = true; failed = false }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }; summary = nil; failed = true
                if let http = error as? StalkNativeHTTPError, [401, 403].contains(http.status) { denied = true; return }
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        } while !Task.isCancelled
    }

    private func names(_ value: StalkMeetingRoomSummary) -> some View {
        var result = String(value.people.count) + (value.partial ? "+" : "") + " · "
        result += value.people.prefix(2).map(\.name).joined(separator: ", ")
        if value.people.count > 2 { result += " +" + String(value.people.count - 2) }
        return Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }

    private func people(_ value: StalkMeetingRoomSummary) -> some View {
        HStack(spacing: -3) {
            ForEach(value.people.prefix(3)) { person in
                LoadableAvatarImage(url: nil, name: person.name, contentID: person.id, avatarSize: .custom(18), mediaProvider: mediaProvider).accessibilityHidden(true)
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter(); formatter.allowedUnits = seconds < 60 ? [.second] : seconds < 3600 ? [.minute] : [.hour, .minute]; formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(1, seconds)) ?? "—"
    }
}
