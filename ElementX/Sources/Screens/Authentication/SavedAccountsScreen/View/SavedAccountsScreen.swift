//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct SavedAccountsScreen: View {
    @Bindable var context: SavedAccountsScreenViewModel.Context

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.tr("Localizable", "saved_accounts_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.actionBack) {
                            context.send(viewAction: .dismiss)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if context.viewState.isEmpty {
            emptyState
        } else {
            accountsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.compound.textSecondary)

            Text(L10n.tr("Localizable", "saved_accounts_empty_title"))
                .font(.compound.headingMD)
                .foregroundColor(.compound.textPrimary)

            Text(L10n.tr("Localizable", "saved_accounts_empty_subtitle"))
                .font(.compound.bodyLG)
                .foregroundColor(.compound.textSecondary)

            Spacer()

            addServerButton
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
    }

    private var accountsList: some View {
        List {
            Section {
                ForEach(context.viewState.accounts) { account in
                    Button {
                        context.send(viewAction: .selectAccount(account))
                    } label: {
                        accountRow(account)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let account = context.viewState.accounts[index]
                        context.send(viewAction: .deleteAccount(id: account.id))
                    }
                }
            } header: {
                Text(L10n.tr("Localizable", "saved_accounts_section_header"))
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
            }

            Section {
                Button {
                    context.send(viewAction: .addNewServer)
                } label: {
                    Label {
                        Text(L10n.tr("Localizable", "saved_accounts_add_server"))
                            .foregroundColor(.compound.textPrimary)
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.compound.iconAccentTertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func accountRow(_ account: SavedAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(.compound.iconSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName ?? account.userId)
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)
                    .lineLimit(1)

                Text(account.serverURL)
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.compound.iconTertiary)
        }
        .padding(.vertical, 4)
    }

    private var addServerButton: some View {
        Button {
            context.send(viewAction: .addNewServer)
        } label: {
            Text(L10n.tr("Localizable", "saved_accounts_add_server"))
        }
        .buttonStyle(.compound(.primary))
    }
}
