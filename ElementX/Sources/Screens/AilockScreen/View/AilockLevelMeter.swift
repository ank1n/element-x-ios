//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Индикатор уровня звука во время диктовки.
///
/// STMOB-274, требование dp: показывать не факт записи, а то, что микрофон реально
/// слышит голос. Статичная точка этого не даёт.
///
/// Три вещи взяты из разбора Molly по вебу, чтобы не повторять её переделки:
/// * у каждой полоски СВОЙ вес — иначе они движутся синхронно и читаются как одна
///   широкая полоса, выглядит сломанным;
/// * нижний порог: в тишине полоски не должны схлопываться в невидимую линию,
///   иначе кажется, что запись не идёт;
/// * уровень НЕ гоняется через публикуемое состояние экрана: `TimelineView`
///   перерисовывает только сам индикатор, а не весь композер по 20 раз в секунду.
struct AilockLevelMeter: View {
    /// Текущий уровень 0…1. Читается прямо у рекордера в момент отрисовки.
    let level: () -> Float

    private let barCount = 4
    private let floorValue: CGFloat = 0.18
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
            HStack(alignment: .center, spacing: barSpacing) {
                let value = CGFloat(max(0, min(1, level())))
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.red)
                        .frame(width: barWidth, height: height(for: index, level: value))
                }
            }
            .frame(height: maxHeight, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: level())
        }
        .accessibilityHidden(true)
    }

    /// Вес полоски: середина выше краёв, поэтому индикатор «дышит», а не дёргается
    /// одним блоком. Формула та же, что в вебе, чтобы клиенты выглядели одинаково.
    private func height(for index: Int, level: CGFloat) -> CGFloat {
        let position = CGFloat(index + 1) / CGFloat(barCount)
        let weight = 0.55 + 0.45 * sin(position * .pi)
        let scaled = max(floorValue, level * weight)
        return maxHeight * scaled
    }
}
