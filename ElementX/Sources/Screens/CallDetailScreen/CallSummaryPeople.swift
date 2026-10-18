// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// These IDs come from recording-api's roster-validated v3 result, never inferred from names.
struct CallSummaryAssignee: Codable, Equatable {
    let matrixID: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case matrixID = "matrix_id"
        case displayName = "display_name"
    }
}

enum CallSummaryPeople {
    static func isUserID(_ id: String) -> Bool {
        id.range(of: "^@[^\\s:]+:[^\\s]+$", options: .regularExpression) != nil
    }

    static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { isUserID($0) && seen.insert($0).inserted }
    }
}

@MainActor
final class CallParticipantPresenter {
    static func present(_ id: String, session: UserSessionProtocol, navigation: NavigationStackCoordinator) {
        guard CallSummaryPeople.isUserID(id) else { return }
        let profile = UserProfileScreenCoordinator(parameters: .init(userID: id, isPresentedModally: true,
                                                                     userSession: session, userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                                     analytics: ServiceLocator.shared.analytics, allowsConversationActions: false))
        let stack = NavigationStackCoordinator()
        // Retain the subscription with the coordinator's presentation, rather than a global token.
        let wrapper = CallParticipantCoordinator(profile: profile, navigation: navigation)
        stack.setRootCoordinator(wrapper)
        navigation.setSheetCoordinator(stack)
    }
}

import Combine
import SwiftUI

@MainActor
private final class CallParticipantCoordinator: CoordinatorProtocol {
    let profile: UserProfileScreenCoordinator
    var token: AnyCancellable?
    init(profile: UserProfileScreenCoordinator, navigation: NavigationStackCoordinator) {
        self.profile = profile
        token = profile.actionsPublisher.sink { [weak navigation] action in
            if case .dismiss = action { navigation?.setSheetCoordinator(nil) }
        }
    }

    func start() {
        profile.start()
    }

    func stop() {
        profile.stop()
    }

    func toPresentable() -> AnyView {
        profile.toPresentable()
    }
}

struct CallParticipantTrack: Decodable {
    let participantIdentity: String
    let participantName: String?
}

struct CallAttendee: Equatable, Identifiable {
    let id: String
    let name: String

    static func from(tracks: [CallParticipantTrack]) -> [Self] {
        var seen = Set<String>()
        return tracks.compactMap { track in
            let raw = track.participantIdentity
            guard !raw.isEmpty, !raw.hasPrefix("EG_") else { return nil }
            let pattern = "^(@[^:\\s]+:(?:\\[[^\\]]+\\]|[^:\\s]+)(?::[0-9]+)?)(?::[^:\\s]+)?$"
            var id = raw
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let range = Range(match.range(at: 1), in: raw) {
                id = String(raw[range])
            }
            guard seen.insert(id).inserted else { return nil }
            return Self(id: id, name: track.participantName.flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
    }
}
