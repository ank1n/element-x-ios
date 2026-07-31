//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UIKit

struct WidgetsListScreen: View {
    @ObservedObject var context: WidgetsListScreenViewModelType.Context
    @State private var selectedCategory: AppCategory = .all
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    enum AppCategory: CaseIterable {
        case all
        case productivity
        case communication
        case tools

        var rawValue: String {
            switch self {
            case .all: return SL10n.appsAll
            case .productivity: return SL10n.appsProductivity
            case .communication: return SL10n.appsCommunication
            case .tools: return SL10n.appsTools
            }
        }
    }

    private let accentBlue = StalkTheme.accent
    private let bgGradientTop = Color(red: 0.90, green: 0.92, blue: 1.0)
    private let bgGradientBottom = Color(red: 0.95, green: 0.96, blue: 1.0)
    private let cardBg = Color(UIColor.systemBackground)

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
                    // Match the other classic tabs (Chats/Calls) which sit on the flat canvas
                    // instead of the grey grouped background — Apps was the only screen using
                    // systemGroupedBackground, which made it look like iOS Settings.
                    .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            }
        }
        .navigationTitle(SL10n.tabApps)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        // STMOB-184: «+» (Add app) убрана — была пустой заглушкой, не нужна пользователю.
    }

    // MARK: - Classic Design

    private var classicContent: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Section {
                        if context.viewState.isLoading {
                            classicLoadingCells
                        } else if filteredWidgets.isEmpty {
                            classicEmptyState(minHeight: geometry.size.height)
                        } else {
                            ForEach(filteredWidgets) { widget in
                                classicWidgetCell(widget)
                            }
                        }
                    } header: {
                        classicCategoriesSection
                    }
                }
                .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
                .compoundSearchField()
                .disableAutocorrection(true)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                context.send(viewAction: .refresh)
            }
        }
    }

    private var classicCategoriesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppCategory.allCases, id: \.self) { category in
                    GenericFilterView(title: category.rawValue,
                                      isActive: Binding(get: { selectedCategory == category },
                                                        set: { if $0 { selectedCategory = category } }))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var classicLoadingCells: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 140, height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: 180, height: 14)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private func classicEmptyState(minHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text(SL10n.appsEmpty)
                .font(.system(size: 20, weight: .bold))
            Text(SL10n.appsEmptyHint)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(minHeight: minHeight - 100)
    }

    private func classicWidgetCell(_ widget: WidgetItem) -> some View {
        Button {
            context.send(viewAction: .selectWidget(widget))
        } label: {
            HStack(spacing: 16) {
                widgetIcon(widget, size: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(widget.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(widget.description)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
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
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 84)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cosmos Design

    private var cosmosContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Categories
                categoriesSection

                // Widgets
                if context.viewState.isLoading {
                    loadingCells
                        .padding(.horizontal, 16)
                } else if filteredWidgets.isEmpty {
                    emptyStateView(minHeight: 300)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredWidgets) { widget in
                            widgetCell(widget)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 70)
                }
            }
        }
        .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
        .compoundSearchField()
        .disableAutocorrection(true)
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            context.send(viewAction: .refresh)
        }
    }

    private var categoriesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppCategory.allCases, id: \.self) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(selectedCategory == category ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule()
                                .fill(selectedCategory == category ? accentBlue : Color(UIColor.systemGray6)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var loadingCells: some View {
        VStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                skeletonCell
            }
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private var skeletonCell: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 120, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 180, height: 12)
            }
            Spacer()
        }
        .padding(12)
        .background(cardBg)
        .cornerRadius(14)
    }

    private func emptyStateView(minHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.35))

            Text(SL10n.appsEmpty)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Text(SL10n.appsEmptyHint)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(minHeight: minHeight)
    }

    private var filteredWidgets: [WidgetItem] {
        var widgets = context.viewState.widgets

        // Apply category filter
        if selectedCategory != .all {
            let widgetCategory: WidgetCategory? = {
                switch selectedCategory {
                case .all: return nil
                case .productivity: return .productivity
                case .communication: return .communication
                case .tools: return .tools
                }
            }()
            if let category = widgetCategory {
                widgets = widgets.filter { $0.category == category }
            }
        }

        // Apply search
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
            HStack(spacing: 14) {
                widgetIcon(widget)

                VStack(alignment: .leading, spacing: 3) {
                    Text(widget.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(widget.description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(12)
            .background(cardBg)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func widgetIcon(_ widget: WidgetItem, size: CGFloat = 48) -> some View {
        // Календарь: живая плитка-дата (решение dp, 01.08) — день недели и
        // сегодняшнее число, как у виджета системного календаря. Статичная
        // картинка из iconUrl так не умеет, поэтому для этого id рисуем сами;
        // цвет — teal референс-дизайна (#2FA98C).
        if widget.id == "meetings-calendar" {
            calendarDateIcon(size: size)
        } else if let iconURL = widget.iconURL {
            AsyncImage(url: iconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                default:
                    sfSymbolIcon(widget, size: size)
                }
            }
        } else {
            sfSymbolIcon(widget, size: size)
        }
    }

    /// Плитка-«отрывной календарь»: аббревиатура дня недели сверху, число крупно.
    /// Локаль системная («Пт» / «Fri»), число с ведущим нулём — как в образце dp.
    /// Дата считается при каждой отрисовке — список пересобирается при каждом
    /// открытии вкладки, протяжённых сессий с «вчерашним» числом не бывает.
    private func calendarDateIcon(size: CGFloat) -> some View {
        let now = Date()
        let weekday = now.formatted(.dateTime.weekday(.abbreviated)).capitalized
        let day = Calendar.current.component(.day, from: now)
        return ZStack {
            // Градиент hero-кнопки референса: linear-gradient(120deg, #0088BB, #2FA98C).
            // 120° CSS ≈ диагональ с лёгким наклоном вниз — точки подобраны под неё.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.0, green: 0.533, blue: 0.733), // #0088BB
                                              Color(red: 0.184, green: 0.663, blue: 0.549)], // #2FA98C
                                     startPoint: UnitPoint(x: 0, y: 0.2),
                                     endPoint: UnitPoint(x: 1, y: 0.8)))
            VStack(spacing: size * 0.02) {
                Text(weekday)
                    .font(.system(size: size * 0.24, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Text(String(format: "%02d", day))
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private func sfSymbolIcon(_ widget: WidgetItem, size: CGFloat = 48) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(iconColor(for: widget.name))
                .frame(width: size, height: size)

            Image(systemName: widget.icon.isEmpty ? "app.fill" : widget.icon)
                .font(.system(size: size * 0.46))
                .foregroundColor(.white)
        }
    }

    private func iconColor(for name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.2, green: 0.6, blue: 0.9),
            Color(red: 0.3, green: 0.7, blue: 0.4),
            Color(red: 0.9, green: 0.5, blue: 0.2),
            Color(red: 0.6, green: 0.3, blue: 0.8),
            Color(red: 0.9, green: 0.3, blue: 0.4),
            Color(red: 0.2, green: 0.7, blue: 0.7)
        ]
        // Stable hash — djb2 algorithm (hashValue is randomized per launch)
        var hash: UInt64 = 5381
        for char in name.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char.value)
        }
        let index = Int(hash % UInt64(colors.count))
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
