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
                             userId: extractUserId(from: context.viewState.widget.url),
                             isLoading: $isLoading,
                             progress: $loadingProgress)
                .id(context.viewState.widget.id)
                .ignoresSafeArea(.all, edges: .bottom)

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                    Text(SL10n.appsLoading)
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

    private func extractUserId(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let userId = components.queryItems?.first(where: { $0.name == "userId" })?.value else {
            return ""
        }
        return userId
    }
}

// MARK: - App Widget WebView

struct AppWidgetWebView: UIViewRepresentable {
    let url: URL
    let userId: String
    @Binding var isLoading: Bool
    @Binding var progress: Double

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        // Inject mx_user_id into localStorage before page loads
        // (widget frontends read localStorage.getItem('mx_user_id') to identify user)
        let escapedUserId = userId.replacingOccurrences(of: "'", with: "\\'")
        let injectScript = WKUserScript(source: """
                                        try {
                                            localStorage.setItem('mx_user_id', '\(escapedUserId)');
                                            localStorage.setItem('mx_hs_url', '\(url.scheme ?? "https")://\(url.host ?? "stalk.implica.ru")');
                                        } catch(e) {}
                                        """,
                                        injectionTime: .atDocumentStart,
                                        forMainFrameOnly: false)
        configuration.userContentController.addUserScript(injectScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Observe loading progress
        context.coordinator.progressObservation = webView.observe(\.estimatedProgress, options: .new) { webView, _ in
            DispatchQueue.main.async {
                progress = webView.estimatedProgress
            }
        }

        // Load URL immediately on creation
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // URL loaded in makeUIView; no reuse needed
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
        let widget = WidgetItem(id: "test",
                                name: "Test Widget",
                                description: "Test description",
                                icon: "chart.bar.fill",
                                url: "https://stats.stalk.implica.ru")
        let viewModel = WidgetWebViewScreenViewModel(widget: widget)
        NavigationStack {
            WidgetWebViewScreen(context: viewModel.context)
        }
    }
}
