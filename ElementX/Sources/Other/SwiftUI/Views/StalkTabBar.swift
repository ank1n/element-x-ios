//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SwiftUI

/// Stalk-style tab bar item configuration
struct StalkTabItem: Identifiable {
    let id: String
    let title: String
    let lottieIcon: String?
    var badgeCount: Int = 0

    init(id: String, title: String, lottieIcon: String? = nil, badgeCount: Int = 0) {
        self.id = id
        self.title = title
        self.lottieIcon = lottieIcon
        self.badgeCount = badgeCount
    }
}

/// Stalk-style tab bar with Lottie-animated icons
struct StalkTabBar: View {
    let items: [StalkTabItem]
    @Binding var selectedIndex: Int

    @State private var animatingIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .frame(height: 0.5)
                .background(Color(.separator))

            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    tabButton(for: items[index], index: index)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func tabButton(for item: StalkTabItem, index: Int) -> some View {
        Button {
            let wasSelected = selectedIndex == index
            selectedIndex = index

            // Play animation on tap (even if already selected, like Stalk)
            if wasSelected || true {
                animatingIndex = index
                // Reset animation flag after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if animatingIndex == index {
                        animatingIndex = nil
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    if let lottieIcon = item.lottieIcon {
                        LottieTabBarIcon(
                            animationName: lottieIcon,
                            isSelected: selectedIndex == index,
                            playAnimation: animatingIndex == index
                        )
                        .frame(width: 28, height: 28)
                    }

                    // Badge
                    if item.badgeCount > 0 {
                        badgeView(count: item.badgeCount)
                            .offset(x: 8, y: -4)
                    }
                }

                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(selectedIndex == index ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badgeView(count: Int) -> some View {
        let text = count > 99 ? "99+" : "\(count)"
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.red)
            .clipShape(Capsule())
    }
}
