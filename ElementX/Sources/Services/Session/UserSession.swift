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
                DiagLog.write("E2EE", "state — verification=\(verificationState) recovery=\(recoveryState)")

                switch (verificationState, recoveryState) {
                case (.verified, .disabled), (.verified, .incomplete):
                    // Try to restore from server first (may be re-install, not first device)
                    autoRecoveryCancellable?.cancel()
                    autoRecoveryCancellable = nil
                    os_log(.fault, log: e2eeLog, "Verified + %{public}@ — trying server key first", String(describing: recoveryState))
                    MXLog.info("sTalk: Verified + \(recoveryState) — trying server recovery key first")
                    DiagLog.write("E2EE", "→ Verified+\(recoveryState) → tryRestoreFromServerKey")
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
                    MXLog.info("sTalk: E2EE fully set up — refreshing SSSS")
                    DiagLog.write("E2EE", "→ Verified+enabled → refresh SSSS")
                    Task {
                        // sTalk: refresh SSSS to keep local backup_decryption_key
                        // in sync with server. SDK handles the actual upload of
                        // local Megolm sessions automatically (autoEnableBackups
                        // in ClientBuilder). Calling our enableBackups() on top
                        // produced "failedEnablingBackup" errors and surfaced
                        // them to UI — we no longer do that.
                        _ = await self.tryRestoreFromServerKey()
                        await self.cleanupOldDevicesByIDFV()
                    }

                case (.unverified, .disabled), (.unverified, .enabled), (.unverified, .incomplete), (.unverified, .unknown):
                    // Second device or unknown state: try to recover using stored recovery key
                    autoRecoveryCancellable?.cancel()
                    autoRecoveryCancellable = nil
                    os_log(.fault, log: e2eeLog, "Unverified + %{public}@ — attempting auto-verify", String(describing: recoveryState))
                    MXLog.info("sTalk: Unverified device — attempting auto-verify with stored recovery key")
                    DiagLog.write("E2EE", "→ Unverified+\(recoveryState) → autoVerifyWithStoredRecoveryKey")
                    Task {
                        await self.autoVerifyWithStoredRecoveryKey()
                    }

                default:
                    DiagLog.write("E2EE", "→ default — no action (verification=\(verificationState) recovery=\(recoveryState))")
                    // .unknown — wait for state to settle
                }
            }
        autoRecoveryCancellable?.store(in: &cancellables)
    }

    /// Try to restore E2EE keys using recovery key from server.
    /// Returns true if restoration succeeded.
    private func tryRestoreFromServerKey() async -> Bool {
        DiagLog.write("E2EE", "tryRestoreFromServerKey START")
        // sTalk: refresh access token via SDK to ensure our custom URLSession call
        // doesn't use a stale snapshot (MAS access_token expires ~15min). Without this,
        // an idle session returns 401 on /account_data — caller mistakenly bootstraps.
        await clientProxy.forceTokenRefresh()
        DiagLog.write("E2EE", "  tryRestore: token refreshed via SDK")
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            MXLog.error("sTalk: tryRestore — no access token")
            DiagLog.write("E2EE", "  tryRestore: no access token — ABORT (pretend restored, no destructive action)")
            return true
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
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagLog.write("E2EE", "  tryRestore: GET account_data → HTTP \(statusCode), \(data.count) bytes")
            // sTalk: distinguish "really missing" (404) from auth/server errors (401/5xx).
            // Returning true on non-404 errors so caller doesn't trigger destructive
            // generateRecoveryKey() that would overwrite a valid key on the server.
            // See STALK-210 incident 2026-04-29.
            guard let httpResponse = response as? HTTPURLResponse else {
                DiagLog.write("E2EE", "  tryRestore: no HTTP response — pretend restored (no destructive action)")
                return true
            }
            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 404 {
                    DiagLog.write("E2EE", "  tryRestore: no key on server (HTTP 404) — caller may bootstrap")
                    return false
                }
                MXLog.error("sTalk: tryRestore — HTTP \(statusCode), pretend restored (auth/server issue, NOT missing key)")
                DiagLog.write("E2EE", "  tryRestore: HTTP \(statusCode) (auth/server) — pretend restored, ABORT bootstrap")
                return true
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recoveryKey = json["key"] as? String, !recoveryKey.isEmpty else {
                MXLog.error("sTalk: tryRestore — invalid JSON, pretend restored (don't overwrite key)")
                DiagLog.write("E2EE", "  tryRestore: invalid JSON — pretend restored, ABORT bootstrap")
                return true
            }

            os_log(.fault, log: e2eeLog, "tryRestore — found key (length: %d), attempting recover...", recoveryKey.count)
            MXLog.info("sTalk: tryRestore — found key (length: \(recoveryKey.count)), attempting recover...")
            DiagLog.write("E2EE", "  tryRestore: found key (len=\(recoveryKey.count)) — calling confirmRecoveryKey")
            let result = await clientProxy.secureBackupController.confirmRecoveryKey(recoveryKey)
            switch result {
            case .success:
                os_log(.fault, log: e2eeLog, "tryRestore — SUCCESS! Keys restored")
                MXLog.info("sTalk: tryRestore — recovery key confirmed, keys restored!")
                DiagLog.write("E2EE", "  tryRestore: confirmRecoveryKey SUCCESS ✅")
                // sTalk: log post-confirm backup state to diagnose stuck cases
                let backupState = clientProxy.secureBackupController.keyBackupState.value
                let recoveryState = clientProxy.secureBackupController.recoveryState.value
                DiagLog.write("E2EE", "  tryRestore: post-confirm backupState=\(backupState) recoveryState=\(recoveryState)")
                // sTalk: STMOB-83 + STMOB-84 — pin own identity + auto-pin internal users
                // (parity with web v236 ensureSecretsLoaded). Removes "authenticity not
                // guaranteed" tooltip on own messages and on messages from `@*:stalk.implica.ru`.
                await pinIdentitiesForDomainTrust()
                return true
            case .failure(let error):
                os_log(.fault, log: e2eeLog, "tryRestore — FAILED: %{public}@", String(describing: error))
                MXLog.error("sTalk: tryRestore — confirmRecoveryKey failed: \(error)")
                DiagLog.write("E2EE", "  tryRestore: confirmRecoveryKey FAILED — \(error)")
                return false
            }
        } catch {
            MXLog.error("sTalk: tryRestore — fetch error: \(error)")
            DiagLog.write("E2EE", "  tryRestore: fetch error — \(error.localizedDescription)")
            return false
        }
    }

    /// sTalk: STMOB-83 + STMOB-84 — pin own identity + auto-pin internal users.
    /// Parity with web v236 ensureSecretsLoaded. Removes "authenticity not guaranteed"
    /// tooltip on own messages and on messages from `@*:stalk.implica.ru` users.
    /// pin() is idempotent and non-destructive — marks identity as TOFU-trusted in
    /// local crypto store, doesn't upload signatures, doesn't rotate any keys.
    private func pinIdentitiesForDomainTrust() async {
        let ownUserID = clientProxy.userID
        DiagLog.write("E2EE", "domainTrust: pinning own identity \(ownUserID)")
        switch await clientProxy.pinUserIdentity(ownUserID) {
        case .success:
            DiagLog.write("E2EE", "domainTrust: own identity pinned ✅")
        case .failure(let error):
            DiagLog.write("E2EE", "domainTrust: own pin failed — \(error)")
        }

        // STMOB-84 build 141: после own — пинить members ВСЕХ joined-комнат с
        // доменом `@*:stalk.implica.ru`. Решает двусторонний UTD: iPhone больше
        // не отбрасывает encrypted events от internal users как «untrusted
        // identity». Парная половина (Михаил web → iPhone доверяет) делается в
        // production-matrix web-half (Molly STALK-XXX).
        await pinDomainTrustMembers()
    }

    /// STMOB-84: pin TOFU всех internal users (`@*:stalk.implica.ru`) которых
    /// мы видим в joined комнатах. Идемпотентно — повторный pin не вредит.
    private func pinDomainTrustMembers() async {
        let domain = ":stalk.implica.ru"
        let ownUserID = clientProxy.userID

        // Ждём пока RoomSummaryProvider загрузится — иначе roomListPublisher
        // пустой и pin'ить будет некого.
        let provider = clientProxy.staticRoomSummaryProvider
        if !provider.statePublisher.value.isLoaded {
            _ = await provider.statePublisher.values.first { $0.isLoaded }
        }

        var seen = Set<String>()
        seen.insert(ownUserID)
        var pinned = 0
        var failed = 0
        for summary in provider.roomListPublisher.value {
            // Только joined комнаты, без invites/knocks/spaces/tombstoned.
            guard summary.joinRequestType == nil,
                  !summary.isSpace,
                  !summary.isTombstoned else { continue }
            guard case let .joined(joined) = await clientProxy.roomForIdentifier(summary.id) else { continue }
            for member in joined.membersPublisher.value where member.userID.hasSuffix(domain) {
                guard seen.insert(member.userID).inserted else { continue }
                switch await clientProxy.pinUserIdentity(member.userID) {
                case .success: pinned += 1
                case .failure: failed += 1
                }
            }
        }
        DiagLog.write("E2EE", "domainTrust: pinned \(pinned) member identities (\(failed) failed)")
    }

    /// Ensure recovery key and backup are properly set up on server.
    /// DEPRECATED: Was deleting backups and recreating. Now replaced by uploadKeysToExistingBackup.
    /// Kept for reference — DO NOT call. Backup deletion is now server-side only.
    @available(*, deprecated, message: "Use uploadKeysToExistingBackup instead")
    private func ensureRecoveryKeyStoredOnServer() async {
        await uploadKeysToExistingBackup()
    }

    /// Upload all local megolm keys to backup.
    /// Never deletes backup versions — that's a server-side responsibility.
    private func uploadKeysToExistingBackup() async {
        os_log(.fault, log: e2eeLog, "uploadKeys: trying enableBackups...")
        DiagLog.write("E2EE", "uploadKeys: enableBackups START")
        let backupResult = await clientProxy.secureBackupController.enable()

        switch backupResult {
        case .success:
            os_log(.fault, log: e2eeLog, "uploadKeys: enableBackups succeeded")
            DiagLog.write("E2EE", "uploadKeys: enableBackups SUCCESS")
        case .failure(let error):
            let count = await getBackupKeyCount()
            os_log(.fault, log: e2eeLog, "uploadKeys: enableBackups failed (BackupExistsOnServer?), server has %d keys", count)
            DiagLog.write("E2EE", "uploadKeys: enableBackups FAILED — \(error). Server backup count=\(count). ABORT")
            return
        }

        os_log(.fault, log: e2eeLog, "uploadKeys: waiting for upload to complete...")
        DiagLog.write("E2EE", "uploadKeys: waiting for upload to complete...")
        _ = await clientProxy.secureBackupController.waitForKeyBackupUpload(uploadStateSubject: .init(.waiting))

        let finalCount = await getBackupKeyCount()
        os_log(.fault, log: e2eeLog, "uploadKeys: DONE — server backup now has %d keys", finalCount)
        DiagLog.write("E2EE", "uploadKeys: DONE — server has \(finalCount) keys")
    }

    /// Store recovery key on Matrix server via custom account data event
    private static func storeRecoveryKeyOnServer(key: String, clientProxy: ClientProxyProtocol) async {
        // sTalk: refresh access token via SDK before custom URLSession call.
        await clientProxy.forceTokenRefresh()
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
        DiagLog.write("E2EE", "autoVerify START")
        guard !isAutoRecoveryInProgress else {
            os_log(.fault, log: e2eeLog, "autoVerify: already in progress, skipping")
            DiagLog.write("E2EE", "  autoVerify: already in progress — SKIP")
            return
        }
        isAutoRecoveryInProgress = true
        defer { isAutoRecoveryInProgress = false }
        // sTalk: refresh access token via SDK before our custom URLSession call.
        // matrixAccessToken() returns a cached snapshot; on a session that's been
        // idle long enough for MAS access_token to expire (15 min), the snapshot
        // is stale → 401 on our custom HTTP. forceTokenRefresh triggers SDK's
        // internal refresh so subsequent matrixAccessToken() returns a fresh token.
        await clientProxy.forceTokenRefresh()
        DiagLog.write("E2EE", "  autoVerify: token refreshed via SDK")
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            os_log(.fault, log: e2eeLog, "autoVerify: no access token!")
            DiagLog.write("E2EE", "  autoVerify: no access token — ABORT")
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
            DiagLog.write("E2EE", "  autoVerify: GET account_data → HTTP \(statusCode), \(data.count) bytes")
            guard let httpResponse = response as? HTTPURLResponse else {
                DiagLog.write("E2EE", "  autoVerify: no HTTP response — ABORT (no destructive bootstrap)")
                return
            }
            // sTalk: ONLY HTTP 404 = "no key on server" → safe to bootstrap.
            // HTTP 401/403 = auth issue, 5xx = server error — DO NOT bootstrap (would
            // overwrite valid recovery key on server). See STALK-210 incident 2026-04-29.
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    MXLog.info("sTalk: No recovery key on server (404) — bootstrapping recovery directly (first device)")
                    DiagLog.write("E2EE", "  autoVerify: no key on server (HTTP 404) — bootstrapRecoveryForFirstDevice")
                    await bootstrapRecoveryForFirstDevice()
                } else {
                    MXLog.error("sTalk: account_data fetch failed with HTTP \(statusCode) — ABORT (auth/server issue, not missing key)")
                    DiagLog.write("E2EE", "  autoVerify: HTTP \(statusCode) (auth/server issue) — ABORT, no destructive bootstrap")
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recoveryKey = json["key"] as? String else {
                os_log(.fault, log: e2eeLog, "autoVerify: invalid JSON or missing key. Raw: %{public}@", String(data: data, encoding: .utf8) ?? "binary")
                DiagLog.write("E2EE", "  autoVerify: invalid JSON — ABORT")
                return
            }

            os_log(.fault, log: e2eeLog, "autoVerify: got key (length: %d), checking if backup exists...", recoveryKey.count)
            DiagLog.write("E2EE", "  autoVerify: got key (len=\(recoveryKey.count))")

            // sTalk: Ждём пока SDK не sync'нет backup state с сервера. Если делать
            // confirmRecoveryKey пока backup state=unknown — recover() пройдёт но
            // НЕ скачает keys (SDK не знает что backup существует). Race на iPhone:
            // app start быстрый → state ещё .unknown → 0 sessions imported → user
            // видит «Ожидание ключа расшифровки». На симуляторе app start медленнее
            // → backup state успевает sync до confirmRecoveryKey → работает.
            for i in 1...20 {
                let state = clientProxy.secureBackupController.keyBackupState.value
                if state != .unknown { break }
                if i == 1 { DiagLog.write("E2EE", "  autoVerify: waiting for backup state to settle (currently .unknown)") }
                try? await Task.sleep(for: .milliseconds(500))
            }
            let backupState = clientProxy.secureBackupController.keyBackupState.value
            os_log(.fault, log: e2eeLog, "autoVerify: backup state: %{public}@", String(describing: backupState))
            DiagLog.write("E2EE", "  autoVerify: backup state=\(backupState) (after wait)")

            await cleanupStaleSSSKeys()

            os_log(.fault, log: e2eeLog, "autoVerify: calling confirmRecoveryKey (with 120s timeout)...")
            DiagLog.write("E2EE", "  autoVerify: calling confirmRecoveryKey")

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
                DiagLog.write("E2EE", "  autoVerify: confirmRecoveryKey SUCCESS — keys restored")
                // STMOB-141 build 168: расширили wait 10s → 30s. Race condition
                // dp.bondar: SDK не успевал применить cross-signing state за
                // 10s → fallback резет identity → новые master keys → у всех
                // в комнате shield/UTD. На медленной сети 30s достаточно.
                for i in 1...15 {
                    try? await Task.sleep(for: .seconds(2))
                    let currentState = clientProxy.verificationStatePublisher.value
                    os_log(.fault, log: e2eeLog, "autoVerify: check %d/15 — state: %{public}@", i, String(describing: currentState))
                    DiagLog.write("E2EE", "  autoVerify: check \(i)/15 — state=\(currentState)")
                    if currentState == .verified {
                        os_log(.fault, log: e2eeLog, "autoVerify: device auto-verified after recovery!")
                        DiagLog.write("E2EE", "  autoVerify: device verified ✅")
                        await cleanupOldDevicesByIDFV()
                        return
                    }
                }
                os_log(.fault, log: e2eeLog, "autoVerify: still unverified after 30s — cross-signing device via resetIdentity")
                DiagLog.write("E2EE", "  autoVerify: still unverified after 30s — selfVerifyDevice")
                await selfVerifyDevice()
                await cleanupOldDevicesByIDFV()
            case .failure(let error):
                os_log(.fault, log: e2eeLog, "autoVerify: confirmRecoveryKey FAILED: %{public}@", String(describing: error))
                DiagLog.write("E2EE", "  autoVerify: confirmRecoveryKey FAILED — \(error)")
                os_log(.fault, log: e2eeLog, "autoVerify: skipping destructive bootstrap — preserving existing key backup")
                DiagLog.write("E2EE", "  autoVerify: skip bootstrap, calling selfVerifyDevice")
                await selfVerifyDevice()
                await cleanupOldDevicesByIDFV()
            }
        } catch {
            os_log(.fault, log: e2eeLog, "autoVerify: network error: %{public}@", String(describing: error))
            DiagLog.write("E2EE", "  autoVerify: network error — \(error.localizedDescription)")
        }
    }

    /// Cross-sign this device after successful key recovery.
    /// Called when confirmRecoveryKey succeeded but device is still unverified after 30s.
    /// ONLY resets cross-signing identity — does NOT touch SSSS or backup.
    /// Keys are already restored at this point, SDK will auto-upload to backup.
    private func selfVerifyDevice() async {
        // STMOB-141 build 169: КРИТИЧЕСКИЙ guard перед resetIdentity.
        // Раньше при slow sync делали resetIdentity → новые master keys →
        // у dp.bondar 2 ротации мастер-ключей → backup access потерян →
        // 'На этом устройстве недоступна история сообщений' во всех комнатах.
        //
        // Правило: если на сервере УЖЕ есть recovery_key + key backup →
        // НЕ ротировать identity. Если SDK ещё не догнал — ждать manual SAS
        // (юзер может verify через другую Web-сессию) или event-driven update.
        // Только если recovery+backup ОТСУТСТВУЮТ (первичный setup) — OK
        // делать resetIdentity для bootstrap fresh identity.
        let hasRecovery = await tryRestoreFromServerKey()
        let backupState = clientProxy.secureBackupController.keyBackupState.value
        // SecureBackupKeyBackupState: .unknown / .enabling / .enabled / .disabling.
        // Считаем backup существующим если .enabled, .enabling, .disabling
        // (любое НЕ-.unknown — backup есть, просто в transition state).
        // .unknown = «we didn't explicitly disable on this client» = fail-safe
        // считать что есть (preserve identity на сомнения).
        let backupExists: Bool = {
            switch backupState {
            case .enabled, .enabling, .disabling, .unknown: return true
            }
        }()
        DiagLog.write("E2EE", "selfVerifyDevice: hasRecovery=\(hasRecovery) backupState=\(backupState) backupExists=\(backupExists)")

        if hasRecovery, backupExists {
            os_log(.fault, log: e2eeLog, "selfVerify: ABORT resetIdentity — recovery_key + backup EXIST (preserve identity to keep backup access)")
            DiagLog.write("E2EE", "selfVerify: ABORT — recovery+backup exist, preserve identity")
            // Device остаётся unverified — юзер может SAS-verify с другой сессии
            // (Web). Identity не меняется → backup access сохраняется → старые
            // megolm sessions остаются доступны как только device получит keys
            // через cross-signing от trusted Web-сессии.
            return
        }

        os_log(.fault, log: e2eeLog, "selfVerify: resetting identity (recovery=%{public}@ backup=%{public}@) — fresh setup", String(describing: hasRecovery), String(describing: backupExists))

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

        // Step 2: Try to re-confirm recovery key so SDK links to existing backup.
        // Keys are already in local store (confirmRecoveryKey was called before selfVerifyDevice).
        // This just re-establishes the SDK's connection to SSSS + backup after identity reset.
        let restored = await tryRestoreFromServerKey()
        if restored {
            os_log(.fault, log: e2eeLog, "selfVerify: DONE — device verified + recovery re-confirmed")
        } else {
            os_log(.fault, log: e2eeLog, "selfVerify: DONE — device verified (recovery re-confirm failed, SDK will auto-upload keys)")
            // Not fatal: device is cross-signed, megolm keys are in local store.
            // SDK will upload them to backup once it gets backup access.
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

        // Step 1: Clean up old E2EE account data (SSSS secrets, cross-signing).
        // Never delete backup versions — server manages backup lifecycle.
        await cleanupServerE2EEState()
        let backupKeyCount = await getBackupKeyCount()
        os_log(.fault, log: e2eeLog, "bootstrap: server backup has %d keys (preserved)", backupKeyCount)

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
    /// NOTE: m.megolm_backup.v1 is intentionally NOT cleared — it contains the backup
    /// encryption key reference in SSSS. Clearing it breaks the chain:
    /// recovery_key → SSSS → backup_key → decrypt backup. This was the #1 cause of key loss.
    private func cleanupServerE2EEState() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }
        let encodedUserID = clientProxy.userID
        let baseURL = "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data"

        // Account data events to clear (cross-signing secrets + SSSS default key).
        // NEVER clear m.megolm_backup.v1 — it links SSSS to backup encryption key.
        let eventTypes = [
            "m.secret_storage.default_key",
            "m.cross_signing.master",
            "m.cross_signing.self_signing",
            "m.cross_signing.user_signing"
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

    /// Minimum number of backup versions to keep on server for rollback safety.
    private static let minBackupVersionsToKeep = 3

    /// Delete only empty or excess backup versions, keeping at least `minBackupVersionsToKeep` copies.
    /// Versions with keys (count > 0) are never deleted unless there are more than minBackupVersionsToKeep of them.
    /// Deletion order: empty first, then oldest non-empty (beyond the keep limit).
    private func deleteAllBackupVersions() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else { return }

        // Collect all backup versions (API only returns latest, so we iterate by deleting empty ones)
        // Strategy: delete only empty (count=0) versions. Keep all versions with keys.
        // This preserves rollback capability.
        var emptyDeleted = 0
        for attempt in 1...20 {
            guard let versionURL = URL(string: "\(homeserverURL)/_matrix/client/v3/room_keys/version") else { return }
            var getRequest = URLRequest(url: versionURL)
            getRequest.httpMethod = "GET"
            getRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: getRequest),
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else {
                os_log(.fault, log: e2eeLog, "backupRotation: no more versions (after %d empty deletions)", emptyDeleted)
                break
            }

            let count = json["count"] as? Int ?? 0

            if count > 0 {
                // Has keys — never delete, stop iteration (older versions are behind this one)
                os_log(.fault, log: e2eeLog, "backupRotation: keeping version %{public}@ (%d keys)", version, count)
                break
            }

            // Empty version — safe to delete
            os_log(.fault, log: e2eeLog, "backupRotation: deleting empty version %{public}@ (attempt %d)", version, attempt)
            guard let deleteURL = URL(string: "\(homeserverURL)/_matrix/client/v3/room_keys/version/\(version)") else { return }
            var deleteRequest = URLRequest(url: deleteURL)
            deleteRequest.httpMethod = "DELETE"
            deleteRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            if let (_, deleteResponse) = try? await URLSession.shared.data(for: deleteRequest),
               let deleteHTTP = deleteResponse as? HTTPURLResponse {
                os_log(.fault, log: e2eeLog, "backupRotation: deleted version %{public}@ — HTTP %d", version, deleteHTTP.statusCode)
                emptyDeleted += 1
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
