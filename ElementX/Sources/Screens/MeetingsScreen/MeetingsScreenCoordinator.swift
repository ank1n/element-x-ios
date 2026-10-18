//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

enum MeetingsScreenCoordinatorAction {
    case startCall(roomID: String)
    case hideTabBar(Bool)
}

struct MeetingsScreenCoordinatorParameters {
    let apiURL: String
    let accessTokenProvider: () throws -> String
    let forceTokenRefresh: (() async -> Void)?
    let currentUserId: String
    let clientProxy: ClientProxyProtocol
    var mediaProvider: MediaProviderProtocol?
    var initialMeetingID: Int?
    var userSession: UserSessionProtocol?
}

final class MeetingsScreenCoordinator: CoordinatorProtocol {
    private let parameters: MeetingsScreenCoordinatorParameters
    private let service: MeetingsService
    private var cancellables: Set<AnyCancellable> = []

    private var isActive = true
    private var historyViewModel: CallsListScreenViewModel?
    private var callHistoryService: CallHistoryServiceProtocol?
    private let listViewModel: MeetingsScreenViewModel
    private var detailViewModel: MeetingDetailViewModel?
    private var editViewModel: MeetingEditViewModel?

    private let navigationStackCoordinator: NavigationStackCoordinator

    private let actionsSubject: PassthroughSubject<MeetingsScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<MeetingsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: MeetingsScreenCoordinatorParameters, navigationStackCoordinator: NavigationStackCoordinator) {
        self.parameters = parameters
        self.navigationStackCoordinator = navigationStackCoordinator
        service = MeetingsService(homeserver: parameters.apiURL, accessTokenProvider: parameters.accessTokenProvider, forceTokenRefresh: parameters.forceTokenRefresh)
        listViewModel = MeetingsScreenViewModel(service: service, clientProxy: parameters.clientProxy, mediaProvider: parameters.mediaProvider)

        listViewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .refreshCallHistory:
                    historyViewModel?.process(viewAction: .refresh)
                case .openCallDetail(let call, let tasks):
                    showCall(call, tasks: tasks)
                case .openMeetingDetail(let meeting):
                    showDetail(meeting)
                case .openCreateMeeting:
                    showEdit(meeting: nil)
                case .dismiss:
                    navigationStackCoordinator.pop()
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(MeetingsListScreen(context: listViewModel.context))
    }

    // MARK: - Navigation

    func start() {
        if historyViewModel == nil, let session = parameters.userSession, let url = URL(string: parameters.apiURL) {
            let service = CallHistoryService(baseURL: url.appendingPathComponent("recording-api"), accessTokenProvider: parameters.accessTokenProvider,
                                             forceTokenRefresh: parameters.forceTokenRefresh)
            callHistoryService = service
            let history = CallsListScreenViewModel(userSession: session,
                                                   localCallHistoryService: ServiceLocator.shared.localCallHistoryService,
                                                   callHistoryService: service, isActive: isActive)
            historyViewModel = history
            history.context.$viewState
                .map { CalendarCallHistorySnapshot(calls: $0.callHistory,
                                                   unavailable: $0.recordingsUnavailable,
                                                   loading: $0.isRefreshingHistory) }
                .removeDuplicates()
                .sink { [weak self] snapshot in
                    self?.listViewModel.process(viewAction: .setCalls(snapshot.calls,
                                                                      unavailable: snapshot.unavailable,
                                                                      loading: snapshot.loading))
                }
                .store(in: &cancellables)
        } else { historyViewModel?.setActive(isActive) }

        if let id = parameters.initialMeetingID {
            Task { [weak self] in
                guard let self else { return }
                do { let meeting = try await service.fetchMeeting(id: id); showDetail(meeting) }
                catch { ServiceLocator.shared.userIndicatorController.submitIndicator(.init(title: error.localizedDescription)) }
            }
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        historyViewModel?.setActive(active)
    }

    func stop() {
        historyViewModel?.stop()
    }

    private func showCall(_ call: CallHistoryItem, tasks: Bool) {
        guard let service = callHistoryService else { return }
        let coordinator = CallDetailScreenCoordinator(parameters: .init(call: call, callHistoryService: service,
                                                                        mediaProvider: parameters.mediaProvider,
                                                                        clientProxy: parameters.clientProxy,
                                                                        initialTab: tasks ? .tasks : nil))
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss: navigationStackCoordinator.pop()
            case .openParticipant(let id):
                if let session = parameters.userSession {
                    CallParticipantPresenter.present(id, session: session, navigation: navigationStackCoordinator)
                }
            case .callBack(let room): actionsSubject.send(.startCall(roomID: room))
            }
        }.store(in: &cancellables)
        actionsSubject.send(.hideTabBar(true))
        navigationStackCoordinator.push(coordinator) { [weak self] in self?.actionsSubject.send(.hideTabBar(false)) }
    }

    private func showDetail(_ meeting: Meeting) {
        let viewModel = MeetingDetailViewModel(meeting: meeting,
                                               currentUserId: parameters.currentUserId,
                                               homeserverURL: parameters.apiURL,
                                               service: service,
                                               clientProxy: parameters.clientProxy,
                                               mediaProvider: parameters.mediaProvider)
        detailViewModel = viewModel

        viewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .editMeeting(let meeting):
                    showEdit(meeting: meeting)
                case .deleted:
                    navigationStackCoordinator.pop()
                    // Refresh list
                    listViewModel.process(viewAction: .refresh)
                case .dismiss:
                    navigationStackCoordinator.pop()
                case .joinCall(let roomId):
                    MXLog.info("sTalk: Join call for room \(roomId)")
                    DiagLog.write("Meeting", "MeetingsScreenCoordinator .joinCall → .startCall room=\(roomId)")
                    self.actionsSubject.send(.startCall(roomID: roomId))
                }
            }
            .store(in: &cancellables)

        actionsSubject.send(.hideTabBar(true))
        navigationStackCoordinator.push(MeetingDetailCoordinatorShim(viewModel: viewModel), dismissalCallback: { [weak self] in
            self?.actionsSubject.send(.hideTabBar(false))
        })
    }

    private func showEdit(meeting: Meeting?) {
        let userDiscoveryService = UserDiscoveryService(clientProxy: parameters.clientProxy)
        let viewModel = MeetingEditViewModel(meeting: meeting, service: service, userDiscoveryService: userDiscoveryService)
        editViewModel = viewModel

        viewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .saved:
                    navigationStackCoordinator.pop()
                    listViewModel.process(viewAction: .refresh)
                case .cancelled:
                    navigationStackCoordinator.pop()
                }
            }
            .store(in: &cancellables)

        actionsSubject.send(.hideTabBar(true))
        navigationStackCoordinator.push(MeetingEditCoordinatorShim(viewModel: viewModel), dismissalCallback: { [weak self] in
            self?.actionsSubject.send(.hideTabBar(false))
        })
    }
}

// MARK: - Shim coordinators for NavigationStack

final class MeetingDetailCoordinatorShim: CoordinatorProtocol {
    let viewModel: MeetingDetailViewModel

    init(viewModel: MeetingDetailViewModel) {
        self.viewModel = viewModel
    }

    func toPresentable() -> AnyView {
        AnyView(MeetingDetailScreen(context: viewModel.context))
    }
}

final class MeetingEditCoordinatorShim: CoordinatorProtocol {
    let viewModel: MeetingEditViewModel

    init(viewModel: MeetingEditViewModel) {
        self.viewModel = viewModel
    }

    func toPresentable() -> AnyView {
        AnyView(MeetingEditScreen(context: viewModel.context))
    }
}
