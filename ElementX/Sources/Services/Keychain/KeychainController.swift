//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
@preconcurrency import KeychainAccess
import MatrixRustSDK

enum KeychainControllerService: String {
    case sessions
    case tests

    var restorationTokenID: String {
        InfoPlistReader.main.baseBundleIdentifier + "." + rawValue
    }
    
    var mainID: String {
        InfoPlistReader.main.baseBundleIdentifier + ".keychain.\(rawValue)"
    }
}

final class KeychainController: KeychainControllerProtocol {
    /// The keychain responsible for storing account restoration tokens (keyed by userID).
    private let restorationTokenKeychain: Keychain
    /// The keychain responsible for storing all other secrets in the app (keyed by `Key`s).
    private let mainKeychain: Keychain
    
    private enum Key: String {
        case appLockPINCode
        case appLockBiometricState
        case savedLoginUsername
        case savedLoginPassword
    }

    init(service: KeychainControllerService, accessGroup: String) {
        restorationTokenKeychain = Keychain(service: service.restorationTokenID, accessGroup: accessGroup)
        mainKeychain = Keychain(service: service.mainID, accessGroup: accessGroup)
    }
    
    // MARK: - Restoration Tokens

    func setRestorationToken(_ restorationToken: RestorationToken, forUsername username: String) {
        do {
            let tokenData = try JSONEncoder().encode(restorationToken)
            try restorationTokenKeychain.set(tokenData, key: username)
        } catch {
            MXLog.error("Failed storing user restore token with error: \(error)")
        }
    }

    func restorationTokenForUsername(_ username: String) -> RestorationToken? {
        do {
            guard let tokenData = try restorationTokenKeychain.getData(username) else {
                return nil
            }
            
            return try JSONDecoder().decode(RestorationToken.self, from: tokenData)
        } catch RestorationTokenError.slidingSyncProxyNotSupported {
            MXLog.error("Unsupported user restore token (contains sliding sync proxy). Deleting token.")
            removeRestorationTokenForUsername(username)
            return nil
        } catch {
            MXLog.error("Failed retrieving user restore token")
            return nil
        }
    }

    func restorationTokens() -> [KeychainCredentials] {
        restorationTokenKeychain.allKeys().compactMap { username in
            guard let restorationToken = restorationTokenForUsername(username) else {
                return nil
            }

            return KeychainCredentials(userID: username, restorationToken: restorationToken)
        }
    }

    func removeRestorationTokenForUsername(_ username: String) {
        MXLog.warning("Removing restoration token for user: \(username).")
        
        do {
            try restorationTokenKeychain.remove(username)
        } catch {
            MXLog.error("Failed removing restore token with error: \(error)")
        }
    }

    func removeAllRestorationTokens() {
        MXLog.warning("Removing all user restoration tokens.")
        
        do {
            try restorationTokenKeychain.removeAll()
        } catch {
            MXLog.error("Failed removing all tokens")
        }
    }
    
    // MARK: - ClientSessionDelegate
    
    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        MXLog.info("Retrieving an updated Session from the keychain.")
        guard let session = restorationTokenForUsername(userId)?.session else {
            throw ClientError.Generic(msg: "Failed to find RestorationToken in the Keychain.", details: nil)
        }
        return session
    }
    
    func saveSessionInKeychain(session: Session) {
        MXLog.info("Saving session changes in the keychain.")

        guard let oldToken = restorationTokenForUsername(session.userId) else {
            MXLog.error("Failed retrieving the restoration token for \(session.userId)")
            fatalError("Something has gone mega wrong, all bets are off.")
        }
        // sTalk: STMOB-90 — instrument deviceId churn. SDK is supposed to
        // refresh the access/refresh tokens on the existing session and keep
        // deviceId stable, but production logs show new device_ids appearing
        // for the same user without explicit login. Capture the change here
        // so the next bug report tells us which code path renamed deviceId.
        if oldToken.session.deviceId != session.deviceId {
            DiagLog.write("DEVID", "Keychain.saveSessionInKeychain DEVICE_ID_CHANGED user=\(session.userId) old=\(oldToken.session.deviceId) new=\(session.deviceId)")
            MXLog.error("STMOB-90 device_id mutated by SDK: user=\(session.userId) old=\(oldToken.session.deviceId) new=\(session.deviceId)")
        }
        let restorationToken = RestorationToken(session: session,
                                                sessionDirectories: oldToken.sessionDirectories,
                                                passphrase: oldToken.passphrase,
                                                pusherNotificationClientIdentifier: oldToken.pusherNotificationClientIdentifier)
        setRestorationToken(restorationToken, forUsername: session.userId)
    }
    
    // MARK: - App Secrets
    
    func resetSecrets() {
        MXLog.warning("Resetting main keychain.")
        
        do {
            try mainKeychain.removeAll()
        } catch {
            MXLog.error("Failed resetting the main keychain.")
        }
    }
    
    func containsPINCode() throws -> Bool {
        try mainKeychain.contains(Key.appLockPINCode.rawValue)
    }
    
    func setPINCode(_ pinCode: String) throws {
        try mainKeychain.set(pinCode, key: Key.appLockPINCode.rawValue)
    }
    
    func pinCode() -> String? {
        do {
            return try mainKeychain.getString(Key.appLockPINCode.rawValue)
        } catch {
            MXLog.error("Failed retrieving the PIN code.")
            return nil
        }
    }
    
    func removePINCode() {
        do {
            try mainKeychain.remove(Key.appLockPINCode.rawValue)
        } catch {
            MXLog.error("Failed removing the PIN code.")
        }
    }
    
    func containsPINCodeBiometricState() -> Bool {
        do {
            return try mainKeychain.contains(Key.appLockBiometricState.rawValue)
        } catch {
            MXLog.error("Failed checking for biometric state.")
            return false // No need to re-throw the error, we can fall back to the PIN code.
        }
    }
    
    func setPINCodeBiometricState(_ state: Data) throws {
        try mainKeychain.set(state, key: Key.appLockBiometricState.rawValue)
    }
    
    func pinCodeBiometricState() -> Data? {
        do {
            return try mainKeychain.getData(Key.appLockBiometricState.rawValue)
        } catch {
            MXLog.error("Failed setting the PIN code biometric state.")
            return nil
        }
    }
    
    func removePINCodeBiometricState() {
        do {
            try mainKeychain.remove(Key.appLockBiometricState.rawValue)
        } catch {
            MXLog.error("Failed removing the PIN code biometric state.")
        }
    }

    // MARK: - Saved Login Credentials

    func setSavedLogin(username: String, password: String) {
        do {
            try mainKeychain.set(username, key: Key.savedLoginUsername.rawValue)
            try mainKeychain.set(password, key: Key.savedLoginPassword.rawValue)
        } catch {
            MXLog.error("Failed saving login credentials: \(error)")
        }
    }

    func savedLogin() -> (username: String, password: String)? {
        do {
            guard let username = try mainKeychain.getString(Key.savedLoginUsername.rawValue),
                  let password = try mainKeychain.getString(Key.savedLoginPassword.rawValue) else {
                return nil
            }
            return (username, password)
        } catch {
            MXLog.error("Failed retrieving saved login: \(error)")
            return nil
        }
    }

    func removeSavedLogin() {
        do {
            try mainKeychain.remove(Key.savedLoginUsername.rawValue)
            try mainKeychain.remove(Key.savedLoginPassword.rawValue)
        } catch {
            MXLog.error("Failed removing saved login: \(error)")
        }
    }
}
