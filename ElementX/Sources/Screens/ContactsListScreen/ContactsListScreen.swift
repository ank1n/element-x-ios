//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

private enum ContactSortOrder: String {
    case name, lastSeen
}

struct ContactsListScreen: View {
    @ObservedObject var context: ContactsListScreenViewModelType.Context
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"
    @AppStorage("stalk_contacts_sort") private var sortOrder: String = ContactSortOrder.name.rawValue

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    // MARK: - Cosmos Colors

    private let accentBlue = StalkTheme.accent
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)

    // MARK: - Body

    var body: some View {
        Group {
            if isCosmos {
                ZStack {
                    LinearGradient(colors: [bgGradientTop, bgGradientBottom, Color(UIColor.systemGroupedBackground)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .ignoresSafeArea()
                    cosmosContent
                }
            } else {
                classicContent
                    .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            }
        }
        .navigationTitle(SL10n.tabContacts)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Menu {
                Button {
                    sortOrder = ContactSortOrder.name.rawValue
                } label: {
                    Label(SL10n.contactsSortByName, systemImage: sortOrder == ContactSortOrder.name.rawValue ? "checkmark" : "textformat")
                }
                Button {
                    sortOrder = ContactSortOrder.lastSeen.rawValue
                } label: {
                    Label(SL10n.contactsSortByTime, systemImage: sortOrder == ContactSortOrder.lastSeen.rawValue ? "checkmark" : "clock")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundColor(isCosmos ? accentBlue : nil)
            }
        }
    }

    // MARK: - Shared Data

    private struct ContactGroup {
        let letter: String
        let contacts: [ContactItem]
    }

    private var filteredContacts: [ContactItem] {
        var contacts = context.viewState.contacts

        // Apply filter
        switch context.viewState.selectedFilter {
        case .all:
            break
        case .online:
            contacts = contacts.filter(\.isOnline)
        case .favorites:
            contacts = contacts.filter(\.isFavorite)
        }

        // Apply search
        if !context.searchQuery.isEmpty {
            contacts = contacts.filter {
                $0.displayName.localizedCaseInsensitiveContains(context.searchQuery)
            }
        }

        return contacts
    }

    private var groupedContacts: [ContactGroup] {
        let contacts = filteredContacts

        if sortOrder == ContactSortOrder.lastSeen.rawValue {
            // Сортировка по времени последнего визита: онлайн первые, потом по дате убывания
            let sorted = contacts.sorted { a, b in
                if a.isOnline != b.isOnline { return a.isOnline }
                let aDate = a.lastSeenDate ?? .distantPast
                let bDate = b.lastSeenDate ?? .distantPast
                return aDate > bDate
            }
            return [ContactGroup(letter: SL10n.contactsAll, contacts: sorted)]
        }

        // Сортировка по имени (по умолчанию) — группировка по буквам
        let sorted = contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        var groups: [String: [ContactItem]] = [:]
        for contact in sorted {
            let firstChar = String(contact.displayName.prefix(1)).uppercased()
            let letter = firstChar.isEmpty ? "#" : firstChar
            groups[letter, default: []].append(contact)
        }
        return groups.keys.sorted().map { ContactGroup(letter: $0, contacts: groups[$0]!) }
    }

    // MARK: - Shared Helpers

    private func contactOrgSubtitle(_ contact: ContactItem) -> String? {
        let parts = [contact.jobTitle, contact.department].compactMap { $0?.isEmpty == true ? nil : $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func contactLastSeen(_ contact: ContactItem) -> String {
        guard let lastSeen = contact.lastSeenDate else {
            return SL10n.contactsOffline
        }
        let interval = Date().timeIntervalSince(lastSeen)
        if interval < 60 {
            return SL10n.contactsJustNow
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return SL10n.contactsMinutesAgo(minutes)
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return SL10n.contactsHoursAgo(hours)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMM"
            return SL10n.contactsLastSeen(formatter.string(from: lastSeen))
        }
    }

    /// Stable avatar color using djb2 hash (hashValue is randomized per launch)
    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.2, green: 0.6, blue: 0.9),
            Color(red: 0.3, green: 0.7, blue: 0.4),
            Color(red: 0.9, green: 0.5, blue: 0.2),
            Color(red: 0.6, green: 0.3, blue: 0.8),
            Color(red: 0.9, green: 0.3, blue: 0.4),
            Color(red: 0.2, green: 0.7, blue: 0.7)
        ]
        var hash: UInt64 = 5381
        for char in name.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char.value)
        }
        let index = Int(hash % UInt64(colors.count))
        return colors[index]
    }

    // MARK: - Classic Design

    private var classicContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        classicFiltersSection

                        if context.viewState.isLoading {
                            classicLoadingCells
                        } else if filteredContacts.isEmpty {
                            classicEmptyStateView(minHeight: geometry.size.height)
                        } else {
                            ForEach(groupedContacts, id: \.letter) { group in
                                Section {
                                    ForEach(group.contacts) { contact in
                                        SwipeActionView(trailingActions: [
                                            SwipeAction(title: contact.isFavorite ? SL10n.actionRemoveFavorite : SL10n.actionAddFavorite,
                                                        icon: contact.isFavorite ? "star.slash" : "star.fill",
                                                        color: .orange) {
                                                context.send(viewAction: .toggleFavorite(contact))
                                            }
                                        ]) {
                                            classicContactCell(contact)
                                        }
                                    }
                                } header: {
                                    classicSectionHeader(group.letter)
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
                    if !groupedContacts.isEmpty, context.searchQuery.isEmpty {
                        classicAlphabetScrubber(scrollProxy: scrollProxy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func classicAlphabetScrubber(scrollProxy: ScrollViewProxy) -> some View {
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
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let index = Int(value.location.y / 14)
                if index >= 0, index < letters.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo(letters[index], anchor: .top)
                    }
                }
            })
    }

    private func classicSectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.compound.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.compound.bgSubtleSecondary)
    }

    private var classicFiltersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                GenericFilterView(title: SL10n.contactsAllCount(context.viewState.contacts.count),
                                  isActive: Binding(get: { context.viewState.selectedFilter == .all },
                                                    set: { if $0 { context.send(viewAction: .selectFilter(.all)) } }))
                GenericFilterView(title: SL10n.contactsOnlineCount(context.viewState.onlineCount),
                                  isActive: Binding(get: { context.viewState.selectedFilter == .online },
                                                    set: { if $0 { context.send(viewAction: .selectFilter(.online)) } }))
                GenericFilterView(title: SL10n.contactsFavoritesCount(context.viewState.favoritesCount),
                                  isActive: Binding(get: { context.viewState.selectedFilter == .favorites },
                                                    set: { if $0 { context.send(viewAction: .selectFilter(.favorites)) } }))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.compound.bgCanvasDefault)
    }

    private var classicLoadingCells: some View {
        ForEach(0..<5, id: \.self) { _ in
            classicSkeletonCell
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var classicSkeletonCell: some View {
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

    private func classicEmptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.2")
                .font(.system(size: 64))
                .foregroundColor(.compound.textSecondary)

            Text(SL10n.contactsNoContacts)
                .font(.compound.headingLG)
                .foregroundColor(.compound.textPrimary)

            Text(SL10n.contactsEmptyHint)
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    private func classicContactCell(_ contact: ContactItem) -> some View {
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

                if let orgSubtitle = contactOrgSubtitle(contact) {
                    Text(orgSubtitle)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                        .lineLimit(1)
                }

                Text(contact.isOnline ? SL10n.contactsOnlineStatus : contactLastSeen(contact))
                    .font(.compound.bodySM)
                    .foregroundColor(contact.isOnline ? .stalkOnlineGreen : .compound.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                context.send(viewAction: .selectContact(contact))
            }

            HStack(spacing: 6) {
                if contact.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                // Build 125: 3-цветная точка (как в HomeScreen + RoomScreen).
                // Зелёный online / жёлтый <1ч / серый offline.
                Circle()
                    .fill(Self.contactPresenceColor(contact))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.compound.bgCanvasDefault)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.compound.borderDisabled)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, 72)
        }
    }

    // MARK: - Cosmos Design

    private var cosmosContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Filters
                        cosmosFiltersSection

                        // Contacts
                        if context.viewState.isLoading {
                            cosmosLoadingCells
                                .padding(.horizontal, 16)
                        } else if filteredContacts.isEmpty {
                            cosmosEmptyStateView(minHeight: geometry.size.height)
                        } else {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                ForEach(groupedContacts, id: \.letter) { group in
                                    Section {
                                        LazyVStack(spacing: 10) {
                                            ForEach(group.contacts) { contact in
                                                SwipeActionView(trailingActions: [
                                                    SwipeAction(title: contact.isFavorite ? SL10n.actionRemoveFavorite : SL10n.actionAddFavorite,
                                                                icon: contact.isFavorite ? "star.slash" : "star.fill",
                                                                color: .orange) {
                                                        context.send(viewAction: .toggleFavorite(contact))
                                                    }
                                                ],
                                                cornerRadius: 14) {
                                                    cosmosContactCell(contact)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 6)
                                    } header: {
                                        cosmosSectionHeader(group.letter)
                                            .id(group.letter)
                                    }
                                }
                            }
                            .padding(.bottom, 70)
                        }
                    }
                }
                .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                .compoundSearchField()
                .disableAutocorrection(true)
                .scrollDismissesKeyboard(.immediately)
                .scrollBounceBehavior(context.viewState.contacts.isEmpty ? .basedOnSize : .automatic)
                .overlay(alignment: .trailing) {
                    if !groupedContacts.isEmpty, context.searchQuery.isEmpty {
                        cosmosAlphabetScrubber(scrollProxy: scrollProxy)
                    }
                }
            }
        }
    }

    // MARK: - Cosmos Filters

    private var cosmosFiltersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                cosmosFilterButton(title: SL10n.contactsAllCount(context.viewState.contacts.count),
                                   isActive: context.viewState.selectedFilter == .all) {
                    context.send(viewAction: .selectFilter(.all))
                }
                cosmosFilterButton(title: SL10n.contactsOnlineCount(context.viewState.onlineCount),
                                   isActive: context.viewState.selectedFilter == .online) {
                    context.send(viewAction: .selectFilter(.online))
                }
                cosmosFilterButton(title: SL10n.contactsFavoritesCount(context.viewState.favoritesCount),
                                   isActive: context.viewState.selectedFilter == .favorites) {
                    context.send(viewAction: .selectFilter(.favorites))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func cosmosFilterButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isActive ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule()
                    .fill(isActive ? accentBlue : Color(UIColor.systemGray6)))
        }
    }

    // MARK: - Cosmos Section Header

    private func cosmosSectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
    }

    // MARK: - Cosmos Alphabet Scrubber

    @ViewBuilder
    private func cosmosAlphabetScrubber(scrollProxy: ScrollViewProxy) -> some View {
        let letters = groupedContacts.map(\.letter)
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 14)
            }
        }
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let index = Int(value.location.y / 14)
                if index >= 0, index < letters.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo(letters[index], anchor: .top)
                    }
                }
            })
    }

    // MARK: - Cosmos Loading

    private var cosmosLoadingCells: some View {
        VStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { _ in
                cosmosSkeletonCell
            }
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var cosmosSkeletonCell: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 100, height: 12)
            }
            Spacer()
        }
        .padding(12)
        .background(cardBg)
        .cornerRadius(14)
    }

    // MARK: - Cosmos Empty State

    private func cosmosEmptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.35))

            Text(SL10n.contactsNoContacts)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Text(SL10n.contactsEmptyHint)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    // MARK: - Cosmos Contact Cell

    private func cosmosContactCell(_ contact: ContactItem) -> some View {
        HStack(spacing: 12) {
            LoadableAvatarImage(url: contact.avatarURL,
                                name: contact.displayName,
                                contentID: contact.id,
                                avatarSize: .custom(44),
                                mediaProvider: context.mediaProvider)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let orgSubtitle = contactOrgSubtitle(contact) {
                    Text(orgSubtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(contact.isOnline ? SL10n.contactsOnlineStatus : contactLastSeen(contact))
                    .font(.system(size: 13))
                    .foregroundColor(contact.isOnline ? .stalkOnlineGreen : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                context.send(viewAction: .selectContact(contact))
            }

            HStack(spacing: 6) {
                if contact.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                // Build 125: 3-цветная точка (как в HomeScreen + RoomScreen).
                // Зелёный online / жёлтый <1ч / серый offline.
                Circle()
                    .fill(Self.contactPresenceColor(contact))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(12)
        .background(cardBg)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

// MARK: - Presence helper

extension ContactsListScreen {
    /// Build 125: 3-цветная семантика presence (общая с HomeScreen и RoomScreen).
    static func contactPresenceColor(_ contact: ContactItem) -> Color {
        if contact.isOnline { return Color(red: 0.18, green: 0.8, blue: 0.44) }
        if let last = contact.lastSeenDate, Date().timeIntervalSince(last) < 3600 {
            return Color(red: 0.95, green: 0.7, blue: 0.18)
        }
        return Color(red: 0.55, green: 0.6, blue: 0.65)
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
