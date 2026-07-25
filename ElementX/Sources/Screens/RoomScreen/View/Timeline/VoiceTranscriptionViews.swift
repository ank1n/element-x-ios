//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

// MARK: - STMOB-265: расшифровка голосового по запросу

//
// Иконка живёт рядом с плеером и НЕ исчезает после показа текста — она работает как
// переключатель (показать/скрыть), так же как на вебе. Самого текста в незашифрованной
// комнате может не быть до первого нажатия: расшифровка считается по запросу.

/// Круглая кнопка-переключатель рядом с плеером голосового.
struct VoiceTranscriptionToggleButton: View {
    @ObservedObject var state: VoiceTranscriptionState
    let action: () -> Void

    @ScaledMetric private var size = 32

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .foregroundColor(isHighlighted ? .compound.bgAccentRest.opacity(0.16) : .compound.bgCanvasDefault)
                if case .loading = state.phase {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundColor(isHighlighted ? .compound.textActionAccent : .compound.iconSecondary)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isLoading: Bool {
        if case .loading = state.phase { return true }
        return false
    }

    /// Подсвечиваем, когда текст показан — чтобы состояние было видно и без текста
    /// (например, когда блок свёрнут скроллом).
    private var isHighlighted: Bool {
        state.isExpanded && !isLoading
    }

    private var accessibilityLabel: String {
        state.isExpanded ? SL10n.transcribeHide : SL10n.transcribeVoice
    }
}

/// Блок с расшифровкой под плеером.
struct VoiceTranscriptionTextView: View {
    @ObservedObject var state: VoiceTranscriptionState

    var body: some View {
        if state.isExpanded, let text {
            Text(text)
                .font(.compound.bodyMD)
                .foregroundColor(isMuted ? .compound.textSecondary : .compound.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.top, 2)
        }
    }

    /// Служебные подписи («речь не распознана», ошибка) показываем приглушённо —
    /// это не содержание сообщения.
    private var isMuted: Bool {
        switch state.phase {
        case .loaded: false
        default: true
        }
    }

    private var text: String? {
        switch state.phase {
        case .idle: nil
        case .loading: nil
        case .loaded(let value): value
        case .empty: SL10n.transcribeEmpty
        case .failed: SL10n.transcribeFailed
        }
    }
}
