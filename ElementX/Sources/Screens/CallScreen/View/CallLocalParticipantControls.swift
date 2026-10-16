// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import LiveKit
import SwiftUI

extension EnvironmentValues {
    @Entry var nativeCallRoomManager: LiveKitRoomManager? = nil
}

struct CallLocalMuteButton: View {
    @ObservedObject var manager: LiveKitRoomManager
    let sid: String
    var body: some View {
        Button { manager.toggleLocalMute(sid: sid) } label: {
            Label(manager.isLocallyMuted(sid: sid) ? NSLocalizedString("Слышать участника", comment: "Local call participant control or status") : NSLocalizedString("Не слышать участника", comment: "Local call participant control or status"),
                  systemImage: manager.isLocallyMuted(sid: sid) ? "speaker.wave.2" : "speaker.slash")
        }
    }
}

struct NativeCallParticipantsPanel: View {
    @ObservedObject var manager: LiveKitRoomManager
    let known: [CallParticipantInfo]
    let invited: Set<String>
    let mediaProvider: MediaProviderProtocol?
    let onInvite: (String) -> Void

    private func contact(_ participant: Participant) -> CallParticipantInfo {
        let identity = participant.identity?.stringValue ?? participant.sid?.stringValue ?? ""
        if let known = CallParticipantSelection.contact(identity: identity, participants: known) { return known }
        return .init(userID: identity, displayName: participant.name, avatarURL: nil)
    }

    private var active: [CallParticipantInfo] {
        var values = manager.displayParticipants.map { contact($0) }
        if let local = manager.localParticipant { values.insert(contact(local), at: 0) }
        var seen = Set<String>()
        return values.filter { seen.insert($0.userID).inserted }
    }

    private var raised: [String] {
        manager.orderedHandSIDs.compactMap { sid in
            if let remote = manager.displayParticipants.first(where: { $0.sid?.stringValue == sid }) { return contact(remote).userID }
            if let local = manager.localParticipant, local.sid?.stringValue == sid { return contact(local).userID }
            return nil
        }
    }

    var body: some View {
        let activeIDs = Set(active.map(\.userID))
        CallParticipantsSheet(participants: active + known.filter { !activeIDs.contains($0.userID) }, activeParticipantIDs: activeIDs,
                              mediaProvider: mediaProvider, raisedHandIDs: raised, invitedIDs: invited, onInvite: onInvite)
    }
}
