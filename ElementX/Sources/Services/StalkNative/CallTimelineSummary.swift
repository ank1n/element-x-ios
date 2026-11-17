// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation

struct CallInitiateMarker: Equatable, Hashable {
    let eventID: String
    let timestamp: Date
    let video: Bool
}

struct CallTimelineRecord: Decodable, Equatable, Identifiable {
    var id: String {
        call_key
    }

    struct Recording: Decodable, Equatable { let present: Bool? }
    struct Transcription: Decodable, Equatable { let state: String? }
    struct Tasks: Decodable, Equatable { let total: Int?; let by_group: [String: Int]? }
    let call_key: String
    let room_id: String
    let status: String?
    let started_at: StalkTimestamp
    let ended_at: StalkTimestamp?
    let duration_s: Double?
    let participants: [String]?
    let recording: Recording?
    let transcription: Transcription?
    let tasks: Tasks?
    let egress_ids: [String]?
    let title: String?

    var uniqueParticipants: [String] {
        var seen = Set<String>()
        return (participants ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var ended: Bool {
        status == "ended" && ended_at?.date != nil
    }

    static func nextPoll(record: Self?, marker: Date, now: Date) -> TimeInterval? {
        guard now.timeIntervalSince(marker) < 30 * 86400, marker.timeIntervalSince(now) < 300 else { return nil }
        guard let record else { return now.timeIntervalSince(marker) < 600 ? 30 : nil }
        if record.status == "active" { return 30 }
        guard record.ended, let end = record.ended_at?.date else { return nil }
        let elapsed = now.timeIntervalSince(end)
        guard elapsed < 3 * 3600 else { return nil }
        if elapsed < 900 || (record.recording?.present == true && record.transcription?.state != "ready") { return 60 }
        return nil
    }
}

struct StalkTimestamp: Decodable, Equatable {
    let date: Date?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self), number.isFinite {
            date = Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        } else if let text = try? c.decode(String.self) {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        } else { date = nil }
    }
}

@MainActor
final class CallTimelineSummaryService: ObservableObject {
    @Published private(set) var records: [String: CallTimelineRecord] = [:]
    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var profiles: [String: UserProfileProxy] = [:]
    @Published private var owners: [String: CallInitiateMarker] = [:]
    @Published private(set) var reconnectRevision = 0
    private var networkToken: AnyCancellable?
    private var forbidden = Set<String>()
    private var membershipAllowed = true
    @Published private(set) var accessRevision = 0
    private let roomID: String
    let api: StalkNativeAPI
    let userSession: UserSessionProtocol?
    init(roomID: String, client: ClientProxyProtocol, session: URLSession? = nil, userSession: UserSessionProtocol? = nil) {
        self.userSession = userSession
        self.roomID = roomID; api = StalkNativeAPI(client: client, session: session)
        if let client = client as? ClientProxy {
            networkToken = client.networkReachability.map { $0 == .reachable }.removeDuplicates().dropFirst().filter { $0 }
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reconnectRevision += 1 }
        }
    }

    func detail(_ key: String) async throws -> CallTimelineRecord {
        guard membershipAllowed else { throw StalkNativeHTTPError(status: 403) }
        let revision = accessRevision
        let data: Data
        do { data = try await api.request(["api", "recording", "calls", key]) }
        catch let error as StalkNativeHTTPError where error.status == 401 || error.status == 403 {
            if error.status == 403 { forbidden.formUnion(records.keys) }
            accessRevision += 1
            records.removeAll(); owners.removeAll(); names.removeAll(); profiles.removeAll()
            throw error
        }
        let record = try JSONDecoder().decode(CallTimelineRecord.self, from: data)
        guard membershipAllowed, accessRevision == revision else { throw StalkNativeHTTPError(status: 403) }
        guard record.call_key == key, record.room_id == roomID, record.ended else { throw URLError(.cannotParseResponse) }
        return record
    }

    func setMembership(joined: Bool) {
        guard membershipAllowed != joined else { return }
        membershipAllowed = joined; accessRevision += 1
        if !joined { records.removeAll(); owners.removeAll(); names.removeAll(); profiles.removeAll() }
    }

    static func failureDelay(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval? {
        guard attempt <= 4, retryAfter == nil || retryAfter!.isFinite && retryAfter! <= 300 else { return nil }
        return min(300, max(30 * pow(2, Double(max(0, attempt - 1))), retryAfter ?? 0))
    }

    func summary(for marker: CallInitiateMarker) -> CallTimelineRecord? {
        guard let record = records[marker.eventID], record.ended, owners[record.call_key] == marker else { return nil }
        return record
    }

    func observe(_ marker: CallInitiateMarker) async {
        guard membershipAllowed, !forbidden.contains(marker.eventID), Date().timeIntervalSince(marker.timestamp) < 30 * 86400,
              marker.timestamp.timeIntervalSinceNow < 300 else { return }
        let revision = accessRevision
        var failures = 0
        // A view owns the polling task. SwiftUI cancels it when hidden/backgrounded.
        while !Task.isCancelled {
            guard membershipAllowed, revision == accessRevision, Date().timeIntervalSince(marker.timestamp) < 30 * 86400 else { return }
            var result = records[marker.eventID]
            var failureWait: TimeInterval?
            do {
                let data = try await api.request(["api", "recording", "calls"], query: [
                    .init(name: "room_id", value: roomID),
                    .init(name: "at", value: String(Int64(marker.timestamp.timeIntervalSince1970 * 1000)))
                ])
                let record = try JSONDecoder().decode(CallTimelineRecord.self, from: data)
                guard membershipAllowed, revision == accessRevision, record.room_id == roomID, !record.call_key.isEmpty, record.started_at.date != nil, !Task.isCancelled else { return }
                failures = 0
                if records.count > 256 { records.removeAll(); owners.removeAll() }
                records[marker.eventID] = record; result = record
                if let owner = owners[record.call_key] {
                    if marker.timestamp < owner.timestamp || (marker.timestamp == owner.timestamp && marker.eventID < owner.eventID) {
                        owners[record.call_key] = marker
                    }
                } else { owners[record.call_key] = marker }
                if owners[record.call_key] != marker { return }
                for id in record.uniqueParticipants.prefix(24) where names[id] == nil && CallSummaryPeople.isUserID(id) {
                    guard !Task.isCancelled else { return }
                    if case .success(let profile) = await api.client.profile(for: id), membershipAllowed, revision == accessRevision {
                        names[id] = profile.displayName ?? id; profiles[id] = profile
                    }
                }
            } catch let error as StalkNativeHTTPError where error.status == 401 || error.status == 403 {
                if error.status == 403 { forbidden.formUnion(records.keys); forbidden.insert(marker.eventID) }
                accessRevision += 1
                records.removeAll(); owners.removeAll(); names.removeAll(); profiles.removeAll(); return
            } catch let error as StalkNativeHTTPError where error.status == 404 {
                guard result == nil else { records[marker.eventID] = nil; return }
            } catch let error as StalkNativeHTTPError where [400, 405, 410, 501].contains(error.status) {
                records[marker.eventID] = nil; return
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                failures += 1
                guard let wait = Self.failureDelay(attempt: failures, retryAfter: (error as? StalkNativeHTTPError)?.retryAfter) else { return }
                failureWait = wait
            }
            guard let delay = failureWait ?? CallTimelineRecord.nextPoll(record: result, marker: marker.timestamp, now: Date()) else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }
}
