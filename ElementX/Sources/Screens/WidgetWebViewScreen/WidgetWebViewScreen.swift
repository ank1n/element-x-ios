//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI
import WebKit

struct WidgetWebViewScreen: View {
    @ObservedObject var context: WidgetWebViewScreenViewModelType.Context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            WidgetWebView(
                widget: context.viewState.widget,
                roomId: context.viewState.roomId,
                userId: context.viewState.userId,
                displayName: context.viewState.displayName,
                viewModel: context.viewState.webViewModel
            )
            .ignoresSafeArea(.all, edges: .bottom)

            if context.viewState.webViewModel.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.compound.bgCanvasDefault.opacity(0.8))
            }

            if let error = context.viewState.webViewModel.error {
                VStack {
                    Spacer()
                    Text("Ошибка загрузки виджета")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
            }
        }
        .navigationTitle(context.viewState.widget.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Text("Закрыть")
                }
            }
        }
        .onChange(of: context.viewState.webViewModel.shouldClose) { _, shouldClose in
            if shouldClose {
                dismiss()
            }
        }
    }
}

// MARK: - Previews

struct WidgetWebViewScreen_Previews: PreviewProvider {
    static var previews: some View {
        let widget = MatrixWidget(
            id: "test",
            type: "customwidget",
            name: "Test Widget",
            url: "https://stats.market.implica.ru",
            creatorUserId: "@test:server.com",
            waitForIframeLoad: nil,
            data: nil
        )
        let viewModel = WidgetWebViewScreenViewModel(widget: widget, roomProxy: JoinedRoomProxyMock(.init(id: "!test:server.com")))
        WidgetWebViewScreen(context: viewModel.context)
    }
}
