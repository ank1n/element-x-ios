// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum StalkChannelForwarding {
    static let key = "io.stalk.forwarded_channel"
    static func content(originalJSON: String?, latestEditJSON: String?, roomID: String, eventID: String) -> String? {
        func body(_ raw: String?) -> [String: Any]? {
            guard let raw, let bytes = raw.data(using: .utf8), let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let content = event["content"] as? [String: Any] else { return nil }
            return content["m.new_content"] as? [String: Any] ?? content
        }
        guard sourceURL(roomID: roomID, eventID: eventID) != nil, let source = body(latestEditJSON) ?? body(originalJSON),
              let type = source["msgtype"] as? String, ["m.text", "m.image", "m.file", "m.video", "m.audio", "m.notice", "m.emote"].contains(type) else { return nil }
        let allowed: Set = ["msgtype", "body", "format", "formatted_body", "filename", "url", "file", "info", "org.matrix.msc1767.audio", "org.matrix.msc3245.voice"]
        var content = source.filter { allowed.contains($0.key) }
        // Keep the existing Disk card, without forwarding the original recipients
        // or claiming that their access rights were granted to a new recipient.
        if let share = source["io.stalk.file_share"] as? [String: Any], let id = share["blobId"] as? String, !id.isEmpty {
            let fields: Set = ["blobId", "name", "size", "mimetype", "disk"]
            content["io.stalk.file_share"] = share.filter { fields.contains($0.key) }
        }
        content[key] = ["room_id": roomID, "event_id": eventID]
        guard let bytes = try? JSONSerialization.data(withJSONObject: content) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func sourceURL(from raw: String?) -> URL? {
        guard let raw, let bytes = raw.data(using: .utf8), let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let source = (event["content"] as? [String: Any])?[key] as? [String: Any],
              let room = source["room_id"] as? String, let id = source["event_id"] as? String else { return nil }
        return sourceURL(roomID: room, eventID: id)
    }

    static func sourceURL(roomID: String, eventID: String) -> URL? {
        guard roomID.hasPrefix("!"), eventID.hasPrefix("$"), roomID.count < 1024, eventID.count < 1024,
              !roomID.contains(where: \.isWhitespace), !eventID.contains(where: \.isWhitespace) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!$:-_"))
        return URL(string: "https://matrix.to/#/" + roomID.addingPercentEncoding(withAllowedCharacters: allowed)! + "/" + eventID.addingPercentEncoding(withAllowedCharacters: allowed)!)
    }
}
