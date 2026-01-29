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
    @State private var isLoading = true
    @State private var loadingProgress: Double = 0

    var body: some View {
        ZStack {
            AppWidgetWebView(url: URL(string: context.viewState.widget.url)!,
                             isLoading: $isLoading,
                             progress: $loadingProgress)
                .ignoresSafeArea(.all, edges: .bottom)

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                    Text("Загрузка...")
                        .font(.compound.bodyMD)
                        .foregroundColor(.compound.textSecondary)

                    if loadingProgress > 0 {
                        ProgressView(value: loadingProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.compound.bgCanvasDefault)
            }
        }
        .navigationTitle(context.viewState.widget.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - App Widget WebView

struct AppWidgetWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var progress: Double

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Observe loading progress
        context.coordinator.progressObservation = webView.observe(\.estimatedProgress, options: .new) { webView, _ in
            DispatchQueue.main.async {
                self.progress = webView.estimatedProgress
            }
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        var progressObservation: NSKeyValueObservation?

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        deinit {
            progressObservation?.invalidate()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MXLog.error("WebView navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MXLog.error("WebView provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
}

// MARK: - Previews

struct WidgetWebViewScreen_Previews: PreviewProvider {
    static var previews: some View {
        let widget = WidgetItem(
            id: "test",
            name: "Test Widget",
            description: "Test description",
            icon: "chart.bar.fill",
            url: "https://stats.market.implica.ru"
        )
        let viewModel = WidgetWebViewScreenViewModel(widget: widget)
        NavigationStack {
            WidgetWebViewScreen(context: viewModel.context)
        }
    }
}
