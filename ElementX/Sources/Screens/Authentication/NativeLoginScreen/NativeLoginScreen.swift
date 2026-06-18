//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

typealias NativeLoginScreenViewModelType = StateStoreViewModel<NativeLoginScreenViewState, NativeLoginScreenViewAction>

struct NativeLoginScreen: View {
    @ObservedObject var context: NativeLoginScreenViewModelType.Context
    @FocusState private var focusedField: Field?
    /// The login form is always presented in the cosmos style, even when the user has selected the
    /// classic design. The classic login variant rendered as a bare grey form (looked broken /
    /// jarring when switching to classic), so we keep a single polished login presentation.
    private var isCosmos: Bool {
        true
    }

    private let accentBlue = StalkTheme.accent
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)

    private enum Field: Hashable {
        case username, password
    }

    var body: some View {
        ZStack {
            if isCosmos {
                LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            ScrollView {
                VStack(spacing: 24) {
                    // Logo + Equalizer
                    if isCosmos {
                        cosmosLogo
                    } else {
                        classicLogo
                    }

                    // Login form
                    VStack(spacing: 16) {
                        TextField(SL10n.authUsername, text: $context.username)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                            .padding()
                            .background(isCosmos ? Color(UIColor.systemBackground) : Color(.systemGray6))
                            .cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(isCosmos ? accentBlue.opacity(0.15) : Color.clear, lineWidth: 1))

                        SecureField(SL10n.authPassword, text: $context.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { loginIfValid() }
                            .padding()
                            .background(isCosmos ? Color(UIColor.systemBackground) : Color(.systemGray6))
                            .cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(isCosmos ? accentBlue.opacity(0.15) : Color.clear, lineWidth: 1))
                    }

                    // Login button
                    if isCosmos {
                        Button {
                            loginIfValid()
                        } label: {
                            if context.viewState.isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            } else {
                                Text(SL10n.authLogin)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                        }
                        .background(isFormValid && !context.viewState.isLoading ? accentBlue : accentBlue.opacity(0.4))
                        .cornerRadius(14)
                        .shadow(color: accentBlue.opacity(0.3), radius: 8, y: 4)
                        .disabled(!isFormValid || context.viewState.isLoading)
                    } else {
                        Button {
                            loginIfValid()
                        } label: {
                            if context.viewState.isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Text(SL10n.authLogin)
                                    .font(.body.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isFormValid || context.viewState.isLoading)
                        .cornerRadius(12)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(SL10n.actionCancel) {
                    context.send(viewAction: .cancel)
                }
            }
        }
        .alert(item: $context.alertInfo) { alertInfo in
            Alert(title: Text(alertInfo.title),
                  message: alertInfo.message.map { Text($0) },
                  dismissButton: .default(Text("OK")))
        }
        .interactiveDismissDisabled(context.viewState.isLoading)
        .onAppear {
            focusedField = .username
        }
    }

    // MARK: - Logo variants

    private var classicLogo: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("sTalk")
                .font(.title.bold())
            Text(SL10n.authLoginTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
        .padding(.bottom, 16)
    }

    private var cosmosLogo: some View {
        VStack(spacing: 6) {
            // sTalk title — "s" black, "Talk" gradient
            HStack(spacing: 0) {
                Text("s")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.primary)
                Text("Talk")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [accentBlue, Color(red: 0.55, green: 0.36, blue: 0.96)],
                                                    startPoint: .leading, endPoint: .trailing))
            }

            // Equalizer animation
            EqualizerView(accentColor: accentBlue)
                .frame(height: 28)
                .padding(.horizontal, 50)

            Text(SL10n.authLoginTitle)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(.top, 48)
        .padding(.bottom, 12)
    }

    private var isFormValid: Bool {
        !context.username.trimmingCharacters(in: .whitespaces).isEmpty &&
            !context.password.isEmpty
    }

    private func loginIfValid() {
        guard isFormValid else { return }
        context.send(viewAction: .login)
    }
}

// MARK: - Equalizer Animation

private struct EqualizerView: View {
    let accentColor: Color
    private let barCount = 7
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                EqualizerBar(accentColor: accentColor,
                             index: index,
                             animating: animating)
            }
        }
        .onAppear { animating = true }
    }
}

private struct EqualizerBar: View {
    let accentColor: Color
    let index: Int
    let animating: Bool

    /// Each bar gets its own random-ish min/max heights and speed
    private var minHeight: CGFloat {
        [3, 4, 2, 5, 3, 4, 2][index % 7]
    }

    private var maxHeight: CGFloat {
        [18, 24, 14, 22, 20, 16, 12][index % 7]
    }

    private var duration: Double {
        [0.45, 0.55, 0.4, 0.5, 0.48, 0.42, 0.52][index % 7]
    }

    private var delay: Double {
        Double(index) * 0.07
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(colors: [accentColor, accentColor.opacity(0.4)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 4, height: animating ? maxHeight : minHeight)
            .animation(animating
                ? .easeInOut(duration: duration)
                .repeatForever(autoreverses: true)
                .delay(delay)
                : .default,
                value: animating)
    }
}
