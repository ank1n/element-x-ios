//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

class WindowManager: SecureWindowManagerProtocol {
    private let appDelegate: AppDelegate
    weak var windowScene: UIWindowScene?
    weak var delegate: SecureWindowManagerDelegate?
    
    private(set) var mainWindow: UIWindow!
    private(set) var overlayWindow: UIWindow!
    private(set) var globalSearchWindow: UIWindow!
    private(set) var alternateWindow: UIWindow!
    /// STMOB-102 Phase 3: window для зелёной полосы активного звонка
    /// (Telegram/WhatsApp-style native pattern).
    private(set) var callBannerWindow: CallBannerWindow!

    var windows: [UIWindow] {
        [mainWindow, overlayWindow, globalSearchWindow, alternateWindow, callBannerWindow]
    }
    
    // periphery:ignore - auto cancels when reassigned
    /// The task used to switch windows, so that we don't get stuck in the wrong state with a quick switch.
    @CancellableTask private var switchTask: Task<Void, Error>?
    /// A duration that allows window switching to wait a couple of frames to avoid a transition through black.
    private let windowHideDelay = Duration.milliseconds(33)
    
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }
    
    func configure(with windowScene: UIWindowScene) {
        self.windowScene = windowScene
        mainWindow = windowScene.keyWindow
        mainWindow.tintColor = .compound.textActionPrimary
        
        overlayWindow = PassthroughWindow(windowScene: windowScene)
        overlayWindow.tintColor = .compound.textActionPrimary
        overlayWindow.backgroundColor = .clear
        overlayWindow.isHidden = false
        
        globalSearchWindow = UIWindow(windowScene: windowScene)
        globalSearchWindow.tintColor = .compound.textActionPrimary
        globalSearchWindow.backgroundColor = .clear
        globalSearchWindow.isHidden = true
        
        alternateWindow = UIWindow(windowScene: windowScene)
        alternateWindow.tintColor = .compound.textActionPrimary

        callBannerWindow = CallBannerWindow(windowScene: windowScene)

        delegate?.windowManagerDidConfigureWindows(self)
    }

    // MARK: - STMOB-102 Phase 3: Call banner window

    private var bannerHostingController: UIViewController?

    func installCallBanner<Tag: Hashable>(coordinator: NavigationTabCoordinator<Tag>) {
        // Re-install: tear down предыдущий host если был
        uninstallCallBanner()

        let content = CallBannerWindowContent(coordinator: coordinator) { [weak self] visible in
            guard let self else { return }
            // Анимированно сжимаем mainWindow контент вниз на высоту полосы.
            UIView.animate(withDuration: 0.25) {
                self.mainWindow.rootViewController?.additionalSafeAreaInsets.top = visible ? CallBannerMetrics.inlineHeight : 0
                self.mainWindow.rootViewController?.view.setNeedsLayout()
            }
            // Build 108: hit-test gating. tappableHeight = status bar + banner content (БЕЗ gap),
            // чтобы вся зелёная зона (включая под status bar где время/батарея) кликалась,
            // а пробел ниже banner — passthrough к nav bar.
            let safeTop = self.callBannerWindow.safeAreaInsets.top
            self.callBannerWindow.tappableTopHeight = visible ? (safeTop + CallBannerMetrics.bannerContentHeight) : 0
        }
        let host = CallBannerHostingController(rootView: content)
        host.view.backgroundColor = .clear
        callBannerWindow.rootViewController = host
        callBannerWindow.isHidden = false
        bannerHostingController = host
    }

    func uninstallCallBanner() {
        callBannerWindow?.isHidden = true
        callBannerWindow?.rootViewController = nil
        bannerHostingController = nil
        // Reset additional inset на mainWindow
        mainWindow?.rootViewController?.additionalSafeAreaInsets.top = 0
    }
    
    func switchToMain() {
        mainWindow.isHidden = false
        overlayWindow.isHidden = false
        
        mainWindow.makeKey()
        
        switchTask = Task {
            // Delay hiding to make sure the main windows are visible.
            try await Task.sleep(for: windowHideDelay)
            
            alternateWindow.isHidden = true
        }
    }
    
    func switchToAlternate() {
        alternateWindow.isHidden = false
        
        // We don't know what route the app will use when returning back
        // to the main window, so end any editing operation now to avoid
        // e.g. the keyboard being displayed on top of a call sheet.
        mainWindow.endEditing(true)
        
        hideGlobalSearch()
        
        // alternateWindow.isHidden = false cannot got inside the Task otherwise the timing
        // is poor when you lock the phone - you briefly see the main window for a few
        // frames after you've unlocked the phone and then the placeholder animates in.
        switchTask = Task {
            // Delay hiding to make sure the alternate window is visible.
            try await Task.sleep(for: windowHideDelay)
            
            mainWindow.isHidden = true
            overlayWindow.isHidden = true
            globalSearchWindow.isHidden = true
        }
    }
    
    func showGlobalSearch() {
        guard alternateWindow.isHidden else {
            return
        }
        
        globalSearchWindow.isHidden = false
        globalSearchWindow.makeKey()
    }
    
    func hideGlobalSearch() {
        guard alternateWindow.isHidden else {
            return
        }
        
        globalSearchWindow.isHidden = true
        mainWindow.makeKey()
    }
    
    func setOrientation(_ orientation: UIInterfaceOrientationMask) {
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }
    
    func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        appDelegate.orientationLock = orientation
    }
}

private class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else {
            return nil
        }
        
        guard let rootViewController else {
            return nil
        }
        
        guard hitView != self else {
            return nil
        }
        
        // If the returned view is the `UIHostingController`'s view, ignore.
        return rootViewController.view == hitView ? nil : hitView
    }
}
