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
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Menu {
                Button { /* TODO: sort by name */ } label: {
                    Label("По имени", systemImage: "textformat")
                }
                Button { /* TODO: sort by last seen */ } label: {
                    Label("По времени", systemImage: "clock")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .addContact)
            } label: {
                Image(systemName: "plus")
            }
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
                GenericFilterView(
                    title: "Все",
                    isActive: Binding(
                        get: { context.viewState.selectedFilter == .all },
                        set: { if $0 { context.send(viewAction: .selectFilter(.all)) } }
                    )
                )
                GenericFilterView(
                    title: "В сети",
                    isActive: Binding(
                        get: { context.viewState.selectedFilter == .online },
                        set: { if $0 { context.send(viewAction: .selectFilter(.online)) } }
                    )
                )
                GenericFilterView(
                    title: "Избранные",
                    isActive: Binding(
                        get: { context.viewState.selectedFilter == .favorites },
                        set: { if $0 { context.send(viewAction: .selectFilter(.favorites)) } }
                    )
                )
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
        var contacts = context.viewState.contacts

        // Apply filter
        switch context.viewState.selectedFilter {
        case .all:
            break
        case .online:
            contacts = contacts.filter { $0.isOnline }
        case .favorites:
            // TODO: Add favorites support
            break
        }

        // Apply search
        if !context.searchQuery.isEmpty {
            contacts = contacts.filter {
                $0.displayName.localizedCaseInsensitiveContains(context.searchQuery)
            }
        }

        return contacts
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

// MARK: - Previews

struct ContactsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = ContactsListScreenViewModel(userSession: UserSessionMock(.init()))
        NavigationStack {
            ContactsListScreen(context: viewModel.context)
        }
    }
}
