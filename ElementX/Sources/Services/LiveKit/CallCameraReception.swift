// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation
import LiveKit

@MainActor
struct CallIncomingPublication {
    let id: AnyHashable
    let isCameraVideo: Bool
    let setSubscribed: @MainActor (_ enabled: Bool, _ retry: Bool) async throws -> Void
}

/// One ordered command stream per call: the latest choice wins even during reconnect.
@MainActor
final class CallCameraReception: ObservableObject {
    enum Status: Equatable { case enabled, disabled, updating, failed }
    @Published private(set) var isEnabled = true
    @Published private(set) var status = Status.enabled
    private let publications: @MainActor () -> [CallIncomingPublication]
    private var applied: [AnyHashable: Bool] = [:]
    private var failed: Set<AnyHashable> = []
    private var task: Task<Void, Never>?
    private var revision = 0
    private var intent = 0
    private var generation = 0

    init(publications: @escaping @MainActor () -> [CallIncomingPublication]) {
        self.publications = publications
    }

    static func isCamera(kind: Track.Kind, source: Track.Source) -> Bool {
        kind == .video && source == .camera
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled || status == .failed else { return }
        isEnabled = enabled
        intent &+= 1
        status = .updating
        reconcile()
    }

    func retry() {
        guard status == .failed else { return }; setEnabled(isEnabled)
    }

    func reconcile(resetApplied: Bool = false) {
        if resetApplied { applied = [:] }
        revision &+= 1
        guard task == nil else { return }
        let generation = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.task = nil } }
            while !Task.isCancelled, self.generation == generation {
                let revision = self.revision, intent = self.intent
                let cameras = self.publications().filter(\.isCameraVideo)
                let ids = Set(cameras.map(\.id))
                self.applied = self.applied.filter { ids.contains($0.key) }
                self.failed.formIntersection(ids)
                var hadFailure = false
                for publication in cameras {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    let enabled = self.isEnabled
                    guard self.applied[publication.id] != enabled || self.failed.contains(publication.id) else { continue }
                    let retry = self.failed.remove(publication.id) != nil
                    do {
                        try await publication.setSubscribed(enabled, retry)
                    } catch {
                        guard !Task.isCancelled, self.generation == generation else { return }
                        self.failed.insert(publication.id)
                        hadFailure = true
                        DiagLog.write("Call", "camera reception update failed: \((error as NSError).code)")
                    }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    if self.revision != revision { break }
                    if !self.failed.contains(publication.id) { self.applied[publication.id] = enabled }
                }
                if hadFailure, self.intent == intent { self.status = .failed; return }
                if self.revision == revision {
                    self.status = self.isEnabled ? .enabled : .disabled
                    return
                }
            }
        }
    }

    func waitForPendingChanges() async {
        await task?.value
    }

    func reset() {
        generation &+= 1
        revision &+= 1
        task?.cancel(); task = nil
        applied = [:]; failed = []
        isEnabled = true; status = .enabled
    }
}
