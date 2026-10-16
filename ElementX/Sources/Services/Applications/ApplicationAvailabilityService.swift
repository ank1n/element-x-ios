// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import Combine
import CryptoKit
import Foundation

struct ApplicationAvailability: Codable, Equatable {
    struct App: Codable, Equatable {
        let id: String
        let enabled: Bool
        var clients: [String]?
    }

    let schemaVersion: Int
    let managed: Bool
    let revision: String
    let apps: [App]

    func allows(_ id: String) -> Bool {
        if let app = apps.first(where: { $0.id == id }) {
            return app.enabled && (app.clients?.contains("ios") ?? true)
        }
        return !managed
    }

    static let legacy = Self(schemaVersion: 1, managed: false, revision: "legacy", apps: [])
}

@MainActor
final class ApplicationAvailabilityService: ObservableObject {
    @Published private(set) var snapshot: ApplicationAvailability?
    @Published private(set) var failed = false
    private let client: ClientProxyProtocol
    private let session: URLSession
    private let defaults: UserDefaults
    private var lastFetch: Date?
    private var inFlight: Task<Void, Never>?
    private let managedKey: String

    init(client: ClientProxyProtocol, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.session = session
        self.defaults = defaults
        managedKey = "stalk-managed-apps-" + SHA256.hash(data: Data((client.homeserver + "\n" + client.userID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func allows(_ id: String) -> Bool {
        !failed && snapshot?.allows(id) == true
    }

    func allowsExternal(_ id: String) -> Bool {
        guard !failed, let snapshot else { return false }
        return snapshot.apps.first(where: { $0.id == id })?.enabled ?? !snapshot.managed
    }

    func refresh(force: Bool = false) async {
        if let inFlight { await inFlight.value; return }
        if !force, !failed, let lastFetch, Date().timeIntervalSince(lastFetch) < 10 { return }
        // Preserve a single request across app list, launch and deep links.
        let pending = Task<Void, Never> { [weak self] in await self?.fetch() }
        inFlight = pending
        await pending.value
        inFlight = nil
    }

    private func fetch() async {
        let base = client.homeserver.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/apps-api/availability") else { failed = true; return }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404, !defaults.bool(forKey: managedKey) {
                snapshot = .legacy
            } else {
                guard status == 200 else { throw URLError(.badServerResponse) }
                let next = try JSONDecoder().decode(ApplicationAvailability.self, from: data)
                guard next.schemaVersion == 1, !next.revision.isEmpty, next.apps.count <= 120,
                      next.managed || !defaults.bool(forKey: managedKey) else { throw URLError(.cannotParseResponse) }
                if next.managed { defaults.set(true, forKey: managedKey) }
                snapshot = next
            }
            lastFetch = Date()
            failed = false
        } catch { failed = true }
    }
}
