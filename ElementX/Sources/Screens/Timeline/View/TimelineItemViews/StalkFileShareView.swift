//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Карточка «поделился файлом» в ленте — вместо строки-уведомления со ссылкой.
///
/// Показываем ровно то, по чему принимают решение открывать: имя, размер и выданное
/// право. Список получателей не выводим: получателю он не нужен, а у отправителя
/// виден в свойствах файла на Диске.
struct StalkFileShareView: View {
    let fileShare: StalkFileShare
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.compound.iconAccentPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.compound.iconAccentPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileShare.name)
                        .font(.compound.bodyMDSemibold)
                        .foregroundStyle(Color.compound.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitle)
                        .font(.compound.bodySM)
                        .foregroundStyle(Color.compound.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.compound.iconTertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Диск-документ и обычная копия — разные вещи: первый редактируется, второй
    /// только открывается. Значок это и показывает.
    private var icon: String {
        fileShare.isDiskDocument ? "doc.richtext.fill" : "doc.fill"
    }

    private var subtitle: String {
        var parts: [String] = []
        if fileShare.size > 0 {
            parts.append(Self.sizeFormatter.string(fromByteCount: fileShare.size))
        }
        parts.append(fileShare.permission.title)
        return parts.joined(separator: " · ")
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
