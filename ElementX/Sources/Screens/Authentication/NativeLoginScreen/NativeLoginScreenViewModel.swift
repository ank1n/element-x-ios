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
            }
            actionsSubject.send(.cancelled)
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
                // Step 1: Headless OIDC — submit credentials to Keycloak programmatically
                MXLog.info("sTalk NativeLogin: Starting headless OIDC auth")
                let callbackURL = try await headlessAuthenticator.authenticate(
                    authURL: oidcData.url,
                    username: username,
                    password: password
                )
                MXLog.info("sTalk NativeLogin: Got callback URL: \(callbackURL)")

                // Step 2: Rewrite custom scheme to HTTPS if needed (same as OIDCPresenter does)
                let finalURL = callbackURL.rewritingCustomSchemeToHTTPS()

                // Step 3: Pass callback URL to SDK for token exchange + device registration
                switch await authenticationService.loginWithOIDCCallback(finalURL) {
                case .success(let userSession):
                    MXLog.info("sTalk NativeLogin: Login successful!")
                    self.saveCredentials(username: username, password: password)
                    actionsSubject.send(.signedIn(userSession))
                case .failure(let error):
                    MXLog.error("sTalk NativeLogin: SDK login failed: \(error)")
                    state.bindings.alertInfo = AlertInfo(
                        id: UUID(),
                        title: "Ошибка входа",
                        message: "Не удалось завершить авторизацию: \(error.localizedDescription)"
                    )
                }
            } catch let error as HeadlessOIDCAuthenticator.AuthError {
                MXLog.error("sTalk NativeLogin: Headless auth failed: \(error)")
                state.bindings.alertInfo = AlertInfo(
                    id: UUID(),
                    title: "Ошибка входа",
                    message: error.errorDescription ?? "Неизвестная ошибка"
                )
            } catch {
                MXLog.error("sTalk NativeLogin: Unexpected error: \(error)")
                state.bindings.alertInfo = AlertInfo(
                    id: UUID(),
                    title: "Ошибка",
                    message: error.localizedDescription
                )
            }

            state.isLoading = false
        }
    }
}
