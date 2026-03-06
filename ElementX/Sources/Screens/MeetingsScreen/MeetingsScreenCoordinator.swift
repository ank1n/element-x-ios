//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

struct MeetingsScreenCoordinatorParameters {
    let apiURL: String
    let accessToken: String
    let currentUserId: String
    let clientProxy: ClientProxyProtocol
}

final class MeetingsScreenCoordinator: CoordinatorProtocol {
    private let parameters: MeetingsScreenCoordinatorParameters
    private let service: MeetingsService
    private var cancellables: Set<AnyCancellable> = []

    private let listViewModel: MeetingsScreenViewModel
    private var detailViewModel: MeetingDetailViewModel?
    private var editViewModel: MeetingEditViewModel?

    private let navigationStackCoordinator: NavigationStackCoordinator

    init(parameters: MeetingsScreenCoordinatorParameters, navigationStackCoordinator: NavigationStackCoordinator) {
        self.parameters = parameters
        self.navigationStackCoordinator = navigationStackCoordinator
        self.service = MeetingsService(homeserver: parameters.apiURL, accessToken: parameters.accessToken)
        self.listViewModel = MeetingsScreenViewModel(service: service)

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
        let viewModel = MeetingDetailViewModel(
            meeting: meeting,
            currentUserId: parameters.currentUserId,
            homeserverURL: parameters.apiURL,
            service: service
        )
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
                    // TODO: Navigate to call screen
                }
            }
            .store(in: &cancellables)

        navigationStackCoordinator.push(MeetingDetailCoordinatorShim(viewModel: viewModel))
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

        navigationStackCoordinator.push(MeetingEditCoordinatorShim(viewModel: viewModel))
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
