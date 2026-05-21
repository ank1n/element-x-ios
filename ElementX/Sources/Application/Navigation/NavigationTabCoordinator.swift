//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Class responsible for displaying an arbitrary number of coordinators within the tab bar.
@Observable class NavigationTabCoordinator<Tag: Hashable>: CoordinatorProtocol, CustomStringConvertible {
    struct Tab {
        let coordinator: CoordinatorProtocol
        let details: TabDetails
        var dismissalCallback: (() -> Void)?
    }
    
    @MainActor
    @Observable class TabDetails {
        /// A unique tab that identifies the tab for selection.
        let tag: Tag
        let title: String
        let icon: KeyPath<CompoundIcons, Image>
        let selectedIcon: KeyPath<CompoundIcons, Image>
        /// SF Symbol name for tab icon (outline style)
        let sfSymbol: String?
        /// SF Symbol name for selected tab icon (filled style)
        let sfSymbolSelected: String?
        /// Lottie animation name (from StalkIcons bundle)
        let lottieAnimation: String?
        var badgeCount = 0
        var barVisibilityOverride: Visibility?

        /// Provide the tab's split coordinator in here to have the tab bar automatically hidden
        /// when pushing a child into the split view's details on iPhone/compact iPad.
        weak var navigationSplitCoordinator: NavigationSplitCoordinator?

        init(tag: Tag, title: String, icon: KeyPath<CompoundIcons, Image>, selectedIcon: KeyPath<CompoundIcons, Image>,
             sfSymbol: String? = nil, sfSymbolSelected: String? = nil, lottieAnimation: String? = nil) {
            self.tag = tag
            self.title = title
            self.icon = icon
            self.selectedIcon = selectedIcon
            self.sfSymbol = sfSymbol
            self.sfSymbolSelected = sfSymbolSelected
            self.lottieAnimation = lottieAnimation
        }
        
        func barVisibility(in horizontalSizeClass: UserInterfaceSizeClass?) -> Visibility {
            if let barVisibilityOverride {
                return barVisibilityOverride
            } else if horizontalSizeClass == .compact, navigationSplitCoordinator?.detailCoordinator != nil {
                // Whilst we support pushing screens on the stack in the sidebarCoordinator, in practice
                // we never do that, so simply checking that the detailCoordinator exists is enough.
                return .hidden
            } else {
                return .automatic
            }
        }
    }
    
    // MARK: Tabs
    
    fileprivate struct TabModule: Identifiable {
        let module: NavigationModule
        let details: TabDetails
        
        var id: ObjectIdentifier {
            module.id
        }

        @MainActor var coordinator: CoordinatorProtocol? {
            module.coordinator
        }
    }
    
    fileprivate var tabModules = [TabModule]() {
        didSet {
            let diffs = tabModules.map(\.module).difference(from: oldValue.map(\.module))
            diffs.forEach { change in
                switch change {
                case .insert(_, let module, _):
                    logPresentationChange("Set tab", module)
                    module.coordinator?.start()
                case .remove(_, let module, _):
                    logPresentationChange("Remove tab", module)
                    module.tearDown()
                }
            }
        }
    }
    
    /// The current set of coordinators displayed by the tabs.
    var tabCoordinators: [any CoordinatorProtocol] {
        tabModules.compactMap(\.module.coordinator)
    }
    
    /// Updates the displayed tabs with the provided array.
    func setTabs(_ tabs: [Tab], animated: Bool = true) {
        var transaction = Transaction()
        transaction.disablesAnimations = !animated

        withTransaction(transaction) {
            tabModules = tabs.map { TabModule(module: .init($0.coordinator, dismissalCallback: $0.dismissalCallback), details: $0.details) }
        }

        selectedTab = tabModules.first?.details.tag
    }
    
    /// The currently selected tab's tag.
    var selectedTab: Tag?
    
    // MARK: Sheets
    
