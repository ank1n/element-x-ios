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
    /// Recovery key is stored via Matrix custom account data event `ru.implica.stalk.recovery_key`
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
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/ru.implica.stalk.recovery_key") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let (data, response) = try? await URLSession.shared.data(for: request),
           let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
           let json = try? JSONDecoder().decode([String: String].self, from: data),
           json["recovery_key"] != nil {
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
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/ru.implica.stalk.recovery_key") else {
            MXLog.error("sTalk: Invalid URL for account data")
            return
        }

        MXLog.info("sTalk: Storing recovery key at URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["recovery_key": key])

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

    /// Fetch stored recovery key from server and use it to verify this device
    private func autoVerifyWithStoredRecoveryKey() async {
        let homeserverURL = clientProxy.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let accessToken = try? clientProxy.matrixAccessToken() else {
            MXLog.error("sTalk: Can't fetch recovery key — no access token")
            return
        }

        let encodedUserID = clientProxy.userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientProxy.userID
        guard let url = URL(string: "\(homeserverURL)/_matrix/client/v3/user/\(encodedUserID)/account_data/ru.implica.stalk.recovery_key") else {
            MXLog.error("sTalk: Invalid URL for account data")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                MXLog.info("sTalk: No stored recovery key found on server (first device?)")
                return
            }

            guard let json = try? JSONDecoder().decode([String: String].self, from: data),
                  let recoveryKey = json["recovery_key"] else {
                MXLog.error("sTalk: Invalid recovery key data from server")
                return
            }

            MXLog.info("sTalk: Got recovery key from server (length: \(recoveryKey.count)), attempting recover...")
            let result = await clientProxy.secureBackupController.confirmRecoveryKey(recoveryKey)
            switch result {
            case .success:
                MXLog.info("sTalk: Device verified via recovery key!")
            case .failure(let error):
                MXLog.error("sTalk: Recovery key verification failed: \(error)")
            }
        } catch {
            MXLog.error("sTalk: Failed to fetch recovery key: \(error)")
        }
    }
}
