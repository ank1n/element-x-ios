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
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        filtersSection

                        if context.viewState.isLoading {
                            loadingCells
                        } else if filteredContacts.isEmpty {
                            emptyStateView(minHeight: geometry.size.height)
                        } else {
                            ForEach(groupedContacts, id: \.letter) { group in
                                Section {
                                    ForEach(group.contacts) { contact in
                                        contactCell(contact)
                                    }
                                } header: {
                                    sectionHeader(group.letter)
                                        .id(group.letter)
                                }
                            }
                        }
                    }
                    .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                    .compoundSearchField()
                    .disableAutocorrection(true)
                }
                .scrollDismissesKeyboard(.immediately)
                .scrollBounceBehavior(context.viewState.contacts.isEmpty ? .basedOnSize : .automatic)
                .overlay(alignment: .trailing) {
                    if !groupedContacts.isEmpty && context.searchQuery.isEmpty {
                        alphabetScrubber(scrollProxy: scrollProxy)
                    }
                }
            }
        }
    }

    // MARK: - Alphabet Scrubber

    @ViewBuilder
    private func alphabetScrubber(scrollProxy: ScrollViewProxy) -> some View {
        let letters = groupedContacts.map(\.letter)
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.compound.textSecondary)
                    .frame(width: 16, height: 14)
            }
        }
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = Int(value.location.y / 14)
                    if index >= 0, index < letters.count {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollProxy.scrollTo(letters[index], anchor: .top)
                        }
                    }
                }
        )
    }

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.compound.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.compound.bgSubtleSecondary)
    }

    private struct ContactGroup {
        let letter: String
        let contacts: [ContactItem]
    }

    private var groupedContacts: [ContactGroup] {
        let sorted = filteredContacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        var groups: [String: [ContactItem]] = [:]
        for contact in sorted {
            let firstChar = String(contact.displayName.prefix(1)).uppercased()
            let letter = firstChar.isEmpty ? "#" : firstChar
            groups[letter, default: []].append(contact)
        }
        return groups.keys.sorted().map { ContactGroup(letter: $0, contacts: groups[$0]!) }
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
            HStack(spacing: 12) {
                LoadableAvatarImage(url: contact.avatarURL,
                                    name: contact.displayName,
                                    contentID: contact.id,
                                    avatarSize: .custom(44),
                                    mediaProvider: context.mediaProvider)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                        .lineLimit(1)

                    Text(contact.isOnline ? "в сети" : contactLastSeen(contact))
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if contact.isOnline {
                    Circle()
                        .fill(Color.stalkOnlineGreen)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.compound.borderDisabled)
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 72)
            }
        }
        .buttonStyle(.plain)
    }

    private func contactLastSeen(_ contact: ContactItem) -> String {
        guard let lastSeen = contact.lastSeenDate else {
            return "не в сети"
        }
        let interval = Date().timeIntervalSince(lastSeen)
        if interval < 60 {
            return "был(а) только что"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "был(а) \(minutes) мин. назад"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "был(а) \(hours) ч. назад"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMM"
            return "был(а) \(formatter.string(from: lastSeen))"
        }
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
