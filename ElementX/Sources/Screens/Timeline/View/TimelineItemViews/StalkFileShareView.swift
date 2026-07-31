//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Карточка «поделился файлом» в ленте — вместо строки-уведомления со ссылкой.
///
/// Вёрстка повторяет веб один в один (значения от Molly, #ops 31.07: `FileShareBody.tsx`
/// + CSS): три зоны в ряд — значок, имя с мета-строкой, кнопка справа. Числа и цвета
/// взяты её, а не подобраны на глаз, чтобы карточка не разъезжалась между клиентами.
///
/// Тёмная тема в вебе не задана: там карточка всегда светлая. Повторяем как есть —
/// это осознанное решение «как отдаёт веб, так и показываем», а не недосмотр.
struct StalkFileShareView: View {
    let fileShare: StalkFileShare
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                FileBadge(fileShare: fileShare)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileShare.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.stalkFileShareTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    metaRow
                }

                Spacer(minLength: 4)

                // Кнопка залитая, с горизонтальным градиентом — как в вебе. Сначала
                // была синей надписью, и карточка не читалась как действие: цвета
                // сняты пипеткой со скриншота прода, а не подобраны.
                Text(NSLocalizedString("stalk_file_share_open_in_disk", tableName: "Localizable",
                                       value: "Открыть в Диске", comment: "File share card action"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(LinearGradient(colors: [.stalkFileShareButtonStart, .stalkFileShareButtonEnd],
                                               startPoint: .leading,
                                               endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .frame(maxWidth: 440, alignment: .leading)
            .background(Color.stalkFileShareBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.stalkFileShareBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Размер · право · с кем поделились. Отправителя и тип файла веб не показывает —
    /// не показываем и мы, иначе строка расползается и карточки перестают совпадать.
    private var metaRow: some View {
        HStack(spacing: 7) {
            if fileShare.size > 0 {
                Text(Self.sizeFormatter.string(fromByteCount: fileShare.size))
            }

            permissionPill

            if !fileShare.sharedWith.isEmpty {
                SharedWithAvatars(recipients: fileShare.sharedWith)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.stalkFileShareMeta)
    }

    /// Право показывается ВСЕГДА, даже когда пришло пустым: по контракту умолчание —
    /// чтение, и пустое место читалось бы как «прав нет вовсе».
    private var permissionPill: some View {
        Text(fileShare.permission.title)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(Color.stalkFileSharePermissionText)
            .padding(.vertical, 1)
            .padding(.horizontal, 7)
            .background(Color.stalkFileShareAccent, in: Capsule())
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

// MARK: - Значок файла

/// Цветной квадрат с аббревиатурой расширения или глифом.
///
/// Считается локально из имени и mimetype — ни превью, ни ссылки на картинку в
/// событии нет, и веб делает ровно так же (`getFileBadge`).
private struct FileBadge: View {
    let fileShare: StalkFileShare

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(kind.color)
            .frame(width: 34, height: 34)
            .overlay {
                switch kind.content {
                case .glyph(let name):
                    Image(systemName: name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                case .abbreviation(let text):
                    Text(text)
                        .font(.system(size: text.count > 3 ? 8 : 9.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                }
            }
    }

    private var kind: BadgeKind {
        BadgeKind(name: fileShare.name, mimetype: fileShare.mimetype)
    }
}

/// Как выглядит значок для конкретного файла.
private struct BadgeKind {
    enum Content {
        case glyph(String)
        case abbreviation(String)
    }

    let color: Color
    let content: Content

    init(name: String, mimetype: String) {
        // Медиа — глифом, остальное — расширением. Так же в вебе: для картинки
        // аббревиатура «PNG» ничего не сообщает, а значок сообщает.
        if mimetype.hasPrefix("image/") {
            color = Color(red: 0.20, green: 0.65, blue: 0.45)
            content = .glyph("photo.fill")
            return
        }
        if mimetype.hasPrefix("video/") {
            color = Color(red: 0.45, green: 0.35, blue: 0.80)
            content = .glyph("play.fill")
            return
        }
        if mimetype.hasPrefix("audio/") {
            color = Color(red: 0.90, green: 0.45, blue: 0.20)
            content = .glyph("music.note")
            return
        }

        let ext = (name as NSString).pathExtension.uppercased()
        content = .abbreviation(ext.isEmpty ? "FILE" : ext)
        color = Self.color(forExtension: ext, mimetype: mimetype)
    }

    /// Цвета по типу документа — привычные по офисным пакетам, чтобы файл
    /// опознавался до чтения имени.
    private static func color(forExtension ext: String, mimetype: String) -> Color {
        switch ext {
        case "PDF":
            Color(red: 0.85, green: 0.22, blue: 0.20)
        case "XLS", "XLSX", "CSV", "NUMBERS":
            Color(red: 0.13, green: 0.60, blue: 0.35)
        case "DOC", "DOCX", "RTF", "PAGES":
            Color(red: 0.15, green: 0.45, blue: 0.80)
        case "PPT", "PPTX", "KEY":
            Color(red: 0.90, green: 0.45, blue: 0.15)
        case "ZIP", "RAR", "7Z", "TAR", "GZ":
            Color(red: 0.50, green: 0.50, blue: 0.55)
        case "TXT", "MD", "LOG":
            // Снято с прода: у `.log` веб рисует именно этот сине-фиолетовый,
            // а не серый, как я предположила сначала.
            Color(red: 0x6A / 255, green: 0x9A / 255, blue: 0xF8 / 255) // #6a9af8
        default:
            mimetype.contains("sheet") ? Color(red: 0.13, green: 0.60, blue: 0.35)
                : Color(red: 0.0, green: 0.53, blue: 0.73)
        }
    }
}

// MARK: - С кем поделились

/// С кем поделились. Штатный аватар приложения: тот же кружок и тот же
/// детерминированный цвет по идентификатору, что и везде в ленте.
///
/// Ссылки на аватар в событии нет — только `user` и `display`, поэтому картинку
/// не грузим: тянуть профиль на каждого получателя в ячейке ленты означало бы
/// сетевой запрос на каждую отрисовку. Компонент в этом случае рисует букву на
/// цветном фоне, и это ровно тот же вид, что у собеседника без фото.
private struct SharedWithAvatars: View {
    let recipients: [StalkFileShare.Recipient]

    private static let visibleLimit = 3

    var body: some View {
        HStack(spacing: -5) {
            ForEach(recipients.prefix(Self.visibleLimit), id: \.user) { recipient in
                LoadableAvatarImage(url: nil,
                                    name: recipient.displayName,
                                    contentID: recipient.user,
                                    avatarSize: .custom(17),
                                    mediaProvider: nil)
                    .overlay(Circle().stroke(Color.stalkFileShareBackground, lineWidth: 1))
            }

            if recipients.count > Self.visibleLimit {
                Text("+\(recipients.count - Self.visibleLimit)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.stalkFileShareMeta)
                    .padding(.leading, 7)
            }
        }
    }
}

// MARK: - Цвета веба

/// Значения из CSS веба, один в один. Держим их вместе, чтобы при следующей правке
/// вида не искать по файлу и не разъехаться с вебом по одному забытому цвету.
private extension Color {
    static let stalkFileShareBackground = Color(red: 1, green: 1, blue: 1) // #ffffff
    static let stalkFileShareBorder = Color(red: 0xDC / 255, green: 0xE8 / 255, blue: 0xEE / 255) // #dce8ee
    static let stalkFileShareTitle = Color(red: 0x16 / 255, green: 0x32 / 255, blue: 0x4E / 255) // #16324e
    static let stalkFileShareMeta = Color(red: 0x7E / 255, green: 0x96 / 255, blue: 0xA9 / 255) // #7e96a9
    static let stalkFileShareAccent = Color(red: 0xE3 / 255, green: 0xF2 / 255, blue: 0xFB / 255) // #e3f2fb
    static let stalkFileSharePermissionText = Color(red: 0x00, green: 0x88 / 255, blue: 0xBB / 255) // #0088bb
    // Градиент кнопки — снят пипеткой со скриншота прода: слева сине-бирюзовый,
    // справа зелёный. В описании вёрстки его не было, а разница заметная.
    static let stalkFileShareButtonStart = Color(red: 0x3D / 255, green: 0x89 / 255, blue: 0xB2 / 255) // #3d89b2
    static let stalkFileShareButtonEnd = Color(red: 0x55 / 255, green: 0xA5 / 255, blue: 0x8F / 255) // #55a58f
}
