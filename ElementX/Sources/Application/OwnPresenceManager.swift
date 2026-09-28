//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// STMOB-103: Поддерживает корректную presence пользователя в Synapse независимо
/// от того, на какой вкладке он находится в приложении.
///
/// Логика жизненного цикла:
/// - Foreground active   → `online`, периодический ping
/// - Background          → `unavailable` (idle, web покажет жёлтый dot + last seen)
/// - Terminate           → `offline`
///
/// STMOB-304: это ЕДИНСТВЕННЫЙ писатель своего статуса. Раньше тот же PUT слал и цикл
/// PresenceService, и два писателя в одном 10-секундном окне получали 429 (лимит Synapse
/// rc_presence — один PUT в 10 с на учётку): на проде все 429 присутствия были от этого.
///
/// Endpoint: PUT /_matrix/client/v3/presence/{userId}/status   {"presence":"<status>"}
@MainActor
final class OwnPresenceManager {
    typealias Status = OwnPresenceSchedule.Status

    static let requestTimeout: TimeInterval = 15

    private let homeserver: String
    private let userID: String
    /// Build 121: token не кэшируем — берём свежий перед каждым запросом (ротация).
    private let tokenProvider: () -> String?
    private let transport: PresenceTransport
    private let now: () -> Date

    private var schedule = OwnPresenceSchedule()
    private var worker: Task<Void, Never>?
    private var isSending = false

    convenience init?(clientProxy: ClientProxyProtocol) {
        // sanity check: token должен быть доступен сейчас (иначе session не set)
        guard (try? clientProxy.matrixAccessToken()) != nil else { return nil }
        self.init(homeserver: clientProxy.homeserver,
                  userID: clientProxy.userID,
                  tokenProvider: { [weak clientProxy] in try? clientProxy?.matrixAccessToken() })
    }

    init(homeserver: String,
         userID: String,
         tokenProvider: @escaping () -> String?,
         transport: PresenceTransport = URLSessionPresenceTransport(),
         now: @escaping () -> Date = Date.init) {
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.userID = userID
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.now = now
    }

    deinit {
        worker?.cancel()
    }

    func startOnline() {
        setDesired(.online)
    }

    func setBackground() {
        setDesired(.unavailable)
    }

    func setOffline() {
        setDesired(.offline)
    }

    /// Выход из аккаунта: больше ничего не шлём.
    func stop() {
        schedule.desiredStatus = nil
        worker?.cancel()
        worker = nil
    }

    // MARK: - Private

    /// Смена статуса не выбрасывается, а откладывается до разрешённого момента: раньше дебаунс
    /// просто глотал её, и после быстрого возврата в приложение на сервере до минуты висел
    /// `unavailable`. Идущий PUT не прерываем — цикл подхватит новый статус сразу после него.
    private func setDesired(_ status: Status) {
        schedule.desiredStatus = status
        guard !isSending else { return }
        worker?.cancel()
        // Цикл держит менеджер слабо: после выхода из аккаунта он не живёт сам по себе.
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.step() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Один шаг: отправляет статус, если пора, и говорит, сколько ждать до следующего шага.
    /// `nil` — ждать нечего (статус отправлен и повторять его не нужно).
    private func step() async -> TimeInterval? {
        let token = tokenProvider()
        switch schedule.nextAction(now: now(), currentToken: token) {
        case .idle:
            return nil
        case .wait(let delay):
            return delay
        case .send(let status):
            let sentAt = now()
            isSending = true
            let result = await send(status, token: token)
            isSending = false
            schedule.record(result, for: status, sentAt: sentAt, answeredAt: now())
            // Сразу следующий шаг: статус мог смениться, пока шёл запрос.
            return 0
        }
    }

    private func send(_ status: Status, token: String?) async -> OwnPresenceSchedule.SendResult {
        guard let url = PresenceRequest.url(homeserver: homeserver, userID: userID) else { return .failed }
        guard let token else {
            DiagLog.write("Presence", "setStatus(\(status.rawValue)) SKIP — no token")
            return .failed
        }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["presence": status.rawValue])

        do {
            return try await Self.result(of: transport.send(request), status: status, token: token)
        } catch {
            DiagLog.write("Presence", "setStatus(\(status.rawValue)) ERR \(error)")
            return .failed
        }
    }

