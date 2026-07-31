//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import os.log
import UIKit

private let ailockDiskLog = OSLog(subsystem: "ru.implica.stalk", category: "AilockDisk")

/// Достаёт содержимое файла из «Диска», чтобы приложить его к сообщению Айлока.
///
/// STMOB-274. Правило владельца сервиса: есть `mxcUrl` — тянем из Matrix-медиа,
/// нет — из блоб-хранилища по `blobId`. Зашифрованные вложения сюда не попадают:
/// в индексе только метаданные, а ключи комнаты есть лишь у клиента-владельца
/// события, поэтому такие файлы в выборе не показываются вовсе (решение dp).
enum AilockDiskAttachment {
    enum Error: Swift.Error, LocalizedError {
        case unsupported
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unsupported: return SL10n.ailockDiskFileUnsupported
            case .http: return SL10n.ailockDiskFileFailed
            }
        }
    }

    /// Скачивает файл во временную директорию и возвращает путь.
    static func fetch(file: DiskFile,
                      baseURL: String,
                      diskService: DiskService,
                      accessToken: String?) async throws -> URL {
        let data: Data

        if let blobID = file.blobID, !blobID.isEmpty {
            data = try await diskService.fetchBlob(id: blobID)
        } else if !file.mxcURL.isEmpty {
            data = try await fetchMatrixMedia(mxcURL: file.mxcURL, baseURL: baseURL, accessToken: accessToken)
        } else {
            throw Error.unsupported
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file.filename.isEmpty ? "file" : file.filename)
        try data.write(to: url)

        os_log(.default, log: ailockDiskLog, "файл из Диска: %{public}d байт", data.count)
        DiagLog.write("AilockDisk", "вложение из Диска: \(data.count) байт")
        return url
    }

    /// Миниатюра изображения для плитки выбора.
    ///
    /// Именно миниатюра, а не файл: тянуть ради превью полный снимок — это трафик
    /// и память на каждой ячейке сетки. `nil` — просто нарисуем глиф по типу файла.
    static func thumbnail(mxcURL: String, baseURL: String, accessToken: String?) async -> UIImage? {
        let trimmed = mxcURL.replacingOccurrences(of: "mxc://", with: "")
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let server = String(parts[0])
        let mediaID = String(parts[1])

        let query = "?width=200&height=200&method=crop"
        let candidates = [
            "\(baseURL)/_matrix/client/v1/media/thumbnail/\(server)/\(mediaID)\(query)",
            "\(baseURL)/_matrix/media/v3/thumbnail/\(server)/\(mediaID)\(query)"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            if let accessToken {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else {
                continue
            }
            return image
        }
        return nil
    }

    /// Скачивание медиа Matrix.
    ///
    /// Сначала авторизованный маршрут (`/_matrix/client/v1/media/download`), при 404 —
    /// legacy: на разных серверах семейства включено разное, и падать из-за этого
    /// вложение не должно.
    private static func fetchMatrixMedia(mxcURL: String, baseURL: String, accessToken: String?) async throws -> Data {
        let trimmed = mxcURL.replacingOccurrences(of: "mxc://", with: "")
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { throw Error.unsupported }
        let server = String(parts[0])
        let mediaID = String(parts[1])

        let candidates = [
            "\(baseURL)/_matrix/client/v1/media/download/\(server)/\(mediaID)",
            "\(baseURL)/_matrix/media/v3/download/\(server)/\(mediaID)"
        ]

        var lastStatus = 0
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if let accessToken {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            lastStatus = status
        }

        throw Error.http(lastStatus)
    }
}
