//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Разбор истории беседы Айлока (GET /conversations/{id}/messages).
///
/// STMOB-274. Движок отдаёт не готовые сообщения, а сырые строки LLM-лога:
/// `{id, role: user|assistant|system|tool, content, created_at, channel, severity,
///   tool_call_id, tool_calls}`. Логика повторяет остров, иначе история будет
/// выглядеть иначе, чем живой стрим:
///
/// 1. строки с `channel == "system"` отбрасываются целиком;
/// 2. ответы пользователя на вопросы агента приезжают как `role == "tool"`
///    с `tool_call_id` от вызова `ask_user` — их надо перевернуть обратно в user,
///    иначе они пропадут из ленты;
/// 3. остальные tool-строки в ленту не идут, но несут вложения;
/// 4. подряд идущие assistant склеиваются в одно сообщение;
/// 5. assistant с непустым `severity` — это системный баннер, а не ответ.
enum AilockHistoryParser {
    /// Вложения приезжают строками внутри content tool-сообщения, по одной на строку:
    /// `__IMAGE_URL__:<mime>:<filename>:<url>` либо `__FILE_URL__:<mime>:<filename>:<url>`.
    private static let imagePrefix = "__IMAGE_URL__:"
    private static let filePrefix = "__FILE_URL__:"

    static func parse(rows: [[String: Any]]) -> [AilockMessage] {
        let askUserCallIDs = askUserToolCallIDs(in: rows)

        var messages: [AilockMessage] = []
        var index = 0

        for row in rows {
            if row["channel"] as? String == "system" { continue }

            let role = row["role"] as? String ?? ""
            let content = row["content"] as? String ?? ""
            let createdAt = AilockService.date(from: row["created_at"] as? String) ?? Date()
            let identifier = (row["id"] as? String) ?? "hist-\(index)"
            index += 1

            // AIBOL-13 ч.1: вложения пользователя приезжают отдельным полем строки.
            // Формат полей не зафиксирован, поэтому читаем терпимо — по нескольким именам.
            let rowAttachments = parseAttachments(row["attachments"])

            switch role {
            case "user":
                messages.append(AilockMessage(id: identifier,
                                              role: .user,
                                              text: content,
                                              files: rowAttachments,
                                              createdAt: createdAt))

            case "tool":
                let callID = row["tool_call_id"] as? String
                if let callID, askUserCallIDs.contains(callID) {
                    // Ответ человека на вопрос агента — возвращаем его в ленту как реплику пользователя.
                    messages.append(AilockMessage(id: identifier, role: .user, text: content, createdAt: createdAt))
                    continue
                }
                // Обычный результат инструмента в ленту не идёт — забираем только вложения.
                let files = parseFiles(from: content)
                guard !files.isEmpty else { continue }
                if let last = messages.indices.last, case .assistant = messages[last].role {
                    messages[last].files.append(contentsOf: files)
                } else {
                    messages.append(AilockMessage(id: identifier, role: .assistant, text: "", files: files, createdAt: createdAt))
                }

            case "assistant":
                let severity = row["severity"] as? String
                if let severity, !severity.isEmpty {
                    messages.append(AilockMessage(id: identifier, role: .system(severity: severity), text: content, createdAt: createdAt))
                    continue
                }
                // Склейка серии: подряд идущие assistant — одно сообщение.
                if let last = messages.indices.last, case .assistant = messages[last].role, !messages[last].text.isEmpty {
                    let existing = messages[last].text
                    if existing != content, !content.isEmpty {
                        messages[last].text = existing + "\n\n" + content
                    }
                    messages[last].createdAt = createdAt
                } else if let last = messages.indices.last, case .assistant = messages[last].role, messages[last].text.isEmpty {
                    messages[last].text = content
                    messages[last].createdAt = createdAt
                } else {
                    messages.append(AilockMessage(id: identifier, role: .assistant, text: content, createdAt: createdAt))
                }
                if !rowAttachments.isEmpty, let last = messages.indices.last {
                    messages[last].files.append(contentsOf: rowAttachments)
                }

            case "system":
                let severity = (row["severity"] as? String) ?? "info"
                messages.append(AilockMessage(id: identifier, role: .system(severity: severity), text: content, createdAt: createdAt))

            default:
                continue
            }
        }

        return messages.filter { !$0.isEmpty }
    }

    /// Идентификаторы вызовов `ask_user` — по ним ответы пользователя опознаются среди tool-строк.
    ///
    /// `tool_calls` в истории имеет двойной тип: массив либо JSON-строка, а имя лежит
    /// то в `function.name`, то в плоском `name`. Прямолинейный Codable здесь разваливается.
    private static func askUserToolCallIDs(in rows: [[String: Any]]) -> Set<String> {
        var result: Set<String> = []

        for row in rows {
            guard row["role"] as? String == "assistant" else { continue }

            let calls: [[String: Any]]
            if let array = row["tool_calls"] as? [[String: Any]] {
                calls = array
            } else if let string = row["tool_calls"] as? String,
                      let data = string.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                calls = parsed
            } else {
                continue
            }

            for call in calls {
                let name = (call["function"] as? [String: Any])?["name"] as? String ?? call["name"] as? String
                if name == "ask_user", let id = call["id"] as? String {
                    result.insert(id)
                }
            }
        }

        return result
    }

    /// Вложения строки истории. Имена полей у движка ещё не зафиксированы (перенос
    /// агентских файлов в `chat_attachments` — M24 Ф3), поэтому принимаем несколько
    /// вариантов и молча пропускаем то, что не опознали.
    static func parseAttachments(_ raw: Any?) -> [AilockFile] {
        guard let items = raw as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            let attachmentID = (item["attachment_id"] as? String) ?? (item["id"] as? String)
            let url = item["url"] as? String
            guard attachmentID != nil || url != nil else { return nil }

            let filename = (item["filename"] as? String) ?? (item["name"] as? String) ?? "file"
            let mime = (item["mime_type"] as? String)
                ?? (item["mimetype"] as? String)
                ?? (item["content_type"] as? String)
                ?? "application/octet-stream"

            return AilockFile(id: attachmentID ?? url ?? filename,
                              filename: filename,
                              mimeType: mime,
                              url: url,
                              attachmentID: attachmentID)
        }
    }

    /// Разбор строк-маркеров вложений. Хвост после второго двоеточия — это URL,
    /// он сам содержит двоеточия, поэтому режем только два раза.
    static func parseFiles(from content: String) -> [AilockFile] {
        guard content.contains(imagePrefix) || content.contains(filePrefix) else { return [] }

        var files: [AilockFile] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isImage = line.hasPrefix(imagePrefix)
            guard isImage || line.hasPrefix(filePrefix) else { continue }

            let payload = String(line.dropFirst(isImage ? imagePrefix.count : filePrefix.count))
            let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let mime = String(parts[0])
            let filename = String(parts[1])
            let url = String(parts[2])
            guard !url.isEmpty else { continue }

            files.append(AilockFile(id: url, filename: filename.isEmpty ? "file" : filename, mimeType: mime, url: url))
        }
        return files
    }
}
