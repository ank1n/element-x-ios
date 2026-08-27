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
/// Палитра референс-дизайна (Robodoc concept.html) — токены оттуда дословно.
/// Экран Айлока в светлой теме следует ему; в тёмной держимся системных
/// материалов: референс светлый, белая карточка в тёмной теме слепит.
private enum AilockPalette {
    static let card = Color.white // --card
    static let border = Color(red: 0.863, green: 0.910, blue: 0.933) // --border #DCE8EE
    static let ice = Color(red: 0.918, green: 0.957, blue: 0.980) // --ice #EAF4FA
    static let iceBorder = Color(red: 0.796, green: 0.894, blue: 0.949) // #CBE4F2
    static let sky = Color(red: 0.0, green: 0.533, blue: 0.733) // --sky #0088BB
    static let skySoft = Color(red: 0.890, green: 0.949, blue: 0.984) // --sky-soft #E3F2FB
    static let teal = Color(red: 0.184, green: 0.663, blue: 0.549) // --teal #2FA98C
    static let muted = Color(red: 0.494, green: 0.588, blue: 0.663) // --muted #7E96A9
    static let shadow = Color(red: 0.086, green: 0.196, blue: 0.306).opacity(0.07) // --shadow
}

struct AilockChatScreen: View {
    @ObservedObject var context: AilockScreenViewModelType.Context
    @Environment(\.colorScheme) private var colorScheme

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
            // STMOB-285: прокрутка ленты убирает клавиатуру. Без этого её нечем
            // закрыть: кнопки «Готово» на клавиатуре нет, тап по ленте занят
            // выделением текста, и человек оказывается заперт в поле ввода —
            // единственный выход был отправить сообщение или уйти с экрана.
            .scrollDismissesKeyboard(.immediately)
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
                // Markdown рисуем и ВО ВРЕМЯ стриминга (dp: сырой текст до конца
                // ответа, потом «перерисовать» — вместо этого форматируем сразу).
                // Дельты приходят пачками раз в 60мс (flushBuffer), разбор блоков
                // на килобайтах текста дешёвый — перерисовка не дёргает ленту.
                AilockMarkdownText(text: message.text)
                    // Меню — на текстовом блоке, НЕ на всём сообщении: иначе оно
                    // перехватывало бы долгий тап файловых карточек ниже. Оно же
                    // заменяет копирование выделением (long-press теперь его) —
                    // «Скопировать» берёт ответ целиком. Только на готовом ответе:
                    // во время стриминга сохранение унесло бы обрезанную середину.
                    .contentShape(Rectangle())
                    .contextMenu {
                        if !message.isStreaming {
                            Button {
                                UIPasteboard.general.string = message.text
                            } label: {
                                Label(SL10n.ailockCopy, systemImage: "doc.on.doc")
                            }
                            // Контекст Диска приходит от координатора всегда; пробы
                            // files-api здесь нет — на домене без него сохранение
                            // честно упадёт в баннер ошибки.
                            if context.viewState.diskPicker != nil {
                                Button {
                                    context.send(viewAction: .saveToDisk(message))
                                } label: {
                                    Label(SL10n.ailockSaveToDisk, systemImage: "externaldrive.badge.plus")
                                }
                            }
                        }
                    }
            }

            ForEach(message.files) { file in
                fileCard(file, isOutgoing: false)
            }

            if message.isStreaming, message.text.isEmpty {
                workingIndicator
            }

            answeredByLabel(message)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «Чем отвечено» — метка ЭТОГО хода.
    ///
    /// Показываем только то, что приехало вместе с ответом. Если метки нет
    /// (старые ходы, движок не прислал) — не пишем ничего и НЕ подставляем
    /// текущую активную модель: иначе вся история задним числом перепишется
    /// под последний выбор.
    @ViewBuilder
    private func answeredByLabel(_ message: AilockMessage) -> some View {
        if !message.isStreaming,
           let llm = message.llm,
           let name = llm.displayName(in: context.viewState.llmChains) {
            HStack(spacing: 4) {
                Text(String(format: SL10n.ailockAnsweredBy, name))
                // Просили размышление, но движок его не применил — говорим прямо.
                // Иначе человек уверен, что получил дорогой режим, а получил обычный.
                if llm.reasoningApplied == false, let mode = llm.reasoningMode, mode != .auto {
                    Text("·")
                    Text(SL10n.ailockReasoningNotApplied)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
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

            if let info = context.viewState.infoToast {
                infoBanner(info)
            }

            if let question = context.viewState.pendingQuestion {
                questionBanner(question)
            }

            if !context.viewState.pendingAttachments.isEmpty {
                attachmentsRow
            }

            controlChips

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
                            .foregroundStyle(colorScheme == .dark ? AnyShapeStyle(.secondary) : AnyShapeStyle(AilockPalette.muted))
                            .frame(width: 34, height: 34)
                    }
                    .disabled(context.viewState.isUploadingAttachment || context.viewState.voicePhase == .transcribing)

                    TextField(composerPlaceholder, text: $context.composerText, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .disabled(context.viewState.voicePhase == .transcribing)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        // Поле = --ice с рамкой, как .fmid референса; тёмная — системное.
                        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : AilockPalette.ice,
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            if colorScheme != .dark {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AilockPalette.iceBorder, lineWidth: 1)
                            }
                        }

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
        // Тост гаснет сам — без анимируемой транзакции его .transition мёртв,
        // и композер дёргался бы по высоте. Ошибки/вопросы не анимируем: их
        // закрывает пользователь.
        .animation(.easeInOut(duration: 0.2), value: context.viewState.infoToast)
        // Карточный стиль референса (dp: «низ плоский» + «соответствие референсу»):
        // белая карточка со скруглённым верхом, волосяной рамкой --border и тенью
        // --shadow — как .tile/.scene в concept.html. Вниз форма продолжается под
        // домашний индикатор — там скругление не нужно. Тёмная тема — материал.
        .background {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
            shape
                .fill(colorScheme == .dark ? AnyShapeStyle(Material.bar) : AnyShapeStyle(AilockPalette.card))
                .overlay {
                    if colorScheme != .dark {
                        shape.stroke(AilockPalette.border, lineWidth: 1)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.06) : AilockPalette.shadow,
                        radius: colorScheme == .dark ? 8 : 18,
                        y: colorScheme == .dark ? -2 : -4)
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

    // MARK: - Чипы поставки 13.08 (STMOB-285)

    /// Выбор модели, уровень размышления и лимиты расхода.
    ///
    /// Все три самоскрывающиеся: сервер не прислал данных — элемента нет вовсе,
    /// ни пустой плашки, ни ошибки. На стендах, где выбор не настроен, композер
    /// выглядит ровно как раньше.
    @ViewBuilder
    private var controlChips: some View {
        let chains = context.viewState.llmChains
        let showsModel = context.viewState.showsModelChip
        let showsReasoning = context.viewState.showsReasoningChip
        let limits = context.viewState.spendLimits

        if showsModel || showsReasoning || !limits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if showsModel, let chains {
                        Menu {
                            // Строка меню как в вебе: название, под ним число
                            // звеньев и пометка варианта по умолчанию, галочка
                            // у действующего. Подзаголовок SwiftUI берёт из
                            // второго Text — так меню читается без иконок.
                            ForEach(chains.chains) { chain in
                                Button {
                                    context.send(viewAction: .selectChain(chain))
                                } label: {
                                    Text(chain.displayName)
                                    if !chain.menuSubtitle.isEmpty {
                                        Text(chain.menuSubtitle)
                                    }
                                    if chain.id == chains.activeChainID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Divider()
                            Button(SL10n.ailockModelDefault) {
                                context.send(viewAction: .selectChain(nil))
                            }
                        } label: {
                            menuChip(text: chains.activeChain?.displayName ?? SL10n.ailockModelTitle)
                        }
                    }

                    if showsReasoning, let chains {
                        Menu {
                            Section(SL10n.ailockReasoningTitle) {
                                ForEach(AilockReasoningMode.allCases, id: \.self) { mode in
                                    Button {
                                        context.send(viewAction: .selectReasoning(mode))
                                    } label: {
                                        if mode == chains.reasoningMode {
                                            Label(mode.title, systemImage: "checkmark")
                                        } else {
                                            Text(mode.title)
                                        }
                                    }
                                }
                            }
                        } label: {
                            // В вебе на чипе только уровень («Авто»), само слово
                            // «Размышление» — заголовок меню. Повторяем: строка
                            // чипов и так тесная, лишнее слово её распирает.
                            menuChip(text: chains.reasoningMode.title)
                        }
                    }

                    // Лимиты — только показываем. Проценты у движка сейчас занижены
                    // (часть ходов `unpriced`), поэтому ничего на них не блокируем
                    // и порогом не пугаем.
                    ForEach(limits) { limit in
                        infoChip(icon: "gauge.with.needle",
                                 text: "\(limit.title.isEmpty ? SL10n.ailockSpendTitle : limit.title) \(Int(limit.percent.rounded()))%")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    /// Чип-меню: текст и «шеврон» справа.
    ///
    /// Ведущей иконки нет намеренно. Во-первых, надпись и так называет, что это
    /// («Модель», «Размышление: Авто») — символ рядом ничего не добавляет.
    /// Во-вторых, значок вроде `brain` на одиннадцати пунктах превращается
    /// в неразборчивую загогулину. Признак нажимаемости несёт шеврон — ровно
    /// так помечены меню в наших настройках.
    private func menuChip(text: String) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(UIColor.systemGray6)))
    }

    /// Чип-показатель: не нажимается, поэтому без шеврона, зато со значком —
    /// он и отличает его от соседних меню.
    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(UIColor.systemGray6)))
    }

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
                    .fill(colorScheme == .dark ? Color(.tertiarySystemFill) : AilockPalette.skySoft)
                    .frame(width: 34, height: 34)
                if context.viewState.voicePhase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? StalkTheme.accent : AilockPalette.sky)
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
                // Активная отправка = градиент hero-кнопки референса (sky→teal),
                // тот же, что на плитке Календаря. Неактивная — системная.
                Circle()
                    .fill(buttonEnabled
                        ? AnyShapeStyle(LinearGradient(colors: [AilockPalette.sky, AilockPalette.teal],
                                                       startPoint: UnitPoint(x: 0, y: 0.2),
                                                       endPoint: UnitPoint(x: 1, y: 0.8)))
                        : AnyShapeStyle(Color(.tertiarySystemFill)))
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

    /// Зелёный близнец errorBanner: подтверждение действия, гаснет само —
    /// поэтому без крестика.
    private func infoBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13))
            Text(message)
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
        .transition(.opacity)
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
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .rule:
            Divider()
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.body)
                .textSelection(.enabled)
        }
    }

    /// Таблица из markdown. Прокручивается вбок отдельно от ленты: колонок бывает
    /// больше, чем влезает в телефон, а переносить ячейки по словам — превращать
    /// таблицу в кашу. Ширины не выравниваем по колонкам вручную — Grid делает это сам.
    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { i in
                            Text(Self.inline(i < header.count ? header[i] : ""))
                                .font(.subheadline.bold())
                        }
                    }
                    Divider().gridCellColumns(columns)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { i in
                            Text(Self.inline(i < row.count ? row[i] : ""))
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            case table(header: [String], rows: [[String]])
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

    /// Строка-разделитель шапки: |---|:---:|---| и любые пробелы внутри.
    private static func isTableDivider(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|") else { return false }
        return line.range(of: #"^\|(\s*:?-{1,}:?\s*\|)+$"#, options: .regularExpression) != nil
    }

    /// Ячейки строки таблицы. Крайние палки — обрамление, а не пустые колонки.
    private static func tableCells(_ raw: String) -> [String] {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") { line.removeLast() }
        return line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
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

        let lines = text.components(separatedBy: "\n")
        var skipUntil = 0

        for (tableIndex, rawLine) in lines.enumerated() {
            if tableIndex < skipUntil { continue }
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
            if let match = line.range(of: "^#{1,6}[ \\t]+", options: .regularExpression) {
                flushParagraph()
                listOpen = false
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(level: level, text: String(line[match.upperBound...])))
                continue
            }

            // Таблица. Признак — строка-разделитель под шапкой: |---|---|.
            // Смотрим на СЛЕДУЮЩУЮ строку, поэтому таблицу собираем целиком тут
            // же, а не по одной строке: иначе шапка успеет уехать в абзац.
            if line.hasPrefix("|"), tableIndex + 1 < lines.count,
               Self.isTableDivider(lines[tableIndex + 1]) {
                flushParagraph()
                listOpen = false
                let header = Self.tableCells(line)
                var rows: [[String]] = []
                var cursor = tableIndex + 2
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("|") else { break }
                    rows.append(Self.tableCells(candidate))
                    cursor += 1
                }
                blocks.append(.table(header: header, rows: rows))
                skipUntil = cursor
                continue
            }

            // Линейка: только --- / *** на всей строке.
            if line.range(of: "^([-*_]){3,}$", options: .regularExpression) != nil {
                flushParagraph()
                listOpen = false
                blocks.append(.rule)
                continue
            }

            if let quoteMatch = line.range(of: "^>[ \\t]+", options: .regularExpression) {
                flushParagraph()
                listOpen = false
                let content = String(line[quoteMatch.upperBound...])
                if case .quote(let existing) = blocks.last {
                    blocks[blocks.count - 1] = .quote(existing + "\n" + content)
                } else {
                    blocks.append(.quote(content))
                }
                continue
            }

            // Маркированный список: -, *, • + пробел.
            if let match = line.range(of: "^[-*•][ \\t]+", options: .regularExpression) {
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
            if let match = line.range(of: #"^\d{1,3}[.)][ \t]+"#, options: .regularExpression) {
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
