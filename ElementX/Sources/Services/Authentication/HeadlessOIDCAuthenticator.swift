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
        /// STMOB-273: личность есть в Keycloak, но матричной учётки на этом сервере нет.
        case accountNotProvisioned

        var errorDescription: String? {
            switch self {
            case .noLoginFormFound: return NSLocalizedString("stalk_auth_no_login_form", tableName: "Localizable", value: "Не удалось найти форму входа", comment: "No login form found error")
            case .loginFailed(let msg): return msg
            case .networkError(let err): return String(format: NSLocalizedString("stalk_auth_network_error", tableName: "Localizable", value: "Ошибка сети: %@", comment: "Network error"), err.localizedDescription)
            case .invalidResponse: return NSLocalizedString("stalk_auth_invalid_response", tableName: "Localizable", value: "Некорректный ответ сервера", comment: "Invalid server response")
            case .accountNotProvisioned: return NSLocalizedString("stalk_auth_not_provisioned", tableName: "Localizable", value: "Учётная запись не заведена на этом сервере. Обратитесь к администратору.", comment: "Account exists in the identity provider but not on this homeserver")
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
    /// STMOB-202: the chosen homeserver (e.g. "market.implica.ru"). Used to recognise the
    /// final OIDC callback and to scope cookie clearing, so login works on any server.
    private var homeserver = "stalk.implica.ru"

    func authenticate(authURL: URL, username: String, password: String, homeserver: String = "stalk.implica.ru") async throws -> URL {
        self.homeserver = homeserver

        // STMOB-182: clear any leftover SSO session cookies before a fresh login.
        // Otherwise Keycloak/MAS sees a previous user's session, serves the consent
        // page directly (skipping the login form), and the credentials we POST are
        // never used — silently authenticating the previous user on a shared device.
        clearAuthCookies()

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

    /// Remove SSO/session cookies for our auth domains so each explicit login starts
    /// from a clean Keycloak session (forces the login form instead of reusing a
    /// previous user's session). See STMOB-182.
    private func clearAuthCookies() {
        // STMOB-202: include the chosen homeserver + its auth subdomain so cookie clearing
        // works for any server, not only stalk.implica.ru.
        var authDomains = ["stalk.implica.ru", "trackit.implica.ru", homeserver]
        if !homeserver.hasPrefix("auth.") { authDomains.append("auth.\(homeserver)") }
        let cookies = cookieStorage.cookies ?? []
        var cleared = 0
        for cookie in cookies {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if authDomains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") }) {
                cookieStorage.deleteCookie(cookie)
                cleared += 1
            }
        }
        MXLog.info("sTalk HeadlessOIDC: cleared \(cleared)/\(cookies.count) auth cookies before login")
    }

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
                // STMOB-273: отправляем ФОРМУ ЦЕЛИКОМ, а не один только токен.
                // Страницы подтверждения у MAS содержат больше полей, чем csrf, и все
                // они уже заполнены сервером. Отправляя только токен, мы получали
                // HTTP 422 и вход падал без внятной причины.
                let formFields = Self.parseFormFields(html: html, fallbackCSRF: csrfToken)

                // НО создавать учётную запись клиент НЕ ДОЛЖЕН. Форма с action=register
                // на /upstream/link — это первичная регистрация: MAS предлагает завести
                // матричный аккаунт для личности, которую он видит впервые. У нас учётки
                // заводит централизованный провижининг, и вход из приложения не имеет
                // права его обходить: иначе матричный аккаунт получит любой, кто есть
                // в Keycloak, минуя пайплайн. Останавливаемся и говорим человеку правду.
                if formFields.contains(where: { $0.name == "action" && $0.value == "register" }) {
                    let mxid = formFields.first { $0.name == "mxid" }?.value ?? "?"
                    MXLog.error("""
                    sTalk HeadlessOIDC: сервер предлагает СОЗДАТЬ учётную запись \(mxid) — \
                    значит она на этом сервере не заведена. Регистрацию из приложения не \
                    выполняем, это зона провижининга. Вход прерван.
                    """)
                    throw AuthError.accountNotProvisioned
                }

                let emptyRequired = formFields.filter { $0.value.isEmpty && $0.name != "csrf" }
                if !emptyRequired.isEmpty {
                    MXLog.error("""
                    sTalk HeadlessOIDC: форма на \(locationURL) требует данных от человека — \
                    пустые поля: \(emptyRequired.map(\.name).joined(separator: ", ")). \
                    Заполнять их за пользователя нельзя, вход прерван.
                    """)
                    throw AuthError.redirectNotFound
                }

                MXLog.info("sTalk HeadlessOIDC: отправляю форму, поля: \(formFields.map(\.name).joined(separator: ", "))")
                var formRequest = URLRequest(url: locationURL)
                formRequest.httpMethod = "POST"
                formRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                formRequest.httpBody = formFields
                    .map { "\(urlEncode($0.name))=\(urlEncode($0.value))" }
                    .joined(separator: "&")
                    .data(using: .utf8)

                let (formData, formResponse) = try await session.data(for: formRequest)
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

                // STMOB-273: форма ушла, но редиректа нет — MAS вернул страницу.
                // Раньше здесь печаталась ИСХОДНАЯ страница под заголовком
                // «200 page without CSRF», хотя токен как раз нашёлся и был отправлен:
                // тело ответа формы отбрасывалось в `_`. Диагностика показывала не тот
                // документ и уводила в сторону. Печатаем ответ НА ОТПРАВКУ и заголовок
                // страницы — по нему сразу видно, чего MAS хочет (привязка аккаунта,
                // выбор имени, повторное согласие).
                let formBody = String(data: formData, encoding: .utf8) ?? ""
                // Ответ может быть и не HTML (422 от MAS приходит почти пустым) —
                // тогда единственное полезное это само тело.
                let fields = Self.formFieldNames(html: formBody)
                MXLog.error("""
                sTalk HeadlessOIDC: форма отправлена на \(locationURL), \
                ответ \(formHTTPResponse.statusCode) без редиректа. \
                Заголовок страницы: \(Self.pageHeading(html: formBody) ?? "не найден"). \
                Поля формы: \(fields.joined(separator: ", ")). \
                Тело (\(formData.count) байт): \(formBody.isEmpty ? "пусто" : String(formBody.prefix(400)))
                """)
                throw AuthError.redirectNotFound
            }

            if nextHTTPResponse.statusCode == 200,
               let html = String(data: nextData, encoding: .utf8) {
                MXLog.error("""
                sTalk HeadlessOIDC: страница \(locationURL) без CSRF-токена. \
                Заголовок: \(Self.pageHeading(html: html) ?? "не найден"). \
                Поля формы: \(Self.formFieldNames(html: html).joined(separator: ", "))
                """)
            }
            throw AuthError.redirectNotFound
        }

        throw AuthError.redirectNotFound
    }

    /// STMOB-273: все поля `<input>` первой формы страницы, в порядке появления.
    /// `<button>` намеренно не берём: у MAS кнопка отправки без имени, а если бы
    /// имя было, отправлять надо только нажатую — угадывать которую мы не вправе.
    /// Если `csrf` в разметке не нашёлся, подставляем уже разобранный токен —
    /// он вытаскивается отдельным разбором, терпимым к порядку атрибутов.
    static func parseFormFields(html: String, fallbackCSRF: String? = nil) -> [(name: String, value: String)] {
        let formHTML: String
        if let start = html.range(of: "<form", options: .caseInsensitive),
           let end = html.range(of: "</form>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) {
            formHTML = String(html[start.lowerBound..<end.upperBound])
        } else {
            formHTML = html
        }

        var fields: [(name: String, value: String)] = []
        var search = formHTML.startIndex..<formHTML.endIndex
        while let tagRange = formHTML.range(of: "<input[^>]*>", options: [.regularExpression, .caseInsensitive], range: search) {
            let tag = String(formHTML[tagRange])
            search = tagRange.upperBound..<formHTML.endIndex

            guard let name = attributeValue("name", in: tag), !name.isEmpty else { continue }
            // Невыбранные флажки и радиокнопки браузер не отправляет — и мы не отправляем.
            if let type = attributeValue("type", in: tag)?.lowercased(),
               type == "checkbox" || type == "radio",
               !tag.lowercased().contains("checked") {
                continue
            }
            fields.append((name, attributeValue("value", in: tag) ?? ""))
        }

        if !fields.contains(where: { $0.name == "csrf" }), let fallbackCSRF {
            fields.insert(("csrf", fallbackCSRF), at: 0)
        }
        return fields
    }

    private static func attributeValue(_ attribute: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\\b\(attribute)=\"[^\"]*\"", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(tag[range]).drop { $0 != "\"" }.dropFirst().dropLast()
        return String(raw)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// STMOB-273: заголовок страницы (`<h1>`) — по нему видно, что именно
    /// показал сервер. `<title>` у MAS всегда «matrix-authentication-service»
    /// и не различает страницы.
    private static func pageHeading(html: String) -> String? {
        guard let range = html.range(of: #"<h1[^>]*>([\s\S]{0,200}?)</h1>"#, options: .regularExpression) else { return nil }
        let heading = html[range]
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? nil : heading
    }

    /// Имена полей формы — показывают, чего серверу не хватило.
    private static func formFieldNames(html: String) -> [String] {
        var names: [String] = []
        var search = html.startIndex..<html.endIndex
        while let range = html.range(of: #"<(?:input|select|button)[^>]*\bname="([^"]+)""#,
                                     options: .regularExpression, range: search) {
            let tag = String(html[range])
            if let nameRange = tag.range(of: #"name="([^"]+)""#, options: .regularExpression) {
                let name = tag[nameRange].replacingOccurrences(of: "name=", with: "").replacingOccurrences(of: "\"", with: "")
                if !names.contains(name) { names.append(name) }
            }
            search = range.upperBound..<html.endIndex
        }
        return names.isEmpty ? ["нет"] : names
    }

    private func isCallbackURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString
        // Only match our final redirect_uri, NOT intermediate MAS/Keycloak callbacks.
        // STMOB-202: match the chosen homeserver's redirect (any server), plus the
        // custom scheme. stalk.implica.ru kept for backward compatibility.
        return urlString.contains("\(homeserver)/oidc/login") ||
            urlString.contains("\(homeserver)/oidc/callback") ||
            urlString.contains("stalk.implica.ru/oidc/login") ||
            urlString.contains("stalk.implica.ru/oidc/callback") ||
            // STMOB-245: match the custom scheme regardless of slash count. On non-.ru servers
            // (e.g. stalk.implica.uz) the final redirect arrives as `ru.implica.stalk:/oidc/callback`
            // (single slash, no authority) instead of `ru.implica.stalk://oidc/callback`. The old
            // `hasPrefix("ru.implica.stalk://")` missed the single-slash form, so the authenticator
            // tried to URLSession-fetch the custom-scheme URL → NSURLErrorUnsupportedURL (-1002,
            // "URL не поддерживается") and login failed on every server other than stalk.implica.ru.
            urlString.hasPrefix("ru.implica.stalk:")
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
