//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The screen shown at the beginning of the onboarding flow.
struct AuthenticationStartScreen: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let context: AuthenticationStartScreenViewModel.Context

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                    .frame(height: UIConstants.spacerHeight(in: geometry))

                content
                    .frame(width: geometry.size.width)
                    .accessibilityIdentifier(A11yIdentifiers.authenticationStartScreen.hidden)

                buttons
                    .frame(width: geometry.size.width)
                    .padding(.bottom, UIConstants.actionButtonBottomPadding)
                    .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? 0 : 16)
                    .padding(.top, 8)

                Spacer()
                    .frame(height: UIConstants.spacerHeight(in: geometry))
            }
            .frame(maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                versionText
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom)
                    .accessibilityIdentifier(A11yIdentifiers.authenticationStartScreen.appVersion)
            }
        }
        .navigationBarHidden(true)
        .background {
            AuthenticationStartScreenBackgroundImage()
        }
        .introspect(.window, on: .supportedVersions) { window in
            context.send(viewAction: .updateWindow(window))
        }
    }

    var content: some View {
        VStack(spacing: 0) {
            Spacer()

            if verticalSizeClass == .regular {
                Spacer()

                if context.viewState.hideBrandChrome {
                    STalkLogoWithVoiceWave()
                } else {
                    AuthenticationStartLogo(hideBrandChrome: false)
                }
            }

            Spacer()

            if context.viewState.hideBrandChrome {
                VStack(spacing: 8) {
                    Text("sTalk")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                    Text(SL10n.authTagline)
                        .font(.compound.bodyMD)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    Text(L10n.screenOnboardingWelcomeTitle)
                        .font(.compound.headingLGBold)
                        .foregroundColor(.compound.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(L10n.screenOnboardingWelcomeMessage(InfoPlistReader.main.productionAppName))
                        .font(.compound.bodyLG)
                        .foregroundColor(.compound.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.bottom)
        .padding(.horizontal, 16)
        .readableFrame()
    }

    /// The main action buttons.
    var buttons: some View {
        VStack(spacing: 16) {
            if context.viewState.showQRCodeLoginButton {
                Button { context.send(viewAction: .loginWithQR) } label: {
                    Label(L10n.screenOnboardingSignInWithQrCode, icon: \.qrCode)
                }
                .buttonStyle(.compound(.primary))
                .accessibilityIdentifier(A11yIdentifiers.authenticationStartScreen.signInWithQr)
            }

            Button { context.send(viewAction: .login) } label: {
                Text(context.viewState.loginButtonTitle)
            }
            .buttonStyle(.compound(.primary))
            .accessibilityIdentifier(A11yIdentifiers.authenticationStartScreen.signIn)

            if context.viewState.showCreateAccountButton {
                Button { context.send(viewAction: .register) } label: {
                    Text(L10n.screenCreateAccountTitle)
                }
                .buttonStyle(.compound(.tertiary))
            }
        }
        .padding(.horizontal, verticalSizeClass == .compact ? 128 : 24)
        .readableFrame()
    }

    var versionText: Text {
        let shortVersionString = ProcessInfo.isRunningTests ? "0.0.0" : InfoPlistReader.main.bundleShortVersionString
        return Text(SL10n.authVersion(shortVersionString))
    }
}

// MARK: - sTalk Logo with equalizer voice bars

/// 72 bars arranged in a circle around the logo, pulsing like an equalizer.
/// A "playback head" sweeps around, triggering bars to pulse with the amplitude
/// pattern of "Привет! Как дела? Это sTalk!" — repeating endlessly.
private struct STalkLogoWithVoiceWave: View {
    @State private var time: CGFloat = 0

    /// Speech amplitude pattern — just the phrase, no long silence at the end.
    /// "При-вет! [pause] Как де-ла? [pause] Э-то сТалк! [tiny gap]"
    private static let speechPattern: [CGFloat] = {
        var p: [CGFloat] = []
        // При (4 bars)
        p += [0.3, 0.6, 0.8, 0.7]
        // вет! (5 bars)
        p += [0.5, 0.9, 1.0, 0.85, 0.4]
        // pause (2 bars)
        p += [0.05, 0.05]
        // Как (3 bars)
        p += [0.3, 0.6, 0.5]
        // mini pause (1)
        p += [0.05]
        // де (3 bars)
        p += [0.25, 0.5, 0.4]
        // ла? (4 bars)
        p += [0.3, 0.55, 0.7, 0.5]
        // pause (2 bars)
        p += [0.03, 0.03]
        // Э (2 bars)
        p += [0.2, 0.4]
        // то (3 bars)
        p += [0.3, 0.5, 0.35]
        // mini pause (1)
        p += [0.05]
        // сТалк! (6 bars)
        p += [0.4, 0.7, 0.95, 1.0, 0.8, 0.3]
        // tiny breath gap before next repetition (2 bars)
        p += [0.08, 0.05]
        return p // ~41 slots, repeats seamlessly
    }()

    private let barCount = 72
    private let logoSize: CGFloat = 140
    private let ringRadius: CGFloat = 75
    private let barWidth: CGFloat = 3.0
    private let maxBarHeight: CGFloat = 45
    // Speed: how many pattern slots the head advances per second
    private let slotsPerSecond = 14.0

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            // Continuous head position on the circle (wraps around barCount)
            let totalSlotsTraveled = now * slotsPerSecond
            let headPos = CGFloat(totalSlotsTraveled.truncatingRemainder(dividingBy: Double(barCount)))
            // Which slot in the speech pattern the head is currently on (wraps around pattern length)
            let patternLen = Self.speechPattern.count
            let currentPatternSlot = Int(totalSlotsTraveled.truncatingRemainder(dividingBy: Double(patternLen)))

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                for i in 0..<barCount {
                    let barAngle = CGFloat(i) / CGFloat(barCount) * .pi * 2 - .pi / 2

                    // How far behind the head is this bar? (circular distance on the ring)
                    let dist = Self.circularDistance(from: CGFloat(i), to: headPos, count: CGFloat(barCount))

                    // Bar decays over ~10 bars behind the head
                    let decay: CGFloat = max(0, 1.0 - dist / 10.0)
                    guard decay > 0 else { continue }

                    // Which pattern slot was playing when the head passed this bar?
                    let slotsAgo = Int(dist)
                    var patIdx = currentPatternSlot - slotsAgo
                    while patIdx < 0 {
                        patIdx += patternLen
                    }
                    patIdx = patIdx % patternLen

                    let targetAmp = Self.speechPattern[patIdx]
                    let amplitude = targetAmp * decay

                    let barHeight = max(2, amplitude * maxBarHeight)

                    let innerR = ringRadius - 1
                    let outerR = ringRadius + barHeight

                    let x1 = center.x + innerR * cos(barAngle)
                    let y1 = center.y + innerR * sin(barAngle)
                    let x2 = center.x + outerR * cos(barAngle)
                    let y2 = center.y + outerR * sin(barAngle)

                    var path = Path()
                    path.move(to: CGPoint(x: x1, y: y1))
                    path.addLine(to: CGPoint(x: x2, y: y2))

                    let opacity = 0.15 + amplitude * 0.7
                    context.stroke(path,
                                   with: .color(Color(red: 0.2, green: 0.45, blue: 0.9).opacity(opacity)),
                                   lineWidth: barWidth)

                    // Glow for active bars
                    if amplitude > 0.3 {
                        context.stroke(path,
                                       with: .color(Color(red: 0.3, green: 0.5, blue: 1.0).opacity(amplitude * 0.3)),
                                       lineWidth: barWidth + 3)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: ringRadius * 2 + maxBarHeight * 2 + 10,
               height: ringRadius * 2 + maxBarHeight * 2 + 10)
        .overlay {
            Image(asset: Asset.Images.appLogo)
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .shadow(color: Color(red: 0.1, green: 0.3, blue: 0.7).opacity(0.3), radius: 16, y: 4)
        }
        .accessibilityHidden(true)
    }

    /// Forward distance from `a` to `b` on a circular track (how far ahead `b` is from `a`)
    private static func circularDistance(from a: CGFloat, to b: CGFloat, count: CGFloat) -> CGFloat {
        let d = (b - a).truncatingRemainder(dividingBy: count)
        return d >= 0 ? d : d + count
    }
}

// MARK: - Previews

struct AuthenticationStartScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let provisionedViewModel = makeViewModel(provisionedServerName: "example.com")

    static var previews: some View {
        AuthenticationStartScreen(context: viewModel.context)
            .previewDisplayName("Default")
        AuthenticationStartScreen(context: provisionedViewModel.context)
            .previewDisplayName("Provisioned")
    }

    static func makeViewModel(provisionedServerName: String? = nil) -> AuthenticationStartScreenViewModel {
        AuthenticationStartScreenViewModel(authenticationService: AuthenticationService.mock,
                                           provisioningParameters: provisionedServerName.map { .init(accountProvider: $0, loginHint: nil) },
                                           isBugReportServiceEnabled: true,
                                           appSettings: ServiceLocator.shared.settings,
                                           userIndicatorController: UserIndicatorControllerMock())
    }
}
