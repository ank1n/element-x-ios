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
    private let clientProxy: ClientProxyProtocol?
    private let actionsSubject: PassthroughSubject<MeetingDetailViewModelAction, Never> = .init()

    var actionsPublisher: AnyPublisher<MeetingDetailViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(meeting: Meeting, currentUserId: String, homeserverURL: String, service: MeetingsService,
         clientProxy: ClientProxyProtocol? = nil, mediaProvider: MediaProviderProtocol? = nil) {
        self.service = service
        self.clientProxy = clientProxy
        var initialState = MeetingDetailViewState(meeting: meeting)
        initialState.currentUserId = currentUserId
        initialState.homeserverURL = homeserverURL
        initialState.mediaProvider = mediaProvider
        // Apply cached profiles immediately
        let cached = MeetingsScreenViewModel.profileCache
        let participantIDs = Set(meeting.participants.map(\.userId))
        initialState.participantProfiles = cached.filter { participantIDs.contains($0.key) }
        super.init(initialViewState: initialState)

        // Resolve any missing profiles
        let missingIDs = participantIDs.filter { cached[$0] == nil }
        if !missingIDs.isEmpty {
            resolveProfiles(userIDs: missingIDs)
        }
    }

    private func resolveProfiles(userIDs: Set<String>) {
        guard let clientProxy else { return }
        let roomId = state.meeting.matrixRoomId

        Task { [weak self] in
            guard let self else { return }
            var newProfiles: [String: ResolvedParticipant] = [:]

            // Try room members first (local SDK cache)
            if let roomId,
               let roomProxyType = await clientProxy.roomForIdentifier(roomId),
               case .joined(let roomProxy) = roomProxyType,
               let members = await roomProxy.members() {
                for member in members where userIDs.contains(member.userID) {
                    let resolved = ResolvedParticipant(displayName: member.displayName ?? member.userID,
                                                       avatarURL: member.avatarURL)
                    newProfiles[member.userID] = resolved
                    MeetingsScreenViewModel.profileCache[member.userID] = resolved
                }
            }

            // Fallback for any still missing
            for userId in userIDs where newProfiles[userId] == nil {
                let result = await clientProxy.profile(for: userId)
                if case .success(let profile) = result {
                    let resolved = ResolvedParticipant(displayName: profile.displayName ?? userId,
                                                       avatarURL: profile.avatarURL)
                    newProfiles[userId] = resolved
                    MeetingsScreenViewModel.profileCache[userId] = resolved
                }
            }

            if !newProfiles.isEmpty {
                await MainActor.run { [newProfiles] in
                    self.state.participantProfiles.merge(newProfiles) { _, new in new }
                }
            }
        }
    }

    override func process(viewAction: MeetingDetailViewAction) {
        switch viewAction {
        case .rsvp(let status):
            performRSVP(status)
        case .joinCall:
            joinCall()
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

    private func joinCall() {
        // If we already have a room ID, join directly
        if let roomId = state.meeting.matrixRoomId, !roomId.isEmpty {
            actionsSubject.send(.joinCall(roomId: roomId))
            return
        }

        // Otherwise, ensure room via meeting code
        guard let code = state.meeting.meetingCode, !code.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            state.isLoading = true
            do {
                let roomId = try await service.ensureRoom(code: code, userId: state.currentUserId)
                state.meeting.matrixRoomId = roomId
                actionsSubject.send(.joinCall(roomId: roomId))
            } catch {
                MXLog.error("sTalk: ensureRoom failed: \(error)")
            }
            state.isLoading = false
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
