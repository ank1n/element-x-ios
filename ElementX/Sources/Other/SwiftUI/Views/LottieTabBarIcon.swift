//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SwiftUI

/// A fixed-size container for LottieAnimationView that reports its intrinsic size correctly to SwiftUI.
class LottieContainerView: UIView {
    let animationView: LottieAnimationView
    private let iconSize: CGFloat

    init(name: String, size: CGFloat) {
        iconSize = size
        animationView = LottieAnimationView(name: name)
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .playOnce
        animationView.backgroundBehavior = .pauseAndRestore
        animationView.isUserInteractionEnabled = false

        addSubview(animationView)
        animationView.frame = bounds
        animationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: iconSize, height: iconSize)
    }
}

/// SwiftUI wrapper for Lottie animation used in Stalk-style tab bar icons.
struct LottieTabBarIcon: UIViewRepresentable {
    let animationName: String
    let isSelected: Bool
    let playAnimation: Bool
    var iconSize: CGFloat = 30

    private let activeColor: UIColor = .systemBlue
    private let inactiveColor: UIColor = .systemGray

    func makeUIView(context: Context) -> LottieContainerView {
        let container = LottieContainerView(name: animationName, size: iconSize)
        let av = container.animationView

        applyColor(to: av, color: isSelected ? activeColor : inactiveColor)
        // Show the frame where all shapes are fully visible (2 frames before end
        // to avoid gap between last shape keyframe and animation end marker).
        showStaticFrame(av)

        return container
    }

    func updateUIView(_ container: LottieContainerView, context: Context) {
        let av = container.animationView
        let color = isSelected ? activeColor : inactiveColor
        applyColor(to: av, color: color)

        if playAnimation, isSelected {
            av.currentProgress = 0
            av.play()
        } else if !av.isAnimationPlaying {
            showStaticFrame(av)
        }
    }

    /// Shows the frame where all shapes are fully rendered.
    /// Some Lottie files have a gap between the last shape keyframe and the animation end marker (op),
    /// so we show 2 frames before the end to land on the fully-expanded shapes.
    private func showStaticFrame(_ av: LottieAnimationView) {
        if let endFrame = av.animation?.endFrame, endFrame > 2 {
            av.currentFrame = endFrame - 2
        } else {
            av.currentProgress = 1
        }
    }

    private func applyColor(to av: LottieAnimationView, color: UIColor) {
        let provider = ColorValueProvider(color.lottieColorValue)
        av.setValueProvider(provider, keypath: AnimationKeypath(keypath: "**.Fill 1.Color"))
        av.setValueProvider(provider, keypath: AnimationKeypath(keypath: "**.Stroke 1.Color"))
    }
}
