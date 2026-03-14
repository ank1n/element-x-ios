//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Performs OIDC authentication programmatically by submitting credentials
/// directly to Keycloak's login form, bypassing the WebView.
/// The resulting callback URL (with auth code) is passed back to the SDK
/// for standard token exchange and device registration.
final class HeadlessOIDCAuthenticator {
    enum AuthError: LocalizedError {
        case noLoginFormFound
        case loginFailed(String)
        case networkError(Error)
        case invalidResponse
        case redirectNotFound

        var errorDescription: String? {
            switch self {
            case .noLoginFormFound: return NSLocalizedString("stalk_auth_no_login_form", tableName: "Localizable", value: "Не удалось найти форму входа", comment: "No login form found error")
            case .loginFailed(let msg): return msg
            case .networkError(let err): return String(format: NSLocalizedString("stalk_auth_network_error", tableName: "Localizable", value: "Ошибка сети: %@", comment: "Network error"), err.localizedDescription)
            case .invalidResponse: return NSLocalizedString("stalk_auth_invalid_response", tableName: "Localizable", value: "Некорректный ответ сервера", comment: "Invalid server response")
            case .redirectNotFound: return NSLocalizedString("stalk_auth_redirect_not_found", tableName: "Localizable", value: "Не получен redirect с кодом авторизации", comment: "Redirect not found")
            }
        }
    }

    /// Authenticate with Keycloak programmatically.
    /// - Parameters:
    ///   - authURL: The OIDC authorization URL (from SDK's `urlForOidc`)
    ///   - username: User's login
    ///   - password: User's password
    /// - Returns: The callback URL containing the authorization code
    func authenticate(authURL: URL, username: String, password: String) async throws -> URL {
        // Use a single session with cookie storage but no auto-redirects
        let session = makeSessionWithCookies()
        defer { session.invalidateAndCancel() }

        // Step 1: GET the auth URL — follow redirects manually to land on Keycloak login page
        MXLog.info("sTalk HeadlessOIDC: Step 1 — GET auth URL: \(authURL)")
        let (htmlData, finalURL) = try await getFollowingRedirects(url: authURL, session: session)
        MXLog.info("sTalk HeadlessOIDC: Step 1 done — landed on: \(finalURL)")

        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw AuthError.invalidResponse
        }

        // Step 2: Determine page type — consent page or Keycloak login form
        if let csrfToken = parseCSRFToken(html: html) {
            // MAS consent page (user already authenticated in Keycloak)
            MXLog.info("sTalk HeadlessOIDC: Step 2 — Consent page detected (skipping Keycloak login), CSRF: \(csrfToken)")
            return try await submitConsentAndFollowRedirects(url: finalURL, csrfToken: csrfToken, session: session)
        }

        guard let formActionURL = parseFormAction(html: html, baseURL: finalURL) else {
            MXLog.info("sTalk HeadlessOIDC: No form action found in HTML (length=\(html.count)), prefix: \(String(html.prefix(500)))")
            throw AuthError.noLoginFormFound
        }
        MXLog.info("sTalk HeadlessOIDC: Step 2 — Keycloak form action: \(formActionURL)")

        // Step 3: POST credentials to the Keycloak login form
        var request = URLRequest(url: formActionURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(urlEncode(username))&password=\(urlEncode(password))&credentialId="
        request.httpBody = body.data(using: .utf8)

        MXLog.info("sTalk HeadlessOIDC: Step 3 — POST credentials to Keycloak")
        let (postData, postResponse) = try await session.data(for: request)

        guard let postHTTPResponse = postResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        MXLog.info("sTalk HeadlessOIDC: Step 3 — POST response status: \(postHTTPResponse.statusCode)")
        saveCookies(from: postHTTPResponse, for: formActionURL)

        // Step 4: Follow redirects manually to find the callback URL
        if [301, 302, 303, 307, 308].contains(postHTTPResponse.statusCode) {
            return try await followRedirects(from: postHTTPResponse, session: session, maxRedirects: 10, baseURL: formActionURL)
        }

        // If we got 200, it means login failed (Keycloak shows the form again with error)
        if postHTTPResponse.statusCode == 200 {
            let responseHTML = String(data: postData, encoding: .utf8) ?? ""
            let errorMsg = parseKeycloakError(html: responseHTML)
            throw AuthError.loginFailed(errorMsg ?? SL10n.authInvalidCredentials)
        }

        // Log unexpected response for debugging
        let responseBody = String(data: postData, encoding: .utf8) ?? "(binary)"
        MXLog.info("sTalk HeadlessOIDC: Unexpected POST status \(postHTTPResponse.statusCode), body prefix: \(String(responseBody.prefix(500)))")
        throw AuthError.invalidResponse
    }