    fileprivate var sheetModule: NavigationModule? {
        didSet {
            if let oldValue {
                logPresentationChange("Remove sheet", oldValue)
                oldValue.tearDown()
            }
            
            if let sheetModule {
                logPresentationChange("Set sheet", sheetModule)
                sheetModule.coordinator?.start()
            }
        }
    }
    
    var presentationDetents: Set<PresentationDetent> = []
    
    /// The currently presented sheet coordinator.
    var sheetCoordinator: (any CoordinatorProtocol)? {
        sheetModule?.coordinator
    }
    
    // Present a sheet on top of the stack. If this NavigationStackCoordinator is embedded within a NavigationSplitCoordinator
    // then the presentation will be proxied to the split
    // - Parameters:
    //   - coordinator: the coordinator to display
    //   - animated: whether to animate the transition or not. Default is true

    ///   - dismissalCallback: called when the sheet has been dismissed, programatically or otherwise
    func setSheetCoordinator(_ coordinator: (any CoordinatorProtocol)?, animated: Bool = true, dismissalCallback: (() -> Void)? = nil) {
        guard let coordinator else {
            sheetModule = nil
            return
        }
        
        if sheetModule?.coordinator === coordinator {
            fatalError("Cannot use the same coordinator more than once")
        }

        var transaction = Transaction()
        transaction.disablesAnimations = !animated

        withTransaction(transaction) {
            sheetModule = NavigationModule(coordinator, dismissalCallback: dismissalCallback)
        }
    }
    
    // MARK: Full Screen Cover
    
    fileprivate var fullScreenCoverModule: NavigationModule? {
        didSet {
            if let oldValue {
                logPresentationChange("Remove fullscreen cover", oldValue)
                oldValue.tearDown()
            }
            
            if let fullScreenCoverModule {
                logPresentationChange("Set fullscreen cover", fullScreenCoverModule)
                fullScreenCoverModule.coordinator?.start()
            }
        }
    }
    
    /// The currently presented fullscreen cover coordinator
    /// Fullscreen covers will be presented through the NavigationSplitCoordinator if provided
    var fullScreenCoverCoordinator: (any CoordinatorProtocol)? {
        fullScreenCoverModule?.coordinator
    }
    
    /// Present a fullscreen cover on top of the stack. If this NavigationStackCoordinator is embedded within a NavigationSplitCoordinator
    /// then the presentation will be proxied to the split
    /// - Parameters:
    ///   - coordinator: the coordinator to display
    ///   - animated: whether to animate the transition or not. Default is true
    ///   - dismissalCallback: called when the fullscreen cover has been dismissed, programatically or otherwise
    func setFullScreenCoverCoordinator(_ coordinator: (any CoordinatorProtocol)?, animated: Bool = true, dismissalCallback: (() -> Void)? = nil) {
        guard let coordinator else {
            fullScreenCoverModule = nil
            return
        }
        
        if fullScreenCoverModule?.coordinator === coordinator {
            fatalError("Cannot use the same coordinator more than once")
        }

        var transaction = Transaction()
        transaction.disablesAnimations = !animated

        withTransaction(transaction) {
            fullScreenCoverModule = NavigationModule(coordinator, dismissalCallback: dismissalCallback)
        }
    }
    
    // MARK: - Overlay
    
    fileprivate var overlayModule: NavigationModule? {
        didSet {
            if let oldValue {
                logPresentationChange("Remove overlay", oldValue)
                oldValue.tearDown()
            }
            
            if let overlayModule {
                logPresentationChange("Set overlay", overlayModule)
                overlayModule.coordinator?.start()
            }
        }
    }
    
    /// The currently displayed overlay coordinator
    var overlayCoordinator: (any CoordinatorProtocol)? {
        overlayModule?.coordinator
    }
    
    enum OverlayPresentationMode { case fullScreen, minimized }
    fileprivate var overlayPresentationMode: OverlayPresentationMode = .minimized

