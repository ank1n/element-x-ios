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

    /// Start recording (API v1 - simple)
    func startRecording(roomName: String) async throws -> String

    /// Start recording with participant metadata (API v2)
    func startRecording(
        roomName: String,
        matrixRoomId: String?,
        participants: [(userId: String, displayName: String)]?,
        initiatedBy: String?
    ) async throws -> String

    func stopRecording() async throws
    func getStatus(egressId: String) async throws -> EgressInfo

    /// Check if there's an active recording for the given room (started by someone else)
    func hasActiveRecording(roomName: String) async -> Bool

    /// Check if there's an active recording in the given Matrix room via /api/recording/active
    func hasActiveRecordingInRoom(matrixRoomId: String) async -> Bool

    /// Принудительный сброс состояния записи (при входе в новый звонок)
    func forceReset()
}

// MARK: - Implementation

class RecordingService: RecordingServiceProtocol {
    private let baseURL: URL
    private let urlSession: URLSession
    private let requestTimeout: TimeInterval = 15.0
    private var accessToken: String?

    private let stateSubject = CurrentValueSubject<RecordingState, Never>(.idle)

    var statePublisher: AnyPublisher<RecordingState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var state: RecordingState {
        stateSubject.value
    }

    private var currentEgressId: String?
    private var stateResetTask: Task<Void, Never>?
    private var durationTimer: Task<Void, Never>?
    private var recordingStartTime: Date?