    static func result(of response: PresenceHTTPResponse, status: Status, token: String) -> OwnPresenceSchedule.SendResult {
        switch response.statusCode {
        case 200:
            return .accepted
        case 401:
            DiagLog.write("Presence", "setStatus(\(status.rawValue)) → HTTP 401, waiting for a new token")
            return .unauthorized(token: token)
        case 429:
            let retryAfter = PresenceRequest.retryAfter(from: response)
            DiagLog.write("Presence", "setStatus(\(status.rawValue)) → HTTP 429, retry in \(retryAfter.map { "\(Int($0 * 1000))ms" } ?? "?")")
            return .rateLimited(retryAfter: retryAfter)
        default:
            DiagLog.write("Presence", "setStatus(\(status.rawValue)) → HTTP \(response.statusCode)")
            return .failed
        }
    }
}

/// STMOB-304: когда слать свой статус. Отдельно от сети и времени, чтобы правила проверялись тестами.
struct OwnPresenceSchedule {
    enum Status: String {
        case online
        case unavailable
        case offline
    }

    enum SendResult: Equatable {
        case accepted
        case rateLimited(retryAfter: TimeInterval?)
        /// Токен протух: с ним повторять бессмысленно, ждём, пока SDK выдаст новый.
        case unauthorized(token: String)
        case failed
    }

    enum Action: Equatable {
        case send(Status)
        case wait(TimeInterval)
        case idle
    }

    /// На sliding sync Synapse не считает телефон синхронизирующимся и снимает его в offline,
    /// если с последнего PUT прошло больше 30 с (sync_online_timeout, проверка раз в 5 с).
    /// Поэтому шаг заметно меньше 30 с: запас на задержку сети и на отложенный после 429 PUT.
    static let pingInterval: TimeInterval = 20
    /// Лимит Synapse rc_presence.per_user по умолчанию — один PUT в 10 с на учётку (на проде так же).
    /// Раньше этого срока после принятого PUT смена статуса гарантированно получила бы 429 —
    /// ждём, а не упираемся.
    static let minPutInterval: TimeInterval = 10
    /// Повтор после сбоя сети: быстро, чтобы один пропуск не уронил в offline, но с ростом до потолка.
    static let initialRetryInterval: TimeInterval = 2
    static let retryInterval: TimeInterval = 10
    /// Пока токен тот же, что получил 401, проверяем смену локально — без сети.
    static let tokenCheckInterval: TimeInterval = 1

    var desiredStatus: Status?
    private(set) var lastSent: (status: Status, at: Date)?
    /// Раньше этого времени PUT не шлём: окно лимита, срок после 429 или после сбоя.
    private(set) var notBefore: Date = .distantPast
    private(set) var rejectedToken: String?
    private var consecutiveFailures = 0

    func nextAction(now: Date, currentToken: String?) -> Action {
        guard let status = desiredStatus else { return .idle }
        if let rejectedToken, currentToken == rejectedToken {
            return .wait(Self.tokenCheckInterval)
        }

        let dueAt: Date
        if let lastSent, lastSent.status == status {
            // Уже на сервере. Повторять нужно только online — иначе Synapse снимет его через 30 с.
            guard status == .online else { return .idle }
            dueAt = lastSent.at.addingTimeInterval(Self.pingInterval)
        } else {
            dueAt = now
        }

        let sendAt = max(dueAt, notBefore)
        return sendAt <= now ? .send(status) : .wait(sendAt.timeIntervalSince(now))
    }

    /// `sentAt` — начало отправки: от него считается следующий пинг, так пауза на сервере не
    /// растягивается на время запроса. `answeredAt` — ответ: от него считается окно лимита.
    mutating func record(_ result: SendResult, for status: Status, sentAt: Date, answeredAt: Date) {
        switch result {
        case .accepted:
            lastSent = (status, sentAt)
            notBefore = answeredAt.addingTimeInterval(Self.minPutInterval)
            rejectedToken = nil
            consecutiveFailures = 0
        case .rateLimited(let retryAfter):
            // Срок берём у сервера (retry_after_ms), а не спим фиксированные 120 с: после такого
            // сна телефон на минуты выпадал в offline.
            notBefore = answeredAt.addingTimeInterval(retryAfter ?? Self.retryInterval)
            consecutiveFailures = 0
        case .unauthorized(let token):
            rejectedToken = token
            notBefore = .distantPast
        case .failed:
            let delay = min(Self.initialRetryInterval * pow(2, Double(consecutiveFailures)), Self.retryInterval)
            notBefore = answeredAt.addingTimeInterval(delay)
            consecutiveFailures += 1
        }
    }
}
