//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import UIKit

class MeetingDetailViewModel: MeetingDetailViewModelType {
    private let service: MeetingsService
    private let actionsSubject: PassthroughSubject<MeetingDetailViewModelAction, Never> = .init()

    var actionsPublisher: AnyPublisher<MeetingDetailViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(meeting: Meeting, currentUserId: String, homeserverURL: String, service: MeetingsService) {
        self.service = service
        var initialState = MeetingDetailViewState(meeting: meeting)
        initialState.currentUserId = currentUserId
        initialState.homeserverURL = homeserverURL
        super.init(initialViewState: initialState)
    }

    override func process(viewAction: MeetingDetailViewAction) {
        switch viewAction {
        case .rsvp(let status):
            performRSVP(status)
        case .joinCall:
            if let roomId = state.meeting.matrixRoomId {
                actionsSubject.send(.joinCall(roomId: roomId))
            }
        case .edit:
            actionsSubject.send(.editMeeting(state.meeting))
        case .delete:
            performDelete()
        case .back:
            actionsSubject.send(.dismiss)
        case .copyLink:
            if let link = state.meetingLink {
                UIPasteboard.general.string = link
                state.linkCopied = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.state.linkCopied = false
                }
            }
        }
    }

    private func performRSVP(_ status: RSVPStatus) {
        Task { [weak self] in
            guard let self else { return }
            state.isLoading = true
            do {
                try await service.rsvp(meetingId: state.meeting.id, status: status)
                let updated = try await service.fetchMeeting(id: state.meeting.id)
                state.meeting = updated
                MXLog.info("sTalk: RSVP \(status) for meeting \(state.meeting.id)")
            } catch {
                MXLog.error("sTalk: RSVP failed: \(error)")
            }
            state.isLoading = false
        }
    }

    private func performDelete() {
        Task { [weak self] in
            guard let self else { return }
            state.isLoading = true
            do {
                try await service.deleteMeeting(id: state.meeting.id)
                MXLog.info("sTalk: Deleted meeting \(state.meeting.id)")
                actionsSubject.send(.deleted)
            } catch {
                MXLog.error("sTalk: Delete meeting failed: \(error)")
            }
            state.isLoading = false
        }
    }
}
