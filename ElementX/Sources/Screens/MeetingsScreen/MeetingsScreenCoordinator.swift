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
}

final class MeetingsScreenCoordinator: CoordinatorProtocol {
    private let parameters: MeetingsScreenCoordinatorParameters
    private let service: MeetingsService
    private var cancellables: Set<AnyCancellable> = []

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
