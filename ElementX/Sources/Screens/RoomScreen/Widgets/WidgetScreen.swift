//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct WidgetScreen: View {
    let widget: MatrixWidget
    let roomId: String
    let userId: String
    let displayName: String?
    let onClose: () -> Void

    @StateObject private var viewModel = WidgetWebViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                WidgetWebView(
                    widget: widget,
                    roomId: roomId,
                    userId: userId,
                    displayName: displayName,
                    viewModel: viewModel
                )
                .ignoresSafeArea(edges: .bottom)

                if viewModel.isLoading {
                    loadingOverlay
                }

                if let error = viewModel.error {
                    errorOverlay(error)
                }
            }
            .navigationTitle(widget.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onClose()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            refreshWidget()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        if let url = viewModel.currentURL {
                            Button {
                                openInBrowser(url)
                            } label: {
                                Label("Open in Browser", systemImage: "safari")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onChange(of: viewModel.shouldClose) { shouldClose in
            if shouldClose {
                onClose()
            }
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Loading widget...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Failed to load widget")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                refreshWidget()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func refreshWidget() {
        viewModel.error = nil
        viewModel.isLoading = true
        // The WebView will reload automatically
    }

    private func openInBrowser(_ url: URL) {
        UIApplication.shared.open(url)
    }
}

// MARK: - Preview

#Preview {
    WidgetScreen(
        widget: MatrixWidget(
            id: "widget1",
            type: "customwidget",
            name: "Stats Widget",
            url: "https://stats.example.com/?roomId=$matrix_room_id",
            creatorUserId: "@admin:example.com",
            waitForIframeLoad: true,
            data: nil
        ),
        roomId: "!room:example.com",
        userId: "@user:example.com",
        displayName: "Test User",
        onClose: { }
    )
}
