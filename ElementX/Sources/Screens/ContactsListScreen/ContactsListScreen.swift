//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct ContactsListScreen: View {
    @ObservedObject var context: ContactsListScreenViewModelType.Context

    var body: some View {
        content
            .navigationTitle("Контакты")
            .toolbar { toolbar }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .toolbarBloom(hasSearchBar: true)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            settingsButton
        }
        .backportSharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .addContact)
            } label: {
                CompoundIcon(\.plus)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            context.send(viewAction: .showSettings)
        } label: {
            LoadableAvatarImage(url: context.viewState.userAvatarURL,
                                name: context.viewState.userDisplayName,
                                contentID: context.viewState.userID,
                                avatarSize: .user(on: .chats),
                                mediaProvider: context.mediaProvider)
                .clipShape(.circle)
                .overlayBadge(10, isBadged: context.viewState.requiresExtraAccountSetup)
                .compositingGroup()
        }
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Section {
                        if context.viewState.isLoading {
                            loadingCells
                        } else if filteredContacts.isEmpty {
                            emptyStateView(minHeight: geometry.size.height)
                        } else {
                            ForEach(filteredContacts) { contact in
                                contactCell(contact)
                            }
                        }
                    } header: {
                        filtersSection
                    }
                }
                .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                .compoundSearchField()
                .disableAutocorrection(true)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(context.viewState.contacts.isEmpty ? .basedOnSize : .automatic)
        }
    }

    @ViewBuilder
    private var filtersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChipView(title: "Все", isSelected: true) { }
                FilterChipView(title: "В сети", isSelected: false) { }
                FilterChipView(title: "Избранные", isSelected: false) { }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.compound.bgCanvasDefault)
    }

    private var loadingCells: some View {
        ForEach(0..<5, id: \.self) { _ in
            skeletonCell
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var skeletonCell: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color.compound.bgSubtleSecondary)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 140, height: 16)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 100, height: 14)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func emptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.2")
                .font(.system(size: 64))
                .foregroundColor(.compound.textSecondary)

            Text("Нет контактов")
                .font(.compound.headingLG)
                .foregroundColor(.compound.textPrimary)

            Text("Начните чат с кем-нибудь, чтобы добавить контакт")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    private var filteredContacts: [ContactItem] {
        if context.searchQuery.isEmpty {
            return context.viewState.contacts
        }
        return context.viewState.contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(context.searchQuery)
        }
    }

    private func contactCell(_ contact: ContactItem) -> some View {
        Button {
            context.send(viewAction: .selectContact(contact))
        } label: {
            HStack(spacing: 16) {
                LoadableAvatarImage(url: contact.avatarURL,
                                    name: contact.displayName,
                                    contentID: contact.id,
                                    avatarSize: .room(on: .chats),
                                    mediaProvider: context.mediaProvider)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(contact.isOnline ? Color.green : Color.compound.iconTertiary)
                            .frame(width: 8, height: 8)

                        Text(contact.isOnline ? "В сети" : "Не в сети")
                            .font(.compound.bodySM)
                            .foregroundColor(.compound.textSecondary)
                    }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.compound.borderDisabled)
                        .frame(height: 1 / UIScreen.main.scale)
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter Chip View

struct FilterChipView: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.compound.bodySM)
                .foregroundColor(isSelected ? .white : .compound.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.compound.bgActionPrimaryRest : Color.compound.bgSubtleSecondary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

struct ContactsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = ContactsListScreenViewModel(userSession: UserSessionMock(.init()))
        NavigationStack {
            ContactsListScreen(context: viewModel.context)
        }
    }
}