    /// Submit MAS consent page and follow redirects to callback URL.
    private func submitConsentAndFollowRedirects(url: URL, csrfToken: String, session: URLSession) async throws -> URL {
        var formRequest = URLRequest(url: url)
        formRequest.httpMethod = "POST"
        formRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        formRequest.httpBody = "csrf=\(urlEncode(csrfToken))".data(using: .utf8)

        let (_, formResponse) = try await session.data(for: formRequest)
        guard let formHTTPResponse = formResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        saveCookies(from: formHTTPResponse, for: url)
        MXLog.info("sTalk HeadlessOIDC: Consent POST response: \(formHTTPResponse.statusCode)")

        if [301, 302, 303, 307, 308].contains(formHTTPResponse.statusCode) {
            return try await followRedirects(from: formHTTPResponse, session: session, maxRedirects: 10, baseURL: url)
        }

        throw AuthError.redirectNotFound
    }

    // MARK: - Private

    private let cookieStorage = HTTPCookieStorage.shared

    private func makeSessionWithCookies() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = cookieStorage
        config.httpShouldSetCookies = true
        let delegate = NonRedirectDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Manually save Set-Cookie headers from a response (needed because NonRedirectDelegate
    /// prevents automatic cookie handling for redirect responses).
    private func saveCookies(from response: HTTPURLResponse, for url: URL) {
        guard let headerFields = response.allHeaderFields as? [String: String] else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
    }

    /// GET a URL, manually following redirects until we get a 200 (the login form).
    /// Returns the HTML data and the final URL we landed on.
    private func getFollowingRedirects(url: URL, session: URLSession, maxRedirects: Int = 15) async throws -> (Data, URL) {
        var currentURL = url
        var redirectCount = 0

        while redirectCount < maxRedirects {
            let request = URLRequest(url: currentURL)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.invalidResponse
            }

            // Save cookies from every response
            saveCookies(from: httpResponse, for: currentURL)

            if httpResponse.statusCode == 200 {
                return (data, currentURL)
            }

            if [301, 302, 303, 307, 308].contains(httpResponse.statusCode) {
                guard let location = httpResponse.value(forHTTPHeaderField: "Location") else {
                    throw AuthError.redirectNotFound
                }
                // Handle relative and absolute URLs
                if let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL {
                    // Check if this is already the callback URL
                    if isCallbackURL(nextURL) {
                        MXLog.info("sTalk HeadlessOIDC: GET redirect landed on callback URL")
                        return (data, nextURL)
                    }
                    currentURL = nextURL
                    redirectCount += 1
                    MXLog.info("sTalk HeadlessOIDC: GET redirect \(redirectCount) → \(currentURL)")
                    continue
                }
                throw AuthError.redirectNotFound
            }

            MXLog.info("sTalk HeadlessOIDC: Unexpected GET status \(httpResponse.statusCode) at \(currentURL)")
            throw AuthError.invalidResponse
        }

        throw AuthError.redirectNotFound
    }

    private func followRedirects(from response: HTTPURLResponse, session: URLSession, maxRedirects: Int, baseURL: URL? = nil) async throws -> URL {
        var currentResponse = response
        var currentBaseURL = baseURL
        var redirectCount = 0

        while redirectCount < maxRedirects {
            guard let locationString = currentResponse.value(forHTTPHeaderField: "Location") else {
                throw AuthError.redirectNotFound
            }

            // Handle both absolute and relative URLs
            let locationURL: URL
            if locationString.hasPrefix("http") {
                guard let url = URL(string: locationString) else { throw AuthError.redirectNotFound }
                locationURL = url
            } else if let base = currentBaseURL ?? response.url {
                guard let url = URL(string: locationString, relativeTo: base)?.absoluteURL else { throw AuthError.redirectNotFound }
                locationURL = url
            } else {
                throw AuthError.redirectNotFound
            }

            MXLog.info("sTalk HeadlessOIDC: POST redirect \(redirectCount + 1) → \(locationURL)")

            // Check if this is the callback URL we're looking for
            if isCallbackURL(locationURL) {
                MXLog.info("sTalk HeadlessOIDC: Found callback URL!")
                return locationURL
            }

            // Follow the redirect
            var request = URLRequest(url: locationURL)
            request.httpMethod = "GET"

            let (nextData, nextResponse) = try await session.data(for: request)
            guard let nextHTTPResponse = nextResponse as? HTTPURLResponse else {
                throw AuthError.invalidResponse
            }

            // Save cookies from redirect responses
            saveCookies(from: nextHTTPResponse, for: locationURL)
            currentBaseURL = locationURL

            if [301, 302, 303, 307, 308].contains(nextHTTPResponse.statusCode) {
                currentResponse = nextHTTPResponse
                redirectCount += 1
                continue
            }

            // Non-redirect response — check if it's the final callback
            if let callbackURL = extractCallbackURL(from: nextHTTPResponse) {
                return callbackURL
            }

            // Check if this is MAS consent page — auto-submit with CSRF token
            MXLog.info("sTalk HeadlessOIDC: POST chain: status \(nextHTTPResponse.statusCode) at \(locationURL)")
            if nextHTTPResponse.statusCode == 200,
               let html = String(data: nextData, encoding: .utf8),
               let csrfToken = parseCSRFToken(html: html) {
                MXLog.info("sTalk HeadlessOIDC: Found consent page, CSRF token: \(csrfToken)")
                var formRequest = URLRequest(url: locationURL)
                formRequest.httpMethod = "POST"
                formRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                formRequest.httpBody = "csrf=\(urlEncode(csrfToken))".data(using: .utf8)

                let (_, formResponse) = try await session.data(for: formRequest)
                guard let formHTTPResponse = formResponse as? HTTPURLResponse else {
                    throw AuthError.invalidResponse
                }
                saveCookies(from: formHTTPResponse, for: locationURL)

                if [301, 302, 303, 307, 308].contains(formHTTPResponse.statusCode) {
                    currentResponse = formHTTPResponse
                    currentBaseURL = locationURL
                    redirectCount += 1
                    continue
                }
            }

            // 200 page without CSRF — log HTML prefix for debugging
            if nextHTTPResponse.statusCode == 200,
               let html = String(data: nextData, encoding: .utf8) {
                MXLog.info("sTalk HeadlessOIDC: 200 page without CSRF, HTML prefix: \(String(html.prefix(500)))")
            }
            throw AuthError.redirectNotFound
        }

        throw AuthError.redirectNotFound
    }

