//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit

struct BugReport: Equatable {
    let userID: String?
    let deviceID: String?
    let ed25519: String?
    let curve25519: String?
    let text: String
    let logFiles: [URL]?
    let canContact: Bool
    var githubLabels: [String]
    let files: [URL]
    /// STALK-1603: «Ошибка» или «Предложение» — как вкладки обратной связи в вебе
    var kind: FeedbackKind = .bug
    /// STALK-1603: сервер пользователя, куда уходит обращение. nil — входа нет, отправить некуда.
    var server: FeedbackServer?
}

enum FeedbackKind: String, Equatable {
    case bug
    case feature
}

/// Сервер «Обратной связи» (meetings-api того же домена, что homeserver) и токен Matrix.
struct FeedbackServer: Equatable {
    let baseURL: URL
    let accessToken: String

    /// Как остальные сервисы sTalk: домен — от homeserver сессии, путь одинаковый на всех серверах.
    init?(homeserver: String, accessToken: String?) {
        guard let accessToken,
              let url = URL(string: homeserver.hasPrefix("http") ? homeserver : "https://\(homeserver)"),
              let scheme = url.scheme, let host = url.host,
              let baseURL = URL(string: "\(scheme)://\(host)") else { return nil }
        self.baseURL = baseURL
        self.accessToken = accessToken
    }
}

struct SubmitBugReportResponse: Decodable {
    var reportURL: String?
    
    enum CodingKeys: String, CodingKey {
        case reportURL = "report_url"
    }
}

enum BugReportServiceError: LocalizedError {
    case uploadFailure(Error)
    case serverError(URLResponse, String)
    case httpError(HTTPURLResponse, String)
    
    var errorDescription: String? {
        switch self {
        case .uploadFailure(let error):
            return error.localizedDescription
        case .serverError(_, let errorDescription):
            return errorDescription
        case .httpError(_, let errorDescription):
            return errorDescription
        }
    }
}

// sourcery: AutoMockable
protocol BugReportServiceProtocol: AnyObject {
    var isEnabled: Bool { get }
    var crashedLastRun: Bool { get }
    
    var lastCrashEventID: String? { get set }
    
    func submitBugReport(_ bugReport: BugReport,
                         progressListener: CurrentValueSubject<Double, Never>) async -> Result<SubmitBugReportResponse, BugReportServiceError>
}
