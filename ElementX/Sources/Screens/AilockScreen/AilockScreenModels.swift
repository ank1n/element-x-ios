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
    case startVoiceInput
    case finishVoiceInput
    case cancelVoiceInput
    /// Сохранить ответ агента к себе на Диск (dp).
    case saveToDisk(AilockMessage)
    /// STMOB-285: выбрать модель. `nil` — вернуть к варианту по умолчанию.
    case selectChain(AilockLLMChain?)
    /// STMOB-285: выбрать уровень размышления.
    case selectReasoning(AilockReasoningMode)
}

/// Состояние голосового ввода: диктовка → расшифровка → текст в поле.
enum AilockVoicePhase: Equatable {
    case idle
    case recording
    case transcribing
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
    /// Короткое подтверждение действия («Сохранено на Диск») — гаснет само.
    var infoToast: String?
    /// Айлок не развёрнут на этом домене — экран показывает заглушку, а не ошибку.
    var isUnavailable = false

    /// STMOB-285: набор моделей беседы. `nil` — выбор ей не положен, чип не рисуем.
    /// Все три чипа поставки 13.08 самоскрывающиеся: нет данных — нет элемента,
    /// а не пустая плашка. Это избавляет от «пустых кнопок» на стендах, где
    /// выбор не настроен.
    var llmChains: AilockLLMChains?
    /// Проценты заполненности лимитов. Пусто — лимитов не назначено, чипа нет.
    /// ⚠️ Проценты занижены (часть ходов у движка `unpriced`) — только
    /// информирование, никаких блокировок на этой цифре.
    var spendLimits: [AilockSpendLimit] = []

    /// Чип выбора модели показываем, как только набор пришёл.
    ///
    /// Раньше здесь стояло «больше одной модели» — моя выдумка, в контракте
    /// такого условия нет. Правило спецификации простое: ключа `llm_chains` нет —
    /// чипа нет; ключ есть — чип есть. Лишнее условие прятало весь набор целиком
    /// у тенанта с одной моделью, и снаружи это выглядело как «ничего не
    /// изменилось».
    var showsModelChip: Bool {
        !(llmChains?.chains.isEmpty ?? true)
    }

    /// Чип размышления — только когда действующая модель им управляет, иначе
    /// кнопка была бы без эффекта.
    var showsReasoningChip: Bool {
        llmChains?.reasoningControllable == true
    }

    /// Голосовой ввод.
    var voicePhase: AilockVoicePhase = .idle
    var voiceDuration: TimeInterval = 0
    /// Уровень сигнала 0…1 — для «живого» индикатора записи.
    var voiceLevel: Float = 0
    /// Расшифровки на этом домене нет — прячем микрофон, а не показываем ошибку каждый раз.
    var isVoiceUnavailable = false

    /// Доступ к «Диску»: пикер вложений и «Сохранить на Диск». Координатор
    /// отдаёт контекст всегда — nil-ветка структурная, отдельной пробы
    /// files-api здесь нет.
    var diskPicker: AilockDiskPickerContext?

    /// Текущий уровень микрофона. Индикатор читает его сам в момент отрисовки —
    /// гнать уровень через публикуемое состояние на каждом кадре нельзя, иначе
    /// перерисовывается весь композер (разбор Molly по вебу).
    var voiceLevelProvider: (() -> Float)?

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

/// Всё, что нужно экрану выбора файла из «Диска». Держим в состоянии, как
/// `mediaProvider` в календаре: вью не должна сама собирать сервис.
struct AilockDiskPickerContext {
    let service: DiskService
    let baseURL: String
    let accessTokenProvider: () throws -> String
}

struct AilockScreenViewStateBindings {
    var composerText = ""
    /// Выбор из медиатеки: снимок прикладывают чаще документа.
    var showPhotosPicker = false
    /// Выбор файла из нашего «Диска». Системный файловый пикер убран намеренно
    /// (решение dp): прикладываем только из галереи и из Диска.
    var showDiskPicker = false
    /// Скачанный файл, который показываем системным листом «Поделиться».
    var sharedFile: AilockSharedFile?
    /// STMOB-285: выбор модели нижним листом, а не выпадающим меню (референс
    /// Perplexity, решение dp 28.08). В меню не помещаются подписи и пометки,
    /// а список моделей у тенанта бывает длинным.
    var showsModelsSheet = false
    /// Лист «плюса»: вложения и уровень размышления в одном месте — у них так же,
    /// и это убирает лишний чип из ряда.
    var showsAttachmentsSheet = false
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
