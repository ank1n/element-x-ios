//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftState
import UIKit

enum WidgetsTabFlowCoordinatorAction {
    case showSettings
    case startCall(roomID: String)
    case hideTabBar(Bool)
    /// STMOB-275: «найти в чате» из «Диска» — открыть сообщение, которым файл
    /// прислали. Вкладка сама этого не умеет: комната живёт во вкладке чатов.
    case openEvent(roomID: String, eventID: String)
    /// STMOB-275: переслать файл из «Диска» в другой чат.
    case forwardEvent(roomID: String, eventID: String)
    /// STMOB-275: переслать содержимым — файл без Matrix-события уходит
    /// вложением через пикер комнат (маршрут Share Extension).
    case forwardFile(url: URL, name: String)
}

class WidgetsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private let availability: ApplicationAvailabilityService
    private var currentAppID: String?
    private var availabilityTask: Task<Void, Never>?
    private var flowParameters: CommonFlowParameters
    private let navigationStackCoordinator: NavigationStackCoordinator

    private var widgetsListCoordinator: WidgetsListScreenCoordinator?

    enum State: StateType {
        case initial
        case widgetsListScreen
    }

    enum Event: EventType {
        case start
    }

    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []

    private let actionsSubject: PassthroughSubject<WidgetsTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<WidgetsTabFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(navigationStackCoordinator: NavigationStackCoordinator, flowParameters: CommonFlowParameters) {
        userSession = flowParameters.userSession
        availability = ApplicationAvailabilityService(client: flowParameters.userSession.clientProxy)
        self.navigationStackCoordinator = navigationStackCoordinator
        self.flowParameters = flowParameters

        stateMachine = .init(state: .initial)
        configureStateMachine()
    }

    func start(animated: Bool) {
        stateMachine.tryEvent(.start)
    }

    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        clearRoute(animated: animated)
        if case .diskDocument(let link) = appRoute {
            Task { await openDiskDocument(link) }
        } else if case .systemSearchTarget(let target, let title) = appRoute {
            Task { await openSearchTarget(target, title: title) }
        }
    }

    private func openSearchTarget(_ target: SystemSearchTarget, title: String?) async {
        do {
            switch target.kind {
            case "file":
                guard let id = target.file_id, UUID(uuidString: id) != nil else { throw SystemSearchError.targetUnavailable }
                var fragment = URLComponents(); fragment.path = "/files/open"
                fragment.queryItems = [.init(name: "blob", value: id), .init(name: "disk", value: "1"), .init(name: "name", value: title ?? "")]
                var url = URLComponents(string: sessionBaseURL)!; url.fragment = fragment.string
                guard let link = url.url.flatMap(StalkDiskLink.init(url:)) else { throw SystemSearchError.targetUnavailable }
                await openDiskDocument(link)
            case "meeting":
                await availability.refresh(force: true)
                guard availability.allows("meetings-calendar"), let raw = target.meeting_id, let id = Int(raw) else { throw SystemSearchError.targetUnavailable }
                let client = userSession.clientProxy
                let parameters = MeetingsScreenCoordinatorParameters(apiURL: sessionBaseURL, accessTokenProvider: { try client.matrixAccessToken() },
                                                                     forceTokenRefresh: { await client.forceTokenRefresh() }, currentUserId: client.userID,
                                                                     clientProxy: client, mediaProvider: userSession.mediaProvider, initialMeetingID: id)
                let coordinator = MeetingsScreenCoordinator(parameters: parameters, navigationStackCoordinator: navigationStackCoordinator)
                coordinator.actionsPublisher.sink { [weak self] action in
                    if case .startCall(let room) = action { self?.actionsSubject.send(.startCall(roomID: room)) }
                }.store(in: &cancellables)
                currentAppID = "meetings-calendar"
                navigationStackCoordinator.push(coordinator)
            case "issue", "page":
                await availability.refresh(force: true)
                guard availability.allowsExternal("trackit") else { throw SystemSearchError.targetUnavailable }
                let url = try await SystemSearchService(client: userSession.clientProxy).externalURL(for: target)
                await UIApplication.shared.open(url)
            default: throw SystemSearchError.targetUnavailable
            }
        } catch {
            flowParameters.userIndicatorController.submitIndicator(.init(title: error.localizedDescription))
        }
    }

    private func openDiskDocument(_ link: StalkDiskLink) async {
        await availability.refresh(force: true)
        guard availability.allows(WidgetItem.filesAppID) else {
            flowParameters.userIndicatorController.submitIndicator(.init(title: String(localized: "stalk_application_disabled", defaultValue: "Приложение отключено или его доступность временно не удалось проверить.")))
            return
        }
        currentAppID = WidgetItem.filesAppID
        guard link.host == URL(string: sessionBaseURL)?.host?.lowercased() else { return }
        let client = userSession.clientProxy
        let service = DiskService(baseURL: sessionBaseURL, accessTokenProvider: { try client.matrixAccessToken() },
                                  forceTokenRefresh: { await client.forceTokenRefresh() })
        navigationStackCoordinator.push(DiskDocumentLinkCoordinator(link: link, service: service))
    }

    func clearRoute(animated: Bool) {
        // Clear any presented screens
    }

    func stop() {
        widgetsListCoordinator?.stop()
        availabilityTask?.cancel()
    }

    func setActive(_ active: Bool) {
        availabilityTask?.cancel()
        guard active else { return }
        availabilityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UIApplication.shared.applicationState == .active {
                    await availability.refresh(force: true)
                    if let id = currentAppID, !availability.allows(id) {
                        navigationStackCoordinator.popToRoot(animated: true)
                        currentAppID = nil
                    }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Private

    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .widgetsListScreen]) { [weak self] _ in
            self?.showWidgetsListScreen()
        }
    }

    private func showWidgetsListScreen() {
        let parameters = WidgetsListScreenCoordinatorParameters(userSession: userSession, availability: availability)
        let coordinator = WidgetsListScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .showSettings:
                self.actionsSubject.send(.showSettings)
            case .openWidget(let widget):
                self.presentWidget(widget)
            }
        }
        .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)
        widgetsListCoordinator = coordinator
    }

    private func presentWidget(_ widget: WidgetItem) {
        Task {
            await availability.refresh(force: true)
            guard availability.allows(widget.id) else { return }
            currentAppID = widget.id
            launchWidget(widget)
        }
    }

    private func launchWidget(_ widget: WidgetItem) {
        // Builtin apps get native screens
        if widget.isBuiltin {
            presentBuiltinApp(widget)
            return
        }

        let parameters = WidgetWebViewScreenCoordinatorParameters(widget: widget)
        let coordinator = WidgetWebViewScreenCoordinator(parameters: parameters)

        navigationStackCoordinator.push(coordinator)
    }

    /// База для наших серверных сервисов — всегда домен текущей сессии (STMOB-246).
    /// Хардкод .ru ломает вход на других доменах семейства sTalk.
    private var sessionBaseURL: String {
        let homeserver = userSession.clientProxy.homeserver
        let normalized = homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"
        if let url = URL(string: normalized), let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)"
        }
        return normalized
    }

    private func presentBuiltinApp(_ widget: WidgetItem) {
        switch widget.id {
        case WidgetItem.ailockAppID:
            // STMOB-274: чат с агентом Айлок. apiURL из apps-api намеренно не используем —
            // путь door-2 фиксирован во всём семействе sTalk, а база берётся от homeserver.
            let clientProxy = userSession.clientProxy
            let concreteProxy = clientProxy as? ClientProxy
            let parameters = AilockScreenCoordinatorParameters(homeserver: sessionBaseURL,
                                                               accessTokenProvider: { try clientProxy.matrixAccessToken() },
                                                               forceTokenRefresh: { await concreteProxy?.forceTokenRefresh() },
                                                               agentID: WidgetItem.ailockAgentID,
                                                               sessionKey: "\(clientProxy.userID)@\(clientProxy.homeserver)")
            let coordinator = AilockScreenCoordinator(parameters: parameters,
                                                      navigationStackCoordinator: navigationStackCoordinator)
            coordinator.actionsPublisher
                .sink { [weak self] action in
                    switch action {
                    case .hideTabBar(let hidden):
                        self?.actionsSubject.send(.hideTabBar(hidden))
                    }
                }
                .store(in: &cancellables)

            // Чат живёт с клавиатурой — оверлейный таб-бар перекрыл бы композер.
            actionsSubject.send(.hideTabBar(true))
            navigationStackCoordinator.push(coordinator, dismissalCallback: { [weak self] in
                coordinator.stop()
                self?.actionsSubject.send(.hideTabBar(false))
            })

        case WidgetItem.filesAppID:
            // STMOB-275: «Диск». База — домен сессии, путь /api/files одинаков во всём
            // семействе sTalk (тот же принцип, что для встреч, STMOB-246).
            // Авторизация — Matrix-токен: проверено живым запросом, без заголовка
            // сервис отвечает 401 «Authorization required».
            let filesProxy = userSession.clientProxy
            let filesConcrete = filesProxy as? ClientProxy
            let diskCoordinator = DiskScreenCoordinator(parameters: .init(baseURL: sessionBaseURL,
                                                                          accessTokenProvider: { try filesProxy.matrixAccessToken() },
                                                                          forceTokenRefresh: { await filesConcrete?.forceTokenRefresh() },
                                                                          mediaProvider: userSession.mediaProvider,
                                                                          profileResolver: { userID in
                                                                              try? await filesProxy.profile(for: userID).get()
                                                                          },
                                                                          roomNameResolver: { roomID in
                                                                              // Имя группы, где запощен файл. Только joined:
                                                                              // остальные состояния для Диска не встречаются.
                                                                              if case .joined(let room) = await filesProxy.roomForIdentifier(roomID) {
                                                                                  return room.infoPublisher.value.displayName
                                                                              }
                                                                              return nil
                                                                          }, ongoingCallRoomID: flowParameters.ongoingCallRoomIDPublisher))
            diskCoordinator.actionsPublisher
                .sink { [weak self] action in
                    switch action {
                    case .openRoom(let roomID, let eventID):
                        self?.actionsSubject.send(.openEvent(roomID: roomID, eventID: eventID))
                    case .forward(let roomID, let eventID):
                        self?.actionsSubject.send(.forwardEvent(roomID: roomID, eventID: eventID))
                    case .forwardFile(let url, let name):
                        self?.actionsSubject.send(.forwardFile(url: url, name: name))
                    case .hideTabBar(let hide):
                        self?.actionsSubject.send(.hideTabBar(hide))
                    }
                }
                .store(in: &cancellables)

            navigationStackCoordinator.push(diskCoordinator)

        case "meetings-calendar":
            guard let apiURL = widget.apiURL, !apiURL.isEmpty else {
                MXLog.error("sTalk: Missing apiURL for meetings-calendar")
                return
            }
            _ = apiURL // presence of the widget gates availability; the host comes from the session below
            // STMOB-246: meetings-api lives on the session's own homeserver. The widget's apiUrl
            // returned by apps-api can be hardcoded to stalk.implica.ru server-side, so using it
            // made iOS hit .ru with the session's (e.g. .uz) token -> 401 -> -1011. Derive the base
            // from the logged-in homeserver instead so meetings load on any sTalk domain. Path stays
            // identical (/api/meetings) since every sTalk deployment shares the same structure.
            let homeserver = userSession.clientProxy.homeserver
            let normalizedHS = homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"
            let baseURL: String
            if let url = URL(string: normalizedHS), let scheme = url.scheme, let host = url.host {
                baseURL = "\(scheme)://\(host)"
            } else {
                baseURL = normalizedHS
            }
            // Pass a closure so each API call gets a fresh OIDC token
            let clientProxy = userSession.clientProxy
            let concreteProxy = clientProxy as? ClientProxy
            let parameters = MeetingsScreenCoordinatorParameters(apiURL: baseURL,
                                                                 accessTokenProvider: { try clientProxy.matrixAccessToken() },
                                                                 forceTokenRefresh: { await concreteProxy?.forceTokenRefresh() },
                                                                 currentUserId: userSession.clientProxy.userID,
                                                                 clientProxy: clientProxy,
                                                                 mediaProvider: userSession.mediaProvider)
            let coordinator = MeetingsScreenCoordinator(parameters: parameters,
                                                        navigationStackCoordinator: navigationStackCoordinator)
            coordinator.actionsPublisher
                .sink { [weak self] action in
                    switch action {
                    case .startCall(let roomID):
                        DiagLog.write("Meeting", "WidgetsTabFlowCoordinator .startCall room=\(roomID) → UserSessionFlow")
                        self?.actionsSubject.send(.startCall(roomID: roomID))
                    case .hideTabBar(let hide):
                        self?.actionsSubject.send(.hideTabBar(hide))
                    }
                }
                .store(in: &cancellables)
            navigationStackCoordinator.push(coordinator)
        default:
            MXLog.warning("sTalk: Unknown builtin app: \(widget.id)")
        }
    }
}
