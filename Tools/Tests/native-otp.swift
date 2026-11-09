import Foundation

// Runs with the production authenticator; only logging/localized fallback are stubbed.
enum MXLog { static func info(_ s: String) { }; static func error(_ s: String) { } }
enum SL10n { static let authInvalidCredentials = "Invalid credentials" }
final class OTPProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, [String: String]))!
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (status, body, headers) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { }
}

struct TestFailure: Error { }
func check(_ condition: @autoclosure () -> Bool, line: Int = #line) throws {
    if !condition() { FileHandle.standardError.write(Data("Failed assertion at line \(line)\n".utf8)); throw TestFailure() }
}

@main struct OTPTests {
    static func main() async throws {
        let login = #"<form action="https://id.example/login"><input name="username"><input name="password"></form>"#
        let otp = #"<form id="kc-otp-login-form" action="https://id.example/otp?execution=1&amp;tab_id=test"><input name="csrf" value="test-csrf"><input type="radio" name="selectedCredentialId" value="selected" checked="checked"><input type="radio" name="selectedCredentialId" value="other"><input name="otp" autocomplete="one-time-code"></form>"#
        let callback = "ru.implica.stalk://oidc/callback?code=test&state=test"
        try check(!HeadlessOIDCAuthenticator.isOneTimeCodeForm(html: login))
        try check(HeadlessOIDCAuthenticator.isOneTimeCodeForm(html: otp))
        try check(!HeadlessOIDCAuthenticator.isOneTimeCodeForm(html: #"<form><input name="otp"><input name="totpSecret" value="setup"></form>"#))
        try check(HeadlessOIDCAuthenticator.isOneTimeCodeForm(html: "<form><input name = 'otp'></form>"))
        for scenario in ["password", "otp", "retry", "cancel", "password-error", "cross-origin", "redirect-otp"] {
            var passwordPosts = 0
            var otpPosts = 0
            OTPProtocol.handler = { request in
                if request.httpMethod == "GET" {
                    if request.url!.path == "/challenge" { return (200, otp, [:]) }
                    return (200, login, [:])
                }
                if request.url!.path == "/login" {
                    passwordPosts += 1
                    if scenario == "password" { return (302, "", ["Location": callback]) }
                    if scenario == "password-error" { return (200, login, [:]) }
                    if scenario == "redirect-otp" { return (302, "", ["Location": "https://id.example/challenge"]) }
                    return (200, scenario == "cross-origin" ? otp.replacingOccurrences(of: "https://id.example/otp", with: "https://evil.example/otp") : otp, [:])
                }
                otpPosts += 1
                var bodyData = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        bodyData.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = String(data: bodyData, encoding: .utf8) ?? ""
                try check(!body.contains("password"))
                try check(body.contains("csrf=test-csrf"))
                try check(body.contains("selectedCredentialId=selected"))
                try check(!body.contains("selectedCredentialId=other"))
                if scenario == "retry", otpPosts == 1 {
                    try check(body.contains("otp=000000"))
                    return (200, otp.replacingOccurrences(of: "execution=1", with: "execution=2"), [:])
                }
                try check(body.contains("otp=123456"))
                if scenario == "retry" { try check(request.url!.query!.contains("execution=2")) }
                return (302, "", ["Location": callback])
            }
            let authenticator = HeadlessOIDCAuthenticator(sessionFactory: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [OTPProtocol.self]
                return URLSession(configuration: config)
            })
            var prompts = 0
            do {
                let url = try await authenticator.authenticate(authURL: URL(string: "https://id.example/authorize")!, username: "test", password: "test", homeserver: "matrix.example") { rejected in
                    prompts += 1
                    try check(rejected == (prompts > 1))
                    if scenario == "cancel" { throw CancellationError() }
                    return scenario == "retry" && prompts == 1 ? "000000" : "123456"
                }
                try check(!["cancel", "password-error", "cross-origin"].contains(scenario))
                try check(url.absoluteString == callback)
            } catch is CancellationError { try check(scenario == "cancel")
            } catch { try check(["password-error", "cross-origin"].contains(scenario)) }
            try check(passwordPosts == 1)
            if ["password", "password-error", "cross-origin"].contains(scenario) { try check(prompts == 0 && otpPosts == 0) }
            if scenario == "cancel" { try check(prompts == 1 && otpPosts == 0) }
            if scenario == "retry" { try check(prompts == 2 && otpPosts == 2) }
            print("PASS \(scenario)")
        }
    }
}
