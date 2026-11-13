//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

class MeetingEditViewModel: MeetingEditViewModelType {
    private let service: MeetingsService
    private let initialVenueID: Int?
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

    init(meeting: Meeting? = nil, service: MeetingsService, userDiscoveryService: UserDiscoveryServiceProtocol? = nil, mediaProvider: MediaProviderProtocol? = nil) {
        self.service = service
        initialVenueID = meeting?.room?.id
        self.userDiscoveryService = userDiscoveryService
        var bindings: MeetingEditViewStateBindings
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
        bindings.venueID = meeting?.room?.id
        bindings.venueName = meeting?.room?.displayName ?? ""
        bindings.venueWanted = meeting?.room != nil
        bindings.venueOfficeID = meeting?.room?.office_id
        let initialState = MeetingEditViewState(meetingId: meeting?.id, bindings: bindings)
        super.init(initialViewState: initialState, mediaProvider: mediaProvider)

        if let meeting {
            Task { [weak self] in await self?.loadReminder(meetingID: meeting.id) }
        } else {
            state.reminderAvailable = true
        }

        searchQuerySubject
            .debounceTextQueriesAndRemoveDuplicates()
            .sink { [weak self] query in
                self?.searchParticipants(query)
            }
            .store(in: &cancellables)
    }

    override func process(viewAction: MeetingEditViewAction) {
        switch viewAction {
        case .loadVenues:
            Task { await loadVenues() }
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

    private func loadReminder(meetingID: Int) async {
        // Не прочитали или встреча на весь день — блок не показываем и настройку не трогаем.
        guard let choice = try? await service.fetchReminder(meetingID: meetingID) else { return }
        state.initialReminder = choice
        state.bindings.reminder = choice
        state.reminderAvailable = true
    }

    private var venueRevision = 0
    private func loadVenues() async {
        venueRevision += 1
        let revision = venueRevision
        let binding = state.bindings
        state.venuesLoading = true; state.venueError = nil
        defer { if revision == venueRevision { state.venuesLoading = false } }
        do {
            let offices = try await service.venueOffices()
            guard revision == venueRevision else { return }
            state.venueOffices = offices; state.venuesAvailable = !offices.isEmpty; state.venuesDisabled = false
            guard binding.venueWanted, !binding.isIndefinite, binding.endDate > binding.startDate else { return }
            let query = binding.venueQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            var rooms = try await service.venueRooms(start: binding.startDate, end: binding.endDate,
                                                     officeID: binding.venueRecent || !query.isEmpty ? nil : binding.venueOfficeID,
                                                     query: query, recent: query.isEmpty && binding.venueRecent)
            if rooms.isEmpty, query.isEmpty, binding.venueRecent, let office = binding.venueOfficeID ?? offices.first?.id {
                rooms = try await service.venueRooms(start: binding.startDate, end: binding.endDate, officeID: office, query: "", recent: false)
            }
            guard revision == venueRevision else { return }
            state.venueRooms = rooms.sorted { lhs, rhs in
                let l = !lhs.can_book ? 2 : (lhs.conflicts(excluding: state.meetingId).isEmpty ? 0 : 1)
                let r = !rhs.can_book ? 2 : (rhs.conflicts(excluding: state.meetingId).isEmpty ? 0 : 1)
                return l == r ? lhs.name < rhs.name : l < r
            }
        } catch {
            guard revision == venueRevision else { return }
            if let venue = error as? MeetingVenueError, venue.code == "rooms_disabled" { state.venuesAvailable = false; state.venuesDisabled = true }
            else { state.venueError = error.localizedDescription }
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

            if !state.venuesDisabled && state.bindings.venueWanted && (state.bindings.isIndefinite || state.bindings.venueID == nil) {
                state.errorMessage = MeetingVenueStrings.text(state.bindings.isIndefinite ? "needs_end" : "choose")
                state.isLoading = false; return
            }
            let meetingCode: String? = nil // Only the server issues a usable link after saving.

            var request = MeetingRequest(title: state.bindings.title,
                                         description: state.bindings.description,
                                         startTime: state.bindings.startDate,
                                         endTime: endDate,
                                         isIndefinite: state.bindings.isIndefinite,
                                         location: state.bindings.location,
                                         participants: state.bindings.participants.map(\.userID),
                                         accessLevel: state.bindings.allowGuests ? "public" : "private",
                                         meetingCode: meetingCode)

            let selectedVenueID = state.bindings.venueWanted ? state.bindings.venueID : nil
            // Only an intentional change modifies the booking. Omission preserves
            // the current room when editing dates or unrelated meeting fields.
            if !state.venuesDisabled, selectedVenueID != initialVenueID {
                request.roomID = selectedVenueID
                request.updatesRoom = true
            }
            do {
                let meeting: Meeting
                if let id = state.meetingId {
                    meeting = try await service.updateMeeting(id: id, request)
                    MXLog.info("sTalk: Updated meeting \(id)")
                } else {
                    meeting = try await service.createMeeting(request)
                    MXLog.info("sTalk: Created meeting \(meeting.id)")
                }
                // Напоминание — отдельный запрос после сохранения встречи, как на вебе.
                if state.reminderAvailable, state.bindings.reminder != state.initialReminder {
                    do {
                        try await service.saveReminder(state.bindings.reminder, meetingID: meeting.id)
                        state.initialReminder = state.bindings.reminder
                    } catch {
                        MXLog.error("sTalk: Save meeting reminder failed: \(error)")
                        // Встреча уже создана: повторное сохранение должно её изменить, а не создать вторую.
                        state.meetingId = meeting.id
                        state.errorMessage = SL10n.meetingReminderSaveFailed
                        state.isLoading = false
                        return
                    }
                }
                actionsSubject.send(.saved(meeting))
            } catch {
                MXLog.error("sTalk: Save meeting failed: \(error)")
                state.errorMessage = (error as? MeetingVenueError)?.localizedDescription ?? SL10n.meetingSaveError
                if (error as? MeetingVenueError)?.code == "rooms_disabled" { state.venuesAvailable = false; state.venuesDisabled = true }
            }
            state.isLoading = false
        }
    }
}
