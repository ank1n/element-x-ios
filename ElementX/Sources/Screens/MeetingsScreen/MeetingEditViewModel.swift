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
    /// STMOB-303: набор в поле участников идёт через гашение дребезга. Раньше каждая буква
    /// сразу уходила поиском по справочнику, прошлые поиски не отменялись, и их поздние
    /// ответы затирали выдачу по уже набранному тексту.
    private let searchQuerySubject = PassthroughSubject<String, Never>()
    private var searchTask: Task<Void, Never>?

    var actionsPublisher: AnyPublisher<MeetingEditViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(meeting: Meeting? = nil, service: MeetingsService, userDiscoveryService: UserDiscoveryServiceProtocol? = nil) {
        self.service = service
        self.userDiscoveryService = userDiscoveryService
        let bindings: MeetingEditViewStateBindings
        if let meeting {
            bindings = MeetingEditViewStateBindings(title: meeting.title,
                                                    description: meeting.description,
                                                    startDate: meeting.startTime,
                                                    endDate: meeting.endTime,
                                                    location: meeting.location,
                                                    isIndefinite: meeting.isIndefinite,
                                                    allowGuests: meeting.accessLevel == "public",
                                                    participants: meeting.participants.map { participant in
                                                        UserProfileProxy(userID: participant.userId, displayName: participant.displayName)
                                                    })
        } else {
            bindings = MeetingEditViewStateBindings()
        }
        let initialState = MeetingEditViewState(meetingId: meeting?.id, bindings: bindings)
        super.init(initialViewState: initialState)

        searchQuerySubject
            .debounceTextQueriesAndRemoveDuplicates()
            .sink { [weak self] query in
                self?.searchParticipants(query)
            }
            .store(in: &cancellables)
    }

    override func process(viewAction: MeetingEditViewAction) {
        switch viewAction {
        case .save:
            save()
        case .cancel:
            actionsSubject.send(.cancelled)
        case .searchParticipants(let query):
            searchQuerySubject.send(query)
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
        searchTask?.cancel()

        guard !query.isEmpty, let userDiscoveryService else {
            state.searchResults = []
            state.isSearching = false
            return
        }
        state.isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            let result = await userDiscoveryService.searchProfiles(with: query)
            // Пока ждали ответа, человек набрал дальше — этот ответ уже не про то, что в поле.
            guard !Task.isCancelled else { return }
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

            // Автокоррекция: если конец <= начала (встреча через полночь), перенести конец на следующий день
            var endDate = state.bindings.endDate
            if endDate <= state.bindings.startDate {
                endDate = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
            }

            // Generate meeting_code for new meetings (needed for shareable links)
            let meetingCode: String? = state.meetingId == nil
                ? String(UUID().uuidString.lowercased().prefix(11))
                : nil

            var request = MeetingRequest(title: state.bindings.title,
                                         description: state.bindings.description,
                                         startTime: state.bindings.startDate,
                                         endTime: endDate,
                                         isIndefinite: state.bindings.isIndefinite,
                                         location: state.bindings.location,
                                         participants: state.bindings.participants.map(\.userID),
                                         accessLevel: state.bindings.allowGuests ? "public" : "private",
                                         meetingCode: meetingCode)

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
                state.errorMessage = SL10n.meetingSaveError
            }
            state.isLoading = false
        }
    }
}
