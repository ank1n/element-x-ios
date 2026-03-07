//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UIKit

typealias MeetingEditViewModelType = StateStoreViewModel<MeetingEditViewState, MeetingEditViewAction>

struct MeetingEditScreen: View {
    @ObservedObject var context: MeetingEditViewModelType.Context
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title, description, location, participantSearch
    }

    // Colors matching calendar screens
    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            LinearGradient(
                colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Main info card
                    mainInfoCard

                    // Date & Time card
                    dateTimeCard

                    // Access card
                    accessCard

                    // Participants card
                    participantsCard

                    // Error
                    if let error = context.viewState.errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }

        }
        .navigationTitle(context.viewState.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") {
                    context.send(viewAction: .cancel)
                }
                .foregroundColor(.secondary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    context.send(viewAction: .save)
                } label: {
                    Text("Сохранить")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(context.title.isEmpty ? .secondary : accentBlue)
                }
                .disabled(context.title.isEmpty || context.viewState.isLoading)
            }
        }
        .disabled(context.viewState.isLoading)
        .overlay {
            if context.viewState.isLoading {
                Color.black.opacity(0.1)
                    .ignoresSafeArea()
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(accentBlue)
            }
        }
    }

    // MARK: - Main Info Card

    private var mainInfoCard: some View {
        VStack(spacing: 0) {
            cardField(
                icon: "pencil.line",
                placeholder: "Название встречи",
                text: $context.title,
                field: .title
            )

            Divider().padding(.leading, 48)

            cardFieldMultiline(
                icon: "text.alignleft",
                placeholder: "Описание",
                text: $context.description
            )

            Divider().padding(.leading, 48)

            cardField(
                icon: "mappin",
                placeholder: "Место или ссылка",
                text: $context.location,
                field: .location
            )
        }
        .background(cardBg)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    @ViewBuilder
    private func cardField(icon: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(accentBlue)
                .frame(width: 24)

            TextField(placeholder, text: text)
                .font(.system(size: 15))
                .focused($focusedField, equals: field)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func cardFieldMultiline(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(accentBlue)
                .frame(width: 24)
                .padding(.top, 2)

            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(2...5)
                .focused($focusedField, equals: .description)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Date & Time Card

    private var dateTimeCard: some View {
        VStack(spacing: 0) {
            // Indefinite toggle
            HStack(spacing: 12) {
                Image(systemName: "infinity")
                    .font(.system(size: 15))
                    .foregroundColor(accentBlue)
                    .frame(width: 24)

                Text("Бессрочная")
                    .font(.system(size: 15))

                Spacer()

                Toggle("", isOn: $context.isIndefinite)
                    .tint(accentBlue)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !context.viewState.bindings.isIndefinite {
                Divider().padding(.leading, 48)

                // Start date
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15))
                        .foregroundColor(accentBlue)
                        .frame(width: 24)

                    Text("Начало")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)

                    Spacer()

                    DatePicker("", selection: $context.startDate)
                        .labelsHidden()
                        .tint(accentBlue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().padding(.leading, 48)

                // End date
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15))
                        .foregroundColor(accentBlue)
                        .frame(width: 24)

                    Text("Конец")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)

                    Spacer()

                    DatePicker("", selection: $context.endDate)
                        .labelsHidden()
                        .tint(accentBlue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(cardBg)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - Access Card

    private var accessCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundColor(accentBlue)
                .frame(width: 24)

            Text("Разрешить гостей")
                .font(.system(size: 15))

            Spacer()

            Toggle("", isOn: $context.allowGuests)
                .tint(accentBlue)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cardBg)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - Participants Card

    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13))
                    .foregroundColor(accentBlue)
                Text("Участники (\(context.viewState.bindings.participants.count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                TextField("Добавить участника...", text: $context.participantSearchQuery)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .participantSearch)
                    .onChange(of: context.participantSearchQuery) { newValue in
                        context.send(viewAction: .searchParticipants(newValue))
                    }

                if !context.participantSearchQuery.isEmpty {
                    Button {
                        context.send(viewAction: .searchParticipants(""))
                        focusedField = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 16)

            // Inline search results (under search field)
            if context.viewState.isSearching || !context.viewState.searchResults.isEmpty {
                VStack(spacing: 0) {
                    if context.viewState.isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(accentBlue)
                            Text("Поиск...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    ForEach(context.viewState.searchResults) { user in
                        Divider().padding(.leading, 52)

                        Button {
                            context.send(viewAction: .addParticipant(user))
                            focusedField = nil
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(avatarColor(for: user.displayName ?? user.userID))
                                    Text(String((user.displayName ?? user.userID).prefix(1)).uppercased())
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 30, height: 30)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName ?? user.userID)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                    if user.displayName != nil {
                                        Text(user.userID)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .background(Color(UIColor.systemGray6).opacity(0.5))
            }

            // Added participants
            if !context.viewState.bindings.participants.isEmpty {
                VStack(spacing: 0) {
                    ForEach(context.viewState.bindings.participants) { user in
                        Divider().padding(.leading, 52)

                        HStack(spacing: 10) {
                            // Avatar
                            ZStack {
                                Circle()
                                    .fill(avatarColor(for: user.displayName ?? user.userID))
                                Text(String((user.displayName ?? user.userID).prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 30, height: 30)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName ?? user.userID)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                if user.displayName != nil {
                                    Text(user.userID)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                context.send(viewAction: .removeParticipant(user))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }

            Spacer().frame(height: 8)
        }
        .background(cardBg)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - Search Results Overlay

    private var searchResultsOverlay: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 44)

            VStack(spacing: 0) {
                if context.viewState.isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(accentBlue)
                        Text("Поиск...")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(12)
                }

                ForEach(context.viewState.searchResults) { user in
                    Button {
                        context.send(viewAction: .addParticipant(user))
                        focusedField = nil
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(avatarColor(for: user.displayName ?? user.userID))
                                Text(String((user.displayName ?? user.userID).prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName ?? user.userID)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                if user.displayName != nil {
                                    Text(user.userID)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    if user.userID != context.viewState.searchResults.last?.userID {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    // MARK: - Helpers

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            accentBlue,
            Color(red: 0.96, green: 0.49, blue: 0.37),
            Color(red: 0.30, green: 0.78, blue: 0.55),
            Color(red: 0.95, green: 0.68, blue: 0.25),
            Color(red: 0.73, green: 0.45, blue: 0.90)
        ]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}
