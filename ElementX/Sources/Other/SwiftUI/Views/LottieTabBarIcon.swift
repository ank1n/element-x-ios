//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SwiftUI

/// SwiftUI wrapper for Lottie animation used in Stalk-style tab bar icons
struct LottieTabBarIcon: UIViewRepresentable {
    let animationName: String
    let isSelected: Bool
    let playAnimation: Bool

    private let activeColor: UIColor = .systemBlue
    private let inactiveColor: UIColor = .systemGray

    func makeUIView(context: Context) -> LottieAnimationView {
        let animationView = LottieAnimationView(name: animationName)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .playOnce
        animationView.backgroundBehavior = .pauseAndRestore

        // Set initial color
        applyColor(to: animationView, color: isSelected ? activeColor : inactiveColor)

        // Show first frame by default
        animationView.currentProgress = 0

        return animationView
    }

    func updateUIView(_ animationView: LottieAnimationView, context: Context) {
        let color = isSelected ? activeColor : inactiveColor
        applyColor(to: animationView, color: color)

        if playAnimation, isSelected {
            animationView.currentProgress = 0
            animationView.play()
        }
    }

    private func applyColor(to animationView: LottieAnimationView, color: UIColor) {
        let colorProvider = ColorValueProvider(color.lottieColorValue)
        // Apply color to all fill and stroke paths
        animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Fill 1.Color"))
        animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Stroke 1.Color"))
    }
}
