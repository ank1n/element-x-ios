//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
@preconcurrency import KeychainAccess
import MatrixRustSDK
import UIKit

/// STMOB-98: persistent storage of Matrix device_id keyed by Apple IDFV
/// (identifier-for-vendor — стабильный per-app per-physical-device).
///
/// Зачем: Element X iOS при каждом login через MAS получал новый
/// Matrix device_id, потому что в `urlForOauth` мы передавали `deviceId: nil`.
/// Synapse создавал свежий device для каждой сессии. После logout/login
/// циклов в `devices` table накапливалось 12+ stale device_id на один
/// физический iPhone. Каждый device создавал свой APNS pusher → 11+ stale
/// pushers → fan-out на каждый event.
///
/// Решение (Molly STMOB-98 + STALK-230 server-side cleanup как backstop):
/// при OIDC URL gen передавать сохранённый device_id если он есть для
/// текущего idfv. Synapse примет (Matrix-spec позволяет client задавать
/// device_id), и при reuse возвращает тот же device_id → одна сессия.
///
/// Семантика persistence:
/// - При успешном login → сохраняем session.deviceId.
/// - При **явном** logout (юзер тапнул "Sign out") → clearStoredDeviceID()
///   чтобы новая сессия начала с свежего device_id.
/// - При **автоматическом** logout (token expired, soft logout) → keychain
///   запись остаётся → следующий login переиспользует тот же device_id,
///   как будто soft logout не было.
enum MatrixDeviceIDKeychain {
    private static let keyPrefix = "device_id_for_idfv_"

    private static var keychain: Keychain {
        Keychain(service: InfoPlistReader.main.baseBundleIdentifier + ".keychain.matrix_device_id",
                 accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
    }

    /// Apple IDFV — UUID, стабильный для всех приложений одного vendor на
    /// одном физическом устройстве. Сбрасывается только когда юзер удаляет
    /// все приложения этого vendor с устройства.
    static var currentIDFV: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }

    /// Returns saved Matrix device_id for current IDFV, or nil if not yet stored.
    static func savedDeviceID() -> String? {
        guard let idfv = currentIDFV else { return nil }
        do {
            return try keychain.get(keyPrefix + idfv)
        } catch {
            MXLog.error("STMOB-98: failed reading device_id from keychain: \(error)")
            return nil
        }
    }

    /// Persists Matrix device_id for current IDFV. Call after successful login.
    static func save(deviceID: String) {
        guard let idfv = currentIDFV else { return }
        do {
            try keychain.set(deviceID, key: keyPrefix + idfv)
            MXLog.info("STMOB-98: saved device_id=\(deviceID) for idfv=\(idfv.prefix(8))…")
            DiagLog.write("STMOB98", "save deviceID=\(deviceID) idfv=\(idfv.prefix(8))…")
        } catch {
            MXLog.error("STMOB-98: failed saving device_id to keychain: \(error)")
        }
    }

    /// Removes saved device_id. Call ONLY on explicit user logout — soft
    /// logout (token revoked) should keep the entry so next login reuses.
    static func clearStoredDeviceID() {
        guard let idfv = currentIDFV else { return }
        do {
            try keychain.remove(keyPrefix + idfv)
            MXLog.info("STMOB-98: cleared device_id for idfv=\(idfv.prefix(8))…")
            DiagLog.write("STMOB98", "clear deviceID idfv=\(idfv.prefix(8))…")
        } catch {
            MXLog.error("STMOB-98: failed clearing device_id from keychain: \(error)")
        }
    }
}

