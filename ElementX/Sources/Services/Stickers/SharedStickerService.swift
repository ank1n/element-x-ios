// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import Combine
import CryptoKit
import Foundation

struct SharedSticker: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let mxc: String
    let mimetype: String
    let size: Int
    let w: Int
    let h: Int
    let animated: Bool
    var thumbnailMxc: String?
    var animatedPreviewMxc: String?

    static func isMXC(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "mxc", let host = url.host, !host.isEmpty,
              url.path.count > 1, url.query == nil, url.fragment == nil else { return false }
        return true
    }

    var isValid: Bool {
        !id.isEmpty && Self.isMXC(mxc) && mimetype == "image/webp" && size >= 0 &&
            (1...512).contains(w) && (1...512).contains(h) &&
            (thumbnailMxc.map(Self.isMXC) ?? true) && (animatedPreviewMxc.map(Self.isMXC) ?? true)
    }

    /// Only clear m.sticker events may replace their display source. Encrypted events retain their encrypted media source.
    static func animatedPreview(from rawJSON: String?, originalMXC: String) -> MediaSourceProxy? {
        guard let rawJSON, let data = rawJSON.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "m.sticker",
              let content = event["content"] as? [String: Any], content["url"] as? String == originalMXC,
              let info = content["info"] as? [String: Any],
              let preview = info["im.stalk.animated_preview_url"] as? String, isMXC(preview),
              let url = URL(string: preview) else { return nil }
        return try? MediaSourceProxy(url: url, mimeType: "image/webp")
    }

    func content(threadRoot: String? = nil) throws -> String {
        var info: [String: Any] = ["mimetype": mimetype, "size": size, "w": w, "h": h,
                                   "org.matrix.msc4230.is_animated": animated]
        if let animatedPreviewMxc { info["im.stalk.animated_preview_url"] = animatedPreviewMxc }
        if let thumbnailMxc { info["thumbnail_url"] = thumbnailMxc }
        var content: [String: Any] = ["body": label, "url": mxc, "info": info]
        if let threadRoot {
            content["m.relates_to"] = ["rel_type": "m.thread", "event_id": threadRoot,
                                       "is_falling_back": true, "m.in_reply_to": ["event_id": threadRoot]]
        }
        return try String(decoding: JSONSerialization.data(withJSONObject: content), as: UTF8.self)
    }
}

struct SharedStickerPack: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let items: [SharedSticker]

    static func decodeCatalogue(_ data: Data) throws -> [Self] {
        struct Catalogue: Decodable { let packs: [Pack] }
        struct Pack: Decodable {
            let value: SharedStickerPack?
            init(from decoder: Decoder) throws {
                value = try? SharedStickerPack(from: decoder)
            }
        }
        var ids = Set<String>()
        return try JSONDecoder().decode(Catalogue.self, from: data).packs.compactMap(\.value).filter {
            !$0.id.isEmpty && ids.insert($0.id).inserted && (1...120).contains($0.items.count) && $0.items.allSatisfy(\.isValid)
        }
    }
}

struct SharedStickerPreferences: Codable, Equatable {
    var favorites: [String] = []
    var recent: [String] = []

    init(favorites: [String] = [], recent: [String] = []) {
        func clean(_ values: [String], limit: Int) -> [String] {
            var seen = Set<String>()
            return Array(values.filter { !$0.isEmpty && $0.count <= 2048 && seen.insert($0).inserted }.prefix(limit))
        }
        self.favorites = clean(favorites, limit: 120)
        self.recent = clean(recent, limit: 10)
    }

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case favorites, recent }
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(favorites: (try? c.decode([String].self, forKey: .favorites)) ?? [],
                  recent: (try? c.decode([String].self, forKey: .recent)) ?? [])
    }

    mutating func record(_ sticker: SharedSticker) {
        self = .init(favorites: favorites, recent: [sticker.mxc] + recent.filter { $0 != sticker.mxc })
    }
}