    /// sTalk: Display name shown in the minimized call indicator
    var minimizedCallDisplayName: String?

    /// sTalk: Explicitly tracks whether a call is minimized (shown as floating bar)
    var isCallMinimized = false

    /// sTalk: Elapsed time for minimized call banner
    var minimizedCallElapsedTime: TimeInterval = 0

    /// sTalk: Callback to restore call from minimized state
    var restoreCallHandler: (() -> Void)?
    
    /// Present an overlay on top of the tab view
    /// - Parameters:
    ///   - coordinator: the coordinator to display
    ///   - presentationMode: how the coordinator should be presented
    ///   - animated: whether the transition should be animated
    ///   - dismissalCallback: called when the overlay has been dismissed, programatically or otherwise
    func setOverlayCoordinator(_ coordinator: (any CoordinatorProtocol)?,
                               presentationMode: OverlayPresentationMode = .fullScreen,
                               animated: Bool = true,
                               dismissalCallback: (() -> Void)? = nil) {
        // sTalk: Always tear down the old overlay coordinator before replacing.
        // This ensures stop() → hangup() → tearDownCallSession() is called,
        // properly ending the MatrixRTC session.
        overlayModule?.tearDown()

        guard let coordinator else {
            overlayModule = nil
            isCallMinimized = false
            return
        }

        if overlayModule?.coordinator === coordinator {
            fatalError("Cannot use the same coordinator more than once")
        }

        var transaction = Transaction()
        transaction.disablesAnimations = !animated

        withTransaction(transaction) {
            overlayPresentationMode = presentationMode
            overlayModule = NavigationModule(coordinator, dismissalCallback: dismissalCallback)
        }
    }
    
    /// Updates the presentation of the overlay coordinator.
    /// - Parameters:
    ///   - mode: The type of presentation to use.
    ///   - animated: whether the transition should be animated
    func setOverlayPresentationMode(_ mode: OverlayPresentationMode, animated: Bool = true) {
        var transaction = Transaction()
        transaction.disablesAnimations = !animated

        withTransaction(transaction) {
            overlayPresentationMode = mode
            isCallMinimized = (mode == .minimized)
        }
    }
    
    // MARK: - CoordinatorProtocol
    
    /// No idea if this is particuarly needed for the TabView but we do this for the NavigationStackCoordinator and NavigationSplitCoordinator so it
    /// doesn't seem to harm to also do it here.
    func stop() {
        tabModules.forEach { $0.module.tearDown() }
    }
    
    func toPresentable() -> AnyView {
        AnyView(NavigationTabCoordinatorView(navigationTabCoordinator: self))
    }
    
    // MARK: - CustomStringConvertible
    
    var description: String {
        guard !tabModules.isEmpty else { return "NavigationTabCoordinator(Empty)" }
        return "NavigationTabCoordinator(\(tabCoordinators)"
    }
    
    // MARK: - Private
    
    private func logPresentationChange(_ change: String, _ module: NavigationModule) {
        if let coordinator = module.coordinator {
            MXLog.info("\(self) \(change): \(coordinator)")
        }
    }
}

