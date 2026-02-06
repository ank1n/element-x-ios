//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct WidgetsListScreen: View {
    @ObservedObject var context: WidgetsListScreenViewModelType.Context
    @State private var selectedCategory: AppCategory = .all

    enum AppCategory: String, CaseIterable {
        case all = "Все"
        case productivity = "Продуктивность"
        case communication = "Связь"
        case tools = "Инструменты"
    }

    var body: some View {
        content
            .navigationTitle("Приложения")
            .toolbar { toolbar }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                // Add app action
            } label: {
                CompoundIcon(\.plus)
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
                        } else if filteredWidgets.isEmpty {
                            emptyStateView(minHeight: geometry.size.height)
                        } else {
                            ForEach(filteredWidgets) { widget in
                                widgetCell(widget)
                            }
                        }
                    } header: {
                        categoriesSection
                    }
                }
                .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                .compoundSearchField()
                .disableAutocorrection(true)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(context.viewState.widgets.isEmpty ? .basedOnSize : .automatic)
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppCategory.allCases, id: \.self) { category in
                    GenericFilterView(
                        title: category.rawValue,
                        isActive: Binding(
                            get: { selectedCategory == category },
                            set: { if $0 { selectedCategory = category } }
                        )
                    )
                }
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
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.compound.bgSubtleSecondary)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 140, height: 16)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 180, height: 14)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func emptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 64))
                .foregroundColor(.compound.textSecondary)

            Text("Нет приложений")
                .font(.compound.headingLG)
                .foregroundColor(.compound.textPrimary)

            Text("Приложения будут отображаться здесь")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    private var filteredWidgets: [WidgetItem] {
        var widgets = context.viewState.widgets

        if !context.searchQuery.isEmpty {
            widgets = widgets.filter {
                $0.name.localizedCaseInsensitiveContains(context.searchQuery) ||
                $0.description.localizedCaseInsensitiveContains(context.searchQuery)
            }
        }

        return widgets
    }

    private func widgetCell(_ widget: WidgetItem) -> some View {
        Button {
            context.send(viewAction: .selectWidget(widget))
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(iconColor(for: widget.name))
                        .frame(width: 52, height: 52)

                    Image(systemName: widget.icon)
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(widget.name)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(widget.description)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                        .lineLimit(2)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.compound.borderDisabled)
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 84)
            }
        }
        .buttonStyle(.plain)
    }

    private func iconColor(for name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.2, green: 0.6, blue: 0.9),
            Color(red: 0.3, green: 0.7, blue: 0.4),
            Color(red: 0.9, green: 0.5, blue: 0.2),
            Color(red: 0.6, green: 0.3, blue: 0.8),
            Color(red: 0.9, green: 0.3, blue: 0.4),
            Color(red: 0.2, green: 0.7, blue: 0.7),
        ]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }
}

// MARK: - Previews

struct WidgetsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = WidgetsListScreenViewModel(userSession: UserSessionMock(.init()))
        NavigationStack {
            WidgetsListScreen(context: viewModel.context)
        }
    }
}
