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
    private let clientProxy: ClientProxyProtocol?
    private let actionsSubject: PassthroughSubject<MeetingsScreenViewModelAction, Never> = .init()

    /// In-memory cache for resolved participant profiles (persists across refreshes, shared with detail VM)
    static var profileCache: [String: ResolvedParticipant] = [:]

    var actionsPublisher: AnyPublisher<MeetingsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: MeetingsService, clientProxy: ClientProxyProtocol? = nil, mediaProvider: MediaProviderProtocol? = nil) {
        self.service = service
        self.clientProxy = clientProxy
        var initialState = MeetingsScreenViewState()
        initialState.mediaProvider = mediaProvider
        super.init(initialViewState: initialState)
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

                let filtered = meetings
                    .filter { $0.status != .cancelled }
                    .sorted { $0.startTime < $1.startTime }
                state.meetings = filtered
                state.holidays = holidays

                // Resolve profiles BEFORE showing UI (so avatars appear instantly)
                await resolveParticipantProfilesSync(filtered)

                state.isLoading = false
                os_log(.default, log: meetingsVMLog, "fetchAll: done, showing %d meetings with profiles", state.meetings.count)
            } catch {
                os_log(.error, log: meetingsVMLog, "fetchAll: FAILED: %{public}@", error.localizedDescription)
                MXLog.error("sTalk: Failed to fetch meetings: \(error)")
                state.isLoading = false
                state.errorMessage = SL10n.meetingLoadError
            }
        }
    }

    /// Resolve profiles synchronously (called from fetchAll before isLoading=false)
    private func resolveParticipantProfilesSync(_ meetings: [Meeting]) async {
        guard let clientProxy else { return }
        let allUserIDs = Set(meetings.flatMap { $0.participants.map(\.userId) })

        // 1. Apply cached profiles
        var profiles = Self.profileCache.filter { allUserIDs.contains($0.key) }

        // 2. Resolve missing from room members (local SDK data)
        let missingIDs = allUserIDs.filter { profiles[$0] == nil }
        if !missingIDs.isEmpty {
            let meetingsWithRooms = meetings.filter { $0.matrixRoomId != nil }
            for meeting in meetingsWithRooms {
                guard let roomId = meeting.matrixRoomId else { continue }
                guard let roomProxyType = await clientProxy.roomForIdentifier(roomId),
                      case .joined(let roomProxy) = roomProxyType else { continue }

                if let members = await roomProxy.members() {
                    for member in members where missingIDs.contains(member.userID) && profiles[member.userID] == nil {
                        let resolved = ResolvedParticipant(displayName: member.displayName ?? member.userID,
                                                           avatarURL: member.avatarURL)
                        profiles[member.userID] = resolved
                        Self.profileCache[member.userID] = resolved
                    }
                }
            }
        }

        // 3. Fallback: fetch still-missing profiles via API
        let stillMissing = allUserIDs.filter { profiles[$0] == nil }
        for userId in stillMissing {
            let result = await clientProxy.profile(for: userId)
            if case .success(let profile) = result {
                let resolved = ResolvedParticipant(displayName: profile.displayName ?? userId,
                                                   avatarURL: profile.avatarURL)
                profiles[userId] = resolved
                Self.profileCache[userId] = resolved
            }
        }

        await MainActor.run { [profiles] in
            self.state.participantProfiles = profiles
        }
    }
}
