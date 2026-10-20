// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct StalkChannelCapabilities: Decodable, Equatable {
    struct Publications: Decodable, Equatable { var drafts: Bool?; var preview: Bool?; var scheduling: Bool?; var formattedBody: Bool?; var encryptedRooms: Bool? }
    struct Lifecycle: Decodable, Equatable { var schemaVersion: Int?; var archive: Bool?; var management: Bool? }
    struct History: Decodable, Equatable { var modes: [String]? }
    var publications: Publications?
    var lifecycle: Lifecycle?
    var historyVisibility: History?
}

struct StalkPublicationContent: Codable, Equatable {
    struct Info: Codable, Equatable { var mimetype: String; var size: Int; var w: Int?; var h: Int? }
    var msgtype = "m.text"
    var body = ""
    var format: String?
    var formatted_body: String?
    var filename: String?
    var url: String?
    var info: Info?

    mutating func setText(_ text: String, formatted: Bool) {
        body = text.isEmpty && msgtype == "m.image" ? filename ?? "" : text
        format = formatted && !text.isEmpty ? "org.matrix.custom.html" : nil
        formatted_body = format == nil ? nil : StalkMarkdown.toHTML(text)
    }

    var editableText: String {
        msgtype == "m.image" && body == filename ? "" : body
    }
}

struct StalkPublication: Codable, Equatable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var room_id: String
    var revision = 0
    var status = "draft"
    var content = StalkPublicationContent()
    var send_at: Double?
    var time_zone = TimeZone.current.identifier
    var updated_at: Double?
    var event_id: String?
    var error_code: String?
    var editable: Bool {
        ["draft", "scheduled", "failed"].contains(status)
    }
}

enum StalkChannelOperationError: LocalizedError {
    case changed, unsupported, encrypted, invalid, uncertain
    var errorDescription: String? {
        let key: String
        switch self {
        case .changed: key = "changed"
        case .unsupported: key = "unsupported"
        case .encrypted: key = "encrypted_drafts"
        case .invalid: key = "invalid_publication"
        case .uncertain: key = "uncertain"
        }
        return StalkChannelStrings.text(key)
    }
}

extension StalkChannelService {
    func currentCapabilities() async throws -> StalkChannelCapabilities {
        try await JSONDecoder().decode(StalkChannelCapabilities.self, from: api.request(["_synapse", "client", "stalk_channels", "capabilities"]))
    }

    private func administration(roomID: String) async throws -> StalkChannelSnapshot {
        guard let state = await refresh(roomID: roomID), state.verified, state.isChannel, state.joined, state.level >= 100 else { throw StalkChannelError.readOnly }
        return state
    }

    func archive(roomID: String, archived: Bool) async throws {
        let state = try await administration(roomID: roomID)
        let caps = try await currentCapabilities()
        guard caps.lifecycle?.schemaVersion == 1, caps.lifecycle?.archive == true else { throw StalkChannelOperationError.unsupported }
        try await administrationRequest("lifecycle", roomID: roomID, body: ["room_id": roomID, "archived": archived, "expected_event_id": state.lifecycleEventID as Any? ?? NSNull()])
    }

    func transfer(roomID: String, userID: String) async throws {
        let state = try await administration(roomID: roomID)
        let caps = try await currentCapabilities()
        guard caps.lifecycle?.schemaVersion == 1, caps.lifecycle?.management == true else { throw StalkChannelOperationError.unsupported }
        guard state.canTransfer, state.joinedPeople.contains(where: { $0.userID == userID }), let eventID = state.powersEventID else { throw StalkChannelError.readOnly }
        try await administrationRequest("management", roomID: roomID, body: ["room_id": roomID, "user_id": userID, "expected_event_id": eventID])
    }

    private func administrationRequest(_ resource: String, roomID: String, body: [String: Any]) async throws {
        do { _ = try await api.object(["_synapse", "client", "stalk_channels", resource], method: "POST", body: body) }
        catch let e as StalkNativeHTTPError where e.status == 409 {
            _ = await refresh(roomID: roomID); throw StalkChannelOperationError.changed
        } catch { _ = await refresh(roomID: roomID); throw error }
        _ = await refresh(roomID: roomID)
    }

