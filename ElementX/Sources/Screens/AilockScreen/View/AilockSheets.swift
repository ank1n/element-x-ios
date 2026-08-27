//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

// STMOB-285: листы вместо выпадающих меню — референс Perplexity (dp, 28.08).
//
// В меню не помещается то, что нужно показать при выборе: подпись под названием,
// пометка варианта по умолчанию, длинный список моделей у тенанта. Лист это
// вмещает и заодно даёт заголовок, по которому понятно, что вообще выбираешь.
//
// Палитра и значки наши — из референса взята только расстановка.

/// Шапка листа: заголовок по центру и крестик справа.
private struct AilockSheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(UIColor.systemGray6)))
                }
                .accessibilityLabel(SL10n.ailockSheetClose)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// Выбор модели: список цепочек, выданных сотруднику.
struct AilockModelsSheet: View {
    let chains: AilockLLMChains
    let onSelect: (AilockLLMChain?) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AilockSheetHeader(title: SL10n.ailockModelsSheetTitle, onClose: onClose)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(chains.chains.enumerated()), id: \.element.id) { index, chain in
                        row(for: chain)

                        if index < chains.chains.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)

                // Возврат к варианту по умолчанию — отдельной строкой, а не
                // пунктом списка: это не «ещё одна модель», а сброс выбора.
                Button {
                    onSelect(nil)
                } label: {
                    Text(SL10n.ailockModelDefault)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(for chain: AilockLLMChain) -> some View {
        Button {
            onSelect(chain)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chain.displayName)
                        .font(.system(size: 16))
                        .foregroundColor(.primary)

                    if !chain.menuSubtitle.isEmpty {
                        Text(chain.menuSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if chain.id == chains.activeChainID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AilockPalette.sky)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// «Плюс»: источники вложения и уровень размышления в одном месте.
///
/// У Perplexity в этом же листе живут «Режимы» — повторяем: так из ряда
/// управления уходит лишний чип, а «плюс» становится единой точкой входа
/// для всего, что не текст.
struct AilockAttachmentsSheet: View {
    let reasoningMode: AilockReasoningMode
    /// Действующая модель не управляет размышлением — секции нет вовсе.
    let showsReasoning: Bool
    let onPickPhoto: () -> Void
    let onPickFromDisk: () -> Void
    let onSelectReasoning: (AilockReasoningMode) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AilockSheetHeader(title: SL10n.ailockAttachSheetTitle, onClose: onClose)

            ScrollView {
                // Источники — крупными кнопками: их всего два, и так они
                // попадают под палец без прицеливания.
                HStack(spacing: 12) {
                    sourceButton(title: SL10n.ailockAttachPhoto, icon: "photo.stack", action: onPickPhoto)
                    sourceButton(title: SL10n.ailockAttachFromDisk, icon: WidgetItem.files.icon, action: onPickFromDisk)
                }
                .padding(.horizontal, 16)

                if showsReasoning {
                    Text(SL10n.ailockReasoningTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach(Array(AilockReasoningMode.allCases.enumerated()), id: \.element) { index, mode in
                            Button {
                                onSelectReasoning(mode)
                            } label: {
                                HStack {
                                    Text(mode.title)
                                        .font(.system(size: 16))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if mode == reasoningMode {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AilockPalette.sky)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < AilockReasoningMode.allCases.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
        // Высота по содержимому: с одними источниками лист в половину экрана
        // выглядит пустым. С секцией размышления содержимого вдвое больше —
        // там половина уместна.
        .presentationDetents(showsReasoning ? [.medium] : [.fraction(0.3)])
        .presentationDragIndicator(.visible)
    }

    private func sourceButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(AilockPalette.sky)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(UIColor.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