/// Preferences use the same Matrix account data as web, never a global defaults key.
@MainActor
final class SharedStickerService: ObservableObject {
    @Published private(set) var packs: [SharedStickerPack] = []
    @Published private(set) var preferences = SharedStickerPreferences()
    @Published private(set) var loading = false
    @Published private(set) var sending = false
    @Published private(set) var error: String?
    @Published private(set) var syncFailed = false
    private let client: ClientProxyProtocol
    private let session: URLSession
    private let cache: STalkCacheService?
    private let sendEvent: (SharedSticker) async throws -> Void
    private var pending = false
    private var loaded = false
    private var catalogueFetchedAt: Date?
    private var preferenceTask: Task<Void, Never>?
    private var revision = 0
    private var key: String {
        "stickers-v1-" + SHA256.hash(data: Data((client.homeserver + "\n" + client.userID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Snapshot: Codable { let packs: [SharedStickerPack]; let preferences: SharedStickerPreferences; let pending: Bool }

    init(client: ClientProxyProtocol, session: URLSession = .shared, cache: STalkCacheService? = nil,
         sendEvent: @escaping (SharedSticker) async throws -> Void) {
        self.client = client
        self.session = session
        self.cache = cache ?? ServiceLocator.shared.cacheService
        self.sendEvent = sendEvent
    }

    func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if !loaded {
            if let saved = await cache?.load(Snapshot.self, forKey: key) {
                packs = saved.packs
                preferences = saved.preferences
                pending = saved.pending
            }
            loaded = true
        }
        if catalogueFetchedAt.map({ Date().timeIntervalSince($0) < 60 }) != true {
            do {
                packs = try await SharedStickerPack.decodeCatalogue(request(path: "/_stalk/stickers/catalog"))
                catalogueFetchedAt = Date()
                await persist()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = NSLocalizedString("stalk_stickers_load_error", value: "Не удалось загрузить наборы. Попробуйте ещё раз.", comment: "Stickers")
            }
        }
        guard !Task.isCancelled else { return }
        if pending {
            enqueuePreferences()
            await preferenceTask?.value
        } else {
            let initialRevision = revision
            do {
                let data = try await request(path: preferencePath)
                let remote = try JSONDecoder().decode(SharedStickerPreferences.self, from: data)
                if revision == initialRevision, !pending { preferences = remote; await persist() }
            } catch StickerError.http(404) { /* No preferences yet. */ }
            catch { if !Task.isCancelled { syncFailed = true } }
        }
    }

    func toggleFavorite(_ id: String) {
        preferences = .init(favorites: preferences.favorites.contains(id) ? preferences.favorites.filter { $0 != id } : preferences.favorites + [id],
                            recent: preferences.recent)
        changed()
    }

    func send(_ item: SharedSticker) async -> Bool {
        guard !sending, item.isValid else { return false }
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await sendEvent(item)
            preferences.record(item)
            changed()
            return true
        } catch {
            self.error = NSLocalizedString("stalk_stickers_send_error", value: "Не удалось отправить стикер. Проверьте права и повторите попытку.", comment: "Stickers")
            return false
        }
    }

    private func changed() {
        revision += 1
        pending = true
        enqueuePreferences()
    }

    private func enqueuePreferences() {
        let previous = preferenceTask
        preferenceTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await persist()
            await flush()
        }
    }

    private func flush() async {
        guard pending else { return }
        let currentRevision = revision
        do {
            _ = try await request(path: preferencePath, method: "PUT", body: JSONEncoder().encode(preferences))
            if revision == currentRevision { pending = false; syncFailed = false }
        } catch { syncFailed = true }
        await persist()
    }

    private func persist() async {
        await cache?.save(Snapshot(packs: packs, preferences: preferences, pending: pending), forKey: key, ttl: 30 * 24 * 3600)
    }

    private var preferencePath: String {
        let user = client.userID.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
        return "/_matrix/client/v3/user/\(user)/account_data/im.stalk.sticker_preferences"
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let base = client.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw StickerError.invalidURL }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let token = try client.matrixAccessToken()
            guard !token.isEmpty else { throw StickerError.http(401) }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 10
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { await client.forceTokenRefresh(); continue }
            guard (200...299).contains(status) else { throw StickerError.http(status) }
            return data
        }
        throw StickerError.http(401)
    }

    enum StickerError: Error { case http(Int), invalidURL }
}
