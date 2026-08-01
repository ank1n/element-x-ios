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
        // Поиск по имени: при первом запросе VM докачивает все страницы,
        // чтобы искать по всему Диску, а не по загруженному куску.
        .searchable(text: $context.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: NSLocalizedString("stalk_disk_search", tableName: "Localizable",
                                              value: "Поиск по файлам", comment: "Disk search prompt"))
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
        } else if context.displayedFiles.isEmpty {
            if context.searchQuery.isEmpty {
                emptyState
            } else {
                searchEmptyState
            }
        } else if context.layout == .list {
            list
        } else {
            grid
        }
    }

    private var list: some View {
        List(context.displayedFiles) { file in
            Button {
                context.selectFile(file)
            } label: {
                DiskFileRow(file: file,
                            isDownloading: context.downloadingFileID == file.id,
                            sharedProfiles: context.sharedProfiles,
                            mediaProvider: context.mediaProvider)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color(.secondarySystemGroupedBackground))
            .contextMenu { actions(for: file) }
            .onAppear { context.ensureSharedProfiles(file) }
            .task { await context.loadMoreIfNeeded(currentItem: file) }
        }
        .listStyle(.insetGrouped)
    }

    /// Карточки. Две колонки: на трёх имя файла обрезается до бессмысленного
    /// огрызка, а по имени здесь и опознают документ.
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(context.displayedFiles) { file in
                    Button {
                        context.selectFile(file)
                    } label: {
                        DiskFileCard(file: file,
                                     isDownloading: context.downloadingFileID == file.id,
                                     thumbnail: context.thumbnails[file.id],
                                     sharedProfiles: context.sharedProfiles,
                                     mediaProvider: context.mediaProvider)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { actions(for: file) }
                    .onAppear {
                        context.ensureThumbnail(file)
                        context.ensureSharedProfiles(file)
                    }
                    .task { await context.loadMoreIfNeeded(currentItem: file) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("stalk_disk_search_empty", tableName: "Localizable",
                                   value: "Ничего не найдено", comment: "Disk search: no results"))
                .foregroundStyle(.secondary)
            Spacer()
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

// MARK: - Тип файла

/// Цвет и глиф по РАСШИРЕНИЮ. Узнаваемые цвета офисных форматов (Word синий,
/// Excel зелёный, PDF красный…) читаются быстрее подписи — dp: «все зелёные»
/// не различимы. Незнакомое расширение падает на серверную категорию.
enum DiskFileStyle {
    static func of(_ file: DiskFile) -> (symbol: String, tint: Color) {
        let ext = (file.filename as NSString).pathExtension.lowercased()
        switch ext {
        case "doc", "docx", "pages", "rtf": return ("doc.text.fill", Color(red: 0.145, green: 0.388, blue: 0.922)) // #2563EB
        case "pdf": return ("doc.richtext.fill", Color(red: 0.937, green: 0.267, blue: 0.267)) // #EF4444
        case "xls", "xlsx", "csv", "numbers": return ("tablecells.fill", Color(red: 0.020, green: 0.588, blue: 0.412)) // #059669
        case "ppt", "pptx", "key": return ("rectangle.stack.fill", Color(red: 0.961, green: 0.620, blue: 0.043)) // #F59E0B
        case "txt", "md", "log": return ("doc.plaintext.fill", Color(red: 0.392, green: 0.455, blue: 0.545)) // #64748B
        case "zip", "rar", "7z", "tar", "gz": return ("archivebox.fill", Color(red: 0.710, green: 0.325, blue: 0.035)) // #B45309
        case "mp3", "wav", "ogg", "m4a", "flac", "opus", "aac": return ("waveform", Color(red: 0.388, green: 0.400, blue: 0.945)) // #6366F1
        case "mp4", "mov", "mkv", "webm", "avi": return ("play.rectangle.fill", Color(red: 0.925, green: 0.286, blue: 0.600)) // #EC4899
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "bmp": return ("photo.fill", Color(red: 0.051, green: 0.741, blue: 0.545)) // #0DBD8B
        default: break
        }
        switch file.category {
        case .documents: return ("doc.text.fill", Color(red: 0.145, green: 0.388, blue: 0.922))
        case .images: return ("photo.fill", Color(red: 0.051, green: 0.741, blue: 0.545))
        case .media: return ("play.rectangle.fill", Color(red: 0.925, green: 0.286, blue: 0.600))
        case .other: return ("doc.fill", Color(red: 0.494, green: 0.588, blue: 0.663)) // #7E96A9
        }
    }
}

/// Значок типа: глиф + РАСШИРЕНИЕ подписью. По одному глифу тип угадывается
/// не всегда (dp: «не очень понятно») — DOCX и TXT рисуются похожими листами,
/// а подпись снимает вопрос. Без расширения — глиф покрупнее по центру.
struct DiskFileTypeIcon: View {
    let file: DiskFile
    var size: CGFloat = 36

    var body: some View {
        let style = DiskFileStyle.of(file)
        let ext = (file.filename as NSString).pathExtension.uppercased()
        VStack(spacing: size * 0.03) {
            Image(systemName: style.symbol)
                .font(.system(size: ext.isEmpty ? size * 0.55 : size * 0.38))
            if !ext.isEmpty {
                Text(String(ext.prefix(4)))
                    .font(.system(size: size * 0.21, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(style.tint)
        .frame(width: size, height: size)
        .background(style.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// До трёх аватарок получателей шаринга внахлёст + «+N» для остальных.
/// Пока профиль не подтянулся, LoadableAvatarImage рисует инициал по userID.
struct DiskSharedAvatars: View {
    let userIDs: [String]
    let profiles: [String: UserProfileProxy]
    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        HStack(spacing: -6) {
            ForEach(userIDs.prefix(3), id: \.self) { id in
                LoadableAvatarImage(url: profiles[id]?.avatarURL,
                                    name: profiles[id]?.displayName ?? String(id.dropFirst().prefix(while: { $0 != ":" })),
                                    contentID: id,
                                    avatarSize: .custom(18),
                                    mediaProvider: mediaProvider)
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 1.5))
            }
            if userIDs.count > 3 {
                Text("+\(userIDs.count - 3)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
                    .padding(.leading, 8)
            }
        }
    }
}

// MARK: - Ячейка

struct DiskFileRow: View {
    let file: DiskFile
    var isDownloading = false
    var sharedProfiles: [String: UserProfileProxy] = [:]
    var mediaProvider: MediaProviderProtocol?

    var body: some View {
        HStack(spacing: 12) {
            DiskFileTypeIcon(file: file, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                // Две строки с обрезанием посередине: видно и начало имени,
                // и расширение — dp: в одну строку длинные имена нечитаемы.
                Text(file.filename)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)

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

            // Кому расшарен: аватарки получателей. Файл без шаринга метки не несёт.
            if let shared = file.sharedWith, !shared.isEmpty {
                DiskSharedAvatars(userIDs: shared, profiles: sharedProfiles, mediaProvider: mediaProvider)
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

/// Плитка в режиме карточек: превью для изображений (dp: «в карточках должно
/// быть видно превью»), крупный цветной значок для остальных, имя в две строки.
struct DiskFileCard: View {
    let file: DiskFile
    var isDownloading = false
    var thumbnail: UIImage?
    var sharedProfiles: [String: UserProfileProxy] = [:]
    var mediaProvider: MediaProviderProtocol?

    var body: some View {
        let style = DiskFileStyle.of(file)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 96)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(style.tint.opacity(0.12))
                        .frame(height: 96)

                    VStack(spacing: 3) {
                        Image(systemName: style.symbol)
                            .font(.system(size: 30))
                        let ext = (file.filename as NSString).pathExtension.uppercased()
                        if !ext.isEmpty {
                            Text(String(ext.prefix(4)))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(style.tint)
                }

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
            .overlay(alignment: .bottomTrailing) {
                if let shared = file.sharedWith, !shared.isEmpty {
                    DiskSharedAvatars(userIDs: shared, profiles: sharedProfiles, mediaProvider: mediaProvider)
                        .padding(6)
                }
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
