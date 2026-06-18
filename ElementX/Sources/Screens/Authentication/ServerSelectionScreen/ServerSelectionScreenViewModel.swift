//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ServerSelectionScreenViewModelType = StateStoreViewModelV2<ServerSelectionScreenViewState, ServerSelectionScreenViewAction>

class ServerSelectionScreenViewModel: ServerSelectionScreenViewModelType, ServerSelectionScreenViewModelProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let authenticationFlow: AuthenticationFlow
    private let appSettings: AppSettings
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private var actionsSubject: PassthroughSubject<ServerSelectionScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<ServerSelectionScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(authenticationService: AuthenticationServiceProtocol,
         authenticationFlow: AuthenticationFlow,
         appSettings: AppSettings,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.authenticationService = authenticationService
        self.authenticationFlow = authenticationFlow
        self.appSettings = appSettings
        self.userIndicatorController = userIndicatorController
        
        // STMOB-217: pre-fill the default provider (stalk.implica.ru) for the login
        // flow so the manual sign-in fallback is one tap (Continue → credentials);
        // the field stays editable for any other Matrix server.
        // STMOB-243: prefer the most recently used server (top of the saved accounts list,
        // sorted by lastUsedAt) so a returning user gets their last server pre-filled instead
        // of always the hardcoded default. Falls back to the configured provider when empty.
        let lastUsedServer = SavedAccountsStore().getAll().first?.serverURL
        let defaultAddress = authenticationFlow == .login ? (lastUsedServer ?? appSettings.accountProviders.first ?? "") : ""
        let bindings = ServerSelectionScreenBindings(homeserverAddress: defaultAddress)
        let placeholder = authenticationFlow == .register ? "matrix.org" : L10n.commonServerUrl
        // STMOB-217: this screen is reached for login via the QR "no other device"
        // fallback — show the hint so the user knows to enter credentials.
        let customFooter = authenticationFlow == .login ? SL10n.authNoDevicesHint : nil
        super.init(initialViewState: ServerSelectionScreenViewState(placeholder: placeholder, bindings: bindings, customFooterMessage: customFooter))
    }
    
    override func process(viewAction: ServerSelectionScreenViewAction) {
        switch viewAction {
        case .confirm:
            configureHomeserver()
        case .dismiss:
            actionsSubject.send(.dismiss)
        case .clearFooterError:
            clearFooterError()
        }
    }
    
    // MARK: - Private
    
    /// Updates the login flow using the supplied homeserver address, or shows an error when this isn't possible.
    private func configureHomeserver() {
        let homeserverAddress = state.bindings.homeserverAddress
        startLoading()
        
        Task {
            switch await authenticationService.configure(for: homeserverAddress, flow: authenticationFlow) {
            case .success:
                MXLog.info("Selected homeserver: \(homeserverAddress)")
                actionsSubject.send(.updated)
                stopLoading()
            case .failure(let error):
                MXLog.info("sTalk: Invalid homeserver: \(homeserverAddress), error: \(error)")
                stopLoading()
                handleError(error)
            }
        }
    }
    
    private func startLoading(label: String = L10n.commonLoading) {
        userIndicatorController.submitIndicator(UserIndicator(type: .modal,
                                                              title: label,
                                                              persistent: true))
    }
    
    private func stopLoading() {
        userIndicatorController.retractAllIndicators()
    }
    
    /// Processes an error to either update the flow or display it to the user.
    private func handleError(_ error: AuthenticationServiceError) {
        switch error {
        case .invalidServer, .invalidHomeserverAddress:
            showFooterMessage(L10n.screenChangeServerErrorInvalidHomeserver)
        case .invalidWellKnown(let error):
            state.bindings.alertInfo = AlertInfo(id: .invalidWellKnownAlert(error),
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenChangeServerErrorInvalidWellKnown(error))
        case .slidingSyncNotAvailable:
            let nonBreakingAppName = InfoPlistReader.main.bundleDisplayName.replacingOccurrences(of: " ", with: "\u{00A0}")
            state.bindings.alertInfo = AlertInfo(id: .slidingSyncAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenChangeServerErrorNoSlidingSyncMessage(nonBreakingAppName))
        case .loginNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .loginAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenLoginErrorUnsupportedAuthentication)
        case .registrationNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .registrationAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.errorAccountCreationNotPossible)
        case .elementProRequired(let serverName):
            state.bindings.alertInfo = AlertInfo(id: .elementProAlert,
                                                 title: L10n.screenChangeServerErrorElementProRequiredTitle,
                                                 message: L10n.screenChangeServerErrorElementProRequiredMessage(serverName),
                                                 primaryButton: .init(title: L10n.screenChangeServerErrorElementProRequiredActionIos) {
                                                     UIApplication.shared.open(self.appSettings.elementProAppStoreURL)
                                                 },
                                                 secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
        default:
            // sTalk DEBUG: show detailed error to diagnose login issues
            state.bindings.alertInfo = AlertInfo(id: .loginAlert,
                                                 title: "sTalk Debug Error",
                                                 message: "Error type: \(error)\n\nDetails: \(String(describing: error))")
        }
    }
    
    /// Set a new error message to be shown in the text field footer.
    private func showFooterMessage(_ message: String) {
        withElementAnimation {
            state.footerErrorMessage = message
        }
    }
    
    /// Clear any errors shown in the text field footer.
    private func clearFooterError() {
        guard state.footerErrorMessage != nil else { return }
        withElementAnimation { state.footerErrorMessage = nil }
    }
}
