//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias WidgetsListScreenViewModelType = StateStoreViewModel<WidgetsListScreenViewState, WidgetsListScreenViewAction>

protocol WidgetsListScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<WidgetsListScreenViewModelAction, Never> { get }
    var context: WidgetsListScreenViewModelType.Context { get }
}

class WidgetsListScreenViewModel: WidgetsListScreenViewModelType, WidgetsListScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let actionsSubject: PassthroughSubject<WidgetsListScreenViewModelAction, Never> = .init()
    private var widgetsCancellables: Set<AnyCancellable> = []

    var actionsPublisher: AnyPublisher<WidgetsListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol) {
        self.userSession = userSession

        var initialState = WidgetsListScreenViewState()
        initialState.userID = userSession.clientProxy.userID
        initialState.userDisplayName = userSession.clientProxy.userDisplayNamePublisher.value
        initialState.userAvatarURL = userSession.clientProxy.userAvatarURLPublisher.value

        super.init(initialViewState: initialState, mediaProvider: userSession.mediaProvider)

        setupSubscriptions()
        fetchWidgets()
    }

    override func process(viewAction: WidgetsListScreenViewAction) {
        switch viewAction {
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .selectWidget(let widget):
            actionsSubject.send(.openWidget(widget))
        case .refresh:
            fetchWidgets(forceRefresh: true)
        }
    }

    // MARK: - Private

    private func setupSubscriptions() {
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &widgetsCancellables)

        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &widgetsCancellables)

        userSession.sessionSecurityStatePublisher
            .map { $0.verificationState != .verified || $0.recoveryState != .enabled }
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.requiresExtraAccountSetup, on: self)
            .store(in: &widgetsCancellables)
    }

    /// Base URL for apps-api — derived from the session's own homeserver.
    private var serverBaseURL: String {
        // STMOB-246: apps-api lives on the logged-in homeserver, so derive the base from the
        // current session (not a hardcoded recording-api URL). This lets the Apps tab work on
        // any server — stalk.implica.uz or an arbitrary Matrix homeserver — instead of always
        // hitting stalk.implica.ru with the wrong token (-1011). Falls back to the configured
        // recording-api base, then the default, only if the homeserver can't be parsed.
        let homeserver = userSession.clientProxy.homeserver
        let normalized = homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"
        if let url = URL(string: normalized), let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)"
        }
        if let base = ServiceLocator.shared.settings?.recordingAPIBaseURL {
            return base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "https://stalk.implica.ru"
    }

    // MARK: - Apps API

    private static let widgetsCacheKey = "widgets-list"
    private static let widgetsCacheTTL: TimeInterval = 3600 // 1 hour

    private func fetchWidgets(forceRefresh: Bool = false) {
        Task { [weak self] in
            guard let self else { return }

            // 1. Always show cache instantly (for fast UI).
            // STMOB-274: кэш рисуем СРАЗУ, не дожидаясь пробы доступности встроенных
            // приложений — иначе вкладка висела бы пустой всё время сетевого запроса.
            if let cached = await ServiceLocator.shared.cacheService?.load([WidgetItem].self, forKey: Self.widgetsCacheKey) {
                self.state.widgets = cached
                self.state.isLoading = false
                MXLog.info("sTalk: Loaded \(cached.count) widgets from cache")
                self.state.widgets = await self.mergingLocalBuiltins(into: cached)
            }

            // 2. Always fetch from server to check for updates
            do {
                let widgets = try await self.fetchWidgetsFromAPI()
                let merged = await self.mergingLocalBuiltins(into: widgets)

                // Update only if different
                if self.state.widgets != merged {
                    self.state.widgets = merged
                }
                self.state.isLoading = false

                // Save to cache. Локальные записи в кэш НЕ попадают — иначе осядут там на TTL
                // и переживут появление настоящей записи на сервере.
                await ServiceLocator.shared.cacheService?.save(widgets, forKey: Self.widgetsCacheKey, ttl: Self.widgetsCacheTTL)
                MXLog.info("sTalk: Updated \(widgets.count) widgets from server")
            } catch {
                MXLog.error("sTalk: Failed to fetch widgets: \(error)")
                // STMOB-246: graceful degrade. apps-api may be absent on a non-sTalk homeserver
                // (404 / -1011), so never sit on an infinite spinner — drop the loading state and
                // show whatever we have (cache) or the empty state instead of erroring.
                // STMOB-274: встроенные приложения от реестра не зависят — показываем их и здесь.
                self.state.widgets = await self.mergingLocalBuiltins(into: self.state.widgets)
                self.state.isLoading = false
            }
        }
    }

    private func fetchWidgetsFromAPI() async throws -> [WidgetItem] {
        let baseURL = serverBaseURL
        // STMOB-243 / STALK-459: unified apps registry filters by platform via ?client=.
        // Server falls back to full set when the param is absent, so this is additive and
        // safe for already-shipped builds. Visible effect only once STMOB-220 client-side
        // filter is lifted (Phase 1b) and the server resolves Keycloak roles.
        let urlString = "\(baseURL)/apps-api/apps?client=ios"
        MXLog.info("sTalk: Fetching apps from \(urlString)")

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15.0
        if let accessToken = try? userSession.clientProxy.matrixAccessToken() {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let apiResponse = try JSONDecoder().decode(AppsAPIResponse.self, from: data)

        let userId = userSession.clientProxy.userID
        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId

        return apiResponse.apps
            .filter(\.enabled)
            // STMOB-220: the App Store build shows only native builtin apps (Calendar).
            // Web widgets (Weather / Statistics / Call Performance) are server-driven and
            // can error — Apple rejected build 193 (Guideline 2.1(a)) because the Weather
            // widget showed an error on iPad. Filtering them out client-side makes the
            // Apps tab deterministic for review regardless of apps-api state. Remove this
            // filter to re-enable web widgets once they are reliable on all devices.
            .filter { $0.type == "builtin" }
            .map { app in
                // URL is already absolute from API v3
                var fullURL = app.url
                // Append userId param
                if fullURL.contains("?") {
                    fullURL += "&userId=\(encodedUserId)"
                } else {
                    fullURL += "?userId=\(encodedUserId)"
                }

                // Use SF Symbol name from API, fallback to generic
                let sfSymbol = app.icon.sf ?? "app.fill"

                return WidgetItem(id: app.id,
                                  name: Self.localizedAppText(app.name),
                                  description: Self.localizedAppText(app.description),
                                  icon: sfSymbol,
                                  url: fullURL,
                                  apiURL: app.apiUrl,
                                  type: app.type,
                                  category: WidgetCategory(apiCategory: app.category))
            }
    }

    /// Кэш результата проверки door-2: одна проба на аккаунт+домен, а не на запуск
    /// приложения. Общий статик пережил бы смену сервера в том же запуске и показал бы
    /// Айлок там, где его нет (или спрятал там, где он есть).
    private static var ailockAvailability: [String: Bool] = [:]

    private var availabilityKey: String {
        "\(userSession.clientProxy.userID)@\(serverBaseURL)"
    }

    /// STMOB-274: подмешивает встроенные приложения, которых ещё нет в реестре apps-api.
    ///
    /// Сейчас это только Айлок. Серверная запись с тем же id имеет приоритет — как только
    /// Molly заведёт `ailock` в apps-api, локальная запись перестанет использоваться,
    /// и этот метод можно будет убрать целиком.
    private func mergingLocalBuiltins(into widgets: [WidgetItem]) async -> [WidgetItem] {
        var result = widgets
        let key = availabilityKey

        // STMOB-275: «Диск». Подмешиваем, пока его нет в реестре apps-api. Наличие
        // сервиса проверяем живым запросом — иначе на доменах, где files-api не
        // развёрнут, приложение открывалось бы в пустоту.
        // Кэш по паре «аккаунт+домен», как у Айлока: общий статик пережил бы смену
        // сервера в том же запуске и показал бы Диск там, где его нет.
        if !result.contains(where: { $0.id == WidgetItem.filesAppID }) {
            if Self.filesAvailability[key] == nil {
                let token = try? userSession.clientProxy.matrixAccessToken()
                Self.filesAvailability[key] = await Self.probeFilesAvailability(baseURL: serverBaseURL, accessToken: token)
                MXLog.info("sTalk: files-api available = \(Self.filesAvailability[key] == true)")
            }
            if Self.filesAvailability[key] == true {
                result.append(WidgetItem.files)
            }
        }

        guard !result.contains(where: { $0.id == WidgetItem.ailockAppID }) else { return result }

        if Self.ailockAvailability[key] == nil {
            let token = try? userSession.clientProxy.matrixAccessToken()
            let available = await AilockService.probeAvailability(homeserver: serverBaseURL, accessToken: token)
            // Кэшируем только положительный ответ: отрицательный мог быть разовым сбоем
            // сети, и запомнить его — значит спрятать приложение до перезапуска.
            if available { Self.ailockAvailability[key] = true }
            MXLog.info("sTalk: Ailock door-2 available = \(available)")
            // В тестерскую выгрузку — тоже: без этой строки причину отсутствия плитки
            // на устройстве не установить, MXLog в неё не попадает (урок сборки 307).
            DiagLog.write("Ailock", "probe \(serverBaseURL) -> available=\(available)")
        }

        guard Self.ailockAvailability[key] == true else { return result }
        return result + [WidgetItem.ailock]
    }

    /// Развёрнут ли files-api на этом домене. Один запрос за сессию, результат кэшируется.
    /// 200 или 401 одинаково означают «сервис есть»: 401 — это ответ живого маршрута,
    /// а не его отсутствие. Отсутствие даёт 404.
    private static var filesAvailability: [String: Bool] = [:]

    private static func probeFilesAvailability(baseURL: String, accessToken: String?) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/files/stats") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return status == 200 || status == 401
        } catch {
            return false
        }
    }

    /// STMOB-196: apps-api (`/apps-api/apps`) пока отдаёт name/description только на
    /// русском. Серверная локализация по Accept-Language — STALK-368 (ещё не задеплоена).
    /// До тех пор, когда UI на английском, подменяем известные строки встроенных
    /// приложений клиентским словарём. Незнакомые строки отдаём как есть (graceful).
    private static func localizedAppText(_ text: String) -> String {
        let language = Bundle.overrideLocalizations?.first ?? Bundle.app.preferredLocalizations.first
        guard language?.hasPrefix("en") == true else { return text }
        return appTextRuToEn[text.trimmingCharacters(in: .whitespacesAndNewlines)] ?? text
    }

    private static let appTextRuToEn: [String: String] = [
        // Названия
        "Айлок": "Ailock",
        "Календарь": "Calendar",
        "Статистика": "Statistics",
        "Погода": "Weather",
        // Описания
        "Планирование встреч, RSVP, повторяющиеся события": "Meeting scheduling, RSVP, recurring events",
        "Статистика использования системы": "System usage statistics",
        "Прогноз погоды": "Weather forecast",
        "Мониторинг производительности звонков": "Call performance monitoring",
        // STMOB-274: пока apps-api отдаёт описания только по-русски, серверная запись
        // Айлока в английском интерфейсе иначе осталась бы русской.
        "Чат с ИИ-агентом": "Chat with the AI agent"
    ]

    /// Fallback widgets when API is unreachable.
    /// STMOB-220: return nothing rather than the Statistics web widget — a web
    /// widget shown during an API hiccup could error in App Review (see the 2.1(a)
    /// Weather reject). The Apps tab shows its empty state until apps-api responds.
    private func fallbackWidgets() -> [WidgetItem] {
        []
    }
}
