// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CallKit
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
    @Published private(set) var senders: [SystemSearchPerson] = []
    @Published private(set) var senderNotice: String?
    @Published private(set) var people: [SystemSearchPerson] = []
    @Published private(set) var peopleNotice: String?
    @Published private(set) var recording = false
    @Published private(set) var transcribing = false
    @Published private(set) var voiceNotice: String?
    private var peopleTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private let recorder: AilockVoiceRecorder
    private let callObserver = CXCallObserver()
    private let isCallActive: () -> Bool
    private let planner: @MainActor (SystemSearchConditions) async throws -> SystemSearchConditions
    private var stopped = false
    private var voiceGeneration = 0
    private var audioInterruption: AnyCancellable?
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

    init(client: ClientProxyProtocol, session: URLSession = .shared, defaults: UserDefaults = .standard, isCallActive: @escaping () -> Bool = { false },
         planner: (@MainActor (SystemSearchConditions) async throws -> SystemSearchConditions)? = nil) {
        let searchService = SystemSearchService(client: client, session: session)
        service = searchService; self.defaults = defaults; self.isCallActive = isCallActive
        recorder = AilockVoiceRecorder(isCallActive: isCallActive)
        self.planner = planner ?? { try await searchService.plan($0) }
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 {
            pinned = Array(saved.pinned.filter(\.valid).prefix(50)); recent = Array(saved.recent.filter(\.valid).prefix(12))
        }
        audioInterruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.recording,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self.cancelVoice()
                self.voiceNotice = NSLocalizedString("Запись прервана. Повторите голосовой запрос после завершения звонка или другого аудио.", comment: "System search notice")
            }
    }

    func updateQuery(_ value: String) {
        guard value != conditions.query else { return }
        cancelVoice()
        conditions.query = value
        conditions.topic = nil; conditions.expand = []; conditions.mode = "basic"; conditions.unsupported = nil; conditions.pendingSenderQuery = nil
        lookupPeople()
    }

    func restore(_ value: SystemSearchConditions) {
        cancelVoice(); conditions = value; lookupPeople(); search()
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
        stopped = false
        lookupPeople()
        if let lastResultAt, Date().timeIntervalSince(lastResultAt) > 30, conditions.canSearch { search() }
    }

    func stop() {
        stopped = true; generation += 1
        task?.cancel(); senderTask?.cancel(); peopleTask?.cancel(); cancelVoice(); loading = false
    }

    func lookupSenders() {
        senderTask?.cancel(); senders = []; senderNotice = NSLocalizedString("Уточняем контакты и справочник…", comment: "System search notice")
        let query = senderQuery
        senderTask = Task {
            let known = await service.knownSenders()
            guard !Task.isCancelled, !stopped, senderQuery == query else { return }
            senders = known.filter { $0.matchesSender(query) }
            senderNotice = NSLocalizedString("Уточняем контакты и справочник…", comment: "System search notice")
            let found = await service.lookupSenders(query: query)
            guard !Task.isCancelled, !stopped, senderQuery == query else { return }
            senders = found.people.filter { $0.matchesSender(query) }
            senderNotice = Self.directoryNotice(found)
        }
    }

    static func directoryNotice(_ directory: SystemSearchDirectory) -> String? {
        guard directory.complete, directory.contactsAvailable else {
            return NSLocalizedString("Список может быть неполным: часть контактов или результатов справочника недоступна. Уточните имя или Matrix ID и повторите поиск.", comment: "System search notice")
        }
        return nil
    }

    func lookupPeople() {
        peopleTask?.cancel(); people = []; peopleNotice = nil
        let query = conditions.query
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2, !stopped else { return }
        peopleTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let local = await service.knownSenders()
            guard !Task.isCancelled, conditions.query == query, !stopped else { return }
            people = service.people(query: query, directory: local)
            let directory = await service.lookupSenders(query: query)
            guard !Task.isCancelled, conditions.query == query, !stopped else { return }
            people = service.people(query: query, directory: directory.people)
            peopleNotice = Self.directoryNotice(directory)
        }
    }

    func search(smart: Bool = false, planNotice: String? = nil) {
        task?.cancel()
        if smart {
            conditions.topic = nil; conditions.expand = []; conditions.mode = "basic"; conditions.unsupported = nil; conditions.pendingSenderQuery = nil
        }
        generation += 1; let revision = generation
        let unsupported = (conditions.unsupported ?? []).compactMap { SystemSearchService.unsupportedLabels[$0] }
        let unsupportedNotice = unsupported.isEmpty ? nil : String(format: NSLocalizedString("stalk_search_unsupported_conditions", comment: "Unsupported search filter warning"), unsupported.joined(separator: ", "))
        let planNotice = planNotice ?? unsupportedNotice
        error = nil; notice = planNotice; loading = true; hasMore = false; viewType = nil; completeSnapshot = nil
        hits = []; facets = []; total = 0
        let snapshot = conditions
        guard snapshot.valid else {
            error = SystemSearchError.invalidConditions.localizedDescription
            submitted = nil; loading = false
            return
        }
        if let requested = snapshot.pendingSenderQuery {
            senderQuery = requested; submitted = nil; loading = false
            notice = [planNotice, String(format: NSLocalizedString("stalk_search_sender_unverified", comment: "Unverified search sender warning"), requested)].compactMap { $0 }.joined(separator: "\n")
            return
        }
        guard snapshot.canSearch else { hits = []; facets = []; total = 0; loading = false; return }
        task = Task {
            defer { if generation == revision { loading = false } }
            if smart {
                async let planned = planner(snapshot)
                var lexicalError: Error?
                var lexicalNotice: String?
                do {
                    let response = try await service.search(snapshot)
                    guard !Task.isCancelled, revision == generation else { return }
                    apply(response, snapshot: snapshot)
                    lexicalNotice = notice
                    notice = [NSLocalizedString("Предварительные результаты по словам. Уточняем условия…", comment: "System search notice"), notice].compactMap { $0 }.joined(separator: "\n")
                } catch { lexicalError = error }
                do {
                    let plan = try await planned
                    guard !Task.isCancelled, revision == generation, conditions == snapshot else { return }
                    task = nil; conditions = plan
                    search()
                } catch {
                    guard !Task.isCancelled, revision == generation else { return }
                    let fallback = lexicalError == nil
                        ? NSLocalizedString("Не удалось уточнить запрос через Айлок. Показаны результаты по исходной фразе; ваши фильтры сохранены.", comment: "System search notice")
                        : NSLocalizedString("Не удалось уточнить запрос через Айлок. Поиск по исходной фразе также не удался; ваши фильтры сохранены.", comment: "System search notice")
                    notice = [fallback, lexicalNotice].compactMap { $0 }.joined(separator: "\n")
                    if let lexicalError { self.error = lexicalError.localizedDescription; hits = []; facets = []; total = 0 }
                }
                return
            }
            do {
                let response = try await service.search(snapshot)
                guard !Task.isCancelled, revision == generation else { return }
                apply(response, snapshot: snapshot, planNotice: planNotice)
            } catch {
                if !Task.isCancelled, revision == generation { self.error = error.localizedDescription }
            }
        }
    }

    private func apply(_ response: SystemSearchResponse, snapshot: SystemSearchConditions, planNotice: String? = nil) {
        submitted = snapshot; hits = response.results; facets = response.facets ?? []; total = response.total + (response.semantic?.tail ?? 0)
        lastResultAt = Date(); offset = response.results.count
        hasMore = !response.results.isEmpty && offset < total && offset <= 10000
        if !hasMore, hits.count == total, response.semantic?.error == nil { completeSnapshot = (Date(), hits) }
        var notices = [planNotice].compactMap { $0 }
        if response.queryTruncated == true { notices.append(String(format: NSLocalizedString("stalk_search_query_truncated", comment: "Search query truncated notice: number of words used"), Int64(response.wordsUsed ?? 0))) }
        if let identity = response.scope?.plane_identity, ["не сопоставлена", "unlinked", "unmatched"].contains(identity) {
            notices.append(NSLocalizedString("Учётная запись TrackIT не связана. Часть задач и страниц может быть недоступна.", comment: "System search notice"))
        }
        if response.semantic?.error != nil { notices.append(NSLocalizedString("Смысловой поиск временно недоступен. Показаны результаты по словам.", comment: "System search notice")) }
        notice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        recent.removeAll { $0.query == snapshot.query }; recent.insert(snapshot, at: 0); recent = Array(recent.prefix(12)); save()
    }

    private var callInProgress: Bool {
        isCallActive() || callObserver.calls.contains { !$0.hasEnded } ||
            [AVAudioSession.Mode.voiceChat, .videoChat].contains(AVAudioSession.sharedInstance().mode)
    }

    /// The microphone is acquired only after this explicit screen action.
    func toggleVoice() {
        if recording { finishVoice(); return }
        guard voiceTask == nil, !transcribing else { return }
        voiceNotice = nil
        guard !callInProgress else { voiceNotice = AilockVoiceError.callInProgress.localizedDescription; return }
        voiceGeneration += 1; let revision = voiceGeneration
        voiceTask = Task {
            defer { if voiceGeneration == revision { voiceTask = nil } }
            guard await AilockVoiceRecorder.requestPermission() else {
                if !Task.isCancelled { voiceNotice = AilockVoiceError.permissionDenied.localizedDescription; voiceTask = nil }
                return
            }
            guard !Task.isCancelled, !stopped else { return }
            guard !callInProgress else { voiceNotice = AilockVoiceError.callInProgress.localizedDescription; voiceTask = nil; return }
            do {
                try recorder.start(); recording = true
                while recorder.duration < AilockVoiceRecorder.maxDuration {
                    try await Task.sleep(for: .milliseconds(250))
                    guard !callInProgress else {
                        cancelVoice(); voiceNotice = AilockVoiceError.callInProgress.localizedDescription; return
                    }
                    if !recorder.isRecording { break }
                }
                finishVoice()
            } catch {
                if !Task.isCancelled { cancelVoice(); voiceNotice = error.localizedDescription }
            }
        }
    }

    private func finishVoice() {
        voiceTask?.cancel(); voiceTask = nil; recording = false
        voiceGeneration += 1; let revision = voiceGeneration
        guard !callInProgress else { recorder.cancel(); voiceNotice = AilockVoiceError.callInProgress.localizedDescription; return }
        guard let file = recorder.finish() else { voiceNotice = NSLocalizedString("Запишите запрос длительностью не менее секунды.", comment: "System search notice"); return }
        transcribing = true
        let snapshot = conditions
        voiceTask = Task {
            defer {
                try? FileManager.default.removeItem(at: file)
                if voiceGeneration == revision { transcribing = false; voiceTask = nil }
            }
            do {
                let transcriber = AilockVoiceTranscriber(homeserver: service.base,
                                                         accessTokenProvider: { try self.service.client.matrixAccessToken() },
                                                         forceTokenRefresh: { await self.service.client.forceTokenRefresh() })
                let phrase = try await transcriber.transcribe(fileURL: file)
                guard !Task.isCancelled, !stopped, conditions == snapshot else { return }
                voiceTask = nil; transcribing = false
                updateQuery(phrase); search(smart: true)
            } catch {
                guard !Task.isCancelled else { return }
                transcribing = false; voiceTask = nil; voiceNotice = error.localizedDescription
            }
        }
    }

    func cancelVoice() {
        voiceGeneration += 1
        voiceTask?.cancel(); voiceTask = nil
        recorder.cancel(); recording = false; transcribing = false
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
                let count = type.flatMap { wanted in facets.first { $0.entity_type == wanted }?.count } ?? response.total + (response.semantic?.tail ?? 0)
                hasMore = !hits.isEmpty && offset < count && offset <= 10000
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
