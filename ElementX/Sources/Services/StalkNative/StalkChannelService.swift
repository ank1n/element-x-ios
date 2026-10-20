// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import CoreFoundation
import CryptoKit
import Foundation

struct StalkChannelSnapshot: Equatable {
    var verified = false
    var isChannel = false
    var archived = false
    var joined = false
    var level = 0
    var comments = false
    var capability = false
    var closed = Set<String>()
    var blocked = false
    var roomName = ""
    var encrypted = false
    var implicitCreator = false
    var lifecycleEventID: String?
    var powersEventID: String?
    var history = "joined"
    var background = "default"
    var backgroundImage: URL?
    var manager: String?
    var canTransfer = false
    var joinedPeople: [UserProfileProxy] = []
    var capabilities: StalkChannelCapabilities?
    var canAdminister: Bool {
        verified && isChannel && joined && level >= 100
    }

    var canPublish: Bool {
        isChannel && joined && !archived && level >= 50
    }

    var canModerate: Bool {
        joined && (level == 25 || level >= 100)
    }

    func canComment(root: String) -> Bool {
        isChannel && joined && !archived && comments && capability && !blocked && !closed.contains(root)
    }
}

enum StalkChannelError: LocalizedError {
    case readOnly
    var errorDescription: String? {
        NSLocalizedString("stalk_channel_read_only", comment: "Channel sending denied")
    }
}

@MainActor
final class StalkChannelService: ObservableObject {
    private final class WeakStore { weak var value: StalkChannelService?; init(_ value: StalkChannelService) {
        self.value = value
    } }
    private static var stores: [ObjectIdentifier: WeakStore] = [:]
    static func shared(client: ClientProxyProtocol) -> StalkChannelService {
        let key = ObjectIdentifier(client)
        if let value = stores[key]?.value { return value }
        stores = stores.filter { $0.value.value != nil }
        let service = StalkChannelService(client: client)
        stores[key] = WeakStore(service)
        return service
    }

    @Published private(set) var snapshots: [String: StalkChannelSnapshot] = [:]
    @Published private(set) var discoveryFailed = false
    @Published private(set) var subscriptionRevision = 0
    @Published private(set) var channelIDs = Set<String>()
    @Published private(set) var archivedIDs = Set<String>()
    let api: StalkNativeAPI
    private let typeDefaults: UserDefaults?
    private let typeCacheKey: String
    private var roomTypes: [String: Bool] = [:]
    private var ordinaryRooms = Set<String>()
    private var sdkCreators: [String: [String]] = [:]
    private var nativePermissions: [String: (joined: Bool, level: Int64?)] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var lastDiscovery: Date?
    init(client: ClientProxyProtocol, session: URLSession? = nil, defaults: UserDefaults? = nil) {
        api = StalkNativeAPI(client: client, session: session)
        typeDefaults = defaults ?? (client is ClientProxy ? .standard : nil)
        typeCacheKey = "stalk.room.types.v1." + SHA256.hash(data: Data((client.homeserver + "\n" + client.userID).utf8)).map { String(format: "%02x", $0) }.joined()
        if let data = typeDefaults?.data(forKey: typeCacheKey), let saved = try? JSONDecoder().decode([String: Bool].self, from: data), saved.count <= 2000 {
            roomTypes = saved
            channelIDs = Set(saved.filter(\.value).keys)
            ordinaryRooms = Set(saved.filter { !$0.value }.keys)
        }
    }

    private func rememberType(roomID: String, channel: Bool) {
        // Only m.room.create is cached: it is immutable. Membership and rights never are.
        if roomTypes.count >= 2000, roomTypes[roomID] == nil { return }
        roomTypes[roomID] = channel
        if let data = try? JSONEncoder().encode(roomTypes) { typeDefaults?.set(data, forKey: typeCacheKey) }
    }