    private func isCallbackURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString
        // Only match our final redirect_uri, NOT intermediate MAS/Keycloak callbacks
        return urlString.contains("stalk.implica.ru/oidc/login") ||
               urlString.contains("stalk.implica.ru/oidc/callback") ||
               urlString.hasPrefix("ru.implica.stalk://")
    }

    private func extractCallbackURL(from response: HTTPURLResponse) -> URL? {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location),
              isCallbackURL(url) else { return nil }
        return url
    }

    private func parseFormAction(html: String, baseURL: URL) -> URL? {
        // Look for <form ... action="..." in the HTML
        // Keycloak format: <form id="kc-form-login" ... action="https://...">
        guard let actionRange = html.range(of: #"action="([^"]+)""#, options: .regularExpression) else {
            return nil
        }

        let match = html[actionRange]
        // Extract the URL between quotes
        guard let urlStart = match.range(of: "\""),
              let urlEnd = match.range(of: "\"", options: .backwards) else {
            return nil
        }

        let urlString = String(match[match.index(after: urlStart.lowerBound)..<urlEnd.lowerBound])
        // Decode HTML entities
        let decoded = urlString
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x3a;", with: ":")
            .replacingOccurrences(of: "&#x2f;", with: "/")

        if decoded.hasPrefix("http") {
            return URL(string: decoded)
        }
        // Relative URL
        return URL(string: decoded, relativeTo: baseURL)
    }

    private func parseKeycloakError(html: String) -> String? {
        // Keycloak shows errors in <span id="input-error" class="...">
        // or in <div class="alert alert-error">
        if let errorRange = html.range(of: #"<span[^>]*id="input-error"[^>]*>([^<]+)</span>"#, options: .regularExpression) {
            let match = html[errorRange]
            // Extract text between > and <
            if let textStart = match.range(of: ">"),
               let textEnd = match.range(of: "</", options: .backwards) {
                let text = String(match[match.index(after: textStart.lowerBound)..<textEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        // Try alert-error div
        if let alertRange = html.range(of: #"class="[^"]*alert-error[^"]*"[^>]*>([^<]+)"#, options: .regularExpression) {
            let match = html[alertRange]
            if let textStart = match.range(of: ">") {
                let text = String(match[match.index(after: textStart.lowerBound)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// Extract CSRF token from MAS consent page HTML.
    /// Looks for `<input type="hidden" name="csrf" value="...">` in the first form.
    private func parseCSRFToken(html: String) -> String? {
        // Match name="csrf" value="..." (in any attribute order)
        if let range = html.range(of: #"name="csrf"\s+value="([^"]+)""#, options: .regularExpression) {
            let match = html[range]
            // Extract value between the last pair of quotes
            if let valStart = match.range(of: #"value=""#, options: .regularExpression),
               let valEnd = match.range(of: "\"", options: .backwards) {
                let start = match.index(valStart.upperBound, offsetBy: 0)
                return String(match[start..<valEnd.lowerBound])
            }
        }
        // Try reverse order: value="..." name="csrf"
        if let range = html.range(of: #"value="([^"]+)"\s+name="csrf""#, options: .regularExpression) {
            let match = html[range]
            if let valStart = match.range(of: "\""),
               let valEnd = match.range(of: "\"", options: [], range: match.index(after: valStart.lowerBound)..<match.endIndex) {
                return String(match[match.index(after: valStart.lowerBound)..<valEnd.lowerBound])
            }
        }
        return nil
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D")
            ?? string
    }
}

// MARK: - URLSession delegate that prevents automatic redirect following

private final class NonRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Return nil to prevent automatic redirect following
        completionHandler(nil)
    }
}
