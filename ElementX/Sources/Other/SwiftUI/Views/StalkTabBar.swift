//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import Lottie
import SwiftUI

/// Stalk-style tab bar item configuration
struct StalkTabItem: Identifiable {
    let id: String
    let title: String
    let lottieIcon: String?
    let sfSymbol: String?
    let sfSymbolSelected: String?
    var badgeCount: Int = 0

    init(id: String, title: String, lottieIcon: String? = nil,
         sfSymbol: String? = nil, sfSymbolSelected: String? = nil,
         badgeCount: Int = 0) {
        self.id = id
        self.title = title
        self.lottieIcon = lottieIcon
        self.sfSymbol = sfSymbol
        self.sfSymbolSelected = sfSymbolSelected
        self.badgeCount = badgeCount
    }
}

/// Stalk-style tab bar with Lottie-animated icons and SF Symbol fallback
struct StalkTabBar: View {
    let items: [StalkTabItem]
    @Binding var selectedIndex: Int

    @State private var animatingIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Top separator (0.5pt per ТЗ §2.1.1)
            Rectangle()
                .fill(Color.compound.borderDisabled)
                .frame(height: 1 / UIScreen.main.scale)

            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    tabButton(for: items[index], index: index)
                }
            }
            .frame(height: 49)
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func tabButton(for item: StalkTabItem, index: Int) -> some View {
        let isActive = selectedIndex == index

        Button {
            selectedIndex = index
            animatingIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if animatingIndex == index {
                    animatingIndex = nil
                }
            }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    iconView(for: item, index: index, isActive: isActive)
                        .frame(width: 30, height: 30)

                    // Badge
                    if item.badgeCount > 0 {
                        badgeView(count: item.badgeCount)
                            .offset(x: 10, y: -4)
                    }
                }

                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isActive ? .accentColor : Color(.systemGray))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconView(for item: StalkTabItem, index: Int, isActive: Bool) -> some View {
        if let lottieIcon = item.lottieIcon {
            LottieTabBarIcon(
                animationName: lottieIcon,
                isSelected: isActive,
                playAnimation: animatingIndex == index
            )
        } else if let sfSymbol = item.sfSymbol {
            Image(systemName: isActive ? (item.sfSymbolSelected ?? sfSymbol) : sfSymbol)
                .font(.system(size: 24))
                .foregroundColor(isActive ? .accentColor : Color(.systemGray))
        }
    }

    @ViewBuilder
    private func badgeView(count: Int) -> some View {
        let text = count > 99 ? "99+" : "\(count)"
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.red)
            .clipShape(Capsule())
    }
}
