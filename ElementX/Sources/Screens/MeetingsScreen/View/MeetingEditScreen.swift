//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

typealias MeetingEditViewModelType = StateStoreViewModel<MeetingEditViewState, MeetingEditViewAction>

struct MeetingEditScreen: View {
    @ObservedObject var context: MeetingEditViewModelType.Context
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Form {
                Section("Основное") {
                    TextField("Название", text: $context.title)
                    TextField("Описание", text: $context.description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Место", text: $context.location)
                }

                Section("Время") {
                    Toggle("Бессрочная", isOn: $context.isIndefinite)

                    if !context.viewState.bindings.isIndefinite {
                        DatePicker("Начало", selection: $context.startDate)
                        DatePicker("Конец", selection: $context.endDate)
                    }
                }

                Section("Доступ") {
                    Toggle("Разрешить гостей", isOn: $context.allowGuests)
                }

                // Participants
                Section {
                    // Search field with overlay results
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Добавить участника...", text: $context.participantSearchQuery)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($isSearchFocused)
                            .onChange(of: context.participantSearchQuery) { newValue in
                                context.send(viewAction: .searchParticipants(newValue))
                            }
                        if !context.participantSearchQuery.isEmpty {
                            Button {
                                context.send(viewAction: .searchParticipants(""))
                                isSearchFocused = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Added participants (chips)
                    if !context.viewState.bindings.participants.isEmpty {
                        ForEach(context.viewState.bindings.participants) { user in
                            HStack(spacing: 8) {
                                Image(systemName: "person.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Color.accentColor)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName ?? user.userID)
                                        .font(.subheadline)
                                    if user.displayName != nil {
                                        Text(user.userID)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    context.send(viewAction: .removeParticipant(user))
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Участники (\(context.viewState.bindings.participants.count))")
                }

                if let error = context.viewState.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }

            // Floating search results overlay
            if !context.viewState.searchResults.isEmpty || context.viewState.isSearching {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 44) // offset below nav bar

                    VStack(spacing: 0) {
                        if context.viewState.isSearching {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Поиск...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(12)
                        }

                        ForEach(context.viewState.searchResults.prefix(5)) { user in
                            Button {
                                context.send(viewAction: .addParticipant(user))
                                isSearchFocused = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.displayName ?? user.userID)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        if user.displayName != nil {
                                            Text(user.userID)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                    .background(.regularMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.horizontal, 16)

                    Spacer()
                }
            }
        }
        .navigationTitle(context.viewState.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") {
                    context.send(viewAction: .cancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    context.send(viewAction: .save)
                }
                .disabled(context.title.isEmpty || context.viewState.isLoading)
            }
        }
        .disabled(context.viewState.isLoading)
        .overlay {
            if context.viewState.isLoading {
                ProgressView()
            }
        }
    }
}
