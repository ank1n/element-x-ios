//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI
import UIKit

// MARK: - sTalk Adaptive Colors

extension Color {
    /// Telegram-style green badge for unread messages (adaptive for dark mode)
    static let stalkBadgeGreen = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.29, green: 0.70, blue: 0.35, alpha: 1)
            : UIColor(red: 0.33, green: 0.78, blue: 0.39, alpha: 1)
    })

    /// Online status indicator green (adaptive for dark mode)
    static let stalkOnlineGreen = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.25, green: 0.72, blue: 0.32, alpha: 1)
            : UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    })

    /// Telegram-style outgoing bubble (green)
    static let stalkBubbleOutgoing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.37, blue: 0.22, alpha: 1)  // #2B5F37
            : UIColor(red: 0.88, green: 0.99, blue: 0.78, alpha: 1)  // #E1FEC6
    })

    /// Telegram-style incoming bubble (white/dark gray)
    static let stalkBubbleIncoming = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)  // #282829
            : UIColor.white
    })
}

/// Stalk-style tab bar item configuration
struct StalkTabItem: Identifiable {
    let id: String
    let title: String
    let sfSymbol: String?
    let sfSymbolSelected: String?
    var badgeCount: Int = 0

    init(id: String, title: String,
         sfSymbol: String? = nil, sfSymbolSelected: String? = nil,
         badgeCount: Int = 0) {
        self.id = id
        self.title = title
        self.sfSymbol = sfSymbol
        self.sfSymbolSelected = sfSymbolSelected
        self.badgeCount = badgeCount
    }
}

/// Stalk-style tab bar with SF Symbol icons (filled/outline)
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
        if let sfSymbol = item.sfSymbol {
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
            .foregroundColor(.compound.textOnSolidPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.compound.textCriticalPrimary)
            .clipShape(Capsule())
    }
}