private struct NavigationTabCoordinatorView<Tag: Hashable>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Bindable var navigationTabCoordinator: NavigationTabCoordinator<Tag>

    @State private var standardAppearance = UITabBarAppearance()
    @State private var selectedIndex = 0

    /// Whether any tab has a Lottie/SF Symbol icon configured (use custom Stalk tab bar)
    private var useCustomTabBar: Bool {
        navigationTabCoordinator.tabModules.contains { $0.details.sfSymbol != nil }
    }

    var body: some View {
        if useCustomTabBar {
            lottieTabBarBody
        } else {
            standardTabBarBody
        }
    }

    // MARK: - Lottie Tab Bar (Stalk-style)

    @AppStorage("stalk_search_active") private var isSearchActive = false

    /// Whether the tab bar should be hidden (e.g. when viewing a room detail on compact layout, or search is active)
    private var shouldHideTabBar: Bool {
        if isSearchActive { return true }
        guard selectedIndex < navigationTabCoordinator.tabModules.count else { return false }
        let details = navigationTabCoordinator.tabModules[selectedIndex].details
        return details.barVisibility(in: horizontalSizeClass) == .hidden
    }

    private var lottieTabBarBody: some View {
        ZStack(alignment: .bottom) {
            // Content area — extends behind tab bar
            ZStack {
                ForEach(navigationTabCoordinator.tabModules.indices, id: \.self) { index in
                    let module = navigationTabCoordinator.tabModules[index]
                    module.coordinator?.toPresentable()
                        .id(module.id)
                        .opacity(selectedIndex == index ? 1 : 0)
                        .allowsHitTesting(selectedIndex == index)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom Lottie Tab Bar — overlays content, hidden when inside a room
            if !shouldHideTabBar {
                StalkTabBar(items: navigationTabCoordinator.tabModules.map { module in
                    StalkTabItem(id: "\(module.details.tag)",
                                 title: module.details.title,
                                 sfSymbol: module.details.sfSymbol,
                                 sfSymbolSelected: module.details.sfSymbolSelected,
                                 lottieAnimation: module.details.lottieAnimation,
                                 badgeCount: module.details.badgeCount)
                },
                selectedIndex: $selectedIndex)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldHideTabBar)
        .onAppear {
            // sTalk: sync initial selectedIndex с selectedTab. Иначе @State default = 0
            // показывает первый tab (Contacts) даже если NavigationTabCoordinator
            // явно установил selectedTab = .chats — onChange срабатывает только
            // после реального изменения, не на начальном render.
            if let selected = navigationTabCoordinator.selectedTab,
               let index = navigationTabCoordinator.tabModules.firstIndex(where: { $0.details.tag == selected }),
               selectedIndex != index {
                selectedIndex = index
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            guard newValue < navigationTabCoordinator.tabModules.count else { return }
            navigationTabCoordinator.selectedTab = navigationTabCoordinator.tabModules[newValue].details.tag
        }
        .onChange(of: navigationTabCoordinator.selectedTab) { _, newValue in
            guard let newValue,
                  let index = navigationTabCoordinator.tabModules.firstIndex(where: { $0.details.tag == newValue }) else { return }
            if selectedIndex != index {
                selectedIndex = index
            }
        }
        .sheet(item: $navigationTabCoordinator.sheetModule) { module in
            module.coordinator?.toPresentable()
                .id(module.id)
        }
        .fullScreenCover(item: $navigationTabCoordinator.fullScreenCoverModule) { module in
            module.coordinator?.toPresentable()
                .id(module.id)
        }
        .accessibilityHidden(navigationTabCoordinator.overlayModule?.coordinator != nil && navigationTabCoordinator.overlayPresentationMode == .fullScreen)
        .overlay {
            // sTalk: Single coordinator.toPresentable() call to prevent WKWebView recreation.
            // When minimized, shrink to mini window; when fullscreen, fill the screen.
            // STMOB-102 Phase 3: зелёная полоса звонка теперь в CallBannerWindow (over status bar),
            // здесь — только mini floating video окно.
            if let coordinator = navigationTabCoordinator.overlayModule?.coordinator {
                callOverlay(coordinator: coordinator)
            }
        }
        .animation(.elementDefault, value: navigationTabCoordinator.overlayModule)
        .animation(.easeInOut(duration: 0.25), value: navigationTabCoordinator.isCallMinimized)
    }

    // MARK: - Standard Tab Bar (fallback)

    private var standardTabBarBody: some View {
        TabView(selection: $navigationTabCoordinator.selectedTab) {
            ForEach(navigationTabCoordinator.tabModules) { module in
                module.coordinator?.toPresentable()
                    .id(module.id)
                    .tabItem {
                        Label {
                            Text(module.details.title)
                        } icon: {
                            CompoundIcon(module.details.tag == navigationTabCoordinator.selectedTab ? module.details.selectedIcon : module.details.icon)
                        }
                    }
                    .tag(module.details.tag)
                    .badge(module.details.badgeCount)
                    .toolbar(module.details.barVisibility(in: horizontalSizeClass), for: .tabBar)
            }
        }
        .backportTabBarMinimizeBehaviorOnScrollDown()
        .introspect(.tabView, on: .supportedVersions, customize: configureAppearance)
        .sheet(item: $navigationTabCoordinator.sheetModule) { module in
            module.coordinator?.toPresentable()
                .id(module.id)
        }
        .fullScreenCover(item: $navigationTabCoordinator.fullScreenCoverModule) { module in
            module.coordinator?.toPresentable()
                .id(module.id)
        }
        .accessibilityHidden(navigationTabCoordinator.overlayModule?.coordinator != nil && navigationTabCoordinator.overlayPresentationMode == .fullScreen)
        .overlay {
            // sTalk: Single coordinator.toPresentable() call to prevent WKWebView recreation
            // STMOB-102 Phase 3: banner moved to CallBannerWindow.
            if let coordinator = navigationTabCoordinator.overlayModule?.coordinator {
                callOverlay(coordinator: coordinator)
            }
        }
        .animation(.elementDefault, value: navigationTabCoordinator.overlayModule)
        .animation(.easeInOut(duration: 0.25), value: navigationTabCoordinator.isCallMinimized)
    }

    // MARK: - sTalk Call Overlay (shared between both tab bar modes)

    /// Single-instance call overlay that switches between fullscreen and mini-window
    /// without recreating the WKWebView (structural identity preserved).
    /// STMOB-102 Phase 3: зелёная полоса звонка живёт в CallBannerWindow (отдельный
    /// UIWindow поверх status bar) — здесь только mini floating видео-окно
    /// в свободно перетаскиваемой позиции.
    @ViewBuilder
    private func callOverlay(coordinator: any CoordinatorProtocol) -> some View {
        let minimized = navigationTabCoordinator.isCallMinimized
        if minimized {
            // Mini floating video окно — banner отдельно в CallBannerWindow.
            GeometryReader { geometry in
                coordinator.toPresentable()
                    .frame(width: 140, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .position(x: geometry.size.width - 82 + miniCallOffset.width,
                              y: geometry.size.height - 190 + miniCallOffset.height)
                    .gesture(DragGesture()
                        .onChanged { value in
                            miniCallDragOffset = value.translation
                        }
                        .onEnded { value in
                            miniCallOffset.width += value.translation.width
                            miniCallOffset.height += value.translation.height
                            miniCallDragOffset = .zero
                        })
                    .offset(miniCallDragOffset)
            }
        } else {
            // Fullscreen — no GeometryReader/position, just fill entire screen
            coordinator.toPresentable()
                .ignoresSafeArea()
        }
    }

    @State private var miniCallOffset: CGSize = .zero
    @State private var miniCallDragOffset: CGSize = .zero

    private func configureAppearance(_ tabBarController: UITabBarController) {
        standardAppearance.configureWithDefaultBackground()
        standardAppearance.stackedLayoutAppearance.normal.badgeBackgroundColor = .compound.iconAccentPrimary
        standardAppearance.compactInlineLayoutAppearance.normal.badgeBackgroundColor = .compound.iconAccentPrimary
        standardAppearance.inlineLayoutAppearance.normal.badgeBackgroundColor = .compound.iconAccentPrimary
        tabBarController.tabBar.standardAppearance = standardAppearance
    }
}

// STMOB-102 Phase 3: ActiveCallBanner перенесён в CallBannerWindow.swift —
// теперь рисуется в отдельном UIWindow поверх status bar (Telegram/WhatsApp pattern).
