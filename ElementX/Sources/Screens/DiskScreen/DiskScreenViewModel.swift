//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftUI

enum DiskScreenViewModelAction {
    /// Файл зашифрован — открыть его можно только в чате, где есть ключи комнаты.
    case openRoom(roomID: String, eventID: String)
    case dismiss
}

@MainActor
final class DiskScreenViewModel: ObservableObject {
    @Published private(set) var files: [DiskFile] = []
    @Published private(set) var stats: DiskStats?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published var selectedCategory: DiskFileCategory? {
        didSet {
            guard oldValue != selectedCategory else { return }
            Task { await reload() }
        }
    }

    /// Файл, скачанный для просмотра. Показывается системным просмотрщиком —
    /// тем же, что и вложения в чате.
    @Published var previewItem: MediaPreviewItem?
    /// Имя файла, который сейчас качается: показываем прогресс на его строке.
    @Published private(set) var downloadingFileID: String?

    private let service: DiskService
    private let mediaProvider: MediaProviderProtocol?
    private var nextBefore: String?
    private var isLoadingMore = false

    private let actionsSubject: PassthroughSubject<DiskScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DiskScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: DiskService, mediaProvider: MediaProviderProtocol?) {
        self.service = service
        self.mediaProvider = mediaProvider
    }

    func onAppear() {
        guard files.isEmpty, !isLoading else { return }
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        errorText = nil
        nextBefore = nil

        // Счётчики и список независимы: пустая статистика не должна прятать файлы.
        async let statsTask = try? service.fetchStats()
        do {
            let page = try await service.fetchFiles(category: selectedCategory)
            files = page.files
            nextBefore = page.nextBefore
        } catch {
            errorText = Self.describe(error)
            files = []
        }
        stats = await statsTask
        isLoading = false
    }

    /// Подгрузка следующей страницы по курсору. Без него список обрывается на
    /// первой выдаче, а сервер отдаёт `nextBefore` именно для продолжения.
    func loadMoreIfNeeded(currentItem: DiskFile) async {
        guard let nextBefore, !isLoadingMore,
              currentItem.id == files.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await service.fetchFiles(category: selectedCategory, before: nextBefore)
            // Дубликаты возможны, если между страницами что-то добавилось.
            let known = Set(files.map(\.id))
            files.append(contentsOf: page.files.filter { !known.contains($0.id) })
            self.nextBefore = page.nextBefore
        } catch {
            // Молча: обрыв догрузки не должен ронять уже показанный список.
            DiagLog.write("Disk", "догрузка не удалась: \(error)")
        }
    }

    /// Открыть файл.
    ///
    /// Зашифрованные вложения расшифровываются ключами КОМНАТЫ, и достать их можно
    /// только через таймлайн — сервер ключей не имеет, а по одному mxc-адресу
    /// содержимое не развернуть. Поэтому для таких файлов уводим в чат, где событие
    /// уже расшифровано, вместо того чтобы показывать заведомо битую заглушку.
    func selectFile(_ file: DiskFile) {
        guard !file.isEncrypted else {
            DiagLog.write("Disk", "файл \(file.filename) зашифрован → открываю в чате")
            actionsSubject.send(.openRoom(roomID: file.roomID, eventID: file.eventID))
            return
        }

        guard let mediaProvider, !file.mxcURL.isEmpty, let url = URL(string: file.mxcURL) else {
            errorText = NSLocalizedString("stalk_disk_error_open", tableName: "Localizable",
                                          value: "Этот файл пока нельзя открыть", comment: "Disk cannot open file")
            return
        }

        downloadingFileID = file.id
        Task { [weak self] in
            defer { self?.downloadingFileID = nil }
            guard let source = try? MediaSourceProxy(url: url, mimeType: file.mimetype) else { return }
            let result = await mediaProvider.loadFileFromSource(source, filename: file.filename)
            switch result {
            case .success(let handle):
                self?.previewItem = MediaPreviewItem(file: handle, title: file.filename)
            case .failure(let error):
                DiagLog.write("Disk", "не скачался \(file.filename): \(error)")
                self?.errorText = NSLocalizedString("stalk_disk_error_download", tableName: "Localizable",
                                                    value: "Не удалось загрузить файл", comment: "Disk download failed")
            }
        }
    }

    func dismiss() {
        actionsSubject.send(.dismiss)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DiskServiceError.unauthorized:
            NSLocalizedString("stalk_disk_error_auth", tableName: "Localizable",
                              value: "Нет доступа к диску. Попробуйте войти заново.", comment: "Disk auth error")
        case DiskServiceError.http(let code):
            String(format: NSLocalizedString("stalk_disk_error_http", tableName: "Localizable",
                                             value: "Сервер ответил ошибкой (%d)", comment: "Disk HTTP error"), code)
        default:
            NSLocalizedString("stalk_disk_error_generic", tableName: "Localizable",
                              value: "Не удалось загрузить список файлов", comment: "Disk generic error")
        }
    }
}
