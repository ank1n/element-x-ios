// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct StalkMeetingRoomSummary: Equatable {
    let started: Date
    var duration: TimeInterval?
    var people: [CallAttendee]
    var partial = false
    var recordingOnly = false
    var historyPartial = false
}

/// Account-scoped, visible rows only, two concurrent reads and a one-minute cache.
@MainActor final class StalkMeetingRoomSummaryService {
    let api: StalkNativeAPI
    private var cache: [String: (Date, StalkMeetingRoomSummary?)] = [:]
    private var active = 0
    init(client: ClientProxyProtocol, session: URLSession? = nil) {
        api = StalkNativeAPI(client: client, session: session)
    }

    func latest(roomID: String) async throws -> StalkMeetingRoomSummary? {
        if let item = cache[roomID], Date().timeIntervalSince(item.0) < 60 { return item.1 }
        while active >= 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        if let item = cache[roomID], Date().timeIntervalSince(item.0) < 60 { return item.1 }
        active += 1; defer { active -= 1 }
        do {
            let result = try await read(roomID: roomID)
            try Task.checkCancellation()
            if cache.count >= 128, let key = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache.removeValue(forKey: key) }
            cache[roomID] = (Date(), result)
            return result
        } catch { cache.removeValue(forKey: roomID); throw error }
    }

    private func read(roomID: String) async throws -> StalkMeetingRoomSummary? {
        let filter = "{\"types\":[\"io.stalk.call.initiate\",\"m.room.encrypted\"]}"
        let events = try await api.object(["_matrix", "client", "v3", "rooms", roomID, "messages"], query: [.init(name: "dir", value: "b"), .init(name: "limit", value: "50"), .init(name: "filter", value: filter)])
        let chunk = events["chunk"] as? [[String: Any]] ?? []
        var marker = chunk.filter { $0["type"] as? String == "io.stalk.call.initiate" }.compactMap { Self.date($0["origin_server_ts"]) }.max()
        var historyPartial = false
        let encryptedIDs = Set(chunk.filter { $0["type"] as? String == "m.room.encrypted" }.compactMap { $0["event_id"] as? String })
        var decodedIDs = Set<String>()
        // Decrypt through the existing SDK only. Do not send encrypted bodies to a server/parser.
        if let encrypted = chunk.first(where: { $0["type"] as? String == "m.room.encrypted" }), let id = encrypted["event_id"] as? String,
           case .joined(let room) = await api.client.roomForIdentifier(roomID),
           case .success(let timeline) = await room.timelineFocusedOnEvent(eventID: id, numberOfEvents: 100) {
            // Focused timelines are returned unsubscribed. Their item provider is
            // initialized only after subscribeForUpdates finishes (Organizer crash360).
            await timeline.subscribeForUpdates()
            try Task.checkCancellation()
            for proxy in timeline.timelineItemProvider.itemProxies {
                guard case .event(let event) = proxy, let json = event.debugInfo.originalJSON,
                      let bytes = json.data(using: .utf8), let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
                if value["type"] as? String != "m.room.encrypted", let id = value["event_id"] as? String { decodedIDs.insert(id) }
                guard value["type"] as? String == "io.stalk.call.initiate", let date = Self.date(value["origin_server_ts"]) else { continue }
                if marker == nil || marker! < date { marker = date }
            }
        }
        if chunk.contains(where: { $0["type"] as? String == "m.room.encrypted" }), marker == nil { historyPartial = true }
        if !encryptedIDs.isSubset(of: decodedIDs) { historyPartial = true }
        var call: CallTimelineRecord?
        if let marker {
            do {
                call = try await JSONDecoder().decode(CallTimelineRecord.self, from: api.request(["api", "recording", "calls"], query: [.init(name: "room_id", value: roomID), .init(name: "at", value: String(Int64(marker.timeIntervalSince1970 * 1000)))]))
            } catch let error as StalkNativeHTTPError where [400, 404].contains(error.status) { }
        }
        if let call, call.room_id != roomID { throw URLError(.badServerResponse) }
        var listing: [String: Any] = [:]
        do { listing = try await api.object(["api", "recording", "list"], query: [.init(name: "matrixRoomId", value: roomID)]) }
        catch let error as StalkNativeHTTPError where [401, 403].contains(error.status) { throw error }
        catch { if call == nil, marker == nil { throw error }; historyPartial = true }
        let recordings = (listing["recordings"] as? [[String: Any]] ?? []).filter { $0["matrixRoomId"] as? String == roomID && Self.date($0["startedAt"]) != nil }
        let latest = recordings.max { Self.date($0["startedAt"])! < Self.date($1["startedAt"])! }
        let group = latest.map { first in recordings.filter { row in
            guard let call = first["callId"] as? String, !call.isEmpty else { return row["egressId"] as? String == first["egressId"] as? String }
            return row["callId"] as? String == call
        } } ?? []
        let recordingStart = group.compactMap { Self.date($0["startedAt"]) }.min()
        let callStart = call?.started_at.date
        let callEnd = call?.ended_at?.date
        let useCall = callStart != nil && (recordingStart == nil || callStart! >= recordingStart! || recordingStart! <= (callEnd ?? Date()))
        let useMarker = !useCall && marker != nil && (recordingStart == nil || marker! > recordingStart!)
        let start = useCall ? callStart : useMarker ? marker : recordingStart
        guard let start else { return nil }
        let relevant = useMarker ? [] : useCall ? group.filter { row in
            guard let date = Self.date(row["startedAt"]) else { return false }
            return date >= start.addingTimeInterval(-120) && date <= (callEnd ?? Date())
        } : group
        var ids = useCall ? call?.egress_ids ?? [] : []
        ids += relevant.flatMap { ($0["sessionIds"] as? [String] ?? []) + [($0["egressId"] as? String ?? "")] }
        ids = Array(NSOrderedSet(array: ids.filter { !$0.isEmpty }).array as? [String] ?? [])
        var people: [CallAttendee] = []
        var partial = ids.count > 8
        for id in ids.prefix(8) {
            do {
                let data = try await api.request(["api", "recording", "tracks", id])
                struct Tracks: Decodable { let tracks: [CallParticipantTrack] }
                try people += CallAttendee.from(tracks: JSONDecoder().decode(Tracks.self, from: data).tracks)
            } catch let error as StalkNativeHTTPError where [401, 403].contains(error.status) { throw error }
            catch { partial = true }
        }
        if useCall, let participants = call?.participants {
            let names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { old, _ in old })
            people = call!.uniqueParticipants.map { .init(id: $0, name: names[$0] ?? $0) }
            // Registry IDs, not the current roster, define the count.
            if !participants.isEmpty { partial = false }
        }
        var seen = Set<String>(); people = people.filter { seen.insert($0.id).inserted }
        if case .joined(let room) = await api.client.roomForIdentifier(roomID) {
            let members = room.membersPublisher.value
            people = people.map { person in
                guard person.name == person.id, let name = members.first(where: { $0.userID == person.id })?.displayName else { return person }
                return .init(id: person.id, name: name)
            }
        }
        let duration: TimeInterval?
        if useCall { duration = call?.ended == true ? call?.duration_s ?? callEnd.map { max(0, $0.timeIntervalSince(start)) } : nil }
        else if relevant.allSatisfy({ Self.date($0["endedAt"]) != nil }), let end = relevant.compactMap({ Self.date($0["endedAt"]) }).max(), end > start { duration = end.timeIntervalSince(start) }
        else { duration = nil }
        return .init(started: start, duration: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, people: people, partial: partial, recordingOnly: !useCall && !useMarker && recordingStart != nil, historyPartial: historyPartial)
    }

    static func date(_ value: Any?) -> Date? {
        guard let value, let bytes = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let result = try? JSONDecoder().decode(StalkTimestamp.self, from: bytes).date,
              result.timeIntervalSince1970 > 0, result.timeIntervalSinceNow < 300 else { return nil }
        return result
    }
}
