// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum ClientSyncStatus: Equatable {
    case stopped, waitingForNetwork, connecting, updating, synced, authenticationRequired

    var title: String {
        switch self {
        case .stopped, .synced: return SL10n.tabChats
        case .waitingForNetwork: return NSLocalizedString("stalk_sync_waiting", value: "Waiting for network…", comment: "Chat sync state")
        case .connecting: return NSLocalizedString("stalk_sync_connecting", value: "Connecting…", comment: "Chat sync state")
        case .updating: return NSLocalizedString("stalk_sync_updating", value: "Updating…", comment: "Chat sync state")
        case .authenticationRequired: return NSLocalizedString("stalk_sync_login", value: "Sign in required", comment: "Chat sync state")
        }
    }

    var showsActivity: Bool {
        self == .connecting || self == .updating
    }
}

/// One cancellable retry loop. In particular an old cancelled task cannot clear
/// the next loop, and a retry may wait for a serialized SDK lifecycle transition.
@MainActor
final class ClientSyncRecovery {
    private var task: Task<Void, Never>?
    private var revision = 0
    private let delay: Duration

    init(delay: Duration = .seconds(3)) {
        self.delay = delay
    }

    func start(shouldRetry: @escaping @MainActor () -> Bool, retry: @escaping @MainActor () async -> Void) {
        guard shouldRetry() else { stop(); return }
        guard task == nil else { return }
        revision += 1
        let current = revision, delay = delay
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.revision == current else { return }
                guard shouldRetry() else { self.task = nil; return }
                await retry()
            }
        }
    }

    func stop() {
        revision += 1
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
