//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI
import WebKit

struct WidgetWebView: UIViewRepresentable {
    let widget: MatrixWidget
    let roomId: String
    let userId: String
    let displayName: String?
    @ObservedObject var viewModel: WidgetWebViewModel

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Setup user content controller for Widget API bridge
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "matrixWidget")

        // Inject Widget API initialization script
        let initScript = WKUserScript(
            source: WidgetAPIBridge.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(initScript)

        configuration.userContentController = userContentController
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Enable inspection for debugging
        #if DEBUG
        webView.isInspectable = true
        #endif

        context.coordinator.webView = webView

        // Load widget URL
        if let url = widget.processedURL(roomId: roomId, userId: userId, displayName: displayName) {
            let request = URLRequest(url: url)
            webView.load(request)
            viewModel.currentURL = url
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Handle URL changes if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, roomId: roomId, userId: userId)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let viewModel: WidgetWebViewModel
        let roomId: String
        let userId: String

        init(viewModel: WidgetWebViewModel, roomId: String, userId: String) {
            self.viewModel = viewModel
            self.roomId = roomId
            self.userId = userId
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            viewModel.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            viewModel.isLoading = false
            viewModel.error = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            viewModel.isLoading = false
            viewModel.error = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            viewModel.isLoading = false
            viewModel.error = error.localizedDescription
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "matrixWidget",
                  let body = message.body as? [String: Any] else {
                return
            }

            handleWidgetMessage(body)
        }

        private func handleWidgetMessage(_ message: [String: Any]) {
            guard let action = message["action"] as? String else {
                return
            }

            MXLog.debug("Widget message received: \(action)")

            switch action {
            case "content_loaded":
                viewModel.isContentLoaded = true

            case "close_widget":
                viewModel.shouldClose = true

            case "supported_api_versions":
                // Respond with supported versions
                sendToWidget(["supported_versions": ["0.0.1", "0.0.2"]])

            default:
                MXLog.debug("Unhandled widget action: \(action)")
            }
        }

        func sendToWidget(_ data: [String: Any]) {
            guard let webView,
                  let jsonData = try? JSONSerialization.data(withJSONObject: data),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            let script = "window.postMessage(\(jsonString), '*');"
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    MXLog.error("Failed to send message to widget: \(error)")
                }
            }
        }
    }
}

// MARK: - ViewModel

class WidgetWebViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var isContentLoaded = false
    @Published var error: String?
    @Published var shouldClose = false
    @Published var currentURL: URL?
}

// MARK: - Widget API Bridge

enum WidgetAPIBridge {
    static let injectionScript = """
    (function() {
        // Matrix Widget API bridge
        window.matrixWidget = {
            api: {
                requestCapabilities: function(capabilities) {
                    window.webkit.messageHandlers.matrixWidget.postMessage({
                        action: 'request_capabilities',
                        capabilities: capabilities
                    });
                },
                sendContentLoaded: function() {
                    window.webkit.messageHandlers.matrixWidget.postMessage({
                        action: 'content_loaded'
                    });
                },
                closeWidget: function() {
                    window.webkit.messageHandlers.matrixWidget.postMessage({
                        action: 'close_widget'
                    });
                }
            }
        };

        // Listen for postMessage events and forward to native
        window.addEventListener('message', function(event) {
            if (event.data && event.data.api === 'fromWidget') {
                window.webkit.messageHandlers.matrixWidget.postMessage(event.data);
            }
        }, false);

        // Notify that the bridge is ready
        window.webkit.messageHandlers.matrixWidget.postMessage({
            action: 'bridge_ready'
        });
    })();
    """
}
