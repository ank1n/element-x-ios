//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// Модели домена лежат в Services/Ailock/AilockService.swift — как у Meetings.

// MARK: - Чат

enum AilockScreenViewAction {
    case sendMessage
    case stopGeneration
    case attachFiles([URL])
    case removeAttachment(String)
    case openConversations
    case newConversation
    case openFile(AilockFile)
    case retry
    case dismissError
}

enum AilockScreenViewModelAction {
    case openConversations
    case hideTabBar(Bool)
}

struct AilockScreenViewState: BindableState {
    var messages: [AilockMessage] = []
    /// Агент генерирует ответ — показываем индикатор и кнопку «стоп».
    var isRunning = false
    var isConnecting = false
    var isLoadingHistory = false
    var conversationTitle: String?
    /// Агент задал уточняющий вопрос и ждёт ответа.
    var pendingQuestion: AilockPendingQuestion?
    /// Файлы, выбранные пользователем и ещё не отправленные.
    var pendingAttachments: [AilockFile] = []
    var isUploadingAttachment = false
    var errorMessage: String?
    /// Айлок не развёрнут на этом домене — экран показывает заглушку, а не ошибку.
    var isUnavailable = false

    var bindings = AilockScreenViewStateBindings()

    var canSend: Bool {
        !isConnecting &&
            !isUploadingAttachment &&
            (!bindings.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    var isEmptyState: Bool {
        messages.isEmpty && !isLoadingHistory && !isUnavailable
    }
}

struct AilockScreenViewStateBindings {
    var composerText = ""
    var showFileImporter = false
    /// Скачанный файл, который показываем системным листом «Поделиться».
    var sharedFile: AilockSharedFile?
}

/// Обёртка вокруг URL для `.sheet(item:)`.
struct AilockSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - История бесед

enum AilockConversationsViewAction {
    case refresh
    case select(AilockConversation)
    case delete(AilockConversation)
    case loadMore
    case search(String)
    case newConversation
}

enum AilockConversationsViewModelAction {
    case selected(AilockConversation)
    case newConversation
    case dismiss
}

struct AilockConversationsViewState: BindableState {
    var conversations: [AilockConversation] = []
    var isLoading = true
    var isLoadingMore = false
    var hasMore = false
    var canDelete = false
    var errorMessage: String?

    var bindings = AilockConversationsViewStateBindings()

    /// Группировка по датам, как в мобильных LLM-клиентах: сегодня / вчера / раньше.
    var sections: [(title: String, items: [AilockConversation])] {
        let calendar = Calendar.current
        var today: [AilockConversation] = []
        var yesterday: [AilockConversation] = []
        var week: [AilockConversation] = []
        var older: [AilockConversation] = []

        for conversation in conversations {
            guard let date = conversation.sortDate else {
                older.append(conversation)
                continue
            }
            if calendar.isDateInToday(date) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(conversation)
            } else if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
                week.append(conversation)
            } else {
                older.append(conversation)
            }
        }

        return [(SL10n.ailockToday, today),
                (SL10n.ailockYesterday, yesterday),
                (SL10n.ailockPrevious7Days, week),
                (SL10n.ailockEarlier, older)]
            .filter { !$0.items.isEmpty }
    }
}

struct AilockConversationsViewStateBindings {
    var searchQuery = ""
}
