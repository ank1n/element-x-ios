// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation

struct StalkChannelInsights: Decodable {
    struct Counters: Decodable, Identifiable {
        var day: String?
        var posts: Int?; var comments: Int?; var reactions: Int?; var active: Int?; var joined: Int?; var left: Int?; var unclassified: Int?
        var id: String {
            day ?? "totals"
        }

        var activity: Int? {
            guard let posts, let comments, let reactions else { return nil }; return posts + comments + reactions
        }
    }

    struct Coverage: Decodable { let since: Double; let processed_at: Double; let retention_days: Int? }
    struct Audit: Decodable, Identifiable {
        struct Details: Decodable {
            struct Role: Decodable { let user_id: String; let before: Int?; let after: Int? }
            let mode: String?; let roles: [Role]?; let changed_count: Int?
        }

        let event_id: String; let position: Int; let timestamp: Double; let actor: String; let action: String; let group: String; let target: String?; let details: Details
        var id: String {
            "\(position):\(event_id)"
        }
    }

    let schemaVersion: Int
    let subscribers: Int?
    let time_zone: String
    let days: Int
    let generated_at: Double
    let coverage: Coverage
    let totals: Counters?
    let daily: [Counters]?
    let items: [Audit]?
    let next: String?
    func formattedTimestamp(_ milliseconds: Double, locale: Locale = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = TimeZone(identifier: time_zone)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    func hasCoverage(day: String) -> Bool {
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: time_zone); format.dateFormat = "yyyy-MM-dd"
        return day >= format.string(from: Date(timeIntervalSince1970: coverage.since / 1000))
    }
}

extension StalkChannelService {
    func insights(roomID: String, mode: String, days: Int, category: String = "", before: String? = nil) async throws -> StalkChannelInsights {
        guard ["statistics", "audit"].contains(mode), [7, 30, 90].contains(days), ["", "publications", "discussion", "members", "settings", "moderation"].contains(category) else { throw StalkChannelOperationError.invalid }
        guard let access = await refresh(roomID: roomID), access.canAdminister else { throw StalkChannelError.readOnly }
        let caps = try await currentCapabilities()
        guard caps.insights?.available == true else { throw StalkChannelOperationError.unsupported }
        var query: [URLQueryItem] = [.init(name: "room_id", value: roomID), .init(name: "mode", value: mode), .init(name: "days", value: String(days)), .init(name: "time_zone", value: TimeZone.current.identifier), .init(name: "category", value: category)]
        if let before { query.append(.init(name: "before", value: before)) }
        let data = try await api.request(["_synapse", "client", "stalk_channels", "insights"], query: query)
        guard snapshots[roomID]?.canAdminister == true else { throw StalkChannelError.readOnly }
        let result = try JSONDecoder().decode(StalkChannelInsights.self, from: data)
        guard result.schemaVersion == 1, result.days == days, TimeZone(identifier: result.time_zone) != nil else { throw StalkChannelOperationError.unsupported }
        return result
    }
}

@MainActor final class StalkChannelInsightsModel: ObservableObject {
    @Published private(set) var result: StalkChannelInsights?
    @Published private(set) var items: [StalkChannelInsights.Audit] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var forbidden = false
    let service: StalkChannelService
    let roomID: String
    @Published private(set) var cursorExhausted = false
    private var wasAllowed = false
    private var revision = 0
    private var task: Task<Void, Never>?
    private var observation: AnyCancellable?
    init(service: StalkChannelService, roomID: String) {
        self.service = service; self.roomID = roomID
        observation = service.$snapshots.sink { [weak self] values in
            guard let self else { return }
            let allowed = values[roomID]?.canAdminister == true
            if !allowed { clear() }
            if allowed, !wasAllowed { forbidden = false; error = nil }
            wasAllowed = allowed
        }
    }

    func clear() {
        revision += 1; task?.cancel(); task = nil; result = nil; items = []; busy = false
    }

    func load(mode: String, days: Int, category: String, more: Bool = false) async {
        guard service.snapshots[roomID]?.canAdminister == true else { clear(); return }
        guard !forbidden else { return }
        if more && (busy || result?.next == nil || forbidden) { return }
        let cursor = more ? result?.next : nil
        task?.cancel(); revision += 1; let token = revision
        if !more { result = nil; items = []; cursorExhausted = false }
        busy = true; error = nil; forbidden = false
        let request = Task { [weak self] in
            guard let self else { return }
            defer { if token == revision { busy = false } }
            do {
                let value = try await service.insights(roomID: roomID, mode: mode, days: days, category: category, before: cursor)
                guard !Task.isCancelled, token == revision, service.snapshots[roomID]?.canAdminister == true else { return }
                var seen = Set(items.map(\.id))
                items += (value.items ?? []).filter { seen.insert($0.id).inserted }
                result = value
                if more, value.next == cursor { cursorExhausted = true; error = StalkUpdateStrings.text("load_error") }
            } catch {
                guard !Task.isCancelled, token == revision else { return }
                if let http = error as? StalkNativeHTTPError, [401, 403].contains(http.status) {
                    result = nil; items = []; forbidden = true
                    self.error = StalkUpdateStrings.text(http.status == 401 ? "login_required" : "admin_required")
                } else { self.error = error.localizedDescription }
            }
        }
        task = request
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }
}
