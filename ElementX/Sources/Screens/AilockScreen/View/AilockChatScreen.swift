//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import PhotosUI
import SwiftUI

/// Чат с агентом Айлок.
///
/// Раскладка как в мобильных LLM-клиентах: реплика пользователя — компактный пузырь справа,
/// ответ агента — во всю ширину без пузыря (длинный текст в пузыре нечитаем).
/// Кнопка отправки во время генерации превращается в «стоп».
struct AilockChatScreen: View {
    @ObservedObject var context: AilockScreenViewModelType.Context

    /// Пользователь сам прокрутил ленту вверх — не дёргаем её обратно на каждый токен.
    @State private var userScrolledUp = false

    /// Выбранное в медиатеке. Очищается сразу после переноса во временные файлы,
    /// иначе повторный выбор того же снимка не вызовет обработку.
    @State private var pickedPhotos: [PhotosPickerItem] = []

    private let bottomAnchor = "ailock-bottom"

    var body: some View {
        Group {
            if context.viewState.isUnavailable {
                unavailableView
            } else {
                chatView
            }
        }
        .navigationTitle(context.viewState.conversationTitle ?? SL10n.ailockTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $context.showDiskPicker) {
            if let picker = context.viewState.diskPicker {
                AilockDiskPickerScreen(service: picker.service,
                                       baseURL: picker.baseURL,
                                       accessTokenProvider: picker.accessTokenProvider) { url in
                    context.send(viewAction: .attachFiles([url]))
                }
            }
        }
        .photosPicker(isPresented: $context.showPhotosPicker,
                      selection: $pickedPhotos,
                      maxSelectionCount: 5,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await attach(photos: items) }
        }
        .sheet(item: $context.sharedFile) { file in
            AppActivityView(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Лента

    private var chatView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if context.viewState.isEmptyState {
                        emptyState
                    }

                    ForEach(context.viewState.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }

                    // Индикатор в ленте — только когда заготовки ответа ещё нет вовсе.
                    // Иначе он дублировал такой же индикатор внутри пустого пузыря.
                    if context.viewState.isRunning, context.viewState.messages.last?.isStreaming != true {
                        workingIndicator
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                // Снизу больше: последнее сообщение не должно липнуть к панели ввода.
                .padding(.bottom, 20)
            }
            .simultaneousGesture(DragGesture().onChanged { value in
                if value.translation.height > 24 { userScrolledUp = true }
            })
            .onChange(of: context.viewState.messages.count) {
                userScrolledUp = false
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: lastMessageLength) {
                guard !userScrolledUp else { return }
                scrollToBottom(proxy, animated: false)
            }
            .overlay(alignment: .bottomTrailing) {
                if userScrolledUp {
                    scrollToBottomButton(proxy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
    }

    private var lastMessageLength: Int {
        context.viewState.messages.last?.text.count ?? 0
    }

    private var isStreamingVisible: Bool {
        context.viewState.messages.last?.isStreaming == true &&
            !(context.viewState.messages.last?.text.isEmpty ?? true)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            userScrolledUp = false
            scrollToBottom(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Сообщения

    @ViewBuilder
    private func messageView(_ message: AilockMessage) -> some View {
        switch message.role {
        case .user:
            userMessage(message)
        case .assistant:
            assistantMessage(message)
        case .system(let severity):
            systemMessage(message, severity: severity)
        }
    }

    private func userMessage(_ message: AilockMessage) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(StalkTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                ForEach(message.files) { file in
                    fileCard(file, isOutgoing: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantMessage(_ message: AilockMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                // Во время стриминга — обычный текст: разметку считаем один раз, когда ответ готов.
                if message.isStreaming {
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    AilockMarkdownText(text: message.text)
                }
            }

            ForEach(message.files) { file in
                fileCard(file, isOutgoing: false)
            }

            if message.isStreaming, message.text.isEmpty {
                workingIndicator
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func systemMessage(_ message: AilockMessage, severity: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(for: severity))
                .font(.system(size: 13))
            Text(message.text)
                .font(.footnote)
        }
        .foregroundStyle(Self.color(for: severity))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.color(for: severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var workingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(SL10n.ailockWorking)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func fileCard(_ file: AilockFile, isOutgoing: Bool) -> some View {
        Button {
            context.send(viewAction: .openFile(file))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: file.isImage ? "photo" : "doc")
                    .font(.system(size: 16))
                    .foregroundStyle(StalkTheme.accent)
                Text(file.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                if file.isDownloadable {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!file.isDownloadable)
    }

    // MARK: - Состояния

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(StalkTheme.accent)
            Text(SL10n.ailockEmptyTitle)
                .font(.headline)
            Text(SL10n.ailockEmptySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(SL10n.ailockUnavailable)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button(SL10n.ailockRetry) {
                context.send(viewAction: .retry)
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Композер

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = context.viewState.errorMessage {
                errorBanner(error)
            }

            if let question = context.viewState.pendingQuestion {
                questionBanner(question)
            }

            if !context.viewState.pendingAttachments.isEmpty {
                attachmentsRow
            }

            if context.viewState.voicePhase == .recording {
                recordingBar
                    .padding(.horizontal, 12)
                    // Отступ снизу: без него композер упирается в самый край —
                    // на устройстве это читается как «подпирает» нижнюю кромку.
                    .padding(.bottom, Self.composerBottomInset)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    // Скрепка даёт выбор источника: снимок прикладывают чаще документа,
                    // а доставать фото через файловый пикер неудобно.
                    Menu {
                        Button {
                            context.showPhotosPicker = true
                        } label: {
                            // Иконку системного «Фото» приложение использовать не может:
                            // Apple не даёт доступа к иконкам чужих приложений. Берём
                            // ближайший системный глиф той же метафоры.
                            Label(SL10n.ailockAttachPhoto, systemImage: "photo.stack")
                        }
                        Button {
                            context.showDiskPicker = true
                        } label: {
                            // Тот же глиф, что у плитки «Диска» в «Приложениях», —
                            // чтобы источник вложения читался с первого взгляда.
                            Label(SL10n.ailockAttachFromDisk, systemImage: WidgetItem.files.icon)
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                    }
                    .disabled(context.viewState.isUploadingAttachment || context.viewState.voicePhase == .transcribing)

                    TextField(composerPlaceholder, text: $context.composerText, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .disabled(context.viewState.voicePhase == .transcribing)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    // Микрофон показываем, пока поле пустое — как в мобильных LLM-клиентах:
                    // начал печатать, кнопка уступает место отправке.
                    if showsMicButton {
                        micButton
                    } else {
                        sendButton
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, Self.composerBottomInset)
            }
        }
        // Просвет между верхней кромкой панели и капсулой поля: без него овал
        // выглядит обрезанным сверху.
        .padding(.top, Self.composerTopInset)
        // Карточный стиль референса (dp: «низ плоский»): панель — карточка со
        // скруглённым верхом и мягкой тенью, а не слепой срез во всю ширину.
        // Вниз форма продолжается под домашний индикатор — там скругление не нужно.
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
                .fill(Material.bar)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
        }
    }

    /// Переносит выбранное в медиатеке во временные файлы и отдаёт их вью-модели —
    /// дальше путь тот же, что у документов из «Файлов».
    private func attach(photos items: [PhotosPickerItem]) async {
        var urls: [URL] = []

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }

            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "dat"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Имени снимка в медиатеке нет — собираем читаемое, чтобы в ленте
                // и на сервере он не назывался случайным набором символов.
                let url = directory.appendingPathComponent("photo-\(urls.count + 1).\(ext)")
                try data.write(to: url)
                urls.append(url)
            } catch {
                MXLog.error("sTalk Ailock: не удалось сохранить снимок: \(error)")
            }
        }

        guard !urls.isEmpty else { return }
        context.send(viewAction: .attachFiles(urls))
    }

    /// Отступ композера от нижней кромки. Ниже него — только системная область
    /// домашнего индикатора (или таб-бар, если экран открыт без его скрытия),
    /// и вплотную к ним поле ввода выглядит прижатым.
    private static let composerBottomInset: CGFloat = 14
    /// Просвет между верхней границей панели ввода и капсулой поля.
    /// Без него овал упирается в кромку панели и выглядит обрезанным.
    private static let composerTopInset: CGFloat = 10

    private var composerPlaceholder: String {
        context.viewState.voicePhase == .transcribing ? SL10n.ailockTranscribing : SL10n.ailockComposerPlaceholder
    }

    private var showsMicButton: Bool {
        !context.viewState.isVoiceUnavailable &&
            context.viewState.bindings.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            context.viewState.pendingAttachments.isEmpty &&
            !context.viewState.isRunning
    }

    private var micButton: some View {
        Button {
            context.send(viewAction: .startVoiceInput)
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 34, height: 34)
                if context.viewState.voicePhase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StalkTheme.accent)
                }
            }
        }
        .disabled(context.viewState.voicePhase == .transcribing)
        .accessibilityLabel(SL10n.ailockVoiceInput)
    }

    /// Панель записи вместо поля ввода: отменить, таймер с индикатором уровня, готово.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                context.send(viewAction: .cancelVoiceInput)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }

            HStack(spacing: 10) {
                // Показываем не факт записи, а уровень: пользователь должен видеть,
                // что микрофон его слышит (требование dp, паритет с вебом).
                if let provider = context.viewState.voiceLevelProvider {
                    AilockLevelMeter(level: provider)
                }

                Text(Self.timecode(context.viewState.voiceDuration))
                    .font(.body.monospacedDigit())

                Spacer(minLength: 0)

                Text(SL10n.ailockRecording)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                context.send(viewAction: .finishVoiceInput)
            } label: {
                ZStack {
                    Circle()
                        .fill(StalkTheme.accent)
                        .frame(width: 34, height: 34)
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var sendButton: some View {
        Button {
            if context.viewState.isRunning {
                context.send(viewAction: .stopGeneration)
            } else {
                context.send(viewAction: .sendMessage)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(buttonEnabled ? StalkTheme.accent : Color(.tertiarySystemFill))
                    .frame(width: 34, height: 34)
                if context.viewState.isConnecting || context.viewState.isUploadingAttachment {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: context.viewState.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(buttonEnabled ? .white : Color.secondary)
                }
            }
        }
        .disabled(!buttonEnabled)
    }

    private var buttonEnabled: Bool {
        context.viewState.isRunning || context.viewState.canSend
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(context.viewState.pendingAttachments) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 12))
                        Text(file.filename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            context.send(viewAction: .removeAttachment(file.id))
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 34)
    }

    private func questionBanner(_ question: AilockPendingQuestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(SL10n.ailockQuestionWaiting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(question.question)
                    .font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StalkTheme.accent.opacity(0.1))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
            Text(message)
                .font(.footnote)
            Spacer(minLength: 0)
            Button {
                context.send(viewAction: .dismissError)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                context.send(viewAction: .openConversations)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                context.send(viewAction: .newConversation)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(context.viewState.messages.isEmpty)
        }
    }

    // MARK: - Хелперы

    private static func color(for severity: String) -> Color {
        switch severity {
        case "danger": return .red
        case "warn": return .orange
        case "success": return .green
        default: return .secondary
        }
    }

    private static func icon(for severity: String) -> String {
        switch severity {
        case "danger": return "exclamationmark.triangle"
        case "warn": return "exclamationmark.circle"
        case "success": return "checkmark.circle"
        default: return "info.circle"
        }
    }
}

// MARK: - Блочный markdown ответа агента

/// Ответ движка приходит полноценным markdown: ###-заголовки, списки, ```-код.
/// `AttributedString(markdown:)` в inline-режиме понимает только **жирный**/`код`,
/// блочные конструкции оставались сырым текстом (скрин dp, 31.07). SwiftUI
/// блочные intents из full-режима тоже не рисует, поэтому блоки разбираем сами;
/// инлайн внутри блока — прежним системным парсером.
/// Живёт в этом же файле сознательно: новый файл = регистрация в pbxproj,
/// а его прямо сейчас параллельно двигает второй инстанс.
struct AilockMarkdownText: View {
    let text: String

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 2 ? .title3.bold() : .headline)
                .textSelection(.enabled)
                .padding(.top, 4)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.body).foregroundStyle(.secondary)
                        Text(Self.inline(item)).font(.body).textSelection(.enabled)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Self.inline(item.text)).font(.body).textSelection(.enabled)
                    }
                }
            }
        case .code(let code):
            // Без горизонтального скролла: длинные строки переносим — внутри
            // ленты вложенная прокрутка мешает листать сам чат.
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(.systemFill))
                    .frame(width: 3)
                Text(Self.inline(text)).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .rule:
            Divider()
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.body)
                .textSelection(.enabled)
        }
    }

    // MARK: разбор

    struct Block: Identifiable {
        enum Kind {
            case heading(level: Int, text: String)
            case bullets([String])
            case ordered([(number: String, text: String)])
            case code(String)
            case quote(String)
            case rule
            case paragraph(String)
        }

        let id: Int
        let kind: Kind
    }

    /// Инлайн-разметка внутри блока. Сохраняет переводы строк, на произвольном
    /// тексте не падает — при ошибке отдаёт как есть.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block.Kind] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false
        // Список «открыт» = предыдущая строка была его пунктом. Пустая строка или
        // любой другой блок закрывают список — без этого абзац после списка
        // приклеивался бы к последнему пункту как «ленивое продолжение».
        var listOpen = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if line.hasPrefix("```") {
                    inCode = false
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushParagraph()
                listOpen = false
                inCode = true
                continue
            }

            if line.isEmpty {
                flushParagraph()
                listOpen = false
                continue
            }

            // Заголовок: 1-6 решёток и пробел.
            if let match = line.range(of: "^#{1,6} +", options: .regularExpression) {
                flushParagraph()
                listOpen = false
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(level: level, text: String(line[match.upperBound...])))
                continue
            }

            // Линейка: только --- / *** на всей строке.
            if line.range(of: "^([-*_]){3,}$", options: .regularExpression) != nil {
                flushParagraph()
                listOpen = false
                blocks.append(.rule)
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                listOpen = false
                let content = String(line.dropFirst(2))
                if case .quote(let existing) = blocks.last {
                    blocks[blocks.count - 1] = .quote(existing + "\n" + content)
                } else {
                    blocks.append(.quote(content))
                }
                continue
            }

            // Маркированный список: -, *, • + пробел.
            if let match = line.range(of: "^[-*•] +", options: .regularExpression) {
                flushParagraph()
                let item = String(line[match.upperBound...])
                if listOpen, case .bullets(var items) = blocks.last {
                    items.append(item)
                    blocks[blocks.count - 1] = .bullets(items)
                } else {
                    blocks.append(.bullets([item]))
                }
                listOpen = true
                continue
            }

            // Нумерованный список: цифры + точка/скобка. Номер сохраняем исходный —
            // движок может нумеровать с произвольного места, перенумерация соврёт.
            if let match = line.range(of: #"^\d{1,3}[.)] +"#, options: .regularExpression) {
                flushParagraph()
                let number = String(line[..<match.upperBound].prefix(while: \.isNumber))
                let item = String(line[match.upperBound...])
                if listOpen, case .ordered(var items) = blocks.last {
                    items.append((number, item))
                    blocks[blocks.count - 1] = .ordered(items)
                } else {
                    blocks.append(.ordered([(number, item)]))
                }
                listOpen = true
                continue
            }

            // Ленивое продолжение пункта списка: строка без маркера СРАЗУ после
            // пункта (список ещё открыт) — перенос его текста, не новый абзац.
            // После пустой строки список закрыт — это уже обычный абзац.
            if listOpen, case .bullets(var items) = blocks.last, !items.isEmpty {
                items[items.count - 1] += " " + line
                blocks[blocks.count - 1] = .bullets(items)
                continue
            }
            if listOpen, case .ordered(var items) = blocks.last, !items.isEmpty {
                items[items.count - 1].text += " " + line
                blocks[blocks.count - 1] = .ordered(items)
                continue
            }

            paragraph.append(rawLine)
        }

        // Незакрытый код-блок — не повод потерять текст.
        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()

        return blocks.enumerated().map { Block(id: $0.offset, kind: $0.element) }
    }
}