    /// One bounded metadata-only sync, not N requests for every row. Does not change the SDK sync cursor.
    func discover() async {
        if let discoveryTask { await discoveryTask.value; return }
        guard lastDiscovery == nil || Date().timeIntervalSince(lastDiscovery!) > 20 else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let filter: [String: Any] = ["room": ["timeline": ["limit": 0], "state": ["types": ["m.room.create", "io.stalk.channel.lifecycle"]], "ephemeral": ["types": []], "account_data": ["types": []]], "presence": ["types": []], "account_data": ["types": []]]
                let encoded = try String(data: JSONSerialization.data(withJSONObject: filter), encoding: .utf8)!
                let result = try await api.object(["_matrix", "client", "v3", "sync"], query: [.init(name: "timeout", value: "0"), .init(name: "filter", value: encoded)])
                guard !Task.isCancelled else { return }
                let rooms = (result["rooms"] as? [String: Any])?["join"] as? [String: Any] ?? [:]
                var channels = Set<String>(); var archives = Set<String>()
                for (id, value) in rooms {
                    let state = ((value as? [String: Any])?["state"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
                    if let event = state.first(where: { $0["type"] as? String == "m.room.create" }), let creation = event["content"] as? [String: Any] {
                        let isChannel = creation["type"] as? String == "io.stalk.channel"
                        rememberType(roomID: id, channel: isChannel)
                        if !isChannel { ordinaryRooms.insert(id) }
                    }
                    if state.contains(where: { $0["type"] as? String == "m.room.create" && ($0["content"] as? [String: Any])?["type"] as? String == "io.stalk.channel" }) {
                        channels.insert(id)
                        if state.contains(where: { $0["type"] as? String == "io.stalk.channel.lifecycle" && ($0["content"] as? [String: Any])?["archived"] as? Bool == true }) { archives.insert(id) }
                    }
                }
                channelIDs = channels; archivedIDs = archives; lastDiscovery = Date(); discoveryFailed = false
            } catch { discoveryFailed = true }
        }
        discoveryTask = task; await task.value; discoveryTask = nil
    }

