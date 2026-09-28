//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

private let presenceLog = OSLog(subsystem: "ru.implica.stalk", category: "Presence")

struct UserPresence: Equatable {
    /// Вердикт сервера на момент ответа. Хранится отдельно, чтобы «невидимку»
    /// (человек сам выставил offline) не зажечь по одной лишь активности.
    let serverOnline: Bool
    let lastSeenDate: Date?

    /// «В сети» считается КАЖДЫЙ раз заново, а не запоминается снимком.
    ///
    /// Правило «активен меньше пяти минут назад» перестаёт выполняться само
    /// собой — просто оттого, что идёт время. Пока это был сохранённый флаг,
    /// запись в кэше держала зелёную точку вечно, и единственным способом
    /// погасить её был новый запрос: приходилось опрашивать всех подряд лишь
    /// затем, чтобы узнать, что человека давно нет. Теперь устаревание
    /// отрабатывает локально, а сеть нужна только чтобы поймать ПОЯВЛЕНИЕ.
    var isOnline: Bool {
        isOnline(at: Date())
    }

    func isOnline(at date: Date) -> Bool {
        Self.isOnline(serverOnline: serverOnline, lastSeenDate: lastSeenDate, at: date)
    }

    static func isOnline(serverOnline: Bool, lastSeenDate: Date?, at date: Date) -> Bool {
        guard serverOnline, let lastSeenDate else { return false }
        return date.timeIntervalSince(lastSeenDate) < PresenceService.onlineWindow
    }
}

/// STMOB-304: кому нужно присутствие. Каждый экран объявляет свой набор; внутри ключа
/// набор заменяется, между ключами объединяется. Так экран может выбросить ушедших из вида,
/// не стирая чужих, а сервис опрашивает только тех, кого сейчас кто-то показывает.
enum PresenceInterest: Hashable {
    /// Собеседники личных чатов из видимых строк «Чатов».
    case chats
    /// Люди из видимых строк «Контактов».
    case contacts
    /// Собеседник открытого личного чата (шапка комнаты). Ключ — у каждого экрана свой.
    case room(String)
    /// Все собеседники по личным чатам — фоном, остатком бюджета и редко. Нужен фильтру «Онлайн»,
    /// счётчику и сортировке «Контактов»: без него новый «в сети» не появился бы там, пока строку
    /// не прокрутят на экран.
    case chatPartners

    /// Видимое на экране опрашивается раньше фона.
    var isForeground: Bool {
        self != .chatPartners
    }

    /// С этими людьми есть общая комната: 403 для них — временное состояние (приглашение ещё
    /// не принято), а не «чужой человек», и надолго его не запоминаем.
    var isRoomBacked: Bool {
        self != .contacts
    }
}

/// STMOB-304: кэш 403 (нет общей комнаты — Synapse не покажет присутствие) переживает
/// перезапуск приложения. Раньше он жил в памяти, и каждый холодный старт давал ~100 лишних 403.
protocol PresenceForbiddenStore {
    func load() -> [String: Date]
    func save(_ forbiddenUntil: [String: Date])
}

struct UserDefaultsPresenceForbiddenStore: PresenceForbiddenStore {
    private let key: String
    private let defaults: UserDefaults

    init(ownUserID: String, defaults: UserDefaults = .standard) {
        key = "presenceForbiddenUntil.\(ownUserID)"
        self.defaults = defaults
    }

    func load() -> [String: Date] {
        defaults.dictionary(forKey: key) as? [String: Date] ?? [:]
    }

    func save(_ forbiddenUntil: [String: Date]) {
        defaults.set(forbiddenUntil, forKey: key)
    }
}