    func setHistory(roomID: String, mode: String) async throws {
        let state = try await administration(roomID: roomID)
        let caps = try await currentCapabilities()
        guard ["joined", "shared"].contains(mode), caps.historyVisibility?.modes?.contains(mode) == true,
              !(mode == "shared" && state.encrypted) else { throw StalkChannelOperationError.unsupported }
        _ = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "state", "m.room.history_visibility", ""], method: "PUT", body: ["history_visibility": mode])
        _ = await refresh(roomID: roomID)
    }

    func setAppearance(roomID: String, preset: String, image: String? = nil) async throws {
        _ = try await administration(roomID: roomID)
        guard ["default", "sky", "mint", "sand", "dots", "grid"].contains(preset) else { throw StalkChannelOperationError.invalid }
        var body: [String: Any] = ["schemaVersion": 1, "preset": preset]
        if let image {
            guard image.count < 2048, image.range(of: #"^mxc://[^/\s]+/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw StalkChannelOperationError.invalid }
            body["image"] = image
        }
        _ = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "state", "io.stalk.channel.appearance", ""], method: "PUT", body: body)
        _ = await refresh(roomID: roomID)
    }

    private func publicationAccess(roomID: String, publishing: Bool) async throws -> StalkChannelCapabilities {
        guard let state = await refresh(roomID: roomID), state.isChannel, state.joined, state.level >= 50,
              !publishing || !state.archived else { throw StalkChannelError.readOnly }
        guard !state.encrypted else { throw StalkChannelOperationError.encrypted }
        let caps = try await currentCapabilities()
        guard caps.publications?.drafts == true else { throw StalkChannelOperationError.unsupported }
        return caps
    }

    func publications(roomID: String) async throws -> [StalkPublication] {
        _ = try await publicationAccess(roomID: roomID, publishing: false)
        struct Response: Decodable { let publications: [StalkPublication] }
        let data = try await api.request(["_synapse", "client", "stalk_channels", "publications"], query: [.init(name: "room_id", value: roomID)])
        return try JSONDecoder().decode(Response.self, from: data).publications.filter { $0.room_id == roomID && $0.status != "deleted" }
    }

    func savePublication(_ item: StalkPublication) async throws -> StalkPublication {
        let caps = try await publicationAccess(roomID: item.room_id, publishing: item.send_at != nil)
        guard item.editable, UUID(uuidString: item.id) != nil, item.revision >= 0 else { throw StalkChannelOperationError.uncertain }
        if let time = item.send_at {
            guard caps.publications?.scheduling == true, time.isFinite, time > Date().timeIntervalSince1970 * 1000 + 1000 else { throw StalkChannelOperationError.invalid }
        }
        if item.content.format != nil, caps.publications?.formattedBody != true { throw StalkChannelOperationError.unsupported }
        guard try (JSONEncoder().encode(item.content)).count <= 60000, (item.content.formatted_body?.utf8.count ?? 0) <= 96000 else { throw StalkChannelOperationError.invalid }
        let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item.content))
        let body: [String: Any] = ["id": item.id, "room_id": item.room_id, "revision": item.revision,
                                   "content": content, "send_at": item.send_at as Any? ?? NSNull(), "time_zone": item.time_zone]
        return try await publicationRequest(method: "PUT", roomID: item.room_id, body: body)
    }

    func publicationAction(_ item: StalkPublication, action: String) async throws -> StalkPublication {
        _ = try await publicationAccess(roomID: item.room_id, publishing: action == "publish")
        guard ["publish", "unschedule", "delete"].contains(action), item.editable else { throw StalkChannelOperationError.uncertain }
        return try await publicationRequest(method: "POST", roomID: item.room_id, body: ["id": item.id, "revision": item.revision, "action": action])
    }

    private func publicationRequest(method: String, roomID: String, body: [String: Any]) async throws -> StalkPublication {
        do {
            let object = try await api.object(["_synapse", "client", "stalk_channels", "publications"], method: method, body: body)
            let item = try JSONDecoder().decode(StalkPublication.self, from: JSONSerialization.data(withJSONObject: object))
            guard item.room_id == roomID else { throw StalkChannelOperationError.invalid }
            return item
        } catch let e as StalkNativeHTTPError where e.status == 409 { throw StalkChannelOperationError.changed }
    }

    func publicationImage(_ item: StalkPublication) async throws -> Data {
        _ = try await publicationAccess(roomID: item.room_id, publishing: false)
        guard let raw = item.content.url, raw.range(of: #"^mxc://[^/\s]+/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: raw), let host = url.host else { throw StalkChannelOperationError.invalid }
        let bytes = try await api.request(["_matrix", "client", "v1", "media", "download", host, String(url.path.dropFirst())])
        guard bytes.count <= 20 * 1024 * 1024 else { throw StalkChannelOperationError.invalid }
        return bytes
    }

    func uploadPublicationImage(roomID: String, data: Data, name: String, mime: String) async throws -> String {
        _ = try await publicationAccess(roomID: roomID, publishing: false)
        guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime), data.count <= 20 * 1024 * 1024 else { throw StalkChannelOperationError.invalid }
        let response = try await api.request(["_matrix", "media", "v3", "upload"], query: [.init(name: "filename", value: name)], method: "POST", body: data, contentType: mime)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any], let mxc = object["content_uri"] as? String,
              mxc.range(of: #"^mxc://[^/\s]+/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw StalkChannelOperationError.invalid }
        return mxc
    }
}