    func refresh(roomID: String, creators: [String] = []) async -> StalkChannelSnapshot? {
        do {
            if !creators.isEmpty { sdkCreators[roomID] = creators }
            // Type is immutable. Avoid polling full state for ordinary rooms.
            if ordinaryRooms.contains(roomID) {
                let state = StalkChannelSnapshot(verified: true)
                snapshots[roomID] = state
                return state
            }
            let create = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "state", "m.room.create", ""])
            guard create["type"] != nil || create["creator"] is String || create["room_version"] is String else { throw URLError(.cannotParseResponse) }
            guard create["type"] as? String == "io.stalk.channel" else {
                rememberType(roomID: roomID, channel: false)
                ordinaryRooms.insert(roomID); snapshots[roomID] = StalkChannelSnapshot(verified: true); return snapshots[roomID]
            }
            rememberType(roomID: roomID, channel: true)
            channelIDs.insert(roomID)
            let data = try await api.request(["_matrix", "client", "v3", "rooms", roomID, "state"])
            let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            func content(_ type: String, _ key: String = "") -> [String: Any] {
                events.first { $0["type"] as? String == type && $0["state_key"] as? String == key }?["content"] as? [String: Any] ?? [:]
            }
            let powers = content("m.room.power_levels")
            let users = powers["users"] as? [String: Any] ?? [:]
            var level = Self.integer(users[api.client.userID]) ?? Self.integer(powers["users_default"]) ?? 0
            let implicitCreator = create["room_version"] as? String == "12" && (sdkCreators[roomID] ?? []).contains(api.client.userID)
            if implicitCreator { level = max(100, level) }
            let policy = content("io.stalk.channel.policy")
            var snapshot = StalkChannelSnapshot(verified: true, isChannel: true, archived: content("io.stalk.channel.lifecycle")["archived"] as? Bool == true,
                                                joined: content("m.room.member", api.client.userID)["membership"] as? String == "join", level: level,
                                                comments: Self.integer(policy["schemaVersion"]) == 3 && policy["mode"] as? String == "announcements" && policy["comments"] as? String == "threads",
                                                blocked: content("io.stalk.channel.commenter", "user/" + api.client.userID)["blocked"] as? Bool == true,
                                                roomName: content("m.room.name")["name"] as? String ?? roomID)
            for event in events where event["type"] as? String == "io.stalk.channel.thread" {
                if (event["content"] as? [String: Any])?["closed"] as? Bool == true, let key = event["state_key"] as? String { snapshot.closed.insert(key) }
            }
            let caps = try? await currentCapabilities()
            snapshot.capabilities = caps
            snapshot.implicitCreator = implicitCreator
            snapshot.encrypted = events.contains { $0["type"] as? String == "m.room.encryption" }
            snapshot.lifecycleEventID = events.first { $0["type"] as? String == "io.stalk.channel.lifecycle" }?["event_id"] as? String
            snapshot.powersEventID = events.first { $0["type"] as? String == "m.room.power_levels" }?["event_id"] as? String
            snapshot.history = content("m.room.history_visibility")["history_visibility"] as? String ?? "joined"
            let appearance = content("io.stalk.channel.appearance")
            if Self.integer(appearance["schemaVersion"]) == 1 {
                let preset = appearance["preset"] as? String ?? "default"
                snapshot.background = ["default", "sky", "mint", "sand", "dots", "grid"].contains(preset) ? preset : "default"
                if let image = appearance["image"] as? String, image.count < 2048,
                   image.range(of: #"^mxc://[^/\s]+/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil { snapshot.backgroundImage = URL(string: image) }
            }
            snapshot.joinedPeople = events.compactMap { event in
                guard event["type"] as? String == "m.room.member", let id = event["state_key"] as? String,
                      let member = event["content"] as? [String: Any], member["membership"] as? String == "join" else { return nil }
                return UserProfileProxy(userID: id, displayName: member["displayname"] as? String,
                                        avatarURL: (member["avatar_url"] as? String).flatMap(URL.init(string:)))
            }
            let manager = (powers["io.stalk.channel.management"] as? [String: Any])?["user_id"] as? String
                ?? events.first { $0["type"] as? String == "m.room.create" }?["sender"] as? String ?? create["creator"] as? String
            snapshot.manager = manager
            let managerLevel = Self.integer(manager.flatMap { users[$0] }) ?? Self.integer(powers["users_default"]) ?? 0
            let implicitManager = create["room_version"] as? String == "12" && (sdkCreators[roomID] ?? []).contains(manager ?? "")
            snapshot.canTransfer = snapshot.canAdminister && (manager == api.client.userID || !snapshot.joinedPeople.contains { $0.userID == manager } || (!implicitManager && managerLevel < 100))
            if snapshot.comments {
                let raw = try await api.object(["_synapse", "client", "stalk_channels", "capabilities"])
                snapshot.capability = Self.integer(raw["policyVersion"]) == 3 && raw["threadedComments"] as? Bool == true && Set(raw["commentEventTypes"] as? [String] ?? []).isSuperset(of: ["m.room.message", "m.room.encrypted", "m.sticker"])
            }
            if nativePermissions[roomID] == nil { nativePermissions[roomID] = (snapshot.joined, Int64(snapshot.level)) }
            snapshots[roomID] = snapshot
            if snapshot.archived { archivedIDs.insert(roomID) } else { archivedIDs.remove(roomID) }
            return snapshot
        } catch {
            if Task.isCancelled { return nil }
            // A lost membership, network failure, or unsupported capability must not leave a stale writable composer.
            var denied = snapshots[roomID] ?? StalkChannelSnapshot(isChannel: channelIDs.contains(roomID))
            denied.verified = false; denied.joined = false; denied.capability = false; snapshots[roomID] = denied
            return nil
        }
    }

    /// Native membership/PL sync can revoke permissions immediately. It never
    /// grants access: promotions still require a fresh server policy/capability read.
    func restrictNativeAccess(roomID: String, joined: Bool, level: Int64?) {
        if let previous = nativePermissions[roomID], previous.joined == joined, previous.level == level { return }
        nativePermissions[roomID] = (joined, level)
        guard var state = snapshots[roomID], state.isChannel else { return }
        let previous = state
        if !joined { state.joined = false; state.verified = false; state.capability = false }
        if let level, !state.implicitCreator { state.level = min(state.level, Int(clamping: level)) }
        if state != previous { snapshots[roomID] = state }
    }

    /// Metadata-only sync for an on-screen channel. The SDK keeps its own cursor;
    /// this read never advances it and never fetches publication bodies.
    func watch(roomID: String) async {
        guard snapshots[roomID]?.isChannel == true, snapshots[roomID]?.joined == true else { return }
        let types = ["io.stalk.channel.policy", "io.stalk.channel.thread", "io.stalk.channel.commenter", "io.stalk.channel.appearance", "io.stalk.channel.lifecycle", "m.room.power_levels", "m.room.member", "m.room.history_visibility"]
        let filter: [String: Any] = ["room": ["rooms": [roomID], "timeline": ["types": types, "limit": 100], "state": ["types": types], "ephemeral": ["types": []], "account_data": ["types": []]], "presence": ["types": []], "account_data": ["types": ["io.stalk.comments.subscription.*"]]]
        guard let encoded = try? JSONSerialization.data(withJSONObject: filter), let json = String(data: encoded, encoding: .utf8) else { return }
        var cursor: String?
        var failures = 0
        while !Task.isCancelled {
            do {
                var query = [URLQueryItem(name: "filter", value: json), .init(name: "timeout", value: "10000")]
                if let cursor { query.append(.init(name: "since", value: cursor)) }
                let result = try await api.object(["_matrix", "client", "v3", "sync"], query: query)
                guard !Task.isCancelled, let next = result["next_batch"] as? String else { return }
                cursor = next; failures = 0
                let rooms = result["rooms"] as? [String: Any] ?? [:]
                if ((rooms["leave"] as? [String: Any])?[roomID]) != nil {
                    restrictNativeAccess(roomID: roomID, joined: false, level: nil); return
                }
                let room = (rooms["join"] as? [String: Any])?[roomID] as? [String: Any] ?? [:]
                let state = (room["state"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
                let timeline = (room["timeline"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
                if !(state + timeline).isEmpty { _ = await refresh(roomID: roomID) }
                let accountData = (result["account_data"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
                if accountData.contains(where: { ($0["content"] as? [String: Any])?["room_id"] as? String == roomID }) { subscriptionRevision += 1 }
                // A proxy may return an empty sync immediately instead of long polling.
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError { return }
            catch let error as StalkNativeHTTPError where error.status == 401 || error.status == 403 {
                restrictNativeAccess(roomID: roomID, joined: false, level: nil); return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                guard let delay = CallTimelineSummaryService.failureDelay(attempt: failures, retryAfter: (error as? StalkNativeHTTPError)?.retryAfter) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func canSend(roomID: String, root: String?, creators: [String] = []) async -> Bool {
        guard let state = await refresh(roomID: roomID, creators: creators) else { return false }
        guard state.isChannel else { return true }
        guard let root else { return state.canPublish }
        guard state.canComment(root: root) else { return false }
        // Do not infer validity from a local reply or plaintext fallback. Check the root itself.
        do {
            let event = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "event", root])
            guard event["event_id"] as? String == root, event["state_key"] == nil,
                  ["m.room.message", "m.room.encrypted", "m.sticker"].contains(event["type"] as? String ?? ""),
                  ((event["unsigned"] as? [String: Any])?["redacted_because"]) == nil,
                  let content = event["content"] as? [String: Any], !content.isEmpty else { return false }
            let relation = content["m.relates_to"] as? [String: Any]
            return relation?["rel_type"] as? String != "m.thread" && relation?["rel_type"] as? String != "m.replace"
        } catch { return false }
    }

    func subscription(roomID: String, root: String? = nil, set mode: String? = nil) async throws -> String {
        guard let value = root, !value.isEmpty, mode == nil || ["following", "mentions", "muted"].contains(mode!) else { throw URLError(.badURL) }

        var body: [String: Any] = ["room_id": roomID]
        if let root { body["root_id"] = root }
        if let mode { body["mode"] = mode }
        let query = [URLQueryItem(name: "room_id", value: roomID)] + (root.map { [URLQueryItem(name: "root_id", value: $0)] } ?? [])
        let result = try await api.object(["_synapse", "client", "stalk_channels", "subscription"], query: mode == nil ? query : [], method: mode == nil ? "GET" : "PUT", body: mode == nil ? nil : body)
        return result["mode"] as? String ?? "mentions"
    }

    func moderate(roomID: String, root: String, closed: Bool) async throws {
        guard let state = await refresh(roomID: roomID), state.isChannel, state.canModerate else { throw StalkChannelError.readOnly }
        _ = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "state", "io.stalk.channel.thread", root], method: "PUT", body: ["closed": closed])
        _ = await refresh(roomID: roomID)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite && d.rounded() == d && abs(d) < Double(Int.max) ? Int(d) : nil
    }
}

struct StalkChannelDirectoryEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let topic: String
    var requiresApproval = false
    var joined = false
}

extension StalkChannelService {
    var joinedChannels: [StalkChannelDirectoryEntry] {
        api.client.staticRoomSummaryProvider.roomListPublisher.value.filter { channelIDs.contains($0.id) }
            .map { .init(id: $0.id, name: $0.name, topic: archivedIDs.contains($0.id) ? StalkChannelStrings.archived : "", joined: true) }
    }

    func directory(since: String? = nil) async throws -> (entries: [StalkChannelDirectoryEntry], next: String?) {
        var body: [String: Any] = ["limit": 50, "filter": ["room_types": ["io.stalk.channel"]]]
        if let since { body["since"] = since }
        let response = try await api.object(["_matrix", "client", "v3", "publicRooms"], method: "POST", body: body)
        let entries = (response["chunk"] as? [[String: Any]] ?? []).compactMap { row -> StalkChannelDirectoryEntry? in
            guard row["room_type"] as? String == "io.stalk.channel", row["join_rule"] as? String == "public",
                  let id = row["room_id"] as? String, id.hasPrefix("!"), !archivedIDs.contains(id) else { return nil }
            return .init(id: id, name: row["name"] as? String ?? id, topic: row["topic"] as? String ?? "")
        }
        return (entries, response["next_batch"] as? String)
    }

    func lookup(_ input: String) async throws -> StalkChannelDirectoryEntry {
        var address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: address), !address.hasPrefix("!"), !address.hasPrefix("#") {
            let route = AppRouteURLParser(appSettings: ServiceLocator.shared.settings).route(from: url)
            switch route {
            case .room(let id, _): address = id
            case .roomAlias(let alias): address = alias
            case .event(_, let id, _): address = id
            case .eventOnRoomAlias(_, let alias): address = alias
            default: throw URLError(.badURL)
            }
        }
        if address.hasPrefix("#") {
            guard case .success(let resolved) = await api.client.resolveRoomAlias(address) else { throw URLError(.badURL) }
            address = resolved.roomId
        }
        guard address.hasPrefix("!"), case .success(let preview) = await api.client.roomPreviewForIdentifier(address, via: []),
              preview.info.isChannel else { throw URLError(.resourceUnavailable) }
        let approval: Bool
        switch preview.info.joinRule {
        case .knock, .knockRestricted: approval = true
        default: approval = false
        }
        return .init(id: address, name: preview.info.displayName ?? address, topic: preview.info.topic ?? "",
                     requiresApproval: approval, joined: channelIDs.contains(address))
    }

    func setComments(roomID: String, enabled: Bool) async throws {
        guard let state = await refresh(roomID: roomID), state.isChannel, state.joined, state.level >= 100, !state.archived else { throw StalkChannelError.readOnly }
        let caps = try await api.object(["_synapse", "client", "stalk_channels", "capabilities"])
        guard Self.integer(caps["policyVersion"]) == 3, caps["threadedComments"] as? Bool == true,
              Set(caps["commentEventTypes"] as? [String] ?? []).isSuperset(of: ["m.room.message", "m.room.encrypted", "m.sticker"]) else { throw StalkChannelError.readOnly }
        let prefix = ["_matrix", "client", "v3", "rooms", roomID, "state"]
        let create = try await api.object(prefix + ["m.room.create", ""])
        let history = try await api.object(prefix + ["m.room.history_visibility", ""])
        if enabled {
            guard create["m.federate"] as? Bool == false else { throw StalkChannelError.readOnly }
            let mode = history["history_visibility"] as? String
            guard mode == "joined" || mode == "shared" else { throw StalkChannelError.readOnly }
            if mode == "shared" {
                guard ((caps["historyVisibility"] as? [String: Any])?["modes"] as? [String] ?? []).contains("shared") else { throw StalkChannelError.readOnly }
                do {
                    _ = try await api.object(prefix + ["m.room.encryption", ""])
                    throw StalkChannelError.readOnly
                } catch let error as StalkNativeHTTPError where error.status == 404 { }
            }
        }
        var policy = try await api.object(prefix + ["io.stalk.channel.policy", ""])
        var powers = try await api.object(prefix + ["m.room.power_levels", ""])
        policy["schemaVersion"] = 3; policy["mode"] = "announcements"; policy["comments"] = enabled ? "threads" : "disabled"
        var events = powers["events"] as? [String: Any] ?? [:]
        for type in ["m.room.message", "m.room.encrypted", "m.sticker", "m.reaction", "m.room.redaction"] {
            events[type] = enabled ? 0 : 50
        }
        events["io.stalk.channel.thread"] = enabled ? 25 : 100
        events["io.stalk.channel.commenter"] = enabled ? 25 : 100
        powers["events"] = events; powers["redact"] = enabled ? 25 : 100
        if !enabled { _ = try await api.object(prefix + ["io.stalk.channel.policy", ""], method: "PUT", body: policy) }
        _ = try await api.object(prefix + ["m.room.power_levels", ""], method: "PUT", body: powers)
        if enabled { _ = try await api.object(prefix + ["io.stalk.channel.policy", ""], method: "PUT", body: policy) }
        _ = await refresh(roomID: roomID)
    }

    func blockCommenter(roomID: String, userID: String, blocked: Bool) async throws {
        guard CallSummaryPeople.isUserID(userID), let state = await refresh(roomID: roomID), state.isChannel,
              state.canModerate else { throw StalkChannelError.readOnly }
        _ = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "state", "io.stalk.channel.commenter", "user/" + userID], method: "PUT", body: ["blocked": blocked])
        _ = await refresh(roomID: roomID)
    }
}
