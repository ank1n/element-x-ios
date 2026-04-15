//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import os.log
import UIKit

private let e2eeLog = OSLog(subsystem: "ru.implica.stalk", category: "E2EE")

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
        autoRecoveryCancellable = Publishers.CombineLatest(clientProxy.verificationStatePublisher,
                                                           clientProxy.secureBackupController.recoveryState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] verificationState, recoveryState in
                guard let self else {
                    autoRecoveryCancellable?.cancel()
                    return
                }

                os_log(.fault, log: e2eeLog, "E2EE state — verification: %{public}@, recovery: %{public}@", String(describing: verificationState), String(describing: recoveryState))
                MXLog.info("sTalk: E2EE state — verification: \(verificationState), recovery: \(recoveryState)")

                switch (verificationState, recoveryState) {
                case (.verified, .disabled), (.verified, .incomplete):
                    // Try to restore from server first (may be re-install, not first device)
                    autoRecoveryCancellable?.cancel()
                    autoRecoveryCancellable = nil
                    os_log(.fault, log: e2eeLog, "Verified + %{public}@ — trying server key first", String(describing: recoveryState))
                    MXLog.info("sTalk: Verified + \(recoveryState) — trying server recovery key first")
                    Task {
                        // First try to recover with existing key from server
                        let restored = await self.tryRestoreFromServerKey()
                        if !restored {
                            // No key on server or invalid — truly first device, generate new
                            MXLog.info("sTalk: No valid server key — generating new recovery key (first device)")
                            let result = await self.clientProxy.secureBackupController.generateRecoveryKey()
                            switch result {
                            case .success(let key):
                                MXLog.info("sTalk: Recovery enabled (key length: \(key.count))")
                                await Self.storeRecoveryKeyOnServer(key: key, clientProxy: self.clientProxy)
                            case .failure(let error):
                                MXLog.error("sTalk: Recovery failed: \(error)")
                            }
                        }
                    }

                case (.verified, .enabled):
                    autoRecoveryCancellable?.cancel()
                    autoRecoveryCancellable = nil
                    MXLog.info("sTalk: E2EE fully set up — uploading keys to backup")
                    Task {
                        await self.uploadKeysToExistingBackup()
                        await self.cleanupOldDevicesByIDFV()
                    }

                case (.unverified, .disabled), (.unverified, .enabled), (.unverified, .incomplete), (.unverified, .unknown):
                    // Second device or unknown state: try to recover using stored recovery key
                    autoRecoveryCancellable?.cancel()
                    autoRecoveryCancellable = nil
                    os_log(.fault, log: e2eeLog, "Unverified + %{public}@ — attempting auto-verify", String(describing: recoveryState))
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

    /// Try to restore E2EE keys using recovery key from server.
    /// Returns true if restoration succeeded.
    private func tryRestoreFromServerKey() async -> Bool {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            MXLog.error("sTalk: tryRestore — no access token")
            return false
        }

        let encodedUserID = clientProxy.userID
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/im.stalk.recovery_key") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recoveryKey = json["key"] as? String, !recoveryKey.isEmpty else {
                os_log(.fault, log: e2eeLog, "tryRestore — no key on server (HTTP %d)", (response as? HTTPURLResponse)?.statusCode ?? -1)
                MXLog.info("sTalk: tryRestore — no recovery key on server")
                return false
            }

            os_log(.fault, log: e2eeLog, "tryRestore — found key (length: %d), attempting recover...", recoveryKey.count)
            MXLog.info("sTalk: tryRestore — found key (length: \(recoveryKey.count)), attempting recover...")
            let result = await clientProxy.secureBackupController.confirmRecoveryKey(recoveryKey)
            switch result {
            case .success:
                os_log(.fault, log: e2eeLog, "tryRestore — SUCCESS! Keys restored")
                MXLog.info("sTalk: tryRestore — recovery key confirmed, keys restored!")
                return true
            case .failure(let error):
                os_log(.fault, log: e2eeLog, "tryRestore — FAILED: %{public}@", String(describing: error))
                MXLog.error("sTalk: tryRestore — confirmRecoveryKey failed: \(error)")
                return false
            }
        } catch {
            MXLog.error("sTalk: tryRestore — fetch error: \(error)")
            return false
        }
    }

    /// Ensure recovery key and backup are properly set up on server.
    /// Deletes stale backup, creates new one, uploads all local Megolm keys.
    private func ensureRecoveryKeyStoredOnServer() async {
        os_log(.fault, log: e2eeLog, "ensureRecovery: starting...")

        // Step 1: Delete old backup (may be encrypted with wrong key)
        os_log(.fault, log: e2eeLog, "ensureRecovery: deleting old backup versions...")
        await deleteAllBackupVersions()

        // Step 2: Enable backup (creates new backup version, uploads all local keys)
        os_log(.fault, log: e2eeLog, "ensureRecovery: enabling backup...")
        let backupResult = await clientProxy.secureBackupController.enable()
        os_log(.fault, log: e2eeLog, "ensureRecovery: enableBackups result: %{public}@", String(describing: backupResult))

        // Step 3: Regenerate recovery key and store on server
        os_log(.fault, log: e2eeLog, "ensureRecovery: regenerating recovery key...")
        let result = await clientProxy.secureBackupController.generateRecoveryKey()
        switch result {
        case .success(let key):
            os_log(.fault, log: e2eeLog, "ensureRecovery: got key (length: %d), storing on server...", key.count)
            await Self.storeRecoveryKeyOnServer(key: key, clientProxy: clientProxy)
            os_log(.fault, log: e2eeLog, "ensureRecovery: DONE — backup created + key stored")
        case .failure(let error):
            os_log(.fault, log: e2eeLog, "ensureRecovery: generateRecoveryKey FAILED: %{public}@", String(describing: error))
        }

        // Step 4: Wait for backup upload to complete
        os_log(.fault, log: e2eeLog, "ensureRecovery: waiting for backup upload...")
        _ = await clientProxy.secureBackupController.waitForKeyBackupUpload(uploadStateSubject: .init(.waiting))
        os_log(.fault, log: e2eeLog, "ensureRecovery: backup upload complete")
    }

    /// Upload all local megolm keys to backup.
    /// If backup exists but we don't have its key, and it's empty (count=0),
    /// delete it and create a new one so SDK can upload.
    private func uploadKeysToExistingBackup() async {
        os_log(.fault, log: e2eeLog, "uploadKeys: trying enableBackups...")
        let backupResult = await clientProxy.secureBackupController.enable()

        switch backupResult {
        case .success:
            os_log(.fault, log: e2eeLog, "uploadKeys: enableBackups succeeded")
        case .failure:
            // enableBackups failed — likely BackupExistsOnServer but we don't have the key
            let count = await getBackupKeyCount()
            os_log(.fault, log: e2eeLog, "uploadKeys: enableBackups failed, server backup has %d keys", count)
            if count == 0 {
                // Safe to delete empty backup and recreate
                os_log(.fault, log: e2eeLog, "uploadKeys: deleting empty backup and recreating...")
                await deleteAllBackupVersions()
                let retryResult = await clientProxy.secureBackupController.enable()
                os_log(.fault, log: e2eeLog, "uploadKeys: retry enableBackups: %{public}@", String(describing: retryResult))
            } else {
                os_log(.fault, log: e2eeLog, "uploadKeys: backup has %d keys — NOT deleting. Need recovery key to access.", count)
                return
            }
        }

        os_log(.fault, log: e2eeLog, "uploadKeys: waiting for upload to complete...")
        _ = await clientProxy.secureBackupController.waitForKeyBackupUpload(uploadStateSubject: .init(.waiting))

        let finalCount = await getBackupKeyCount()
        os_log(.fault, log: e2eeLog, "uploadKeys: DONE — server backup now has %d keys", finalCount)
    }

    /// Store recovery key on Matrix server via custom account data event
    private static func storeRecoveryKeyOnServer(key: String, clientProxy: ClientProxyProtocol) async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            MXLog.error("sTalk: Can't store recovery key — no access token")
            return
        }

        let encodedUserID = clientProxy.userID
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
        os_log(.fault, log: e2eeLog, "autoVerify: starting")
        guard !isAutoRecoveryInProgress else {
            os_log(.fault, log: e2eeLog, "autoVerify: already in progress, skipping")
            return
        }
        isAutoRecoveryInProgress = true
        defer { isAutoRecoveryInProgress = false }
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            os_log(.fault, log: e2eeLog, "autoVerify: no access token!")
            return
        }
        os_log(.fault, log: e2eeLog, "autoVerify: homeserver=%{public}@ token=%{public}@...", homeserverURL, String(accessToken.prefix(10)))

        let encodedUserID = clientProxy.userID
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/im.stalk.recovery_key") else {
            MXLog.error("sTalk: Invalid URL for account data")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        os_log(.fault, log: e2eeLog, "autoVerify: URL=%{public}@", url.absoluteString)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            os_log(.fault, log: e2eeLog, "autoVerify: HTTP %d, %d bytes", statusCode, data.count)
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
                os_log(.fault, log: e2eeLog, "autoVerify: invalid JSON or missing key. Raw: %{public}@", String(data: data, encoding: .utf8) ?? "binary")
                return
            }

            os_log(.fault, log: e2eeLog, "autoVerify: got key (length: %d), checking if backup exists...", recoveryKey.count)

            // Check if key backup exists on server before trying to recover
            let backupExists = await clientProxy.secureBackupController.keyBackupState.value != .unknown
            os_log(.fault, log: e2eeLog, "autoVerify: backup state: %{public}@", String(describing: clientProxy.secureBackupController.keyBackupState.value))

            // Clean up stale SSSS keys before recovery — too many keys slow down the SDK
            await cleanupStaleSSSKeys()

            os_log(.fault, log: e2eeLog, "autoVerify: calling confirmRecoveryKey (with 120s timeout)...")

            // Wrap in timeout — large key counts need more time
            let result: Result<Void, SecureBackupControllerError> = await withTaskGroup(of: Result<Void, SecureBackupControllerError>?.self) { group in
                group.addTask {
                    await self.clientProxy.secureBackupController.confirmRecoveryKey(recoveryKey)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(120))
                    return nil // timeout sentinel
                }
                if let first = await group.next(), let result = first {
                    group.cancelAll()
                    return result
                }
                // Timeout reached
                group.cancelAll()
                os_log(.fault, log: e2eeLog, "autoVerify: confirmRecoveryKey TIMED OUT (15s)")
                return .failure(.failedConfirmingRecoveryKey)
            }
            switch result {
            case .success:
                os_log(.fault, log: e2eeLog, "autoVerify: confirmRecoveryKey SUCCESS! Keys restored from backup.")
                // Wait for SDK to process recovery and potentially auto-verify device
                for i in 1...5 {
                    try? await Task.sleep(for: .seconds(2))
                    let currentState = clientProxy.verificationStatePublisher.value
                    os_log(.fault, log: e2eeLog, "autoVerify: check %d/5 — state: %{public}@", i, String(describing: currentState))
                    if currentState == .verified {
                        os_log(.fault, log: e2eeLog, "autoVerify: device auto-verified after recovery!")
                        await cleanupOldDevicesByIDFV()
                        return
                    }
                }
                // Still unverified after 10s — explicitly cross-sign device
                os_log(.fault, log: e2eeLog, "autoVerify: still unverified after 10s — cross-signing device via resetIdentity")
                await selfVerifyDevice()
                await cleanupOldDevicesByIDFV()
            case .failure(let error):
                os_log(.fault, log: e2eeLog, "autoVerify: confirmRecoveryKey FAILED: %{public}@", String(describing: error))
                // sTalk: Do NOT call bootstrapRecoveryForFirstDevice() here!
                // It deletes ALL backup versions, destroying keys uploaded by other clients.
                // Instead, just cross-sign the device to get verified status.
                os_log(.fault, log: e2eeLog, "autoVerify: skipping destructive bootstrap — preserving existing key backup")
                await selfVerifyDevice()
                await cleanupOldDevicesByIDFV()
            }
        } catch {
            os_log(.fault, log: e2eeLog, "autoVerify: network error: %{public}@", String(describing: error))
        }
    }

    /// Cross-sign this device after successful key recovery.
    /// Unlike bootstrapRecoveryForFirstDevice(), this preserves existing key backup
    /// (Megolm keys are already restored). Only resets cross-signing identity and SSSS.
    private func selfVerifyDevice() async {
        os_log(.fault, log: e2eeLog, "selfVerify: resetting identity to cross-sign device...")

        // Step 1: Reset identity — creates new cross-signing keys + signs this device
        let resetResult = await clientProxy.resetIdentity()
        switch resetResult {
        case .success(let handle):
            if let handle {
                os_log(.fault, log: e2eeLog, "selfVerify: OIDC auth required — cancelling (server needs _allow_cross_signing_replacement_without_uia)")
                await handle.cancel()
                return
            }
            os_log(.fault, log: e2eeLog, "selfVerify: identity reset succeeded — device should be cross-signed")
        case .failure(let error):
            os_log(.fault, log: e2eeLog, "selfVerify: resetIdentity failed: %{public}@", String(describing: error))
            return
        }

        // Wait for SDK to process new cross-signing keys
        try? await Task.sleep(for: .seconds(3))

        let state = clientProxy.verificationStatePublisher.value
        os_log(.fault, log: e2eeLog, "selfVerify: after reset — verification state: %{public}@", String(describing: state))

        // Step 2: Clean up old SSSS (now invalid after identity reset)
        await cleanupServerE2EEState()

        // Step 3: Create new SSSS with new cross-signing keys + new backup + recovery key
        // Existing backup is deleted and recreated with current keys (including recovered Megolm keys)
        let result = await clientProxy.secureBackupController.forceEnableRecovery()
        switch result {
        case .success(let key):
            os_log(.fault, log: e2eeLog, "selfVerify: recovery enabled — key length: %d", key.count)
            await Self.storeRecoveryKeyOnServer(key: key, clientProxy: clientProxy)
            os_log(.fault, log: e2eeLog, "selfVerify: DONE — device verified + recovery key stored on server")
        case .failure(let error):
            os_log(.fault, log: e2eeLog, "selfVerify: forceEnableRecovery failed: %{public}@", String(describing: error))
        }
    }

    /// First device bootstrap: create fresh cross-signing keys and recovery.
    /// WARNING: Only deletes backup if it has 0 keys. Otherwise preserves it.
    private func bootstrapRecoveryForFirstDevice() async {
        os_log(.fault, log: e2eeLog, "bootstrap: STARTING full E2EE bootstrap...")
        // Small delay to let SDK settle after login
        try? await Task.sleep(for: .seconds(3))

        let recoveryState = clientProxy.secureBackupController.recoveryState.value
        MXLog.info("sTalk: Full bootstrap — current state: \(recoveryState)")

        // Step 1: Clean up old E2EE account data.
        // Only delete backup versions if they contain NO keys (count=0).
        // Backup with keys from other clients must be preserved!
        await cleanupServerE2EEState()
        let backupKeyCount = await getBackupKeyCount()
        if backupKeyCount == 0 {
            os_log(.fault, log: e2eeLog, "bootstrap: backup has 0 keys — safe to delete and recreate")
            await deleteAllBackupVersions()
        } else {
            os_log(.fault, log: e2eeLog, "bootstrap: backup has %d keys — PRESERVING existing backup", backupKeyCount)
        }

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
        let encodedUserID = clientProxy.userID
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

    /// Log current SSSS default key for diagnostics.
    /// Stale SSSS keys are cleaned up server-side (DB maintenance).
    private func cleanupStaleSSSKeys() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }
        let encodedUserID = clientProxy.userID

        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/m.secret_storage.default_key") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let (data, response) = try? await URLSession.shared.data(for: request),
           let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let keyID = json["key"] as? String {
            os_log(.fault, log: e2eeLog, "cleanupSSS: default SSSS key: %{public}@", keyID)
        } else {
            os_log(.fault, log: e2eeLog, "cleanupSSS: no default SSSS key found")
        }
    }

    /// Check how many keys are in the current backup version.
    private func getBackupKeyCount() async -> Int {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken(),
              let url = URL(string: "\(homeserverURL)/_matrix/client/v3/room_keys/version") else { return 0 }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["count"] as? Int else {
            return 0
        }
        return count
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

    // MARK: - Device Cleanup (IDFV)

    /// IDFV tag prefix used in device display_name to identify the physical device.
    private static let idfvTagPrefix = "[idfv:"
    private static let idfvTagSuffix = "]"

    /// Clean up old Matrix devices that belong to the same physical device (same IDFV).
    /// Each reinstall creates a new device_id, but IDFV stays the same.
    /// After successful verification, we tag current device with IDFV and delete old ones.
    private func cleanupOldDevicesByIDFV() async {
        guard let idfv = await UIDevice.current.identifierForVendor?.uuidString else {
            os_log(.fault, log: e2eeLog, "cleanup: no IDFV available")
            return
        }

        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }
        let currentDeviceID = clientProxy.deviceID

        os_log(.fault, log: e2eeLog, "cleanup: IDFV=%{public}@, current device=%{public}@", idfv, currentDeviceID ?? "nil")

        // Step 1: Tag current device with IDFV in display_name
        let idfvTag = "\(Self.idfvTagPrefix)\(idfv)\(Self.idfvTagSuffix)"
        if let deviceID = currentDeviceID {
            await tagDeviceWithIDFV(deviceID: deviceID, idfvTag: idfvTag, homeserverURL: homeserverURL, accessToken: accessToken)
        }

        // Step 2: List all devices
        guard let devicesURL = URL(string: "\(homeserverURL)/_matrix/client/v3/devices") else { return }
        var request = URLRequest(url: devicesURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else {
            os_log(.fault, log: e2eeLog, "cleanup: failed to list devices")
            return
        }

        os_log(.fault, log: e2eeLog, "cleanup: found %d devices total", devices.count)

        // Step 3: Find and delete old devices with same IDFV
        var deletedCount = 0
        for device in devices {
            guard let deviceID = device["device_id"] as? String,
                  deviceID != currentDeviceID,
                  let displayName = device["display_name"] as? String,
                  displayName.contains(idfvTag) else {
                continue
            }

            os_log(.fault, log: e2eeLog, "cleanup: deleting old device %{public}@ (same IDFV)", deviceID)
            await deleteDevice(deviceID: deviceID, homeserverURL: homeserverURL, accessToken: accessToken)
            deletedCount += 1
        }

        os_log(.fault, log: e2eeLog, "cleanup: deleted %d old devices with same IDFV", deletedCount)
    }

    /// Tag a device's display_name with IDFV identifier.
    private func tagDeviceWithIDFV(deviceID: String, idfvTag: String, homeserverURL: String, accessToken: String) async {
        // First get current display_name
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/devices/\(deviceID)") else { return }
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: getRequest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let currentName = json["display_name"] as? String else { return }

        // Don't re-tag if already tagged
        if currentName.contains(idfvTag) { return }

        // Remove old IDFV tag if present (from different IDFV — shouldn't happen but just in case)
        var cleanName = currentName
        if let range = cleanName.range(of: " \\[idfv:[^\\]]+\\]", options: .regularExpression) {
            cleanName.removeSubrange(range)
        }

        let newName = "\(cleanName) \(idfvTag)"

        var putRequest = URLRequest(url: url)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["display_name": newName])

        if let (_, response) = try? await URLSession.shared.data(for: putRequest),
           let httpResponse = response as? HTTPURLResponse {
            os_log(.fault, log: e2eeLog, "cleanup: tagged device %{public}@ — status %d", deviceID, httpResponse.statusCode)
        }
    }

    /// Delete a single device from the server.
    private func deleteDevice(deviceID: String, homeserverURL: String, accessToken: String) async {
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/devices/\(deviceID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Empty auth dict — may work if UIA is not required or server allows it
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["auth": [:]])

        if let (data, response) = try? await URLSession.shared.data(for: request),
           let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                os_log(.fault, log: e2eeLog, "cleanup: deleted device %{public}@", deviceID)
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                os_log(.fault, log: e2eeLog, "cleanup: failed to delete %{public}@ — %d: %{public}@", deviceID, httpResponse.statusCode, body)
            }
        }
    }
}
