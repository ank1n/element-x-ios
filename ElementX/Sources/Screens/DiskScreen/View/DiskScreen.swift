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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    context.layout = context.layout.toggled
                } label: {
                    Image(systemName: context.layout.toggleIcon)
                }
                .accessibilityLabel(NSLocalizedString("stalk_disk_toggle_layout", tableName: "Localizable",
                                                      value: "Вид списка", comment: "Disk layout toggle"))
            }
        }
        .onAppear { context.onAppear() }
        .refreshable { await context.reload() }
        // Тот же системный просмотрщик, что и для вложений в чате.
        .interactiveQuickLook(item: $context.previewItem, allowEditing: false)
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
        // Высота задана явно. Без неё горизонтальная лента получала ноль:
        // сосед снизу растягивается жадно, а у ScrollView своей высоты нет.
        // `.fixedSize(vertical:)` тут не сработал — проверено на симуляторе.
        .frame(height: 56)
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
            .background(Capsule().fill(isSelected ? Color.compound.bgActionPrimaryRest : Color(.secondarySystemGroupedBackground)))
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
        } else if context.layout == .list {
            list
        } else {
            grid
        }
    }

    private var list: some View {
        List(context.files) { file in
            Button {
                context.selectFile(file)
            } label: {
                DiskFileRow(file: file, isDownloading: context.downloadingFileID == file.id)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color(.secondarySystemGroupedBackground))
            .contextMenu { actions(for: file) }
            .task { await context.loadMoreIfNeeded(currentItem: file) }
        }
        .listStyle(.insetGrouped)
    }

    /// Карточки. Две колонки: на трёх имя файла обрезается до бессмысленного
    /// огрызка, а по имени здесь и опознают документ.
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(context.files) { file in
                    Button {
                        context.selectFile(file)
                    } label: {
                        DiskFileCard(file: file, isDownloading: context.downloadingFileID == file.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { actions(for: file) }
                    .task { await context.loadMoreIfNeeded(currentItem: file) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    /// Меню действий. Пункты, которые некуда вести, не показываем вовсе:
    /// у Диск-документов и копий для шаринга Matrix-события нет, и «найти в чате»
    /// с «переслать» были бы мёртвыми кнопками.
    @ViewBuilder
    private func actions(for file: DiskFile) -> some View {
        Button {
            context.selectFile(file)
        } label: {
            Label(NSLocalizedString("stalk_disk_action_open", tableName: "Localizable",
                                    value: "Открыть", comment: "Disk action"), systemImage: "eye")
        }

        if context.hasChatEvent(file) {
            Button {
                context.findInChat(file)
            } label: {
                Label(NSLocalizedString("stalk_disk_action_find_in_chat", tableName: "Localizable",
                                        value: "Найти в чате", comment: "Disk action"), systemImage: "bubble.left.and.text.bubble.right")
            }

            Button {
                context.forward(file)
            } label: {
                Label(NSLocalizedString("stalk_disk_action_forward", tableName: "Localizable",
                                        value: "Переслать", comment: "Disk action"), systemImage: "arrowshape.turn.up.right")
            }
        }
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
    var isDownloading = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.category.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.compound.iconAccentPrimary)
                .frame(width: 36, height: 36)
                .background(Color.compound.iconAccentPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

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

            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            }

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

    static let sizeFormatter: ByteCountFormatter = {
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

// MARK: - Карточка

/// Плитка в режиме карточек: крупный значок, имя в две строки, размер и дата.
struct DiskFileCard: View {
    let file: DiskFile
    var isDownloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.compound.iconAccentPrimary.opacity(0.12))
                    .frame(height: 96)

                Image(systemName: file.category.systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.compound.iconAccentPrimary)

                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Те же метки, что и в списке: замок у зашифрованных, звезда у
                // избранных. Иначе при переключении вида часть сведений исчезает.
                HStack(spacing: 4) {
                    if file.starred {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    if file.isEncrypted {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .padding(6)
            }

            Text(file.filename)
                .font(.subheadline)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Text(DiskFileRow.sizeFormatter.string(fromByteCount: file.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}
