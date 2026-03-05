//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import os.log

private let orgProfileLog = OSLog(subsystem: "ru.implica.stalk", category: "OrgProfile")

struct OrgProfile: Equatable {
    let jobTitle: String?
    let department: String?
}

struct OrgProfileSettings {
    let fieldJobTitleEnabled: Bool
    let fieldDepartmentEnabled: Bool
}

class OrgProfileService {
    private let homeserver: String
    private let accessToken: String

    private var fetchTask: Task<Void, Never>?
    private var settings: OrgProfileSettings?

    let profilesSubject = CurrentValueSubject<[String: OrgProfile], Never>([:])

    init(homeserver: String, accessToken: String) {
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.accessToken = accessToken
        os_log(.info, log: orgProfileLog, "OrgProfileService init: homeserver=%{public}@", self.homeserver)
    }

    // MARK: - Settings

    func fetchSettings() async -> OrgProfileSettings? {
        guard let url = URL(string: "\(homeserver)/api/org-profile/settings") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            os_log(.error, log: orgProfileLog, "fetchSettings: failed")
            return nil
        }

        let s = OrgProfileSettings(
            fieldJobTitleEnabled: json["field_job_title_enabled"] as? Bool ?? false,
            fieldDepartmentEnabled: json["field_department_enabled"] as? Bool ?? false
        )
        settings = s
        os_log(.info, log: orgProfileLog, "fetchSettings: jobTitle=%d, department=%d",
               s.fieldJobTitleEnabled ? 1 : 0, s.fieldDepartmentEnabled ? 1 : 0)
        return s
    }

    // MARK: - Fetch Profiles

    func fetchProfiles(for userIDs: [String]) async {
        // Fetch settings once if needed
        if settings == nil {
            let s = await fetchSettings()
            guard s != nil, (s!.fieldJobTitleEnabled || s!.fieldDepartmentEnabled) else {
                os_log(.info, log: orgProfileLog, "org-profile fields disabled, skipping")
                return
            }
        }

        guard let settings, (settings.fieldJobTitleEnabled || settings.fieldDepartmentEnabled) else { return }

        var results = profilesSubject.value

        await withTaskGroup(of: (String, OrgProfile?).self) { group in
            for userID in userIDs {
                // Skip if already fetched
                if results[userID] != nil { continue }

                group.addTask { [weak self] in
                    guard let self else { return (userID, nil) }
                    return (userID, await self.fetchSingleProfile(userID: userID))
                }
            }

            for await (userID, profile) in group {
                if let profile {
                    results[userID] = profile
                }
            }
        }

        profilesSubject.send(results)
    }

    private func fetchSingleProfile(userID: String) async -> OrgProfile? {
        let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        guard let url = URL(string: "\(homeserver)/api/org-profile/\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            os_log(.info, log: orgProfileLog, "fetchProfile(%{public}@): not found or error", userID)
            return OrgProfile(jobTitle: nil, department: nil)
        }

        let profile = OrgProfile(
            jobTitle: json["job_title"] as? String,
            department: json["department"] as? String
        )
        os_log(.info, log: orgProfileLog, "fetchProfile(%{public}@): title=%{public}@, dept=%{public}@",
               userID, profile.jobTitle ?? "-", profile.department ?? "-")
        return profile
    }
}