    init(baseURL: URL, accessToken: String? = nil, urlSession: URLSession? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken

        // Create URLSession with timeout configuration
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 10.0
            configuration.timeoutIntervalForResource = 30.0
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    /// Update the access token (e.g. when user session becomes available)
    func updateAccessToken(_ token: String) {
        accessToken = token
    }

    // MARK: - Public Methods

    /// Start recording (API v1 - simple)
    func startRecording(roomName: String) async throws -> String {
        try await startRecording(
            roomName: roomName,
            matrixRoomId: nil,
            participants: nil,
            initiatedBy: nil
        )
    }

    /// Start recording with participant metadata (API v2)
    func startRecording(
        roomName: String,
        matrixRoomId: String?,
        participants: [(userId: String, displayName: String)]?,
        initiatedBy: String?
    ) async throws -> String {
        guard !state.isRecording else {
            throw RecordingError.alreadyRecording
        }

        // Cancel any pending state reset
        stateResetTask?.cancel()
        stateResetTask = nil

        stateSubject.send(.starting)

        do {
            let request = RecordingStartRequest(
                roomName: roomName,
                matrixRoomId: matrixRoomId,
                participants: participants,
                initiatedBy: initiatedBy
            )

            // Add timeout to the request
            let response: RecordingStartResponse = try await withTimeout(seconds: requestTimeout) {
                try await self.post(endpoint: "/recording-api/start", body: request)
            }

            guard response.success, let egressId = response.egressId else {
                let errorMessage = response.error ?? "Unknown error"
                stateSubject.send(.error(errorMessage))
                scheduleStateReset()
                throw RecordingError.serverError(errorMessage)
            }

            currentEgressId = egressId
            recordingStartTime = Date()
            stateSubject.send(.recording(egressId: egressId, duration: 0))

            // Start duration timer
            startDurationTimer(egressId: egressId)

            MXLog.info("Recording started with egressId: \(egressId)")
            return egressId

        } catch let error as RecordingError {
            stateSubject.send(.error(error.localizedDescription))
            scheduleStateReset()
            throw error
        } catch {
            let errorMessage = error.localizedDescription
            stateSubject.send(.error(errorMessage))
            scheduleStateReset()
            throw RecordingError.networkError(error)
        }
    }

    func stopRecording() async throws {
        guard let egressId = currentEgressId else {
            throw RecordingError.noActiveRecording
        }

        // Cancel any pending state reset
        stateResetTask?.cancel()
        stateResetTask = nil

        stateSubject.send(.stopping)

        do {
            let request = RecordingStopRequest(egressId: egressId)

            // Add timeout to the request
            let response: RecordingStopResponse = try await withTimeout(seconds: requestTimeout) {
                try await self.post(endpoint: "/recording-api/stop", body: request)
            }

            guard response.success else {
                let errorMessage = response.error ?? "Unknown error"

                // If recording already stopped/completed, just reset state
                if errorMessage.contains("EGRESS_COMPLETE") || errorMessage.contains("cannot be stopped") {
                    MXLog.info("Recording already completed, resetting state")
                    currentEgressId = nil
                    stopDurationTimer()
                    stateSubject.send(.idle)
                    return
                }

                stateSubject.send(.error(errorMessage))
                scheduleStateReset()
                throw RecordingError.serverError(errorMessage)
            }

            currentEgressId = nil
            stopDurationTimer()
            stateSubject.send(.idle)

            MXLog.info("Recording stopped: \(egressId)")

        } catch let error as RecordingError {
            stateSubject.send(.error(error.localizedDescription))
            scheduleStateReset()
            throw error
        } catch {
            stateSubject.send(.error(error.localizedDescription))
            scheduleStateReset()
            throw RecordingError.networkError(error)
        }
    }

    func getStatus(egressId: String) async throws -> EgressInfo {
        let response: RecordingStatusResponse = try await get(
            endpoint: "/recording-api/status/\(egressId)"
        )

        guard response.success, let egress = response.egress else {
            let errorMessage = response.error ?? "Unknown error"
            throw RecordingError.serverError(errorMessage)
        }

        return egress
    }

    /// Check if there's an active recording for the given room (status=1 ACTIVE)
    func hasActiveRecording(roomName: String) async -> Bool {
        // Deprecated: use hasActiveRecordingInRoom(matrixRoomId:) instead
        await hasActiveRecordingInRoom(matrixRoomId: roomName)
    }

    /// Check if there's an active recording in the given Matrix room via /api/recording/active
    func hasActiveRecordingInRoom(matrixRoomId: String) async -> Bool {
        do {
            guard let encoded = matrixRoomId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return false
            }
            // Build URL directly (appendingPathComponent would encode the query string)
            guard let url = URL(string: "\(baseURL.absoluteString)/api/recording/active?matrixRoomId=\(encoded)") else {
                return false
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let accessToken {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = requestTimeout

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            let result = try JSONDecoder().decode(ActiveRecordingResponse.self, from: data)
            MXLog.info("sTalk hasActiveRecording: matrixRoomId=\(matrixRoomId.prefix(30)), recording=\(result.recording)")
            return result.recording
        } catch {
            MXLog.info("sTalk hasActiveRecording: ERROR \(error)")
            return false
        }
    }

    /// Принудительный сброс состояния записи (при входе в новый звонок)
    func forceReset() {
        MXLog.info("Force resetting recording state")
        stateResetTask?.cancel()
        stateResetTask = nil
        durationTimer?.cancel()
        durationTimer = nil
        currentEgressId = nil
        recordingStartTime = nil
        stateSubject.send(.idle)
    }

    // MARK: - Private Methods

    /// Schedule automatic state reset to idle after showing error
    private func scheduleStateReset() {
        stateResetTask?.cancel()
        stateResetTask = Task { [weak self] in
            // Show error for 3 seconds, then reset to idle
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stateSubject.send(.idle)
        }
    }

    /// Start timer to update recording duration every second
    private func startDurationTimer(egressId: String) {
        durationTimer?.cancel()
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                guard !Task.isCancelled,
                      let self,
                      let startTime = self.recordingStartTime else { return }

                let duration = Date().timeIntervalSince(startTime)
                self.stateSubject.send(.recording(egressId: egressId, duration: duration))
            }
        }
    }

    /// Stop duration timer
    private func stopDurationTimer() {
        durationTimer?.cancel()
        durationTimer = nil
        recordingStartTime = nil
    }

    /// Add timeout to async operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RecordingError.networkError(NSError(domain: "RecordingService", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Request timeout"]))
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func post<T: Encodable, R: Decodable>(endpoint: String, body: T) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = requestTimeout
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
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = requestTimeout

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
        try await startRecording(
            roomName: roomName,
            matrixRoomId: nil,
            participants: nil,
            initiatedBy: nil
        )
    }

    func startRecording(
        roomName: String,
        matrixRoomId: String?,
        participants: [(userId: String, displayName: String)]?,
        initiatedBy: String?
    ) async throws -> String {
        switch startRecordingResult {
        case .success(let egressId):
            stateSubject.send(.recording(egressId: egressId, duration: 0))
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

    func hasActiveRecording(roomName: String) async -> Bool { false }

    func hasActiveRecordingInRoom(matrixRoomId: String) async -> Bool { false }

    func forceReset() {
        stateSubject.send(.idle)
    }

    func simulateState(_ state: RecordingState) {
        stateSubject.send(state)
    }
}
