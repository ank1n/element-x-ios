//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

private let meetingsVMLog = OSLog(subsystem: "ru.implica.stalk", category: "MeetingsVM")

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
        os_log(.default, log: meetingsVMLog, "fetchAll: starting")
        Task { [weak self] in
            guard let self else { return }
            do {
                os_log(.default, log: meetingsVMLog, "fetchAll: fetching meetings...")
                let meetings = try await service.fetchMeetingsList()
                os_log(.default, log: meetingsVMLog, "fetchAll: got %d meetings", meetings.count)

                var holidays: Set<String> = []
                do {
                    let h = try await service.fetchHolidays()
                    holidays = Set(h)
                    os_log(.default, log: meetingsVMLog, "fetchAll: got %d holidays", h.count)
                } catch {
                    os_log(.error, log: meetingsVMLog, "fetchAll: holidays failed (non-fatal): %{public}@", error.localizedDescription)
                }

                state.meetings = meetings
                    .filter { $0.status != .cancelled }
                    .sorted { $0.startTime < $1.startTime }
                state.holidays = holidays
                state.isLoading = false
                os_log(.default, log: meetingsVMLog, "fetchAll: done, showing %d meetings", state.meetings.count)
            } catch {
                os_log(.error, log: meetingsVMLog, "fetchAll: FAILED: %{public}@", error.localizedDescription)
                MXLog.error("sTalk: Failed to fetch meetings: \(error)")
                state.isLoading = false
                state.errorMessage = SL10n.meetingLoadError
            }
        }
    }
}
