//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias MeetingsScreenViewModelType = StateStoreViewModel<MeetingsScreenViewState, MeetingsScreenViewAction>

class MeetingsScreenViewModel: MeetingsScreenViewModelType {
    private let service: MeetingsService
    private let actionsSubject: PassthroughSubject<MeetingsScreenViewModelAction, Never> = .init()

    var actionsPublisher: AnyPublisher<MeetingsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: MeetingsService) {
        self.service = service
        super.init(initialViewState: MeetingsScreenViewState())
        fetchAll()
    }

    override func process(viewAction: MeetingsScreenViewAction) {
        switch viewAction {
        case .selectDate(let date):
            state.selectedDate = date
        case .selectMeeting(let meeting):
            actionsSubject.send(.openMeetingDetail(meeting))
        case .createMeeting:
            actionsSubject.send(.openCreateMeeting)
        case .refresh:
            fetchAll()
        case .back:
            actionsSubject.send(.dismiss)
        }
    }

    private func fetchAll() {
        Task { [weak self] in
            guard let self else { return }
            do {
                async let meetingsResult = service.fetchMeetingsList()
                async let holidaysResult = service.fetchHolidays()

                let meetings = try await meetingsResult
                let holidays = try await holidaysResult

                state.meetings = meetings
                    .filter { $0.status != .cancelled }
                    .sorted { $0.startTime < $1.startTime }
                state.holidays = Set(holidays)
                state.isLoading = false
                MXLog.info("sTalk: Loaded \(meetings.count) meetings, \(holidays.count) holidays")
            } catch {
                MXLog.error("sTalk: Failed to fetch meetings: \(error)")
                state.isLoading = false
                state.errorMessage = SL10n.meetingLoadError
            }
        }
    }
}
