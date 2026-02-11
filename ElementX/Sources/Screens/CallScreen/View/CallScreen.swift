//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import EmbeddedElementCall
import SFSafeSymbols
import SwiftUI
import WebKit

struct CallScreen: View {
    @ObservedObject var context: CallScreenViewModel.Context
    @State private var showRecordingConsent = false

    var body: some View {
        NavigationStack {
            ZStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // sTalk: Top gradient to mask WebView header/dashed border
                VStack {
                    LinearGradient(
                        colors: [.black, .black, .black.opacity(0.85), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                    Spacer()
                }
                .allowsHitTesting(false)

                // sTalk: Recording button as overlay (top-right, under header)
                // Shows both idle (start) and recording (stop) states in one button
                if context.viewState.isRecordingEnabled {
                    VStack {
                        RecordingButton(recordingState: context.viewState.recordingState) {
                            if context.viewState.recordingState.isRecording {
                                context.send(viewAction: .toggleRecording)
                            } else {
                                showRecordingConsent = true
                            }
                        }
                        // Show REC indicator next to button when recording
                        if context.viewState.recordingState.isRecording {
                            RecordingIndicator()
                                .padding(.top, 4)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                }

                // sTalk: Native call control buttons at bottom
                VStack {
                    Spacer()

                    // Bottom gradient overlay
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.3), .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 140)
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottom) {
                        callControlButtons
                            .padding(.bottom, 32)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { toolbar }
        }
        .alert(item: $context.alertInfo)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showRecordingConsent) {
            RecordingConsentView(
                onConfirm: {
                    showRecordingConsent = false
                    context.send(viewAction: .confirmStartRecording)
                },
                onCancel: {
                    showRecordingConsent = false
                }
            )
            .presentationDetents([.medium])
        }
        .onReceive(context.$viewState) { _ in
            // This will be triggered by coordinator for showing consent
        }
    }
    
    @ViewBuilder
    var content: some View {
        if context.viewState.url == nil {
            ProgressView()
        } else {
            CallView(url: context.viewState.url, viewModelContext: context)
                // This URL is stable, forces view reloads if this representable is ever reused for another url
                .id(context.viewState.url)
                .ignoresSafeArea()
        }
    }
    
    // sTalk: Native call control buttons
    var callControlButtons: some View {
        HStack(spacing: 24) {
            // Mute button
            CallControlButton(
                icon: context.viewState.isMuted ? "mic.slash.fill" : "mic.fill",
                label: "звук",
                isActive: !context.viewState.isMuted
            ) {
                context.send(viewAction: .toggleMute)
            }

            // Video button
            CallControlButton(
                icon: context.viewState.isVideoEnabled ? "video.fill" : "video.slash.fill",
                label: "видео",
                isActive: context.viewState.isVideoEnabled
            ) {
                context.send(viewAction: .toggleVideo)
            }

            // Raise hand button
            CallControlButton(
                icon: "hand.raised.fill",
                label: "рука",
                isActive: context.viewState.isHandRaised
            ) {
                context.send(viewAction: .toggleRaiseHand)
            }

            // End call button
            CallControlButton(
                icon: "phone.down.fill",
                label: "завершить",
                style: .destructive
            ) {
                context.send(viewAction: .endCall)
            }
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { context.send(viewAction: .navigateBack) } label: {
                HStack(spacing: 4) {
                    Image(systemSymbol: .chevronBackward)
                        .fontWeight(.semibold)
                    Text("Назад")
                        .font(.system(size: 16))
                }
            }
        }

        // sTalk: Compact name + status in toolbar center
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                if let name = context.viewState.roomDisplayName {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                Text(context.viewState.callStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - sTalk Native Call Control Button

private struct CallControlButton: View {
    enum Style {
        case normal
        case destructive
    }

    let icon: String
    let label: String
    var isActive: Bool = true
    var style: Style = .normal
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(foregroundColor)
                    .frame(width: 56, height: 56)
                    .background(backgroundColor)
                    .clipShape(Circle())
            }

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .destructive:
            return Color(red: 1.0, green: 0.23, blue: 0.19) // #FF3B30
        case .normal:
            return isActive ? .white.opacity(0.15) : .white.opacity(0.9)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .destructive:
            return .white
        case .normal:
            return isActive ? .white : Color(red: 0.1, green: 0.1, blue: 0.1)
        }
    }
}

private struct CallView: UIViewRepresentable {
    /// The top-level view this representable displays. It wraps the web view when picture in picture isn't running.
    typealias WebViewWrapper = UIView
    
    let url: URL?
    let viewModelContext: CallScreenViewModel.Context
    
    func makeUIView(context: Context) -> WebViewWrapper {
        context.coordinator.webViewWrapper
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModelContext: viewModelContext)
    }
    
    func updateUIView(_ callWebView: WebViewWrapper, context: Context) {
        if let url {
            context.coordinator.load(url)
        }
    }
    
    @MainActor
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, AVPictureInPictureControllerDelegate {
        private weak var viewModelContext: CallScreenViewModel.Context?
        private let certificateValidator: CertificateValidatorHookProtocol
        
        private var webView: WKWebView!
        private var pictureInPictureController: AVPictureInPictureController?
        private let pictureInPictureViewController: AVPictureInPictureVideoCallViewController
        private var routePickerView: AVRoutePickerView!
        
        /// The view to be shown in the app. This will contain the web view when picture in picture isn't running.
        let webViewWrapper = WebViewWrapper(frame: .zero)
        
        private var url: URL!
        
        init(viewModelContext: CallScreenViewModel.Context) {
            self.viewModelContext = viewModelContext
            certificateValidator = viewModelContext.viewState.certificateValidator
            pictureInPictureViewController = AVPictureInPictureVideoCallViewController()
            pictureInPictureViewController.preferredContentSize = CGSize(width: 1920, height: 1080)
            
            super.init()
            
            DispatchQueue.main.async { // Avoid `Publishing changes from within view update` warnings
                viewModelContext.javaScriptEvaluator = self.evaluateJavaScript
                viewModelContext.requestPictureInPictureHandler = self.requestPictureInPicture
            }
            
            let configuration = WKWebViewConfiguration()
            
            let userContentController = WKUserContentController()
            CallScreenJavaScriptMessageName.allCases.forEach {
                userContentController.add(WKScriptMessageHandlerWrapper(self), name: $0.rawValue)
            }
            
            // Required to allow a webview that uses file URL to load its own assets
            configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            configuration.userContentController = userContentController
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true
            
            if let script = viewModelContext.viewState.script {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
                configuration.userContentController.addUserScript(userScript)
            }
            
            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.uiDelegate = self
            webView.navigationDelegate = self
            webView.isInspectable = true
            
            // https://stackoverflow.com/a/77963877/730924
            webView.allowsLinkPreview = true
            
            // sTalk: black background for Telegram-style call
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.backgroundColor = .black
            webView.scrollView.showsVerticalScrollIndicator = false
            webView.scrollView.showsHorizontalScrollIndicator = false
            webView.scrollView.bounces = false
            
            // This button is always hidden and is only used to be programmaticaly tapped
            routePickerView = AVRoutePickerView(frame: .zero)
            routePickerView.isHidden = true
            routePickerView.isUserInteractionEnabled = false
            webView.addSubview(routePickerView)
            
            webViewWrapper.addMatchedSubview(webView)
            
            if AVPictureInPictureController.isPictureInPictureSupported() {
                let pictureInPictureController = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: webViewWrapper,
                                                                                                   contentViewController: pictureInPictureViewController))
                pictureInPictureController.delegate = self
                self.pictureInPictureController = pictureInPictureController
                viewModelContext.send(viewAction: .pictureInPictureIsAvailable(pictureInPictureController))
            }
        }
        
        func load(_ url: URL) {
            self.url = url
            // The only file URL we allow is the one coming from our own local ElementCall bundle, so it's okay to allow read permission only to our local EC bundle
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: EmbeddedElementCall.bundle.bundleURL)
            } else {
                let request = URLRequest(url: url)
                webView.load(request)
            }
        }
        
        func evaluateJavaScript(_ script: String) async throws -> Any? {
            // After testing different scenarios it seems that when using async/await version of these
            // methods wkwebView expects JavaScript to return with a value (something other than Void),
            // if there is no value returning from the JavaScript that you evaluate you will have a crash.
            try await withCheckedThrowingContinuation { [weak self] continuaton in
                self?.webView.evaluateJavaScript(script) { result, error in
                    if let error {
                        continuaton.resume(throwing: error)
                    } else {
                        continuaton.resume(returning: result)
                    }
                }
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let handlerID = CallScreenJavaScriptMessageName(rawValue: message.name) else {
                return
            }
            
            switch handlerID {
            case .widgetAction:
                guard let message = message.body as? String else { return }
                viewModelContext?.send(viewAction: .widgetAction(message: message))
            case .showNativeOutputDevicePicker:
                DispatchQueue.main.async {
                    self.tapRoutePickerView()
                }
            case .onOutputDeviceSelect:
                guard let deviceID = message.body as? String else { return }
                viewModelContext?.send(viewAction: .outputDeviceSelected(deviceID: deviceID))
            case .onBackButtonPressed:
                viewModelContext?.send(viewAction: .navigateBack)
            case .onLobbyDetected:
                // sTalk: Remote party hung up, Element Call returned to lobby — auto-dismiss
                // Only dismiss if call was previously connected (skip initial lobby during load)
                if viewModelContext?.viewState.wasConnected == true {
                    viewModelContext?.send(viewAction: .endCall)
                }
            }
        }
        
        // This function is called by the webview output routing button
        // it allows to open the OS output selector using the hidden button.
        private func tapRoutePickerView() {
            guard let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton else {
                return
            }
            
            button.sendActions(for: .touchUpInside)
        }
        
        // MARK: - WKUIDelegate
        
        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            // Allow if the origin is local, otherwise don't allow permissions for domains different than what the call was started on
            guard origin.protocol == "file" || origin.host == url.host else {
                return .deny
            }
            
            viewModelContext?.send(viewAction: .mediaCapturePermissionGranted)
            return .grant
        }
        
        // MARK: - WKNavigationDelegate
        
        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            await certificateValidator.respondTo(challenge)
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let navigationURL = navigationAction.request.url {
                // Do not allow navigation to a different URL scheme.
                if navigationURL.scheme != url.scheme {
                    return .cancel
                }
                
                // Allow any content from the main URL.
                if navigationURL.host == url.host {
                    return .allow
                }
            }
            
            // Additionally allow any embedded content such as captchas.
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                return .allow
            }
            
            // Otherwise the request is invalid.
            return .cancel
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            viewModelContext?.send(viewAction: .urlChanged(webView.url))
        }
        
        // MARK: - Picture in Picture
        
        func requestPictureInPicture() async -> Result<Void, CallScreenError> {
            guard let pictureInPictureController,
                  pictureInPictureController.isPictureInPicturePossible,
                  case .success(true) = await webViewCanEnterPictureInPicture() else {
                return .failure(.pictureInPictureNotAvailable)
            }
            
            pictureInPictureController.startPictureInPicture()
            return .success(())
        }
        
        func stopPictureInPicture() {
            pictureInPictureController?.stopPictureInPicture()
        }
        
        nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                // We move the view via the delegate so it works when you background the app without calling requestPictureInPicture
                pictureInPictureViewController.view.addMatchedSubview(webView)
                _ = try? await evaluateJavaScript("controls.enablePip()")
            }
        }
        
        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                // Double check that the controller is definitely showing a page that supports picture in picture.
                // This is necessary as it doesn't get checked when backgrounding the app or tapping a notification.
                guard case .success(true) = await webViewCanEnterPictureInPicture() else {
                    MXLog.error("Picture in picture started on a webpage that doesn't support it. Ending the call.")
                    viewModelContext?.send(viewAction: .endCall)
                    return
                }
            }
        }
        
        nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { await viewModelContext?.send(viewAction: .pictureInPictureWillStop) }
        }
        
        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                webViewWrapper.addMatchedSubview(webView)
                _ = try? await evaluateJavaScript("controls.disablePip()")
            }
        }
        
        /// Whether the web view can do picture in picture or not (e.g. it is showing an error or the page didn't load).
        private func webViewCanEnterPictureInPicture() async -> Result<Bool, CallScreenError> {
            do {
                guard let canEnterPictureInPicture = try await evaluateJavaScript("controls.canEnterPip()") as? Bool else {
                    MXLog.error("canEnterPip returned an unexpected value, skipping picture in picture.")
                    return .failure(.pictureInPictureNotAvailable)
                }
                MXLog.info("canEnterPip returned \(canEnterPictureInPicture)")
                return .success(canEnterPictureInPicture)
            } catch {
                MXLog.error("Error checking canEnterPip: \(error)")
                return .failure(.pictureInPictureNotAvailable)
            }
        }
    }
    
    /// Avoids retain loops between the configuration and webView coordinator
    private class WKScriptMessageHandlerWrapper: NSObject, WKScriptMessageHandler {
        private weak var coordinator: Coordinator?
        
        init(_ coordinator: Coordinator) {
            self.coordinator = coordinator
        }
        
        // MARK: - WKScriptMessageHandler
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.userContentController(userContentController, didReceive: message)
        }
    }
}

// MARK: - Previews

struct CallScreen_Previews: PreviewProvider {
    static let viewModel = {
        let clientProxy = ClientProxyMock()
        clientProxy.deviceID = "call-device-id"
        
        let roomProxy = JoinedRoomProxyMock()
        
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = PassthroughSubject<ElementCallWidgetDriverAction, Never>().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver
        
        return CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                   configuration: .init(roomProxy: roomProxy,
                                                        clientProxy: clientProxy,
                                                        clientID: "io.element.elementx",
                                                        elementCallBaseURL: "https://call.element.io",
                                                        elementCallBaseURLOverride: nil,
                                                        colorScheme: .light),
                                   allowPictureInPicture: false,
                                   appHooks: AppHooks(),
                                   appSettings: ServiceLocator.shared.settings,
                                   analyticsService: ServiceLocator.shared.analytics)
    }()
    
    static var previews: some View {
        CallScreen(context: viewModel.context)
    }
}
