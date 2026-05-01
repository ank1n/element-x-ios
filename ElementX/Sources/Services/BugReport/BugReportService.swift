//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import GZIP
import Sentry
import UIKit

class BugReportService: NSObject, BugReportServiceProtocol {
    private var rageshakeURL: RageshakeConfiguration
    private let applicationID: String
    private let sdkGitSHA: String
    private let maxUploadSize: Int
    private let session: URLSession
    private let appHooks: AppHooks
    
    private let progressSubject = PassthroughSubject<Double, Never>()
    private var cancellables = Set<AnyCancellable>()
    
    var isEnabled: Bool {
        rageshakeURL != .disabled
    }

    var lastCrashEventID: String?
    
    init(rageshakeURLPublisher: CurrentValuePublisher<RageshakeConfiguration, Never>,
         applicationID: String,
         sdkGitSHA: String,
         maxUploadSize: Int,
         session: URLSession = .shared,
         appHooks: AppHooks) {
        rageshakeURL = rageshakeURLPublisher.value
        self.applicationID = applicationID
        self.sdkGitSHA = sdkGitSHA
        self.maxUploadSize = maxUploadSize
        self.session = session
        self.appHooks = appHooks
        
        super.init()
        
        rageshakeURLPublisher
            .weakAssign(to: \.rageshakeURL, on: self)
            .store(in: &cancellables)
    }

    // MARK: - BugReportServiceProtocol
    
    var crashedLastRun: Bool {
        SentrySDK.crashedLastRun
    }
    
    // sTalk: STMOB-88 — submit goes to TrackIT (Plane) instead of upstream
    // rageshake. Bug Report → создаёт issue в STMOB project с user text +
    // device/version + tail log как HTML preformatted block.
    private static let trackitURL = URL(string: "https://trackit.implica.ru/api/v1/workspaces/implica/projects/a0b9904b-b856-422f-9540-3b975e54f42e/issues/")!
    private static let trackitAPIKey = "plane_api_c380b83adf714ffa0a4fefa20d7193ae"
    private static let trackitTodoState = "e864041b-1cec-43f2-aee3-6ea5d1c0b2f6"
    private static let logTailLimit = 50000 // bytes

