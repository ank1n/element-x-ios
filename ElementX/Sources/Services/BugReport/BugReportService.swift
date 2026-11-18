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
    
    // sTalk: STALK-1603 — отчёт уходит в «Обратную связь» сервера, к которому подключён
    // пользователь (meetings-api POST /api/feedback, как в вебе): у каждого заказчика — в его
    // собственную «Поддержку». Раньше (STMOB-88) задача создавалась прямо в нашем Plane STMOB
    // ключом, зашитым в сборку (STMOB-312), и обращения чужих серверов попадали к нам.
    private static let logTailLimit = 6 * 1024 * 1024 // байт журнала до сжатия
    private static let maxScreenshotDimension: CGFloat = 1600

    func submitBugReport(_ bugReport: BugReport,
                         progressListener: CurrentValueSubject<Double, Never>) async -> Result<SubmitBugReportResponse, BugReportServiceError> {
        let bugReport = appHooks.bugReportHook.update(bugReport)

        guard let server = bugReport.server else {
            return .failure(.uploadFailure(NSError(domain: "BugReport", code: -3,
                                                   userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("stalk_feedback_requires_session",
                                                                                                           tableName: "Localizable",
                                                                                                           value: "Чтобы отправить обращение, войдите в аккаунт",
                                                                                                           comment: "Feedback cannot be sent without a signed-in account")])))
        }

        progressSubject
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.value, on: progressListener)
            .store(in: &cancellables)
        progressSubject.send(0.1)

        let firstLine = bugReport.text.components(separatedBy: .newlines).first?.prefix(80).description ?? ""
        var payload: [String: Any] = [
            "type": bugReport.kind.rawValue,
            "title": firstLine,
            "description": buildDescription(for: bugReport),
            "userAgent": Self.userAgent,
            "url": "sTalk://settings"
        ]

        let screenshots = bugReport.files.compactMap(Self.screenshotDataURL)
        if !screenshots.isEmpty {
            payload["screenshots"] = screenshots
        }

        if let logFiles = bugReport.logFiles, !logFiles.isEmpty {
            let tail = tailLogs(logFiles, maxBytes: Self.logTailLimit)
            // Последние ошибки сервер вставляет в текст обращения, а журнал целиком —
            // вложением для команды (заявитель его в «Моих заявках» не видит).
            payload["logs"] = Array(tail.components(separatedBy: .newlines).filter { $0.contains("ERROR") }.suffix(20))
            if let gzipped = (Data(tail.utf8) as NSData).gzipped() {
                payload["attachments"] = [["name": "ios-logs.txt.gz",
                                           "mime": "application/gzip",
                                           "data": gzipped.base64EncodedString()]]
            }
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.uploadFailure(NSError(domain: "BugReport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize payload"])))
        }

        var request = URLRequest(url: server.baseURL.appending(path: "api/feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(server.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        progressSubject.send(0.2)

        do {
            let (data, response) = try await session.data(for: request, delegate: self)

            guard let httpResponse = response as? HTTPURLResponse else {
                let errorDescription = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                MXLog.error("Feedback: no HTTP response — \(errorDescription)")
                return .failure(.serverError(response, errorDescription))
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let errorDescription = httpResponse.statusCode == 503
                    ? NSLocalizedString("stalk_feedback_not_configured", tableName: "Localizable",
                                        value: "Обратная связь на этом сервере пока не настроена",
                                        comment: "Feedback service is not configured on the server (HTTP 503)")
                    : String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                MXLog.error("Feedback failed: HTTP \(httpResponse.statusCode) — \(errorDescription)")
                return .failure(.httpError(httpResponse, errorDescription))
            }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let key = json?["key"] as? String
            MXLog.info("Feedback submitted — \(key ?? "без номера")")
            lastCrashEventID = nil
            progressSubject.send(1.0)
            return .success(SubmitBugReportResponse(reportURL: key))
        } catch {
            return .failure(.uploadFailure(error))
        }
    }

    /// «sTalk iOS 26.21.14 (391); iPhone17,2; iOS 26.1» — как userAgent веба и Android.
    private static var userAgent: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "sTalk iOS \(InfoPlistReader.main.bundleShortVersionString) (\(InfoPlistReader.main.bundleVersion)); \(model); \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    /// Скриншот как data:image/jpeg;base64 — уменьшенный, чтобы обращение уложилось в 10 МБ.
    private static func screenshotDataURL(for url: URL) -> String? {
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        let scale = min(1, maxScreenshotDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.7) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// Текст обращения: что написал человек + сведения об устройстве для команды.
    private func buildDescription(for bugReport: BugReport) -> String {
        var lines = [bugReport.text, "", "—"]
        lines.append("App: sTalk \(InfoPlistReader.main.bundleShortVersionString) (build \(InfoPlistReader.main.bundleVersion))")
        lines.append("OS: \(os)")
        lines.append("Languages: \(Locale.preferredLanguages.joined(separator: ", "))")
        if let userID = bugReport.userID { lines.append("User: \(userID)") }
        if let deviceID = bugReport.deviceID { lines.append("Device: \(deviceID)") }
        if let ed25519 = bugReport.ed25519, let curve25519 = bugReport.curve25519 {
            lines.append("ed25519: \(ed25519)")
            lines.append("curve25519: \(curve25519)")
        }
        if let crashEventID = lastCrashEventID {
            lines.append("Crash: \(crashEventID)")
        }
        lines.append("can_contact: \(bugReport.canContact)")
        return lines.joined(separator: "\n")
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

// MARK: - STALK-1603: «Мои заявки»

/// Обращения пользователя на его сервере: GET /api/feedback/mine и /mine/:id (meetings-api).
/// Сервер отдаёт только свои обращения и только ответы, видимые заявителю.
struct FeedbackRequestsService {
    let server: FeedbackServer
    var session: URLSession = .shared

    struct State: Decodable, Equatable {
        let group: String?
        let name: String?
    }

    struct Reply: Decodable, Equatable {
        let author: String?
        let createdAt: String?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case author, text
            case createdAt = "created_at"
        }
    }

    struct Item: Decodable, Equatable, Identifiable {
        let id: String
        let key: String?
        let title: String?
        let kind: String?
        let state: State?
        let createdAt: String?
        let updatedAt: String?
        let replies: Int?
        let lastReply: Reply?
        let unavailable: Bool?

        enum CodingKeys: String, CodingKey {
            case id, key, title, kind, state, replies, unavailable
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case lastReply = "last_reply"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeFlexibleID(forKey: .id)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            state = try container.decodeIfPresent(State.self, forKey: .state)
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            replies = try container.decodeIfPresent(Int.self, forKey: .replies)
            lastReply = try container.decodeIfPresent(Reply.self, forKey: .lastReply)
            unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable)
        }
    }

    struct Comment: Decodable, Equatable, Identifiable {
        let id: String
        let author: String?
        let mine: Bool?
        let createdAt: String?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case id, author, mine, text
            case createdAt = "created_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeFlexibleID(forKey: .id)
            author = try container.decodeIfPresent(String.self, forKey: .author)
            mine = try container.decodeIfPresent(Bool.self, forKey: .mine)
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            text = try container.decodeIfPresent(String.self, forKey: .text)
        }
    }

    struct Detail: Decodable, Equatable {
        let title: String?
        let kind: String?
        let state: State?
        let text: String?
        let comments: [Comment]?
    }

    private struct ListResponse: Decodable {
        let items: [Item]
    }

    func myRequests() async throws -> [Item] {
        try await get(ListResponse.self, path: "api/feedback/mine").items
    }

    func request(id: String) async throws -> Detail {
        try await get(Detail.self, path: "api/feedback/mine/\(id)")
    }

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        var request = URLRequest(url: server.baseURL.appending(path: path))
        request.setValue("Bearer \(server.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            MXLog.error("Feedback \(path) failed: HTTP \(status)")
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension KeyedDecodingContainer {
    /// id обращения сервер может отдать и строкой, и числом.
    func decodeFlexibleID(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        return try String(decode(Int.self, forKey: key))
    }
}