/// Опрос чужого присутствия по REST.
///
/// STMOB-304: на sliding sync присутствие не приходит вовсе (ни в SDK, ни в Synapse SSS),
/// поэтому опрос остаётся, но ограниченный:
/// - опрашиваем только объединение интересов экранов (видимые строки, открытая комната);
/// - на запросы есть бюджет: пачка до `burst`, дальше не чаще `refillPerSecond`,
///   одновременно не больше `maxConcurrent`; самые несвежие — первыми;
/// - 429 — пауза по `retry_after_ms` с удвоением; 401 — волна прерывается, и запросов нет,
///   пока SDK не выдаст новый токен; 403 у человека без общей комнаты — не опрашивается 6 часов,
///   и между запусками тоже;
/// - фон (`chatPartners`) получает только остаток бюджета и не чаще `offlineRefreshInterval`.
/// Свой статус этот сервис больше не отправляет — это делает только `OwnPresenceManager`.
@MainActor
final class PresenceService {
    /// Граница «в сети»: сервер считает человека активным, пока последняя
    /// активность моложе пяти минут. Одно правило и для разбора ответа, и для
    /// затухания в `UserPresence`, и для расчёта частоты опроса.
    nonisolated static let onlineWindow: TimeInterval = 5 * 60
    /// Тех, кто в сети, освежаем чаще: иначе точка гасла бы между ответами, хотя человек на месте.
    static let onlineRefreshInterval: TimeInterval = 30
    /// Серверное «в сети» держится пять минут после активности — опроса дважды за это окно
    /// достаточно, чтобы не пропустить появление.
    static let offlineRefreshInterval: TimeInterval = onlineWindow / 2
    /// Шаг планировщика: за столько новая видимая строка гарантированно получает запрос.
    static let tickInterval: TimeInterval = 5
    /// Пачка покрывает экран строк сразу в «Чатах» и «Контактах»; дальше — не чаще 30 в минуту
    /// (прежний опрос давал до ~200 в минуту и пачки по 114 запросов в секунду).
    static let burst = 20
    static let refillPerSecond = 0.5
    /// Фон тратит бюджет только сверх этого запаса: новый экран видимых строк получает запросы сразу,
    /// даже если фону всегда есть кого спросить.
    static let backgroundReserve = 10
    static let maxConcurrent = 6
    static let forbiddenTTL: TimeInterval = 6 * 60 * 60
    static let requestTimeout: TimeInterval = 15

    private let homeserver: String
    /// STMOB-109: токен берём свежий перед каждым запросом — он ротируется.
    private let tokenProvider: () -> String?
    /// Просьба к SDK обновить токен после 401. Ответа не ждём: запросы возобновятся,
    /// когда `tokenProvider` вернёт другой токен.
    private let tokenRefresher: () async -> Void
    private let ownUserID: String
    private let transport: PresenceTransport
    private let forbiddenStore: PresenceForbiddenStore
    private let now: () -> Date

    private var interests: [PresenceInterest: Set<String>] = [:]
    private var lastFetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var forbiddenUntil: [String: Date]
    private var backoff = PresenceRateLimitBackoff()
    /// Токен, на который пришёл 401: с ним больше не ходим.
    private var rejectedToken: String?
    private var budget: Double
    private var budgetUpdatedAt: Date
    private var pollingTask: Task<Void, Never>?
    /// Внеочередной шаг (новая строка на экране). Хранится, чтобы stop() гасил и его.
    private var soonTask: Task<Void, Never>?
    private var isPollInProgress = false
    /// Когда последний раз проверяли затухание точек «в сети».
    private var decayCheckedAt: Date

    let presenceSubject = CurrentValueSubject<[String: UserPresence], Never>([:])