    func submitBugReport(_ bugReport: BugReport,
                         progressListener: CurrentValueSubject<Double, Never>) async -> Result<SubmitBugReportResponse, BugReportServiceError> {
        let bugReport = appHooks.bugReportHook.update(bugReport)
        let descriptionHTML = buildDescriptionHTML(for: bugReport)

        let firstLine = bugReport.text.components(separatedBy: .newlines).first?.prefix(80).description ?? "(no title)"
        let issueTitle = "[iOS Bug] " + firstLine

        let payload: [String: Any] = [
            "name": issueTitle,
            "description_html": descriptionHTML,
            "state": Self.trackitTodoState,
            "priority": "medium"
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.uploadFailure(NSError(domain: "BugReport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize payload"])))
        }

        var request = URLRequest(url: Self.trackitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.trackitAPIKey, forHTTPHeaderField: "X-Api-Key")
        request.httpBody = body

        progressSubject
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.value, on: progressListener)
            .store(in: &cancellables)
        progressSubject.send(0.1)

        do {
            let (data, response) = try await session.data(for: request, delegate: self)
            progressSubject.send(0.9)

            guard let httpResponse = response as? HTTPURLResponse else {
                let errorDescription = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                MXLog.error("Bug report TrackIT: no HTTP response — \(errorDescription)")
                return .failure(.serverError(response, errorDescription))
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let errorDescription = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                MXLog.error("Bug report TrackIT failed: HTTP \(httpResponse.statusCode) — \(errorDescription)")
                return .failure(.httpError(httpResponse, errorDescription))
            }

            // Parse Plane response — has `id` + `sequence_id`. Build trackit web URL.
            var reportURL: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["id"] as? String {
                reportURL = "https://trackit.implica.ru/implica/projects/a0b9904b-b856-422f-9540-3b975e54f42e/issues/\(id)"
                if let seq = json["sequence_id"] as? Int {
                    MXLog.info("Bug report submitted — STMOB-\(seq) \(reportURL ?? "")")
                }
            }
            lastCrashEventID = nil
            progressSubject.send(1.0)
            return .success(SubmitBugReportResponse(reportURL: reportURL))
        } catch {
            return .failure(.uploadFailure(error))
        }
    }

    /// Build HTML description for TrackIT issue: user text + device/version + log tail.
    private func buildDescriptionHTML(for bugReport: BugReport) -> String {
        let escapedText = bugReport.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        var html = "<p><b>Описание</b></p><p>\(escapedText.replacingOccurrences(of: "\n", with: "<br>"))</p>"
        html += "<h3>Diagnostic</h3><ul>"
        html += "<li>App: sTalk \(InfoPlistReader.main.bundleShortVersionString) (build \(InfoPlistReader.main.bundleVersion))</li>"
        html += "<li>OS: \(os)</li>"
        html += "<li>Bundle: \(InfoPlistReader.main.baseBundleIdentifier)</li>"
        html += "<li>Languages: \(Locale.preferredLanguages.joined(separator: ", "))</li>"
        if let userID = bugReport.userID { html += "<li>User: \(escape(userID))</li>" }
        if let deviceID = bugReport.deviceID { html += "<li>Device: \(escape(deviceID))</li>" }
        if let ed25519 = bugReport.ed25519, let curve25519 = bugReport.curve25519 {
            html += "<li>ed25519: \(escape(ed25519))</li><li>curve25519: \(escape(curve25519))</li>"
        }
        if let crashEventID = lastCrashEventID {
            html += "<li>Crash: \(escape(crashEventID))</li>"
        }
        if !bugReport.githubLabels.isEmpty {
            html += "<li>Labels: \(bugReport.githubLabels.joined(separator: ", "))</li>"
        }
        html += "<li>can_contact: \(bugReport.canContact)</li>"
        html += "</ul>"

        // Tail of log files
        if let logFiles = bugReport.logFiles, !logFiles.isEmpty {
            html += "<h3>Log tail (last \(Self.logTailLimit) bytes)</h3><pre>"
            html += escape(tailLogs(logFiles, maxBytes: Self.logTailLimit))
            html += "</pre>"
        }
        return html
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func tailLogs(_ urls: [URL], maxBytes: Int) -> String {
        var combined = ""
        for url in urls.suffix(3) { // последние 3 файла лога
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let from = max(0, Int64(size) - Int64(maxBytes / 3))
            try? handle.seek(toOffset: UInt64(from))
            if let data = try? handle.readToEnd(), let s = String(data: data, encoding: .utf8) {
                combined += "--- \(url.lastPathComponent) ---\n"
                combined += s
                combined += "\n\n"
            }
        }
        // hard truncate
        if combined.utf8.count > maxBytes {
            let endIdx = combined.index(combined.endIndex, offsetBy: -maxBytes, limitedBy: combined.startIndex) ?? combined.startIndex
            combined = String(combined[endIdx...])
        }
        return combined
    }

    // MARK: - Private

    private var defaultParams: [MultipartFormData] {
        let (localTime, utcTime) = localAndUTCTime(for: Date())
        let version = "\(InfoPlistReader.main.bundleShortVersionString) (\(InfoPlistReader.main.bundleVersion))"
        return [
            MultipartFormData(key: "user_agent", type: .text(value: "iOS")),
            MultipartFormData(key: "app", type: .text(value: applicationID)),
            MultipartFormData(key: "version", type: .text(value: version)),
            MultipartFormData(key: "build", type: .text(value: InfoPlistReader.main.bundleVersion)),
            MultipartFormData(key: "sdk_sha", type: .text(value: sdkGitSHA)),
            MultipartFormData(key: "os", type: .text(value: os)),
            MultipartFormData(key: "resolved_languages", type: .text(value: Bundle.app.preferredLocalizations.joined(separator: ", "))),
            MultipartFormData(key: "user_languages", type: .text(value: Locale.preferredLanguages.joined(separator: ", "))),
            MultipartFormData(key: "fallback_language", type: .text(value: Bundle.app.developmentLocalization ?? "null")),
            MultipartFormData(key: "local_time", type: .text(value: localTime)),
            MultipartFormData(key: "utc_time", type: .text(value: utcTime)),
            MultipartFormData(key: "base_bundle_identifier", type: .text(value: InfoPlistReader.main.baseBundleIdentifier))
        ]
    }

    private func localAndUTCTime(for date: Date) -> (String, String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let localTime = dateFormatter.string(from: date)
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let utcTime = dateFormatter.string(from: date)
        return (localTime, utcTime)
    }

    private var os: String {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // The other APIs report macOS's equivalent iOS version, so lets use the right one to get the macOS version.
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        } else {
            "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        }
    }

    private func zipFiles(_ logFiles: [URL]) async -> Logs {
        MXLog.info("zipFiles")
        
        var compressedLogs = Logs(maxFileSize: maxUploadSize)
        
        for url in logFiles {
            do {
                try attachFile(at: url, to: &compressedLogs)
            } catch {
                MXLog.error("Failed to compress log at \(url)")
                // Continue so that other logs can still be sent.
            }
        }
        
        MXLog.info("zipFiles: originalSize: \(compressedLogs.originalSize), zippedSize: \(compressedLogs.zippedSize)")

        return compressedLogs
    }
    
    /// Zips a file creating chunks based on 10MB inputs.
    private func attachFile(at url: URL, to zippedFiles: inout Logs) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        
        while let data = try fileHandle.readToEnd() {
            if let zippedData = (data as NSData).gzipped() {
                let zippedURL = URL.temporaryDirectory.appending(path: url.lastPathComponent)
                
                // Remove old zipped file if exists
                try? FileManager.default.removeItem(at: zippedURL)
                
                try zippedData.write(to: zippedURL)
                zippedFiles.appendFile(at: zippedURL, zippedSize: zippedData.count, originalSize: data.count)
            }
        }
    }
    
    /// A collection of logs to be uploaded to the bug report service.
    struct Logs {
        /// The maximum total size of all the files.
        let maxFileSize: Int
        
        /// The files included.
        private(set) var files: [URL] = []
        /// The total size of the files after compression.
        private(set) var zippedSize = 0
        /// The original size of the files.
        private(set) var originalSize = 0
        
        mutating func appendFile(at url: URL, zippedSize: Int, originalSize: Int) {
            guard self.zippedSize + zippedSize < maxFileSize else {
                MXLog.error("Logs too large, skipping attachment: \(url.lastPathComponent)")
                return
            }
            files.append(url)
            self.originalSize += originalSize
            self.zippedSize += zippedSize
        }
    }
}

private extension Data {
    mutating func appendString(string: String, encoding: String.Encoding = .utf8) {
        if let data = string.data(using: encoding) {
            append(data)
        }
    }

    mutating func appendParam(_ param: MultipartFormData, boundary: String) throws {
        appendString(string: "--\(boundary)\r\n")
        appendString(string: "Content-Disposition:form-data; name=\"\(param.key)\"")
        switch param.type {
        case .text(let value):
            appendString(string: "\r\n\r\n\(value)\r\n")
        case .file(let url):
            appendString(string: "; filename=\"\(url.lastPathComponent)\"\r\n")
            appendString(string: "Content-Type: \"content-type header\"\r\n\r\n")
            try append(Data(contentsOf: url))
            appendString(string: "\r\n")
        }
    }
}

private struct MultipartFormData {
    let key: String
    let type: MultipartFormDataType
}

private enum MultipartFormDataType {
    case text(value: String)
    case file(url: URL)
}

extension BugReportService: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.progress.publisher(for: \.fractionCompleted)
            .sink { [weak self] value in
                self?.progressSubject.send(value)
            }
            .store(in: &cancellables)
    }
}
