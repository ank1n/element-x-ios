//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SwiftUI

enum DiskScreenViewModelAction {
    /// Пользователь выбрал файл. Открытие содержимого — следующий шаг, он
    /// зависит от ответов по контракту скачивания (см. STMOB-275).
    case openFile(DiskFile)
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

    private let service: DiskService
    private var nextBefore: String?
    private var isLoadingMore = false

    private let actionsSubject: PassthroughSubject<DiskScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DiskScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(service: DiskService) {
        self.service = service
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

    func selectFile(_ file: DiskFile) {
        actionsSubject.send(.openFile(file))
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
