//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// Shared gesture state, including cancellation and permissions changing mid-swipe.
struct SwipeReplyActionState {
    static let threshold: CGFloat = 56
    private(set) var offset: CGFloat = 0

    mutating func update(_ translation: CGSize, enabled: Bool) -> Bool {
        let wasReady = offset >= Self.threshold
        guard enabled, -translation.width > abs(translation.height) else {
            offset = 0
            return false
        }
        let width = max(0, -translation.width)
        offset = width <= 100 ? width : 100 + sqrt(width - 100)
        return !wasReady && offset >= Self.threshold
    }

    mutating func finish(cancelled: Bool, enabled: Bool) -> Bool {
        defer { offset = 0 }
        return !cancelled && enabled && offset >= Self.threshold
    }
}

struct SwipeReplyAction: ViewModifier {
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    @State private var swipe = SwipeReplyActionState()
    let shouldStartAction: () -> Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .offset(x: -swipe.offset)
            .animation(.interactiveSpring(), value: swipe.offset)
            .gesture(HorizontalPanGesture(shouldBegin: shouldStartAction, allowsLeftward: true, allowsRightward: false) { gesture in
                switch gesture.state {
                case .ended:
                    if swipe.finish(cancelled: false, enabled: shouldStartAction()) { action() }
                case .cancelled, .failed:
                    _ = swipe.finish(cancelled: true, enabled: false)
                case .began, .changed:
                    if gesture.state == .began { feedbackGenerator.prepare() }
                    let translation = gesture.translation(in: gesture.view)
                    if swipe.update(CGSize(width: translation.x, height: translation.y), enabled: shouldStartAction()) {
                        feedbackGenerator.impactOccurred()
                    }
                default: break
                }
            })
    }
}

extension View {
    func swipeReplyAction(shouldStartAction: @escaping () -> Bool,
                          action: @escaping () -> Void) -> some View {
        modifier(SwipeReplyAction(shouldStartAction: shouldStartAction, action: action))
    }
}

struct SwipeRightAction_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        Preview()
    }
    
    struct Preview: View {
        @State private var isPresentingSheet = false
        
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This is a message from somebody with a couple of lines of text.")
                            .bubbleBackground()
                            .swipeReplyAction(shouldStartAction: {
                                true
                            }) {
                                isPresentingSheet = true
                            }
                    }
                    .padding()
                }
                .navigationTitle("Work chat")
                .navigationBarTitleDisplayMode(.inline)
            }
            .sheet(isPresented: $isPresentingSheet) {
                Text("Action triggered!")
                    .presentationDetents([.medium])
            }
        }
    }
}

/// Fixes the issue on iOS 18 where DragGesture conflicts with the scroll view
/// https://github.com/feedback-assistant/reports/issues/542#issuecomment-2581322968
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var shouldBegin: () -> Bool
    var allowsLeftward = false
    var allowsRightward = true
    var handle: (UIPanGestureRecognizer) -> Void
    
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        .init(shouldBegin: shouldBegin, allowsLeftward: allowsLeftward, allowsRightward: allowsRightward)
    }
    
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.delegate = context.coordinator
        gesture.isEnabled = true
        gesture.cancelsTouchesInView = false
        return gesture
    }
    
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.allowsLeftward = allowsLeftward
        context.coordinator.allowsRightward = allowsRightward
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        handle(recognizer)
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: () -> Bool
        var allowsLeftward: Bool
        var allowsRightward: Bool

        init(shouldBegin: @escaping () -> Bool, allowsLeftward: Bool, allowsRightward: Bool = true) {
            self.shouldBegin = shouldBegin
            self.allowsLeftward = allowsLeftward
            self.allowsRightward = allowsRightward
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }
        
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else { return false }

            let velocity = panRecognizer.velocity(in: gestureRecognizer.view)
            return shouldBegin() && abs(velocity.x) > abs(velocity.y) && ((allowsLeftward && velocity.x < 0) || (allowsRightward && velocity.x > 0))
        }
    }
}