class AuthenticationService: AuthenticationServiceProtocol {
    /// Есть ли на диске данные сессии SDK — вместе с ними живёт крипто-хранилище.
    /// Пусто = приложение поставили заново, прежние ключи шифрования утеряны.
    private static var hasLocalCryptoStore: Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: URL.sessionsBaseDirectory.path)
        return !(contents ?? []).isEmpty
    }

    private var client: ClientProtocol?
    private var sessionDirectories: SessionDirectories
    private let passphrase: String
    
    private let clientFactory: AuthenticationClientFactoryProtocol
    private let userSessionStore: UserSessionStoreProtocol
    private let appSettings: AppSettings
    private let appHooks: AppHooks
    
    private let homeserverSubject: CurrentValueSubject<LoginHomeserver, Never>
    var homeserver: CurrentValuePublisher<LoginHomeserver, Never> {
        homeserverSubject.asCurrentValuePublisher()
    }

    private(set) var flow: AuthenticationFlow
    
    init(userSessionStore: UserSessionStoreProtocol,
         encryptionKeyProvider: EncryptionKeyProviderProtocol,
         clientFactory: AuthenticationClientFactoryProtocol = AuthenticationClientFactory(),
         appSettings: AppSettings,
         appHooks: AppHooks) {
        sessionDirectories = .init()
        passphrase = encryptionKeyProvider.generateKey().base64EncodedString()
        self.clientFactory = clientFactory
        self.userSessionStore = userSessionStore
        self.appSettings = appSettings
        self.appHooks = appHooks
        
        // When updating these, don't forget to update the reset method too.
        homeserverSubject = .init(LoginHomeserver(address: appSettings.accountProviders[0], loginMode: .unknown))
        flow = .login
    }
    
    // MARK: - Public
    
    func configure(for homeserverAddress: String, flow: AuthenticationFlow) async -> Result<Void, AuthenticationServiceError> {
        do {
            var homeserver = LoginHomeserver(address: homeserverAddress, loginMode: .unknown)
            
            let client = try await makeClient(homeserverAddress: homeserverAddress)
            let loginDetails = await client.homeserverLoginDetails()
            
            homeserver.loginMode = if loginDetails.supportsOauthLogin() {
                .oidc(supportsCreatePrompt: loginDetails.supportedOauthPrompts().contains(.create))
            } else if loginDetails.supportsPasswordLogin() {
                .password
            } else {
                .unsupported
            }
            
            if flow == .login, homeserver.loginMode == .unsupported {
                return .failure(.loginNotSupported)
            }
            if flow == .register, !homeserver.loginMode.supportsOIDCFlow {
                return .failure(.registrationNotSupported)
            }
            
            self.client = client
            self.flow = flow
            homeserverSubject.send(homeserver)
            return .success(())
        } catch ClientBuildError.WellKnownDeserializationError(let error) {
            MXLog.error("The user entered a server with an invalid well-known file: \(error)")
            return .failure(.invalidWellKnown(error))
        } catch ClientBuildError.SlidingSyncVersion(let error) {
            MXLog.info("User entered a homeserver that isn't configured for sliding sync: \(error)")
            return .failure(.slidingSyncNotAvailable)
        } catch RemoteSettingsError.elementProRequired(let serverName) {
            return .failure(.elementProRequired(serverName: serverName))
        } catch {
            MXLog.error("Failed configuring a server: \(error)")
            return .failure(.invalidHomeserverAddress)
        }
    }
    
    func urlForOIDCLogin(loginHint: String?, forceLogin: Bool = false) async -> Result<OIDCAuthorizationDataProxy, AuthenticationServiceError> {
        guard let client else { return .failure(.oidcError(.urlFailure)) }
        do {
            // The create prompt is broken: https://github.com/element-hq/matrix-authentication-service/issues/3429
            // let prompt: OAuthPrompt = flow == .register ? .create : .consent
            // Use .login prompt to force re-authentication when forceLogin is true
            let prompt: OAuthPrompt = forceLogin ? .login : .consent
            // STMOB-98: переиспользуем Matrix device_id если он сохранён для
            // текущего IDFV. MAS примет parameter и Synapse вернёт тот же
            // device_id, не создавая новый. Это убирает накопление stale
            // devices при logout/login циклах. Если в keychain пусто
            // (первый login на этом IDFV) — передаём nil как раньше, MAS
            // сгенерирует свежий device_id который мы сохраним после callback.
            // Переиспользовать идентификатор устройства можно ТОЛЬКО если пережило и
            // локальное крипто-хранилище. Оно лежит внутри приложения и исчезает при
            // переустановке, а идентификатор — в keychain, который переустановку
            // переживает. В такой паре мы представляемся старым устройством с новыми
            // ключами: собеседник продолжает шифровать под старые, и его сообщения с
            // ключами звонка приходят, но расшифровать их нечем — видео с той стороны
            // не появляется вовсе (разбор 28.07, логи 171/172: после переустановки
            // «incoming key parsed from=@rusty» пропадает полностью).
            let storedDeviceID = Self.hasLocalCryptoStore ? MatrixDeviceIDKeychain.savedDeviceID() : nil
            if storedDeviceID == nil, MatrixDeviceIDKeychain.savedDeviceID() != nil {
                // Хранилища нет — значит это чистая установка. Забываем идентификатор,
                // иначе сервер выдаст нам то же устройство и мы снова окажемся в паре
                // «старое устройство, новые ключи».
                MatrixDeviceIDKeychain.clearStoredDeviceID()
                DiagLog.write("STMOB98", "чистая установка: идентификатор устройства сброшен, будет новый")
            }
            DiagLog.write("STMOB98", "urlForOIDCLogin reuse deviceID=\(storedDeviceID ?? "nil")")
            let oidcData = try await client.urlForOauth(oauthConfiguration: appSettings.oidcConfiguration(for: homeserverSubject.value.address).rustValue,
                                                        prompt: prompt,
                                                        loginHint: loginHint,
                                                        deviceId: storedDeviceID,
                                                        additionalScopes: nil)
            return .success(OIDCAuthorizationDataProxy(underlyingData: oidcData))
        } catch {
            MXLog.error("Failed to get URL for OIDC login: \(error)")
            return .failure(.oidcError(.urlFailure))
        }
    }
    
    func abortOIDCLogin(data: OIDCAuthorizationDataProxy) async {
        guard let client else { return }
        MXLog.info("Aborting OIDC login.")
        await client.abortOauthAuth(authorizationData: data.underlyingData)
    }
    
    func loginWithOIDCCallback(_ callbackURL: URL) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        guard let client else { return .failure(.failedLoggingIn) }
        do {
            try await client.loginWithOauthCallback(callbackUrl: callbackURL.absoluteString)
            // STMOB-98: persist actual device_id from session. На первом login
            // (когда передавали deviceId=nil) Synapse вернул свежий, нужно
            // сохранить чтобы следующий login переиспользовал. На повторном
            // login (deviceId был передан) MAS вернул тот же — overwrite
            // тем же значением, no-op.
            if let session = try? client.session() {
                MatrixDeviceIDKeychain.save(deviceID: session.deviceId)
            }
            return await userSession(for: client)
        } catch OAuthError.Cancelled {
            return .failure(.oidcError(.userCancellation))
        } catch {
            MXLog.error("Login with OIDC failed: \(error)")
            return .failure(.failedLoggingIn)
        }
    }
    
    func login(username: String, password: String, initialDeviceName: String?, deviceID: String?) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        guard let client else { return .failure(.failedLoggingIn) }
        do {
            try await client.login(username: username, password: password, initialDeviceName: initialDeviceName, deviceId: deviceID)
            
            let refreshToken = try? client.session().refreshToken
            if refreshToken != nil {
                MXLog.warning("Refresh token found for a non oidc session, can't restore session, logging out")
                _ = try? await client.logout()
                return .failure(.sessionTokenRefreshNotSupported)
            }
            
            return await userSession(for: client)
        } catch let ClientError.MatrixApi(errorKind, _, _, _) {
            MXLog.error("Failed logging in with error kind: \(errorKind)")
            switch errorKind {
            case .forbidden:
                return .failure(.invalidCredentials)
            case .userDeactivated:
                return .failure(.accountDeactivated)
            default:
                return .failure(.failedLoggingIn)
            }
        } catch {
            MXLog.error("Failed logging in with error: \(error)")
            return .failure(.failedLoggingIn)
        }
    }
    
    func loginWithQRCode(data: Data) -> QRLoginProgressPublisher {
        let progressSubject = CurrentValueSubject<QRLoginProgress, AuthenticationServiceError>(.starting)
        
        let qrData: QrCodeData
        do {
            qrData = try QrCodeData.fromBytes(bytes: data)
        } catch {
            MXLog.error("QRCode decode error: \(error)")
            progressSubject.send(completion: .failure(.qrCodeError(.invalidQRCode)))
            return progressSubject.asCurrentValuePublisher()
        }
        
        // At some stage the SDK will have a `qrCodeData.intent` which we should check before continuing here.
        // Note the equivalent check will also happen for linking a device by QR in the LinkNewDeviceService.
        
        guard let scannedServerName = qrData.serverName() else {
            MXLog.error("The QR code is from a device that is not yet signed in.")
            progressSubject.send(completion: .failure(.qrCodeError(.deviceNotSignedIn)))
            return progressSubject.asCurrentValuePublisher()
        }
        
        if !appSettings.allowOtherAccountProviders, !appSettings.accountProviders.contains(scannedServerName) {
            MXLog.error("The scanned device's server is not allowed: \(scannedServerName)")
            progressSubject.send(completion: .failure(.qrCodeError(.providerNotAllowed(scannedProvider: scannedServerName, allowedProviders: appSettings.accountProviders))))
            return progressSubject.asCurrentValuePublisher()
        }
        
        let listener = SDKListener { progress in
            guard let progress = QRLoginProgress(rustProgress: progress) else { return }
            progressSubject.send(progress)
        }
        
        Task {
            do {
                let client = try await makeClient(homeserverAddress: scannedServerName)
                let qrCodeHandler = client.newLoginWithQrCodeHandler(oauthConfiguration: appSettings.oidcConfiguration(for: scannedServerName).rustValue)
                try await qrCodeHandler.scan(qrCodeData: qrData, progressListener: listener)
                
                switch await userSession(for: client) {
                case .success(let userSession):
                    progressSubject.send(.signedIn(userSession))
                case .failure(let error):
                    progressSubject.send(completion: .failure(error))
                }
            } catch let error as HumanQrLoginError {
                MXLog.error("QRCode login error: \(error)")
                progressSubject.send(completion: .failure(error.serviceError))
            } catch RemoteSettingsError.elementProRequired(let serverName) {
                progressSubject.send(completion: .failure(.elementProRequired(serverName: serverName)))
            } catch {
                MXLog.error("QRCode login unknown error: \(error)")
                progressSubject.send(completion: .failure(.qrCodeError(.unknown)))
            }
        }
        
        return progressSubject.asCurrentValuePublisher()
    }
    
    func reset() {
        homeserverSubject.send(LoginHomeserver(address: appSettings.accountProviders[0], loginMode: .unknown))
        flow = .login
        client = nil
    }
    
    // MARK: - Private
    
    private func makeClient(homeserverAddress: String) async throws -> ClientProtocol {
        // Use a fresh session directory each time the user enters a different server
        // so that caches (e.g. server versions) are always fresh for the new server.
        rotateSessionDirectory()
        
        let client = try await clientFactory.makeClient(homeserverAddress: homeserverAddress,
                                                        sessionDirectories: sessionDirectories,
                                                        passphrase: passphrase,
                                                        clientSessionDelegate: userSessionStore.clientSessionDelegate,
                                                        appSettings: appSettings,
                                                        appHooks: appHooks)
        try await appHooks.remoteSettingsHook.initializeCache(using: client, applyingTo: appSettings).get()
        
        return client
    }
    
    private func rotateSessionDirectory() {
        sessionDirectories.delete()
        sessionDirectories = .init()
    }
    
    private func userSession(for client: ClientProtocol) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        switch await userSessionStore.userSession(for: client, sessionDirectories: sessionDirectories, passphrase: passphrase) {
        case .success(let clientProxy):
            return .success(clientProxy)
        case .failure:
            return .failure(.failedLoggingIn)
        }
    }
}

