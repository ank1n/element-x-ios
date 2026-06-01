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
    private static let trackitBaseURL = "https://trackit.implica.ru"
    private static let trackitProject = "a0b9904b-b856-422f-9540-3b975e54f42e"
    private static let trackitWorkspace = "implica"
    private static let trackitIssuesURL = URL(string: "\(trackitBaseURL)/api/v1/workspaces/\(trackitWorkspace)/projects/\(trackitProject)/issues/")!
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

        var request = URLRequest(url: Self.trackitIssuesURL)
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
            progressSubject.send(0.4)

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

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let issueID = json["id"] as? String else {
                MXLog.error("Bug report TrackIT: cannot parse issue id from response")
                return .failure(.uploadFailure(NSError(domain: "BugReport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot parse issue id"])))
            }
            let sequence = json["sequence_id"] as? Int

            // Upload attachments (logs + screenshots/files) to Plane and append
            // links/images to issue description.
            var attachmentLinks: [String] = []
            var attachmentImages: [String] = []
            let allFiles: [(URL, String)] =
                (bugReport.logFiles ?? []).map { ($0, "text/plain") } +
                bugReport.files.map { ($0, Self.mimeType(for: $0)) }
            for (idx, (fileURL, mime)) in allFiles.enumerated() {
                if let assetURL = await uploadAttachment(fileURL: fileURL, mime: mime, issueID: issueID) {
                    let absoluteAssetURL = "\(Self.trackitBaseURL)\(assetURL)"
                    let name = fileURL.lastPathComponent
                    let escapedName = escape(name)
                    if mime.hasPrefix("image/") {
                        attachmentImages.append("<p><img src=\"\(absoluteAssetURL)\" alt=\"\(escapedName)\" style=\"max-width:600px\"/></p>")
                    } else {
                        attachmentLinks.append("<li><a href=\"\(absoluteAssetURL)\">\(escapedName)</a></li>")
                    }
                } else {
                    MXLog.warning("Bug report: failed to upload attachment \(fileURL.lastPathComponent)")
                }
                progressSubject.send(0.4 + 0.5 * (Double(idx + 1) / Double(max(allFiles.count, 1))))
            }

            // Patch issue description with attachment HTML if anything uploaded.
            if !attachmentLinks.isEmpty || !attachmentImages.isEmpty {
                var attachmentHTML = ""
                if !attachmentImages.isEmpty {
                    attachmentHTML += "<h3>Screenshots</h3>" + attachmentImages.joined()
                }
                if !attachmentLinks.isEmpty {
                    attachmentHTML += "<h3>Attached files</h3><ul>" + attachmentLinks.joined() + "</ul>"
                }
                let updatedHTML = descriptionHTML + attachmentHTML
                _ = await patchIssueDescription(issueID: issueID, descriptionHTML: updatedHTML)
            }

            let reportURL = "\(Self.trackitBaseURL)/\(Self.trackitWorkspace)/projects/\(Self.trackitProject)/issues/\(issueID)"
            if let sequence {
                MXLog.info("Bug report submitted — STMOB-\(sequence) \(reportURL)")
            }
            lastCrashEventID = nil
            progressSubject.send(1.0)
            return .success(SubmitBugReportResponse(reportURL: reportURL))
        } catch {
            return .failure(.uploadFailure(error))
        }
    }

    /// Upload one file as Plane issue-attachment in 3 stages:
    ///   1) POST issue-attachments → presigned upload data
    ///   2) POST upload_data.url multipart → S3-compatible bucket
    ///   3) PATCH attachment to mark uploaded
    /// Returns asset URL path (relative, prepend trackitBaseURL for full URL) on success.
    private func uploadAttachment(fileURL: URL, mime: String, issueID: String) async -> String? {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            MXLog.warning("Bug report: cannot read file \(fileURL.lastPathComponent)")
            return nil
        }
        // Stage 1: register attachment, get presigned upload URL.
        let attachmentsEndpoint = URL(string: "\(Self.trackitBaseURL)/api/v1/workspaces/\(Self.trackitWorkspace)/projects/\(Self.trackitProject)/issues/\(issueID)/issue-attachments/")!
        let registerPayload: [String: Any] = [
            "name": fileURL.lastPathComponent,
            "type": mime,
            "size": fileData.count
        ]
        guard let registerBody = try? JSONSerialization.data(withJSONObject: registerPayload) else { return nil }
        var registerRequest = URLRequest(url: attachmentsEndpoint)
        registerRequest.httpMethod = "POST"
        registerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        registerRequest.setValue(Self.trackitAPIKey, forHTTPHeaderField: "X-Api-Key")
        registerRequest.httpBody = registerBody
        guard let (registerData, registerResponse) = try? await session.data(for: registerRequest),
              let registerHTTP = registerResponse as? HTTPURLResponse,
              (200..<300).contains(registerHTTP.statusCode),
              let registerJSON = try? JSONSerialization.jsonObject(with: registerData) as? [String: Any],
              let uploadData = registerJSON["upload_data"] as? [String: Any],
              let uploadURLString = uploadData["url"] as? String,
              let uploadURL = URL(string: uploadURLString),
              let fields = uploadData["fields"] as? [String: String],
              let assetID = registerJSON["asset_id"] as? String,
              let assetURL = registerJSON["asset_url"] as? String else {
            return nil
        }

        // Stage 2: multipart POST to presigned upload URL.
        let boundary = "BugReportBoundary-\(UUID().uuidString)"
        var multipartBody = Data()
        let preferredFieldOrder = ["Content-Type", "key", "x-amz-algorithm", "x-amz-credential", "x-amz-date", "policy", "x-amz-signature"]
        let orderedKeys = preferredFieldOrder.filter { fields[$0] != nil } + fields.keys.filter { !preferredFieldOrder.contains($0) }
        for key in orderedKeys {
            guard let value = fields[key] else { continue }
            multipartBody.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
            multipartBody.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8) ?? Data())
            multipartBody.append("\(value)\r\n".data(using: .utf8) ?? Data())
        }
        multipartBody.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        multipartBody.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8) ?? Data())
        multipartBody.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8) ?? Data())
        multipartBody.append(fileData)
        multipartBody.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = multipartBody
        guard let (_, uploadResponse) = try? await session.data(for: uploadRequest),
              let uploadHTTP = uploadResponse as? HTTPURLResponse,
              (200..<300).contains(uploadHTTP.statusCode) else {
            return nil
        }

        // Stage 3: PATCH to mark uploaded (Plane requires this to make it visible).
        let finalizeURL = URL(string: "\(Self.trackitBaseURL)/api/v1/workspaces/\(Self.trackitWorkspace)/projects/\(Self.trackitProject)/issues/\(issueID)/issue-attachments/\(assetID)/")!
        var finalizeRequest = URLRequest(url: finalizeURL)
        finalizeRequest.httpMethod = "PATCH"
        finalizeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        finalizeRequest.setValue(Self.trackitAPIKey, forHTTPHeaderField: "X-Api-Key")
        finalizeRequest.httpBody = "{}".data(using: .utf8)
        _ = try? await session.data(for: finalizeRequest)

        return assetURL
    }

    /// PATCH issue with updated description_html (used to append attachment links/images).
    private func patchIssueDescription(issueID: String, descriptionHTML: String) async -> Bool {
        let url = URL(string: "\(Self.trackitBaseURL)/api/v1/workspaces/\(Self.trackitWorkspace)/projects/\(Self.trackitProject)/issues/\(issueID)/")!
        guard let body = try? JSONSerialization.data(withJSONObject: ["description_html": descriptionHTML]) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.trackitAPIKey, forHTTPHeaderField: "X-Api-Key")
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return false
        }
        return true
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "log", "txt": return "text/plain"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    /// Build HTML description for TrackIT issue: user text + device/version + log tail.
    private func buildDescriptionHTML(for bugReport: BugReport) -> String {
        let escapedText = bugReport.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let descriptionLabel = NSLocalizedString("stalk_bugreport_description", tableName: "Localizable", value: "Описание", comment: "Bug report description label")
        var html = "<p><b>\(descriptionLabel)</b></p><p>\(escapedText.replacingOccurrences(of: "\n", with: "<br>"))</p>"
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
