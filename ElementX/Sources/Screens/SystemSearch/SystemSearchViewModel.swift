// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import CryptoKit
import Foundation

@MainActor
final class SystemSearchViewModel: ObservableObject {
    @Published var conditions = SystemSearchConditions() {
        didSet { if conditions != oldValue { generation += 1; task?.cancel(); loading = false; hasMore = false; viewType = nil; completeSnapshot = nil } }
    }

    @Published private(set) var hits: [SystemSearchHit] = []
    @Published private(set) var facets: [SystemSearchResponse.Facet] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var viewType: String?
    @Published private(set) var pinned: [SystemSearchConditions] = []
    @Published private(set) var recent: [SystemSearchConditions] = []
    @Published var senderQuery = ""
    @Published private(set) var senders: [(id: String, name: String)] = []
    let service: SystemSearchService
    let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var generation = 0
    private var offset = 0
    private var completeSnapshot: (Date, [SystemSearchHit])?
    private var submitted: SystemSearchConditions?
    private var lastResultAt: Date?
    private var key: String {
        "stalk.search.saved.v1." + SHA256.hash(data: Data((service.base + "\n" + service.client.userID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Saved: Codable { let version: Int; let pinned: [SystemSearchConditions]; let recent: [SystemSearchConditions] }

    init(client: ClientProxyProtocol, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        service = SystemSearchService(client: client, session: session); self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 {
            pinned = Array(saved.pinned.filter(\.valid).prefix(50)); recent = Array(saved.recent.filter(\.valid).prefix(12))
        }
    }

    func updateQuery(_ value: String) {
        guard value != conditions.query else { return }
        conditions.query = value
        conditions.topic = nil; conditions.expand = []; conditions.mode = "basic"
    }

    func restore(_ value: SystemSearchConditions) {
        conditions = value; search()
    }

    func pin() {
        guard conditions.valid, conditions.query.count >= 2 else { return }
        if pinned.contains(where: { $0.query == conditions.query }) { pinned.removeAll { $0.query == conditions.query } }
        else { pinned.insert(conditions, at: 0); pinned = Array(pinned.prefix(50)) }
        save()
    }

    func forgetRecent() {
        recent = []; save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(Saved(version: 1, pinned: pinned, recent: recent)), forKey: key)
    }

    func resume() {
        if let lastResultAt, Date().timeIntervalSince(lastResultAt) > 30, conditions.canSearch { search() }
    }

    func stop() {
        task?.cancel(); senderTask?.cancel(); loading = false
    }

    func lookupSenders() {
        senderTask?.cancel()
        let query = senderQuery
        senderTask = Task {
            do { let found = try await service.senders(query: query); guard !Task.isCancelled, senderQuery == query else { return }; senders = found }
            catch { if !Task.isCancelled { self.error = NSLocalizedString("Не удалось загрузить отправителей. Повторите запрос.", comment: "System search notice or error") } }
        }
    }

    func search(smart: Bool = false) {
        task?.cancel(); generation += 1; let revision = generation
        error = nil; notice = nil; loading = true; hasMore = false; viewType = nil; completeSnapshot = nil
        let snapshot = conditions
        guard snapshot.canSearch else { hits = []; loading = false; return }
        task = Task {
            defer { if generation == revision { loading = false } }
            do {
                if smart {
                    let plan = try await service.plan(snapshot)
                    guard !Task.isCancelled, conditions == snapshot else { return }
                    task = nil; conditions = plan; search(); return
                }
                let response = try await service.search(snapshot)
                guard !Task.isCancelled, revision == generation else { return }
                submitted = snapshot; hits = response.results; facets = response.facets ?? []; total = response.total + (response.semantic?.tail ?? 0)
                lastResultAt = Date()
                offset = response.results.count
                hasMore = !response.results.isEmpty && offset < response.total + (response.semantic?.tail ?? 0) && offset <= 10000
                if !hasMore, hits.count == response.total + (response.semantic?.tail ?? 0), response.semantic?.error == nil { completeSnapshot = (Date(), hits) }
                var notices: [String] = []
                if response.queryTruncated == true { notices.append(String(format: NSLocalizedString("stalk_search_query_truncated", comment: "Search query truncated notice: number of words used"), Int64(response.wordsUsed ?? 0))) }
                if let identity = response.scope?.plane_identity, ["не сопоставлена", "unlinked", "unmatched"].contains(identity) {
                    notices.append(NSLocalizedString("Учётная запись TrackIT не связана. Часть задач и страниц может быть недоступна.", comment: "System search notice or error"))
                }
                if response.semantic?.error != nil { notices.append(NSLocalizedString("Смысловой поиск временно недоступен. Показаны результаты по словам.", comment: "System search notice or error")) }
                notice = notices.isEmpty ? nil : notices.joined(separator: "\n")
                recent.removeAll { $0.query == snapshot.query }; recent.insert(snapshot, at: 0); recent = Array(recent.prefix(12)); save()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func browse(_ type: String?) {
        task?.cancel(); generation += 1; let revision = generation; viewType = type; error = nil
        if let completeSnapshot, Date().timeIntervalSince(completeSnapshot.0) < 30 {
            hits = completeSnapshot.1.filter { type == nil || $0.facetKind == type }; hasMore = false; return
        }
        guard let submitted, conditions == submitted else { search(); return }
        loading = true
        task = Task {
            defer { if generation == revision { loading = false } }
            do {
                let response = try await service.search(submitted, viewType: type)
                guard !Task.isCancelled, generation == revision else { return }
                hits = response.results; offset = response.results.count
                let count = type.flatMap { wanted in facets.first { $0.entity_type == wanted }?.count } ?? response.total
                hasMore = !hits.isEmpty && offset < count
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func more() {
        guard hasMore, !loading, let submitted, conditions == submitted else { return }
        task?.cancel(); let revision = generation; loading = true
        let nextOffset = offset; let selected = viewType
        task = Task {
            defer { if generation == revision { loading = false } }
            do {
                let response = try await service.search(submitted, offset: nextOffset, viewType: selected)
                guard !Task.isCancelled, generation == revision else { return }
                let known = Set(hits.map(\.id)); hits += response.results.filter { !known.contains($0.id) }
                offset += response.results.count
                let count = selected.flatMap { wanted in facets.first { $0.entity_type == wanted }?.count } ?? response.total + (response.semantic?.tail ?? 0)
                hasMore = !response.results.isEmpty && offset < count && offset <= 10000
                if selected == nil, !hasMore, hits.count == response.total + (response.semantic?.tail ?? 0), response.semantic?.error == nil { completeSnapshot = (Date(), hits) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
