//
// Copyright 2026 Implica Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias ArchiveScreenViewModelType = StateStoreViewModel<ArchiveScreenViewState, ArchiveScreenViewAction>

class ArchiveScreenViewModel: ArchiveScreenViewModelType {
    private let userSession: UserSessionProtocol
    private let roomSummaryProvider: RoomSummaryProviderProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    private var actionsSubject: PassthroughSubject<ArchiveScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<ArchiveScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol,
         mediaProvider: MediaProviderProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.userSession = userSession
        roomSummaryProvider = userSession.clientProxy.alternateRoomSummaryProvider
        self.userIndicatorController = userIndicatorController

        super.init(initialViewState: .init(), mediaProvider: mediaProvider)

        setupSubscriptions()

        // Set filter to show only low-priority (archived) rooms
        roomSummaryProvider.setFilter(.all(filters: [.lowPriority]))
    }

    deinit {
        // Restore the low-priority filter so HomeScreen's archive count subscription continues working
        roomSummaryProvider.setFilter(.all(filters: [.lowPriority]))
    }

    // MARK: - Public

    override func process(viewAction: ArchiveScreenViewAction) {
        switch viewAction {
        case .selectRoom(let roomIdentifier):
            actionsSubject.send(.selectRoom(roomIdentifier: roomIdentifier))
        case .unarchiveRoom(let roomIdentifier):
            Task { await unarchiveRoom(roomIdentifier) }
        case .showRoomDetails(let roomIdentifier):
            actionsSubject.send(.showRoomDetails(roomIdentifier: roomIdentifier))
        case .leaveRoom(let roomIdentifier):
            startLeaveRoomProcess(roomID: roomIdentifier)
        case .confirmLeaveRoom(let roomIdentifier):
            Task { await leaveRoom(roomID: roomIdentifier) }
        }
    }

    // MARK: - Private

    private func setupSubscriptions() {
        roomSummaryProvider.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providerState in
                guard let self else { return }
                state.isLoading = !providerState.isLoaded
            }
            .store(in: &cancellables)

        roomSummaryProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)
    }

    private func updateRooms() {
        state.rooms = roomSummaryProvider.roomListPublisher.value.map { summary in
            HomeScreenRoom(summary: summary, hideUnreadMessagesBadge: false)
        }
    }

    private func unarchiveRoom(_ roomIdentifier: String) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
            MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
            return
        }

        // Remove low-priority flag
        if case .failure(let error) = await roomProxy.flagAsLowPriority(false) {
            MXLog.error("Failed unarchiving room \(roomIdentifier): \(error)")
            return
        }

        // Restore default notification mode (unmute)
        do {
            try await userSession.clientProxy.notificationSettings.restoreDefaultNotificationMode(roomId: roomIdentifier)
        } catch {
            MXLog.error("Failed restoring notification mode for room \(roomIdentifier): \(error)")
        }
    }

    private static let leaveRoomLoadingID = "ArchiveLeaveRoomLoading"

    private func startLeaveRoomProcess(roomID: String) {
        Task {
            defer {
                userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
            }
            userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLoading, persistent: true))

            guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
                state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
                return
            }

            state.bindings.leaveRoomAlertItem = LeaveRoomAlertItem(roomID: roomID,
                                                                   isDM: roomProxy.isDirectOneToOneRoom,
                                                                   state: roomProxy.infoPublisher.value.isPrivate ?? true ? .empty : .public)
        }
    }

    private func leaveRoom(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
        }
        userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLeavingRoom, persistent: true))

        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID),
              case .success = await roomProxy.leaveRoom() else {
            state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
            return
        }

        userIndicatorController.submitIndicator(UserIndicator(id: UUID().uuidString,
                                                              type: .toast,
                                                              title: L10n.commonCurrentUserLeftRoom,
                                                              iconName: "checkmark"))
    }
}
