// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum StalkChannelCreationError: LocalizedError {
    case invalidInput
    var errorDescription: String? {
        StalkUpdateStrings.text("channel_invalid_input")
    }
}

extension StalkChannelService {
    func createChannel(name: String, topic: String, approval: Bool, avatar: Data? = nil) async throws -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 255, topic.count <= 5000, avatar == nil || avatar!.count <= 5 * 1024 * 1024 else { throw StalkChannelCreationError.invalidInput }
        let versions = try await api.object(["_matrix", "client", "versions"])
        var wellKnown: [String: Any] = [:]
        do { wellKnown = try await api.object([".well-known", "matrix", "client"]) }
        catch let error as StalkNativeHTTPError where error.status == 404 { }
        let encryption = Self.channelEncryption(versions: versions, wellKnown: wellKnown)
        var state: [[String: Any]] = [
            ["type": "io.stalk.channel.policy", "state_key": "", "content": ["schemaVersion": 2, "mode": "announcements", "comments": "disabled", "access": approval ? "approval" : "open"]],
            ["type": "m.room.guest_access", "state_key": "", "content": ["guest_access": "forbidden"]],
            ["type": "m.room.history_visibility", "state_key": "", "content": ["history_visibility": "joined"]],
            ["type": "m.room.join_rules", "state_key": "", "content": ["join_rule": approval ? "knock" : "public"]]
        ]
        if encryption { state.append(["type": "m.room.encryption", "state_key": "", "content": ["algorithm": "m.megolm.v1.aes-sha2"]]) }
        if let avatar {
            let bytes = try await api.request(["_matrix", "media", "v3", "upload"], query: [.init(name: "filename", value: "channel-avatar.png")], method: "POST", body: avatar, contentType: "image/png")
            let upload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let mxc = upload?["content_uri"] as? String, MeetingVenueStrings.photoURL(mxc) != nil else { throw StalkChannelCreationError.invalidInput }
            state.append(["type": "m.room.avatar", "state_key": "", "content": ["url": mxc]])
        }
        let power: [String: Any] = ["users_default": 0, "events_default": 50, "state_default": 100, "invite": 100, "kick": 100, "ban": 100, "redact": 100, "notifications": ["room": 100],
                                    "events": ["m.room.message": 50, "m.room.encrypted": 50, "m.reaction": 50, "m.room.redaction": 50, "m.room.power_levels": 100, "m.room.pinned_events": 50, "m.room.tombstone": 150, "io.stalk.channel.policy": 100, "io.stalk.channel.appearance": 100]]
        var body: [String: Any] = ["name": title, "topic": topic, "preset": "private_chat", "visibility": approval ? "private" : "public", "creation_content": ["type": "io.stalk.channel", "m.federate": false], "power_level_content_override": power, "initial_state": state]
        if !approval { body["room_alias_name"] = "channel-" + UUID().uuidString.lowercased() }
        let result = try await api.object(["_matrix", "client", "v3", "createRoom"], method: "POST", body: body)
        guard let room = result["room_id"] as? String, room.hasPrefix("!") else { throw StalkChannelCreationError.invalidInput }
        (api.client as? ClientProxy)?.addRoomsToAwait([room])
        return room
    }

    static func channelEncryption(versions: [String: Any], wellKnown: [String: Any]) -> Bool {
        if (versions["unstable_features"] as? [String: Any])?["io.element.e2ee_forced.private"] as? Bool == true { return true }
        let policy = wellKnown["io.element.e2ee"] as? [String: Any] ?? wellKnown["im.vector.riot.e2ee"] as? [String: Any] ?? [:]
        if policy["force_disable"] as? Bool == true { return false }
        return policy["default"] as? Bool != false
    }
}
