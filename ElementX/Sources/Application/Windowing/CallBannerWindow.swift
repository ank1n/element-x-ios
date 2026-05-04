//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// STMOB-102 Phase 3 (Option C): UIWindow рисующий зелёную полосу активного звонка
/// поверх системной статусной зоны — как Telegram/WhatsApp/FaceTime.
///
/// Уровень окна: `.statusBar - 1` — iOS рисует время/батарею (status bar) ПОВЕРХ
/// нашей зелёной полосы. Сама полоса уезжает в safe area top через GeometryReader.
///
/// Содержимое прозрачно вне полосы, hit test пропускает touches к нижележащему
/// `mainWindow` — поэтому navigation bar / back button / списки остаются полностью
/// доступны. `additionalSafeAreaInsets.top` на mainWindow.rootViewController сжимает
/// контент основного приложения вниз на высоту полосы.
final class CallBannerWindow: UIWindow {
    /// STMOB-102 build 108 fix: Высота тапабельной зоны banner-а в координатах окна
    /// (status bar + banner content). Обновляется WindowManager-ом из колбека
    /// CallBannerWindowContent.onVisibilityChange. 0 когда banner скрыт.
    var tappableTopHeight: CGFloat = 0

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = UIWindow.Level.statusBar - 1
        backgroundColor = .clear
        isHidden = true
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hit-test: внутри banner zone (y < tappableTopHeight) — обрабатываем здесь
    /// (Button → onTap → restoreCallHandler). Снаружи — passthrough к mainWindow,
    /// чтобы nav bar / списки оставались интерактивными.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard tappableTopHeight > 0, point.y < tappableTopHeight else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

/// Hosting controller для CallBannerWindow — фиксирует светлый текст статус-бара
/// (белые часы/батарея на зелёном фоне).
final class CallBannerHostingController<Content: View>: UIHostingController<Content> {
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }
}

/// SwiftUI контент окна. Наблюдает за NavigationTabCoordinator через @Observable.
struct CallBannerWindowContent<Tag: Hashable>: View {
    let coordinator: NavigationTabCoordinator<Tag>
    /// Колбек: банер показан/скрыт — WindowManager использует это для
    /// `additionalSafeAreaInsets.top` на mainWindow и обновления
    /// `CallBannerWindow.tappableTopHeight` (для hitTest).
    let onVisibilityChange: (Bool) -> Void

    private var isVisible: Bool {
        coordinator.isCallMinimized
            && coordinator.overlayCoordinator != nil
            && coordinator.minimizedCallDisplayName != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible, let name = coordinator.minimizedCallDisplayName {
                CallBannerButton(displayName: name,
                                 elapsedTime: coordinator.minimizedCallElapsedTime,
                                 onTap: { coordinator.restoreCallHandler?() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        // Только banner row занимает горизонтальную полосу; ниже — пустое место,
        // которое НЕ интерактивно (window.hitTest passthrough'ит y > tappableHeight).
        // Не игнорим safe area здесь — banner естественно НИЖЕ status bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .onAppear { onVisibilityChange(isVisible) }
        .onChange(of: isVisible) { _, new in onVisibilityChange(new) }
    }
}

private struct CallBannerButton: View {
    let displayName: String
    let elapsedTime: TimeInterval
    let onTap: () -> Void

    private var timeString: String {
        let m = Int(elapsedTime) / 60
        let s = Int(elapsedTime) % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .modifier(CallBannerPulse())

                Image(systemName: "phone.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(timeString)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                Text(SL10n.actionBack)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
            }
            // Build 108: trailing 24pt — отступ от правого края (под зону компоуз-иконки).
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle()) // explicit hit shape для всей green зоны
            .background(LinearGradient(colors: [Color(red: 0.18, green: 0.8, blue: 0.44),
                                                Color(red: 0.13, green: 0.68, blue: 0.38)],
                                       startPoint: .leading,
                                       endPoint: .trailing)
                    // Зелёный фон уезжает ВВЕРХ в зону status bar — iOS рисует
                    // время/батарею белым ПОВЕРХ.
                    .ignoresSafeArea(.all, edges: .top))
        }
        .buttonStyle(.plain)
    }
}

private struct CallBannerPulse: ViewModifier {
    @State private var isPulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

/// Высота банера ниже status bar (только видимая часть, без status bar zone).
/// Используется как `additionalSafeAreaInsets.top` на mainWindow для сжатия контента.
/// Соответствует CallBannerButton.padding(.vertical, 10) * 2 + content_height (~18) ≈ 38pt.
enum CallBannerMetrics {
    static let inlineHeight: CGFloat = 38
}
