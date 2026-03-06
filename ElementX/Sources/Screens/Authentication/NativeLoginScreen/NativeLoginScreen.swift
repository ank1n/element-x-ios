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

    private enum Field: Hashable {
        case username, password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Logo
                VStack(spacing: 12) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    Text("sTalk")
                        .font(.title.bold())
                    Text("Вход в аккаунт")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                .padding(.bottom, 16)

                // Login form
                VStack(spacing: 16) {
                    TextField("Имя пользователя", text: $context.username)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)

                    SecureField("Пароль", text: $context.password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { loginIfValid() }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }

                // Login button
                Button {
                    loginIfValid()
                } label: {
                    if context.viewState.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Text("Войти")
                            .font(.body.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid || context.viewState.isLoading)
                .cornerRadius(12)

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") {
                    context.send(viewAction: .cancel)
                }
            }
        }
        .alert(item: $context.alertInfo) { alertInfo in
            Alert(
                title: Text(alertInfo.title),
                message: alertInfo.message.map { Text($0) },
                dismissButton: .default(Text("OK"))
            )
        }
        .interactiveDismissDisabled(context.viewState.isLoading)
        .onAppear {
            focusedField = .username
        }
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
