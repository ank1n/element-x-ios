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

    /// Base URL for apps-api (same server as recording-api)
    private var serverBaseURL: String {
        // Use the same domain as recording-api (from AppSettings)
        let recordingBase = ServiceLocator.shared.settings?.recordingAPIBaseURL
        if let base = recordingBase {
            return base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // Fallback: extract from homeserver
        let homeserver = userSession.clientProxy.homeserver
        if let url = URL(string: homeserver), let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)"
        }
        return "https://stalk.implica.ru"
    }

    // MARK: - Apps API

    private static let widgetsCacheKey = "widgets-list"
    private static let widgetsCacheTTL: TimeInterval = 3600 // 1 hour

    private func fetchWidgets(forceRefresh: Bool = false) {
        Task { [weak self] in
            guard let self else { return }

            // 1. Always show cache instantly (for fast UI)
            if let cached = await ServiceLocator.shared.cacheService?.load([WidgetItem].self, forKey: Self.widgetsCacheKey) {
                self.state.widgets = cached
                self.state.isLoading = false
                MXLog.info("sTalk: Loaded \(cached.count) widgets from cache")
            }

            // 2. Always fetch from server to check for updates
            do {
                let widgets = try await self.fetchWidgetsFromAPI()

                // Update only if different
                if self.state.widgets != widgets {
                    self.state.widgets = widgets
                }
                self.state.isLoading = false

                // Save to cache
                await ServiceLocator.shared.cacheService?.save(widgets, forKey: Self.widgetsCacheKey, ttl: Self.widgetsCacheTTL)
                MXLog.info("sTalk: Updated \(widgets.count) widgets from server")
            } catch {
                MXLog.error("sTalk: Failed to fetch widgets: \(error)")
                // Only show fallback if no cached data either
                if self.state.widgets.isEmpty {
                    self.state.widgets = self.fallbackWidgets()
                }
                self.state.isLoading = false
            }
        }
    }

    private func fetchWidgetsFromAPI() async throws -> [WidgetItem] {
        let baseURL = serverBaseURL
        let urlString = "\(baseURL)/apps-api/widgets"
        MXLog.info("sTalk: Fetching widgets from \(urlString)")

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15.0
        request.setValue("Bearer \(userSession.clientProxy.userID)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let apiResponse = try JSONDecoder().decode(AppsAPIResponse.self, from: data)

        let userId = userSession.clientProxy.userID
        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId

        return apiResponse.widgets
            .filter(\.enabled)
            .map { widget in
                // Build full URL from relative path
                var fullURL = "\(baseURL)\(widget.url)"
                // Append userId param for widgets that need it
                if fullURL.contains("?") {
                    fullURL += "&userId=\(encodedUserId)"
                } else {
                    fullURL += "?userId=\(encodedUserId)"
                }

                // Build icon URL from relative path
                let iconURL: URL? = URL(string: "\(baseURL)\(widget.icon)")

                // Map SF Symbol for known widget types as fallback
                let sfSymbol = sfSymbolForWidget(id: widget.id, type: widget.type)

                return WidgetItem(
                    id: widget.id,
                    name: widget.name,
                    description: widget.description,
                    icon: sfSymbol,
                    iconURL: iconURL,
                    url: fullURL,
                    category: WidgetCategory(apiType: widget.type)
                )
            }
    }

    /// Map known widget IDs to SF Symbols for fallback
    private func sfSymbolForWidget(id: String, type: String) -> String {
        switch id {
        case "weather-bot": return "cloud.sun.fill"
        case "recording-player": return "waveform"
        case "stats-dashboard": return "chart.bar.fill"
        default:
            switch type {
            case "smartapp": return "square.grid.2x2.fill"
            case "widget": return "puzzlepiece.fill"
            default: return "app.fill"
            }
        }
    }

    /// Fallback widgets when API is unreachable
    private func fallbackWidgets() -> [WidgetItem] {
        let baseURL = serverBaseURL
        let userId = userSession.clientProxy.userID
        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
        return [
            WidgetItem(
                id: "statistics",
                name: "Статистика",
                description: "Статистика сервера и активности",
                icon: "chart.bar.fill",
                url: "\(baseURL)/application/stats/?userId=\(encodedUserId)",
                category: .tools
            )
        ]
    }
}