private extension HumanQrLoginError {
    var serviceError: AuthenticationServiceError {
        switch self {
        case .Cancelled:
            .qrCodeError(.cancelled)
        case .ConnectionInsecure:
            .qrCodeError(.connectionInsecure)
        case .Declined:
            .qrCodeError(.declined)
        case .LinkingNotSupported:
            .qrCodeError(.linkingNotSupported)
        case .Expired:
            .qrCodeError(.expired)
        case .SlidingSyncNotAvailable:
            .qrCodeError(.deviceNotSupported)
        case .OtherDeviceNotSignedIn:
            .qrCodeError(.deviceNotSignedIn)
        case .Unknown, .NotFound, .OAuthMetadataInvalid, .CheckCodeAlreadySent, .CheckCodeCannotBeSent, .UnsupportedQrCodeType:
            .qrCodeError(.unknown)
        }
    }
}

// MARK: - Mocks

extension AuthenticationService {
    static var mock: AuthenticationService {
        AuthenticationService(userSessionStore: UserSessionStoreMock(configuration: .init()),
                              encryptionKeyProvider: EncryptionKeyProvider(),
                              clientFactory: AuthenticationClientFactoryMock(configuration: .init()),
                              appSettings: ServiceLocator.shared.settings,
                              appHooks: AppHooks())
    }
}
