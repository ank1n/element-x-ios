//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

class MeetingEditViewModel: MeetingEditViewModelType {
    private let service: MeetingsService
    private let userDiscoveryService: UserDiscoveryServiceProtocol?
    private let actionsSubject: PassthroughSubject<MeetingEditViewModelAction, Never> = .init()

    var actionsPublisher: AnyPublisher<MeetingEditViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(meeting: Meeting? = nil, service: MeetingsService, userDiscoveryService: UserDiscoveryServiceProtocol? = nil) {
        self.service = service
        self.userDiscoveryService = userDiscoveryService
        let bindings: MeetingEditViewStateBindings
        if let meeting {
            bindings = MeetingEditViewStateBindings(
                title: meeting.title,
                description: meeting.description,
                startDate: meeting.startTime,
                endDate: meeting.endTime,
                location: meeting.location,
                isIndefinite: meeting.isIndefinite,
                allowGuests: meeting.accessLevel == "public",
                participants: meeting.participants.map { participant in
                    UserProfileProxy(userID: participant.userId, displayName: participant.displayName)
                }
            )
        } else {
            bindings = MeetingEditViewStateBindings()
        }
        let initialState = MeetingEditViewState(meetingId: meeting?.id, bindings: bindings)
        super.init(initialViewState: initialState)
    }

    override func process(viewAction: MeetingEditViewAction) {
        switch viewAction {
        case .save:
            save()
        case .cancel:
            actionsSubject.send(.cancelled)
        case .searchParticipants(let query):
            searchParticipants(query)
        case .addParticipant(let user):
            if !state.bindings.participants.contains(where: { $0.userID == user.userID }) {
                state.bindings.participants.append(user)
            }
            state.searchResults = []
            state.bindings.participantSearchQuery = ""
        case .removeParticipant(let user):
            state.bindings.participants.removeAll(where: { $0.userID == user.userID })
        }
    }

    private func searchParticipants(_ query: String) {
        guard !query.isEmpty, let userDiscoveryService else {
            state.searchResults = []
            state.isSearching = false
            return
        }
        state.isSearching = true
        Task { [weak self] in
            guard let self else { return }
            let result = await userDiscoveryService.searchProfiles(with: query)
            switch result {
            case .success(let profiles):
                // Filter out already added participants
                let existingIds = Set(state.bindings.participants.map(\.userID))
                state.searchResults = profiles.filter { !existingIds.contains($0.userID) }
            case .failure:
                state.searchResults = []
            }
            state.isSearching = false
        }
    }

    private func save() {
        Task { [weak self] in
            guard let self else { return }
            state.isLoading = true
            state.errorMessage = nil

            // Generate meeting_code for new meetings (needed for shareable links)
            let meetingCode: String? = state.meetingId == nil
                ? String(UUID().uuidString.lowercased().prefix(11))
                : nil

            var request = MeetingRequest(
                title: state.bindings.title,
                description: state.bindings.description,
                startTime: state.bindings.startDate,
                endTime: state.bindings.endDate,
                isIndefinite: state.bindings.isIndefinite,
                location: state.bindings.location,
                participants: state.bindings.participants.map(\.userID),
                accessLevel: state.bindings.allowGuests ? "public" : "private",
                meetingCode: meetingCode
            )

            do {
                let meeting: Meeting
                if let id = state.meetingId {
                    meeting = try await service.updateMeeting(id: id, request)
                    MXLog.info("sTalk: Updated meeting \(id)")
                } else {
                    meeting = try await service.createMeeting(request)
                    MXLog.info("sTalk: Created meeting \(meeting.id)")
                }
                actionsSubject.send(.saved(meeting))
            } catch {
                MXLog.error("sTalk: Save meeting failed: \(error)")
                state.errorMessage = "Не удалось сохранить встречу"
            }
            state.isLoading = false
        }
    }
}
