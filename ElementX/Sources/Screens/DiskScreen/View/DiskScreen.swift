//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct DiskScreen: View {
    @ObservedObject var context: DiskScreenViewModel

    var body: some View {
        VStack(spacing: 0) {
            categoryBar
            content
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(NSLocalizedString("stalk_disk_title", tableName: "Localizable", value: "Диск", comment: "Disk screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { context.onAppear() }
        .refreshable { await context.reload() }
    }

    // MARK: - Категории

    /// Фильтр по категориям со счётчиками из `/api/files/stats`. Счётчик рядом с
    /// названием — единственный способ понять, что в разделе пусто, ДО перехода.
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: NSLocalizedString("stalk_disk_category_all", tableName: "Localizable", value: "Все", comment: "Disk: all files"),
                     count: context.stats?.all,
                     isSelected: context.selectedCategory == nil) {
                    context.selectedCategory = nil
                }

                ForEach(DiskFileCategory.allCases.filter { $0 != .other }, id: \.self) { category in
                    chip(title: category.title,
                         count: context.stats?.count(for: category),
                         isSelected: context.selectedCategory == category) {
                        context.selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        if context.isLoading, context.files.isEmpty {
            Spacer()
            ProgressView()
            Spacer()
        } else if let errorText = context.errorText {
            errorState(errorText)
        } else if context.files.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List(context.files) { file in
            Button {
                context.selectFile(file)
            } label: {
                DiskFileRow(file: file)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color(.secondarySystemGroupedBackground))
            .task { await context.loadMoreIfNeeded(currentItem: file) }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("stalk_disk_empty", tableName: "Localizable",
                                   value: "Здесь пока нет файлов", comment: "Disk empty state"))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorState(_ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button(NSLocalizedString("stalk_disk_retry", tableName: "Localizable", value: "Повторить", comment: "Disk retry")) {
                Task { await context.reload() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}

// MARK: - Ячейка

struct DiskFileRow: View {
    let file: DiskFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.category.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(Self.sizeFormatter.string(fromByteCount: file.size))
                    Text("·")
                    Text(Self.dateFormatter.string(from: file.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Замок показывает, что файл зашифрован: такие лежат в чатах, и
            // расшифровать их может только клиент — сервер ключей не имеет.
            if file.isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if file.starred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