    /// Кого сейчас опрашиваем: объединение интересов всех экранов.
    var polledUserIDs: Set<String> {
        interests.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    var isPolling: Bool {
        pollingTask != nil
    }

    init(homeserver: String,
         tokenProvider: @escaping () -> String?,
         tokenRefresher: @escaping () async -> Void = { },
         ownUserID: String,
         transport: PresenceTransport = URLSessionPresenceTransport(),
         forbiddenStore: PresenceForbiddenStore? = nil,
         now: @escaping () -> Date = Date.init) {
        // Remove trailing slash to avoid double-slash in URLs
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.tokenProvider = tokenProvider
        self.tokenRefresher = tokenRefresher
        self.ownUserID = ownUserID
        self.transport = transport
        self.forbiddenStore = forbiddenStore ?? UserDefaultsPresenceForbiddenStore(ownUserID: ownUserID)
        self.now = now

        let start = now()
        forbiddenUntil = self.forbiddenStore.load().filter { $0.value > start }
        budget = Double(Self.burst)
        budgetUpdatedAt = start
        decayCheckedAt = start
        os_log(.info, log: presenceLog, "PresenceService init: forbidden cached=%d", forbiddenUntil.count)
    }

    deinit {
        pollingTask?.cancel()
        soonTask?.cancel()
    }

    // MARK: - Interest

    func setInterest(_ userIDs: some Sequence<String>, for key: PresenceInterest) {
        let userIDs = Set(userIDs).subtracting([ownUserID])
        let hasNewUsers = !userIDs.subtracting(polledUserIDs).isEmpty
        interests[key] = userIDs.isEmpty ? nil : userIDs

        // Новая строка на экране не ждёт следующего шага, но бюджет всё равно действует.
        if hasNewUsers {
            pollSoon()
        }
    }

    func removeInterest(for key: PresenceInterest) {
        interests[key] = nil
    }

    /// Набор одного экрана — для проверок.
    func userIDs(for key: PresenceInterest) -> Set<String> {
        interests[key] ?? []
    }

    // MARK: - Polling

    /// Запускает опрос (приложение на переднем плане). Повторный вызов ничего не делает.
    func start() {
        guard pollingTask == nil else { return }

        // Цикл держит сервис слабо: иначе после выхода из аккаунта он жил бы вечно
        // и продолжал ходить в сеть рядом с новым экземпляром.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                guard self != nil else { return }
                try? await Task.sleep(for: .seconds(PresenceService.tickInterval))
            }
        }
    }

    /// Останавливает опрос (уход с переднего плана, выход из аккаунта). Интересы экранов сохраняются.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        soonTask?.cancel()
        soonTask = nil
    }

    private func pollSoon() {
        guard pollingTask != nil, !isPollInProgress, soonTask == nil else { return }
        soonTask = Task { [weak self] in
            await self?.pollOnce()
            self?.soonTask = nil
        }
    }

    /// Один шаг планировщика: выбирает, кого пора спросить, в пределах бюджета.
    func pollOnce() async {
        guard !isPollInProgress else { return }
        isPollInProgress = true
        defer { isPollInProgress = false }

        let now = now()
        publishDecay(now: now)
        guard !backoff.isBlocked(now: now) else { return }
        guard let token = tokenProvider() else { return }
        if let rejectedToken {
            // После 401 ждём, пока SDK обновит токен: со старым каждый запрос — тот же 401.
            guard token != rejectedToken else { return }
            self.rejectedToken = nil
        }

        refillBudget(now: now)
        let due = selectDue(now: now)
        guard !due.isEmpty else { return }

        var outcome = BatchOutcome()
        for chunk in Array(due).chunked(into: Self.maxConcurrent) {
            // Остановленный опрос (фон, выход из аккаунта) не досылает волну.
            guard !outcome.shouldStop, !Task.isCancelled else { break }
            // Пока шла прошлая пачка, строки могли уйти с экрана — на них бюджет не тратим.
            let chunk = chunk.filter { polledUserIDs.contains($0) }
            guard !chunk.isEmpty else { continue }
            budget -= Double(chunk.count)
            await fetch(chunk, token: token, outcome: &outcome)
        }

        if outcome.networkErrors > 0 || outcome.sawUnauthorized || outcome.sawRateLimit {
            DiagLog.write("Presence", "poll: asked=\(outcome.asked) ok=\(outcome.accepted) 401=\(outcome.sawUnauthorized) 429=\(outcome.sawRateLimit) networkErrors=\(outcome.networkErrors)")
        }
    }

    // MARK: - Private

    private struct BatchOutcome {
        var asked = 0
        var accepted = 0
        var networkErrors = 0
        var sawUnauthorized = false
        var sawRateLimit = false

        var shouldStop: Bool {
            sawUnauthorized || sawRateLimit
        }
    }

    private func refillBudget(now: Date) {
        let elapsed = max(0, now.timeIntervalSince(budgetUpdatedAt))
        budget = min(Double(Self.burst), budget + elapsed * Self.refillPerSecond)
        budgetUpdatedAt = now
    }

    /// Кого пора спросить: видимые раньше фона; внутри — ещё ни разу не спрошенные первыми,
    /// дальше самые несвежие.
    private func dueUserIDs(now: Date) -> [String] {
        let foreground = userIDs(where: { $0.isForeground })
        let roomBacked = userIDs(where: { $0.isRoomBacked })
        return polledUserIDs
            .filter { userID in
                if inFlight.contains(userID) { return false }
                if !roomBacked.contains(userID), let until = forbiddenUntil[userID], until > now { return false }
                guard let fetchedAt = lastFetchedAt[userID] else { return true }
                return now.timeIntervalSince(fetchedAt) >= refreshInterval(for: userID, isForeground: foreground.contains(userID), now: now)
            }
            .sorted { lhs, rhs in
                let lhsForeground = foreground.contains(lhs)
                let rhsForeground = foreground.contains(rhs)
                if lhsForeground != rhsForeground { return lhsForeground }
                let lhsDate = lastFetchedAt[lhs] ?? .distantPast
                let rhsDate = lastFetchedAt[rhs] ?? .distantPast
                return lhsDate == rhsDate ? lhs < rhs : lhsDate < rhsDate
            }
    }

    /// Сколько кого спросить в этот шаг: видимые — в пределах всего бюджета, фон — сверх запаса.
    private func selectDue(now: Date) -> [String] {
        let foreground = userIDs(where: { $0.isForeground })
        let due = dueUserIDs(now: now)
        let available = Int(budget)
        let foregroundDue = due.prefix { foreground.contains($0) }.prefix(available)
        let backgroundAllowance = max(0, available - foregroundDue.count - Self.backgroundReserve)
        return Array(foregroundDue) + due.drop { foreground.contains($0) }.prefix(backgroundAllowance)
    }

    private func userIDs(where predicate: (PresenceInterest) -> Bool) -> Set<String> {
        interests.filter { predicate($0.key) }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    private func refreshInterval(for userID: String, isForeground: Bool, now: Date) -> TimeInterval {
        guard isForeground else { return Self.offlineRefreshInterval }
        return presenceSubject.value[userID]?.isOnline(at: now) == true ? Self.onlineRefreshInterval : Self.offlineRefreshInterval
    }

    /// Точка «в сети» гаснет по времени, но экран перерисуется, только если карта пришла заново.
    /// Пока опрос стоит (пауза после 429, ждём токен, все ответы 403), новых ответов нет — поэтому
    /// переотправляем карту, как только чья-то точка должна погаснуть.
    private func publishDecay(now: Date) {
        let presence = presenceSubject.value
        let hasFaded = presence.values.contains { $0.isOnline(at: decayCheckedAt) && !$0.isOnline(at: now) }
        decayCheckedAt = now
        if hasFaded {
            presenceSubject.send(presence)
        }
    }

    private func fetch(_ userIDs: [String], token: String, outcome: inout BatchOutcome) async {
        inFlight.formUnion(userIDs)
        defer { inFlight.subtract(userIDs) }

        let requests = userIDs.compactMap { userID -> (String, URLRequest)? in
            guard let url = PresenceRequest.url(homeserver: homeserver, userID: userID) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return (userID, request)
        }

        let transport = transport
        let responses = await withTaskGroup(of: (String, PresenceHTTPResponse?).self) { group in
            for (userID, request) in requests {
                group.addTask {
                    let response = try? await transport.send(request)
                    return (userID, response)
                }
            }
            var responses: [(String, PresenceHTTPResponse?)] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        // Карту читаем В МОМЕНТ применения, а не снимком до запросов: иначе ответы,
        // пришедшие в другом шаге, перетирались бы.
        var presence = presenceSubject.value
        let answeredAt = now()
        var forbiddenChanged = false
        var rateLimitResponse: PresenceHTTPResponse?
        var acceptedCount = 0
        let roomBackedUserIDs = self.userIDs(where: { $0.isRoomBacked })
        outcome.asked += responses.count

        for (userID, response) in responses {
            guard let response else {
                // Сеть или отмена: человека не помечаем спрошенным — спросим на следующем шаге.
                outcome.networkErrors += 1
                continue
            }
            os_log(.info, log: presenceLog, "presence(%{public}@) → %d", userID, response.statusCode)

            switch response.statusCode {
            case 200:
                acceptedCount += 1
                lastFetchedAt[userID] = answeredAt
                if let parsed = Self.parse(response.body, answeredAt: answeredAt) {
                    presence[userID] = parsed
                }
            case 401:
                // Не повторяем сразу: SDK обновит токен по 401 синка, а проба forceTokenRefresh
                // на Synapse ничего не обновляет (/profile не проверяет токен). Повтор со старым
                // токеном только удваивал пачку.
                if !outcome.sawUnauthorized {
                    rejectedToken = token
                    Task { [tokenRefresher] in await tokenRefresher() }
                }
                outcome.sawUnauthorized = true
            case 403:
                lastFetchedAt[userID] = answeredAt
                // С собеседником по комнате общая комната есть или вот-вот будет (приглашение не
                // принято) — ему хватит обычного срока свежести, на часы не запоминаем.
                if !roomBackedUserIDs.contains(userID) {
                    forbiddenUntil[userID] = answeredAt.addingTimeInterval(Self.forbiddenTTL)
                    forbiddenChanged = true
                }
            case 429:
                rateLimitResponse = rateLimitResponse ?? response
            default:
                // 404, 5xx: ответ получен — ждём обычный срок, а не долбим каждый шаг.
                lastFetchedAt[userID] = answeredAt
            }
        }

        // Отказ по частоте в пачке важнее соседних успехов: иначе ответ 200, пришедший после 429,
        // снимал бы паузу, и следующая пачка снова упиралась бы в лимит.
        outcome.accepted += acceptedCount
        if let rateLimitResponse {
            outcome.sawRateLimit = true
            backoff.recordRateLimited(retryAfter: PresenceRequest.retryAfter(from: rateLimitResponse), now: answeredAt)
        } else if acceptedCount > 0 {
            backoff.recordAccepted()
        }

        if forbiddenChanged {
            forbiddenStore.save(forbiddenUntil.filter { $0.value > answeredAt })
        }
        if presence != presenceSubject.value {
            presenceSubject.send(presence)
        }
    }

    static func parse(_ body: Data, answeredAt: Date) -> UserPresence? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        let presence = json["presence"] as? String ?? "offline"
        let currentlyActive = json["currently_active"] as? Bool ?? false
        let lastActiveAgoMs = json["last_active_ago"] as? Double
        let lastSeenDate = lastActiveAgoMs.map { answeredAt.addingTimeInterval(-$0 / 1000) }
        // STMOB-133: в сети — ТОЛЬКО если последняя активность моложе пяти минут. Synapse
        // иногда отдаёт currently_active для давно ушедших; шапка и «Контакты» должны совпадать.
        let recentlyActive = (lastActiveAgoMs ?? .greatestFiniteMagnitude) / 1000 < onlineWindow
        let serverOnline = (presence == "online" || currentlyActive) && recentlyActive
        return UserPresence(serverOnline: serverOnline, lastSeenDate: lastSeenDate)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
