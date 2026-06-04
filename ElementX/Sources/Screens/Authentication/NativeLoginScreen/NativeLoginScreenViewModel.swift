//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
@preconcurrency import KeychainAccess

class NativeLoginScreenViewModel: NativeLoginScreenViewModelType {
    private let authenticationService: AuthenticationServiceProtocol
    private let oidcData: OIDCAuthorizationDataProxy
    private let headlessAuthenticator = HeadlessOIDCAuthenticator()

    private static let credentialsKeychain = Keychain(service: InfoPlistReader.main.baseBundleIdentifier + ".savedLogin")

    private let actionsSubject: PassthroughSubject<NativeLoginScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<NativeLoginScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(authenticationService: AuthenticationServiceProtocol, oidcData: OIDCAuthorizationDataProxy) {
        self.authenticationService = authenticationService
        self.oidcData = oidcData
        super.init(initialViewState: NativeLoginScreenViewState())
        loadSavedCredentials()
    }

    private func loadSavedCredentials() {
        if let username = try? Self.credentialsKeychain.getString("username"),
           let password = try? Self.credentialsKeychain.getString("password") {
            state.bindings.username = username
            state.bindings.password = password
        }
    }

    private func saveCredentials(username: String, password: String) {
        try? Self.credentialsKeychain.set(username, key: "username")
        try? Self.credentialsKeychain.set(password, key: "password")
    }

    override func process(viewAction: NativeLoginScreenViewAction) {
        switch viewAction {
        case .login:
            login()
        case .cancel:
            Task {
                await authenticationService.abortOIDCLogin(data: oidcData)
                actionsSubject.send(.cancelled)
            }
        }
    }

    private func login() {
        let username = state.bindings.username.trimmingCharacters(in: .whitespaces)
        let password = state.bindings.password

        state.isLoading = true
        state.bindings.alertInfo = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                // STMOB-202: use the chosen homeserver so login works on any server.
                let homeserver = authenticationService.homeserver.value.address

                // Step 1: Headless OIDC — submit credentials to Keycloak programmatically
                MXLog.info("sTalk NativeLogin: Starting headless OIDC auth for \(homeserver)")
                let callbackURL = try await headlessAuthenticator.authenticate(authURL: oidcData.url,
                                                                               username: username,
                                                                               password: password,
                                                                               homeserver: homeserver)
                MXLog.info("sTalk NativeLogin: Got callback URL: \(callbackURL)")

                // Step 2: stalk.implica.ru uses an HTTPS redirect_uri (static registration), so
                // its custom-scheme callback must be rewritten back to HTTPS for the SDK. Other
                // servers register the custom scheme directly, so the callback is passed as-is.
                let finalURL = homeserver == "stalk.implica.ru"
                    ? callbackURL.rewritingCustomSchemeToHTTPS(homeserver: homeserver)
                    : callbackURL

                // Step 3: Pass callback URL to SDK for token exchange + device registration
                switch await authenticationService.loginWithOIDCCallback(finalURL) {
                case .success(let userSession):
                    MXLog.info("sTalk NativeLogin: Login successful!")
                    self.saveCredentials(username: username, password: password)
                    actionsSubject.send(.signedIn(userSession))
                case .failure(let error):
                    MXLog.error("sTalk NativeLogin: SDK login failed: \(error)")
                    state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                         title: SL10n.authLoginError,
                                                         message: SL10n.authLoginFailed(error.localizedDescription))
                }
            } catch let error as HeadlessOIDCAuthenticator.AuthError {
                MXLog.error("sTalk NativeLogin: Headless auth failed: \(error)")
                state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                     title: SL10n.authLoginError,
                                                     message: error.errorDescription ?? SL10n.authUnknownError)
            } catch {
                MXLog.error("sTalk NativeLogin: Unexpected error: \(error)")
                state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                     title: SL10n.authError,
                                                     message: error.localizedDescription)
            }

            state.isLoading = false
        }
    }
}
