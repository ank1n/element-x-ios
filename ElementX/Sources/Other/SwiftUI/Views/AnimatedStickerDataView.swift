// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import ImageIO
import SwiftUI

/// ImageIO decodes WebP frames on demand: no array of full-size animation frames in memory.
struct AnimatedStickerDataView: UIViewRepresentable {
    let data: Data
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> StickerAnimationImageView {
        let view = StickerAnimationImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: StickerAnimationImageView, context: Context) {
        view.configure(data: data, animate: !reduceMotion && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    static func dismantleUIView(_ view: StickerAnimationImageView, coordinator: ()) {
        view.stop()
    }
}

final class StickerAnimationImageView: UIImageView {
    private var source: CGImageSource?
    private var data: Data?
    private var link: CADisplayLink?
    private var index = 0
    private var deadline: CFTimeInterval = 0
    private var animate = false

    private final class TickTarget {
        weak var view: StickerAnimationImageView?
        init(_ view: StickerAnimationImageView) {
            self.view = view
        }

        @objc func tick(_ link: CADisplayLink) {
            view?.tick(link)
        }
    }

    func configure(data: Data, animate: Bool) {
        if self.data != data {
            stop()
            self.data = data
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            index = 0
            drawFrame()
        }
        self.animate = animate
        updatePlayback()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    func stop() {
        link?.invalidate()
        link = nil
        deadline = 0
    }

    private func updatePlayback() {
        guard animate, window != nil, let source, CGImageSourceGetCount(source) > 1 else { stop(); return }
        guard link == nil else { return }
        let link = CADisplayLink(target: TickTarget(self), selector: #selector(TickTarget.tick(_:)))
        link.preferredFrameRateRange = .init(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func tick(_ link: CADisplayLink) {
        guard let source, link.timestamp >= deadline else { return }
        index = (index + 1) % CGImageSourceGetCount(source)
        drawFrame()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        let webp = properties?[kCGImagePropertyWebPDictionary as String] as? [String: Any]
        let delay = (webp?[kCGImagePropertyWebPUnclampedDelayTime as String] as? Double) ??
            (webp?[kCGImagePropertyWebPDelayTime as String] as? Double) ?? 0.1
        deadline = link.timestamp + max(1.0 / 30, delay)
    }

    private func drawFrame() {
        guard let source else { return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return }
        image = UIImage(cgImage: frame)
    }
}
