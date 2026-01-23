//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct WidgetListView: View {
    @ObservedObject var viewModel: WidgetListViewModel
    let onWidgetSelected: (MatrixWidget) -> Void

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.widgets.isEmpty {
                emptyView
            } else {
                widgetsList
            }
        }
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadWidgets()
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading widgets...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Widgets")
                .font(.headline)

            Text("This room doesn't have any widgets configured.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var widgetsList: some View {
        List(viewModel.widgets) { widget in
            WidgetRowView(widget: widget)
                .contentShape(Rectangle())
                .onTapGesture {
                    onWidgetSelected(widget)
                }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Widget Row View

struct WidgetRowView: View {
    let widget: MatrixWidget

    var body: some View {
        HStack(spacing: 12) {
            widgetIcon
                .frame(width: 40, height: 40)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(widget.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(widget.type)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var widgetIcon: some View {
        let iconName: String
        let iconColor: Color

        switch widget.type.lowercased() {
        case "jitsi", "m.jitsi":
            iconName = "video.fill"
            iconColor = .blue
        case "etherpad":
            iconName = "doc.text.fill"
            iconColor = .orange
        case "customwidget", "custom":
            iconName = "square.grid.2x2.fill"
            iconColor = .purple
        default:
            iconName = "globe"
            iconColor = .green
        }

        return Image(systemName: iconName)
            .font(.system(size: 18))
            .foregroundColor(iconColor)
    }
}

// MARK: - ViewModel

class WidgetListViewModel: ObservableObject {
    @Published var widgets: [MatrixWidget] = []
    @Published var isLoading = false
    @Published var error: String?

    private let widgetService: WidgetServiceProtocol

    init(widgetService: WidgetServiceProtocol) {
        self.widgetService = widgetService
    }

    @MainActor
    func loadWidgets() async {
        isLoading = true
        defer { isLoading = false }

        widgets = await widgetService.getWidgets()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        WidgetListView(
            viewModel: {
                let vm = WidgetListViewModel(widgetService: WidgetServiceMock())
                vm.widgets = [
                    MatrixWidget(
                        id: "widget1",
                        type: "customwidget",
                        name: "Stats Widget",
                        url: "https://stats.example.com",
                        creatorUserId: "@admin:example.com",
                        waitForIframeLoad: true,
                        data: nil
                    ),
                    MatrixWidget(
                        id: "widget2",
                        type: "jitsi",
                        name: "Video Conference",
                        url: "https://jitsi.example.com",
                        creatorUserId: "@admin:example.com",
                        waitForIframeLoad: nil,
                        data: nil
                    )
                ]
                return vm
            }(),
            onWidgetSelected: { _ in }
        )
    }
}
