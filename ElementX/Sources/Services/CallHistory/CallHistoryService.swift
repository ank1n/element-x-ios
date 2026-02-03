//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

// MARK: - Protocol

protocol CallHistoryServiceProtocol: AnyObject {
    func fetchRecordings() async throws -> [CallRecordingItem]
    func getRecordingDetails(egressId: String) async throws -> CallRecordingItem
}

// MARK: - Implementation

class CallHistoryService: CallHistoryServiceProtocol {
    private let baseURL: URL
    private let urlSession: URLSession
    private let requestTimeout: TimeInterval = 10.0

    init(baseURL: URL, urlSession: URLSession? = nil) {
        self.baseURL = baseURL

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 10.0
            configuration.timeoutIntervalForResource = 30.0
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    // MARK: - Public Methods

    func fetchRecordings() async throws -> [CallRecordingItem] {
        let response: CallHistoryResponse = try await get(endpoint: "/recording-api/list")

        guard response.success, let recordings = response.recordings else {
            let errorMessage = response.error ?? "Failed to fetch recordings"
            throw CallHistoryError.serverError(errorMessage)
        }

        return recordings.compactMap { $0.toCallRecordingItem() }
            .sorted { $0.startedAt > $1.startedAt } // Most recent first
    }

    func getRecordingDetails(egressId: String) async throws -> CallRecordingItem {
        let response: RecordingStatusResponse = try await get(
            endpoint: "/recording-api/status/\(egressId)"
        )

        guard response.success, let egress = response.egress else {
            let errorMessage = response.error ?? "Failed to fetch recording details"
            throw CallHistoryError.serverError(errorMessage)
        }

        guard let startedAtString = egress.startedAt,
              let startDate = ISO8601DateFormatter().date(from: startedAtString) else {
            throw CallHistoryError.invalidData
        }

        let endDate: Date? = if let endedAtString = egress.endedAt {
            ISO8601DateFormatter().date(from: endedAtString)
        } else {
            nil
        }

        let status = RecordingStatus(rawValue: egress.status ?? 0) ?? .failed

        return CallRecordingItem(
            id: egress.egressId,
            roomId: egress.roomName ?? "",
            roomName: egress.roomName ?? "Unknown Room",
            startedAt: startDate,
            endedAt: endDate,
            status: status,
            filepath: nil
        )
    }

    // MARK: - Private Methods

    private func get<R: Decodable>(endpoint: String) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CallHistoryError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw CallHistoryError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(R.self, from: data)
    }
}

// MARK: - Error

enum CallHistoryError: LocalizedError {
    case networkError(Error)
    case serverError(String)
    case invalidResponse
    case invalidData

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidData:
            return "Invalid data received"
        }
    }
}

// MARK: - Mock for Testing

class CallHistoryServiceMock: CallHistoryServiceProtocol {
    var mockRecordings: [CallRecordingItem] = []
    var shouldFail = false

    func fetchRecordings() async throws -> [CallRecordingItem] {
        if shouldFail {
            throw CallHistoryError.serverError("Mock error")
        }
        return mockRecordings
    }

    func getRecordingDetails(egressId: String) async throws -> CallRecordingItem {
        if shouldFail {
            throw CallHistoryError.serverError("Mock error")
        }
        return mockRecordings.first { $0.id == egressId }
            ?? CallRecordingItem(
                id: egressId,
                roomId: "!mock:server.com",
                roomName: "Mock Room",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(120),
                status: .complete,
                filepath: "recordings/mock.mp4"
            )
    }
}
