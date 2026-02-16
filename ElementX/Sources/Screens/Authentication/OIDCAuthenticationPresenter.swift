//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices

/// Presents a web authentication session for an OIDC request.
@MainActor
class OIDCAuthenticationPresenter: NSObject {
    private let authenticationService: AuthenticationServiceProtocol
    private let oidcRedirectURL: URL
    private let presentationAnchor: UIWindow
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let useEphemeralSession: Bool

    private var activeSession: ASWebAuthenticationSession?

    init(authenticationService: AuthenticationServiceProtocol,
         oidcRedirectURL: URL,
         presentationAnchor: UIWindow,
         userIndicatorController: UserIndicatorControllerProtocol,
         useEphemeralSession: Bool = false) {
        self.authenticationService = authenticationService
        self.oidcRedirectURL = oidcRedirectURL
        self.presentationAnchor = presentationAnchor
        self.userIndicatorController = userIndicatorController
        self.useEphemeralSession = useEphemeralSession
        super.init()
    }
    
    /// Presents a web authentication session for the supplied data.
    func authenticate(using oidcData: OIDCAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        let (url, error) = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: oidcData.url, callback: .oidcRedirectURL(oidcRedirectURL)) { url, error in
                continuation.resume(returning: (url, error))
            }

            session.prefersEphemeralWebBrowserSession = useEphemeralSession
            session.presentationContextProvider = self
            session.additionalHeaderFields = [
                "X-Element-User-Agent": UserAgentBuilder.makeASCIIUserAgent()
            ]

            activeSession = session
            session.start()
        }
        
        activeSession = nil
        
        MXLog.info("sTalk: OIDC session completed — url=\(url?.absoluteString ?? "nil"), error=\(error.map(String.init(describing:)) ?? "nil")")

        guard let url else {
            // Check for user cancellation to avoid showing an alert in that instance.
            if error?.isOIDCUserCancellation == true {
                // No need to show an error here, just abort and return a failure.
                await authenticationService.abortOIDCLogin(data: oidcData)
                return .failure(.oidcError(.userCancellation))
            }
            
            let errorDescription = error.map(String.init(describing:)) ?? "Unknown error"
            MXLog.error("Missing callback URL from the web authentication session: \(errorDescription)")
            
            userIndicatorController.alertInfo = AlertInfo(id: UUID())
            await authenticationService.abortOIDCLogin(data: oidcData)
            return .failure(.oidcError(.unknown))
        }
        
        // Exchanging the callback with the homeserver can be slow, so show the loading indicator while we wait (the modal has already been dismissed).
        startLoading(delay: .milliseconds(50)) // Small delay to handle a cancellation callback without the indicator showing.
        defer { stopLoading() }
        
        // Rewrite custom scheme URL back to HTTPS for the SDK (MAS expects HTTPS redirect_uri).
        let callbackURL = url.rewritingCustomSchemeToHTTPS()

        switch await authenticationService.loginWithOIDCCallback(callbackURL) {
        case .success(let userSession):
            return .success(userSession)
        case .failure(.oidcError(.userCancellation)):
            // No need to show an error here, just return the failure.
            return .failure(.oidcError(.userCancellation))
        case .failure(let error):
            MXLog.error("Error occurred: \(error)")
            userIndicatorController.alertInfo = AlertInfo(id: UUID())
            return .failure(error)
        }
    }
    
    func cancel() {
        activeSession?.cancel()
    }
    
    private static let loadingIndicatorID = "\(OIDCAuthenticationPresenter.self)-Loading"
    
    private func startLoading(delay: Duration? = nil) {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true),
                                                delay: delay)
    }
    
    private func stopLoading() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorID)
    }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension OIDCAuthenticationPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { presentationAnchor }
}

extension ASWebAuthenticationSession.Callback {
    /// sTalk: Use custom scheme callback to avoid associated-domains requirement (Personal Team).
    /// Server at stalk.implica.ru/oidc/callback redirects HTTPS → ru.implica.stalk:// custom scheme.
    static let sTalkCustomScheme = "ru.implica.stalk"

    static func oidcRedirectURL(_ url: URL) -> Self {
        // Always use custom scheme — server will 302 redirect from HTTPS to custom scheme.
        // This avoids the need for Associated Domains entitlement (not supported by Personal Team).
        .customScheme(sTalkCustomScheme)
    }
}

extension URL {
    /// Rewrites a custom scheme callback URL back to the HTTPS redirect URL expected by the SDK.
    /// ru.implica.stalk://oidc/callback?code=X → https://stalk.implica.ru/oidc/callback?code=X
    /// Note: URLComponents parses ru.implica.stalk://oidc/callback as host="oidc" path="/callback",
    /// so we reconstruct the full path from host + path.
    func rewritingCustomSchemeToHTTPS() -> URL {
        guard scheme == ASWebAuthenticationSession.Callback.sTalkCustomScheme else { return self }
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        // Reconstruct path: host was parsed as "oidc", path as "/callback" → need "/oidc/callback"
        let originalHost = components?.host ?? ""
        let originalPath = components?.path ?? ""
        components?.scheme = "https"
        components?.host = "stalk.implica.ru"
        components?.path = originalHost.isEmpty ? originalPath : "/\(originalHost)\(originalPath)"
        MXLog.info("sTalk: OIDC callback rewrite: \(self) → \(components?.url?.absoluteString ?? "nil")")
        return components?.url ?? self
    }
}

// MARK: - Helpers

extension Error {
    var isOIDCUserCancellation: Bool {
        let nsError = self as NSError
        
        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue,
           // If there's a failure reason then the cancellation wasn't made by the user.
           nsError.localizedFailureReason == nil {
            return true
        }
        
        return false
    }
}
