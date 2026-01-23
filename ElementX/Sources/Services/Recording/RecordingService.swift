//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

// MARK: - Protocol

protocol RecordingServiceProtocol: AnyObject {
    var statePublisher: AnyPublisher<RecordingState, Never> { get }
    var state: RecordingState { get }

    func startRecording(roomName: String) async throws -> String
    func stopRecording() async throws
    func getStatus(egressId: String) async throws -> EgressInfo
}

// MARK: - Implementation

class RecordingService: RecordingServiceProtocol {
    private let baseURL: URL
    private let urlSession: URLSession

    private let stateSubject = CurrentValueSubject<RecordingState, Never>(.idle)

    var statePublisher: AnyPublisher<RecordingState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var state: RecordingState {
        stateSubject.value
    }

    private var currentEgressId: String?

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    // MARK: - Public Methods

    func startRecording(roomName: String) async throws -> String {
        guard !state.isRecording else {
            throw RecordingError.alreadyRecording
        }

        stateSubject.send(.starting)

        do {
            let request = RecordingStartRequest(roomName: roomName)
            let response: RecordingStartResponse = try await post(
                endpoint: "/api/recording/start",
                body: request
            )

            guard response.success, let egressId = response.egressId else {
                let errorMessage = response.error ?? "Unknown error"
                stateSubject.send(.error(errorMessage))
                throw RecordingError.serverError(errorMessage)
            }

            currentEgressId = egressId
            stateSubject.send(.recording(egressId: egressId))

            MXLog.info("Recording started with egressId: \(egressId)")
            return egressId

        } catch let error as RecordingError {
            throw error
        } catch {
            stateSubject.send(.error(error.localizedDescription))
            throw RecordingError.networkError(error)
        }
    }

    func stopRecording() async throws {
        guard let egressId = currentEgressId else {
            throw RecordingError.noActiveRecording
        }

        stateSubject.send(.stopping)

        do {
            let request = RecordingStopRequest(egressId: egressId)
            let response: RecordingStopResponse = try await post(
                endpoint: "/api/recording/stop",
                body: request
            )

            guard response.success else {
                let errorMessage = response.error ?? "Unknown error"
                stateSubject.send(.error(errorMessage))
                throw RecordingError.serverError(errorMessage)
            }

            currentEgressId = nil
            stateSubject.send(.idle)

            MXLog.info("Recording stopped: \(egressId)")

        } catch let error as RecordingError {
            throw error
        } catch {
            stateSubject.send(.error(error.localizedDescription))
            throw RecordingError.networkError(error)
        }
    }

    func getStatus(egressId: String) async throws -> EgressInfo {
        let response: RecordingStatusResponse = try await get(
            endpoint: "/api/recording/status/\(egressId)"
        )

        guard response.success, let egress = response.egress else {
            let errorMessage = response.error ?? "Unknown error"
            throw RecordingError.serverError(errorMessage)
        }

        return egress
    }

    // MARK: - Private Methods

    private func post<T: Encodable, R: Decodable>(endpoint: String, body: T) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecordingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(RecordingStartResponse.self, from: data) {
                throw RecordingError.serverError(errorResponse.error ?? "HTTP \(httpResponse.statusCode)")
            }
            throw RecordingError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(R.self, from: data)
    }

    private func get<R: Decodable>(endpoint: String) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecordingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw RecordingError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(R.self, from: data)
    }
}

// MARK: - Mock for Testing

class RecordingServiceMock: RecordingServiceProtocol {
    private let stateSubject = CurrentValueSubject<RecordingState, Never>(.idle)

    var statePublisher: AnyPublisher<RecordingState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var state: RecordingState {
        stateSubject.value
    }

    var startRecordingResult: Result<String, Error> = .success("mock-egress-id")
    var stopRecordingResult: Result<Void, Error> = .success(())

    func startRecording(roomName: String) async throws -> String {
        switch startRecordingResult {
        case .success(let egressId):
            stateSubject.send(.recording(egressId: egressId))
            return egressId
        case .failure(let error):
            throw error
        }
    }

    func stopRecording() async throws {
        switch stopRecordingResult {
        case .success:
            stateSubject.send(.idle)
        case .failure(let error):
            throw error
        }
    }

    func getStatus(egressId: String) async throws -> EgressInfo {
        EgressInfo(egressId: egressId, roomName: "test-room", status: 1, startedAt: nil, endedAt: nil)
    }

    func simulateState(_ state: RecordingState) {
        stateSubject.send(state)
    }
}
