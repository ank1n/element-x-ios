//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

class UserSession: UserSessionProtocol {
    private var cancellables = Set<AnyCancellable>()

    private var authErrorCancellable: AnyCancellable?

    /// sTalk: Prevents duplicate auto-recovery bootstrap runs
    private var isAutoRecoveryInProgress = false

    let clientProxy: ClientProxyProtocol
    let mediaProvider: MediaProviderProtocol
    let voiceMessageMediaManager: VoiceMessageMediaManagerProtocol
    
    let callbacks = PassthroughSubject<UserSessionCallback, Never>()
    
    let sessionSecurityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .unknown, recoveryState: .unknown))
    var sessionSecurityStatePublisher: CurrentValuePublisher<SessionSecurityState, Never> {
        sessionSecurityStateSubject.asCurrentValuePublisher()
    }
    
    init(clientProxy: ClientProxyProtocol, mediaProvider: MediaProviderProtocol, voiceMessageMediaManager: VoiceMessageMediaManagerProtocol) {
        self.clientProxy = clientProxy
        self.mediaProvider = mediaProvider
        self.voiceMessageMediaManager = voiceMessageMediaManager
        
        authErrorCancellable = clientProxy.actionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] callback in
                guard let self else { return }
                switch callback {
                case .receivedAuthError(let isSoftLogout):
                    callbacks.send(.didReceiveAuthError(isSoftLogout: isSoftLogout))
                    authErrorCancellable = nil
                default:
                    break
                }
            }
        
        Publishers.CombineLatest(clientProxy.verificationStatePublisher, clientProxy.secureBackupController.recoveryState)
            .map {
                MXLog.info("Session security state changed, verificationState: \($0), recoveryState: \($1)")
                return SessionSecurityState(verificationState: $0, recoveryState: $1)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.sessionSecurityStateSubject.send(value)
            }
            .store(in: &cancellables)

        // sTalk: Auto-bootstrap recovery (secret storage / 4S) after login.
        // The Rust SDK already auto-enables cross-signing and key backup via ClientBuilder
        // (autoEnableCrossSigning + autoEnableBackups). Recovery must be enabled separately
        // so that the "set up recovery" / "key storage out of sync" banners don't appear.
        // This mirrors Element Web's post-login bootstrapSecretStorage() behavior.
        setupAutoRecovery()
    }

    // MARK: - Private

    /// sTalk: Full automatic E2EE bootstrap.
    /// - First device (verified by SDK): generates recovery key and stores it on server
    /// - Second device (unverified): fetches recovery key from server and auto-verifies
    /// Recovery key is stored via Matrix custom account data event `im.stalk.recovery_key`
    private func setupAutoRecovery() {
        var autoRecoveryCancellable: AnyCancellable?
        autoRecoveryCancellable = Publishers.CombineLatest(
            clientProxy.verificationStatePublisher,
            clientProxy.secureBackupController.recoveryState
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] verificationState, recoveryState in
            guard let self else {
                autoRecoveryCancellable?.cancel()
                return
            }

            MXLog.info("sTalk: E2EE state — verification: \(verificationState), recovery: \(recoveryState)")

            switch (verificationState, recoveryState) {
            case (.verified, .disabled), (.verified, .incomplete):
                // First device or broken state: generate recovery key
                autoRecoveryCancellable?.cancel()
                autoRecoveryCancellable = nil
                MXLog.info("sTalk: Auto-enabling recovery (verified, state: \(recoveryState))")
                Task {
                    let result = await self.clientProxy.secureBackupController.generateRecoveryKey()
                    switch result {
                    case .success(let key):
                        MXLog.info("sTalk: Recovery enabled (key length: \(key.count))")
                        // Store recovery key on server for other devices
                        await Self.storeRecoveryKeyOnServer(key: key, clientProxy: self.clientProxy)
                    case .failure(let error):
                        MXLog.error("sTalk: Recovery failed: \(error)")
                    }
                }

            case (.verified, .enabled):
                autoRecoveryCancellable?.cancel()
                autoRecoveryCancellable = nil
                MXLog.info("sTalk: E2EE fully set up — checking if recovery key is stored on server")
                Task {
                    await self.ensureRecoveryKeyStoredOnServer()
                }

            case (.unverified, .disabled), (.unverified, .enabled), (.unverified, .incomplete):
                // Second device: try to recover using stored recovery key
                autoRecoveryCancellable?.cancel()
                autoRecoveryCancellable = nil
                MXLog.info("sTalk: Unverified device — attempting auto-verify with stored recovery key")
                Task {
                    await self.autoVerifyWithStoredRecoveryKey()
                }

            default:
                break // .unknown — wait for state to settle
            }
        }
        autoRecoveryCancellable?.store(in: &cancellables)
    }

    /// Check if recovery key is stored on server; if not, regenerate and store it
    private func ensureRecoveryKeyStoredOnServer() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }

        let encodedUserID = clientProxy.userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientProxy.userID
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/im.stalk.recovery_key") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let (data, response) = try? await URLSession.shared.data(for: request),
           let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["key"] is String {
            MXLog.info("sTalk: Recovery key already stored on server")
            return
        }

        // Key not on server — regenerate (reset) and store
        MXLog.info("sTalk: Recovery key not on server — regenerating and storing")
        let result = await clientProxy.secureBackupController.generateRecoveryKey()
        switch result {
        case .success(let key):
            await Self.storeRecoveryKeyOnServer(key: key, clientProxy: clientProxy)
        case .failure(let error):
            MXLog.error("sTalk: Failed to regenerate recovery key: \(error)")
        }
    }

    /// Store recovery key on Matrix server via custom account data event
    private static func storeRecoveryKeyOnServer(key: String, clientProxy: ClientProxyProtocol) async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            MXLog.error("sTalk: Can't store recovery key — no access token")
            return
        }

        let encodedUserID = clientProxy.userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientProxy.userID
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/im.stalk.recovery_key") else {
            MXLog.error("sTalk: Invalid URL for account data")
            return
        }

        MXLog.info("sTalk: Storing recovery key at URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["key": key, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                MXLog.info("sTalk: Recovery key stored on server")
            } else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                MXLog.error("sTalk: Failed to store recovery key — status: \((response as? HTTPURLResponse)?.statusCode ?? -1), body: \(body)")
            }
        } catch {
            MXLog.error("sTalk: Failed to store recovery key: \(error)")
        }
    }

    /// Fetch stored recovery key from server and use it to verify this device.
    /// If no key found, bootstrap recovery directly (first device scenario).
    private func autoVerifyWithStoredRecoveryKey() async {
        guard !isAutoRecoveryInProgress else {
            MXLog.info("sTalk: Auto-recovery already in progress, skipping")
            return
        }
        isAutoRecoveryInProgress = true
        defer { isAutoRecoveryInProgress = false }
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            MXLog.error("sTalk: Can't fetch recovery key — no access token")
            return
        }

        let encodedUserID = clientProxy.userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientProxy.userID
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/im.stalk.recovery_key") else {
            MXLog.error("sTalk: Invalid URL for account data")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                // No recovery key on server — first device scenario.
                // Instead of waiting for SDK to auto-verify (which may never happen),
                // directly bootstrap recovery. enableRecovery() creates SSSS + recovery key
                // and self-signs the device as a side effect.
                MXLog.info("sTalk: No recovery key on server — bootstrapping recovery directly (first device)")
                await bootstrapRecoveryForFirstDevice()
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recoveryKey = json["key"] as? String else {
                MXLog.error("sTalk: Invalid recovery key data from server")
                return
            }

            MXLog.info("sTalk: Got recovery key from server (length: \(recoveryKey.count)), attempting recover...")
            let result = await clientProxy.secureBackupController.confirmRecoveryKey(recoveryKey)
            switch result {
            case .success:
                MXLog.info("sTalk: Recovery key confirmed successfully")
                // Wait a moment for verification state to propagate
                try? await Task.sleep(for: .seconds(2))
                let currentState = clientProxy.verificationStatePublisher.value
                MXLog.info("sTalk: After confirm — verification state: \(currentState)")
                if currentState != .verified {
                    MXLog.info("sTalk: Still unverified after confirm — doing full bootstrap")
                    await bootstrapRecoveryForFirstDevice()
                }
            case .failure(let error):
                MXLog.error("sTalk: Recovery key verification failed: \(error) — doing full bootstrap")
                await bootstrapRecoveryForFirstDevice()
            }
        } catch {
            MXLog.error("sTalk: Failed to fetch recovery key: \(error)")
        }
    }

    /// First device bootstrap: delete existing backup, then use forceEnableRecovery()
    /// which calls enableRecovery() directly. This does a FULL bootstrap:
    /// creates SSSS with cross-signing private keys, backup, and recovery key.
    private func bootstrapRecoveryForFirstDevice() async {
        // Small delay to let SDK settle after login
        try? await Task.sleep(for: .seconds(3))

        let recoveryState = clientProxy.secureBackupController.recoveryState.value
        MXLog.info("sTalk: Full bootstrap — current state: \(recoveryState)")

        // Step 1: Clean up ALL old E2EE account data and backups from server.
        // This is needed when the server has stale SSSS keys/secrets from previous sessions
        // that can't be decrypted with any known recovery key.
        await cleanupServerE2EEState()
        await deleteAllBackupVersions()

        // Step 2: Reset identity to create fresh cross-signing keys.
        // With _allow_cross_signing_replacement_without_uia set on server,
        // this should proceed without OIDC auth (returns nil handle).
        MXLog.info("sTalk: Resetting identity to create fresh cross-signing keys...")
        let resetResult = await clientProxy.resetIdentity()
        switch resetResult {
        case .success(let handle):
            if let handle {
                // OIDC auth required — can't do automatically, cancel
                MXLog.error("sTalk: resetIdentity requires OIDC auth — cancelling")
                await handle.cancel()
            } else {
                MXLog.info("sTalk: Identity reset succeeded (no auth needed)")
            }
        case .failure(let error):
            MXLog.error("sTalk: resetIdentity failed: \(error)")
        }

        // Wait for SDK to process the new cross-signing keys
        try? await Task.sleep(for: .seconds(3))

        // Step 3: Now enable recovery with the fresh cross-signing keys
        let result = await clientProxy.secureBackupController.forceEnableRecovery()
        switch result {
        case .success(let key):
            MXLog.info("sTalk: Full bootstrap succeeded (key length: \(key.count))")
            await Self.storeRecoveryKeyOnServer(key: key, clientProxy: clientProxy)
        case .failure(let error):
            MXLog.error("sTalk: Full bootstrap failed: \(error)")
        }
    }

    /// Clean up stale E2EE account data on server (SSSS keys, cross-signing secrets).
    /// This allows enableRecovery() to create everything fresh.
    private func cleanupServerE2EEState() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }
        let encodedUserID = clientProxy.userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientProxy.userID
        let baseURL = "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data"

        // Account data events to clear
        let eventTypes = [
            "m.secret_storage.default_key",
            "m.cross_signing.master",
            "m.cross_signing.self_signing",
            "m.cross_signing.user_signing",
            "m.megolm_backup.v1"
        ]

        for eventType in eventTypes {
            guard let url = URL(string: "\(baseURL)/\(eventType)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{}".data(using: .utf8)

            if let (_, response) = try? await URLSession.shared.data(for: request),
               let httpResponse = response as? HTTPURLResponse {
                MXLog.info("sTalk: Cleared \(eventType) — status: \(httpResponse.statusCode)")
            }
        }

        // Also find and clear any SSSS key definitions (m.secret_storage.key.*)
        // We can't enumerate them, but the default_key is cleared above,
        // so enableRecovery will create a new one.
        MXLog.info("sTalk: Server E2EE state cleaned up")
    }

    /// Delete all key backup versions from the server via Matrix API.
    private func deleteAllBackupVersions() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }

        // Delete backup versions in a loop until none are left
        for attempt in 1...5 {
            guard let versionURL = URL(string: "\(homeserverURL)/_matrix/client/v3/room_keys/version") else { return }
            var getRequest = URLRequest(url: versionURL)
            getRequest.httpMethod = "GET"
            getRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: getRequest),
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else {
                MXLog.info("sTalk: No more backup versions on server (attempt \(attempt))")
                break
            }

            MXLog.info("sTalk: Deleting backup version \(version) (attempt \(attempt))...")
            guard let deleteURL = URL(string: "\(homeserverURL)/_matrix/client/v3/room_keys/version/\(version)") else { return }
            var deleteRequest = URLRequest(url: deleteURL)
            deleteRequest.httpMethod = "DELETE"
            deleteRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            if let (_, deleteResponse) = try? await URLSession.shared.data(for: deleteRequest),
               let deleteHTTP = deleteResponse as? HTTPURLResponse {
                MXLog.info("sTalk: Delete backup version \(version) response: \(deleteHTTP.statusCode)")
            }
        }

        // Wait for SDK to detect that backup is gone
        MXLog.info("sTalk: Waiting for SDK to update backup state...")
        try? await Task.sleep(for: .seconds(3))
    }
}
