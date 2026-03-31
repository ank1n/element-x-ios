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
    @State private var showParticipants = false

    private var isMinimized: Bool {
        context.viewState.isMinimized
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all)

                if !isMinimized {
                    // sTalk: Native call control buttons at bottom
                    VStack {
                        Spacer()
                        ZStack(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.3), .black.opacity(0.75)],
                                           startPoint: .top,
                                           endPoint: .bottom)
                                .frame(height: 140)
                                .allowsHitTesting(false)

                            callControlButtons
                                .padding(.bottom, 48)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                } else {
                    // sTalk: Mini controls for floating window
                    miniControls
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(isMinimized ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if !isMinimized { toolbar }
            }
        }
        .ignoresSafeArea()
        .alert(item: $context.alertInfo)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showRecordingConsent) {
            RecordingConsentView(onConfirm: {
                                     showRecordingConsent = false
                                     context.send(viewAction: .confirmStartRecording)
                                 },
                                 onCancel: {
                                     showRecordingConsent = false
                                 })
                                 .presentationDetents([.medium])
        }
        .sheet(isPresented: $showParticipants) {
            CallParticipantsSheet(participants: context.viewState.participants,
                                  activeParticipantIDs: Set(context.viewState.activeCallParticipantIDs),
                                  mediaProvider: context.viewState.mediaProvider)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(20)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(UIColor.systemBackground))
        }
    }

    /// Mini controls for floating window mode.
    /// Tap on video area → restore fullscreen. Buttons: mic, camera, hangup.
    private var miniControls: some View {
        VStack(spacing: 0) {
            // Tap area — tap anywhere on video to return to fullscreen
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    context.send(viewAction: .restoreFromMinimized)
                }

            // Bottom control bar
            HStack(spacing: 10) {
                // Mic
                Button {
                    context.send(viewAction: .toggleMute)
                } label: {
                    Image(systemName: context.viewState.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(context.viewState.isMuted ? Color(red: 0.1, green: 0.1, blue: 0.1) : .white)
                        .frame(width: 26, height: 26)
                        .background(context.viewState.isMuted ? Color.white.opacity(0.9) : Color.white.opacity(0.2))
                        .clipShape(Circle())
                }

                // Camera
                Button {
                    context.send(viewAction: .toggleVideo)
                } label: {
                    Image(systemName: context.viewState.isVideoEnabled ? "video.fill" : "video.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(context.viewState.isVideoEnabled ? .white : Color(red: 0.1, green: 0.1, blue: 0.1))
                        .frame(width: 26, height: 26)
                        .background(context.viewState.isVideoEnabled ? Color.white.opacity(0.2) : Color.white.opacity(0.9))
                        .clipShape(Circle())
                }

                // Hangup
                Button {
                    context.send(viewAction: .endCall)
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Color(red: 1.0, green: 0.23, blue: 0.19))
                        .clipShape(Circle())
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.6))
        }
    }
    
    @ViewBuilder
    var content: some View {
        if let roomManager = context.viewState.liveKitRoomManager, context.viewState.url == nil {
            // sTalk: Native call mode — no WebView, native LiveKit rendering
            NativeCallGridView(roomManager: roomManager,
                               isDirect: context.viewState.isDirect,
                               isMinimized: isMinimized)
                .ignoresSafeArea()
        } else if context.viewState.url == nil {
            ProgressView()
        } else {
            ZStack {
                // sTalk: WebView renders Element Call video fullscreen.
                // CSS injection hides EC UI chrome (header, buttons) — only video tiles visible.
                // Our native SwiftUI controls overlay on top.
                CallView(url: context.viewState.url, viewModelContext: context)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }
    
    // sTalk: Native call control buttons
    var callControlButtons: some View {
        HStack(spacing: context.viewState.isDirect ? 20 : 14) {
            // Hand raise (group only)
            if !context.viewState.isDirect {
                CallControlButton(icon: "hand.raised.fill",
                                  label: SL10n.callHand,
                                  isActive: context.viewState.isHandRaised) {
                    context.send(viewAction: .toggleHandRaise)
                }
            }

            // Screen share (group only)
            if !context.viewState.isDirect {
                CallControlButton(icon: context.viewState.isScreenSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle",
                                  label: SL10n.callScreenShare,
                                  isActive: context.viewState.isScreenSharing) {
                    context.send(viewAction: .toggleScreenShare)
                }
            }

            // Camera
            CallControlButton(icon: context.viewState.isVideoEnabled ? "video.fill" : "video.slash.fill",
                              label: SL10n.callCamera,
                              isActive: context.viewState.isVideoEnabled) {
                context.send(viewAction: .toggleVideo)
            }

            // Microphone — muted: перечёркнутый микрофон (белый фон), active: микрофон (прозрачный фон)
            CallControlButton(icon: context.viewState.isMuted ? "mic.slash.fill" : "mic.fill",
                              label: context.viewState.isMuted ? SL10n.callMicOn : SL10n.callMic,
                              isActive: !context.viewState.isMuted) {
                context.send(viewAction: .toggleMute)
            }

            // Speaker toggle — earpiece (phone icon) ↔ speaker (speaker icon), like Telegram
            CallControlButton(icon: context.viewState.isSpeakerOn ? "speaker.wave.3.fill" : "phone.fill",
                              label: context.viewState.isSpeakerOn ? SL10n.callSpeaker : SL10n.callPhone,
                              isActive: context.viewState.isSpeakerOn) {
                context.send(viewAction: .toggleSpeaker)
            }

            // End call
            CallControlButton(icon: "phone.down.fill",
                              label: SL10n.callEnd,
                              style: .destructive) {
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
                    Text(SL10n.callBack)
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

        // sTalk: Participants button
        if !context.viewState.isDirect {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showParticipants = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 13))
                        Text("\(context.viewState.callParticipantsCount)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())
                }
            }
        }

        // sTalk: Recording button in toolbar (top-right, same level as "Назад")
        if context.viewState.isRecordingEnabled || context.viewState.isRemoteRecording {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    if context.viewState.isRemoteRecording, !context.viewState.recordingState.isRecording {
                        // Remote recording — show red indicator, no action
                        RecordingButton(recordingState: .recording(egressId: "remote", duration: 0)) { }
                            .disabled(true)
                    } else {
                        RecordingButton(recordingState: context.viewState.recordingState) {
                            if context.viewState.recordingState.isRecording {
                                context.send(viewAction: .toggleRecording)
                            } else {
                                showRecordingConsent = true
                            }
                        }
                    }
                }
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
    var isActive = true
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
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        private weak var viewModelContext: CallScreenViewModel.Context?
        private let certificateValidator: CertificateValidatorHookProtocol

        private var webView: WKWebView!
        private var routePickerView: AVRoutePickerView!

        /// Minimal wrapper returned to SwiftUI — WebView needs non-zero frame for JS/getUserMedia.
        let webViewWrapper: WebViewWrapper = {
            let v = WebViewWrapper(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            v.backgroundColor = .black
            v.isOpaque = false
            return v
        }()

        // sTalk: WebView in same hierarchy but CSS injection hides all visual content.

        private var url: URL!
        
        init(viewModelContext: CallScreenViewModel.Context) {
            self.viewModelContext = viewModelContext
            certificateValidator = viewModelContext.viewState.certificateValidator

            super.init()
            
            DispatchQueue.main.async { // Avoid `Publishing changes from within view update` warnings
                viewModelContext.javaScriptEvaluator = self.evaluateJavaScript
                viewModelContext.showSpeakerPickerHandler = self.tapRoutePickerView
                // sTalk: Handler to remove WebView from view hierarchy (kills IOSurface compositing).
                // Called after LiveKit credentials are captured — WebView no longer needs to render.
                viewModelContext.hideWebViewHandler = { [weak self] in
                    guard let self else { return }
                    self.webView.removeFromSuperview()
                    self.webView.frame = .zero
                    MXLog.info("sTalk: WebView removed from superview — IOSurface should stop compositing")
                }
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
            
            // sTalk: Inject WebSocket interception + CSS hiding script BEFORE page loads.
            // forMainFrameOnly: false — Element Call UI renders in iframes,
            // CSS must apply to ALL frames to hide their content.
            let wsHookScript = WKUserScript(source: CallScreenJavaScriptMessageName.webSocketInterceptionScript,
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: false)
            configuration.userContentController.addUserScript(wsHookScript)

            if let script = viewModelContext.viewState.script {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
                configuration.userContentController.addUserScript(userScript)
            }

            // sTalk: DOM-clearing script no longer needed — WebView is in off-screen UIWindow,
            // IOSurface doesn't render in the visible area.
            
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            webView.uiDelegate = self
            webView.navigationDelegate = self
            webView.isInspectable = true

            // https://stackoverflow.com/a/77963877/730924
            webView.allowsLinkPreview = true

            // sTalk: WebView is used ONLY for Widget API signaling.
            // It will be removed from view hierarchy in didFinish after page loads.
            webView.isOpaque = false
            webView.backgroundColor = .clear
            
            // This button is always hidden and is only used to be programmatically tapped
            routePickerView = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 0, height: 0))
            routePickerView.isHidden = true
            routePickerView.isUserInteractionEnabled = false
            webViewWrapper.addSubview(routePickerView)
            
            // sTalk: Place WebView in a SEPARATE off-screen UIWindow.
            // WKWebView IOSurface compositing happens at the system compositor level
            // and renders ABOVE all UIKit/SwiftUI views regardless of opacity, hidden,
            // alpha, transform, frame constraints, or CSS display:none.
            // The ONLY reliable solution: put the WebView in a different UIWindow
            // that is off-screen. IOSurface is confined to that window's coordinate space.
            // WebView still loads pages, executes JS, and receives WKScriptMessages —
            // it just doesn't render anywhere visible.
            // sTalk: WebView must be in a view hierarchy for page loading and JS execution.
            // IOSurface hiding is handled by CSS injection (html{display:none}) at atDocumentStart.
            // When the WebView renders nothing, IOSurface is empty/transparent.
            webViewWrapper.addMatchedSubview(webView)

            // sTalk: PiP via WebView is not usable — we use native LiveKit video.
            // Skip AVPictureInPictureController setup entirely.
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
            case .onLobbyDetected:
                // sTalk: Debug messages from DOM clearing script — ignore
                if let msg = message.body as? String,
                   msg.hasPrefix("domClear") {
                    MXLog.info("sTalk: DOM clearing: \(msg)")
                    return
                }
                // sTalk: Remote party hung up, Element Call returned to lobby — auto-dismiss.
                // Safety: only trigger after 5+ seconds of connected call to avoid false positives.
                if let elapsed = viewModelContext?.viewState.callElapsedTime,
                   elapsed > 5 {
                    viewModelContext?.send(viewAction: .endCall)
                }
            case .onHandRaiseStateChanged:
                // sTalk: Update hand raise state from WebView observer
                if let stateStr = message.body as? String {
                    viewModelContext?.send(viewAction: .handRaiseStateChanged(raised: stateStr == "raised"))
                }
            case .onLiveKitCredentials:
                // sTalk: LiveKit credentials intercepted from WebSocket URL
                MXLog.info("sTalk WS Hook: raw message received: \(String(describing: message.body).prefix(300))")
                guard let jsonString = message.body as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    MXLog.info("sTalk WS Hook: failed to parse JSON")
                    return
                }
                // Debug messages — just log WS URLs being created
                if json["debug"] != nil {
                    MXLog.info("sTalk WS Hook DEBUG: WebSocket created — \(json["wsUrl"] as? String ?? "?")")
                    return
                }
                guard let url = json["url"] as? String,
                      let token = json["token"] as? String else {
                    MXLog.info("sTalk WS Hook: no url/token in JSON")
                    return
                }
                viewModelContext?.send(viewAction: .liveKitCredentialsIntercepted(url: url, token: token))
            }
        }
        
        /// This function is called by the webview output routing button
        /// it allows to open the OS output selector using the hidden button.
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
            // sTalk: Do NOT removeFromSuperview() here.
            // didFinish fires when the HTML shell loads, but Element Call (React app)
            // hasn't finished initializing yet. Removing WebView kills getUserMedia,
            // WebSocket creation, and Widget API — content_loaded never arrives.
            // WebView is already 1x1 with opacity 0.01 — IOSurface renders ~nothing.
            MXLog.info("sTalk: WebView didFinish — keeping in hierarchy for EC initialization")
        }
        
        // MARK: - Picture in Picture (disabled — native video uses SwiftUI minimize overlay)

        func requestPictureInPicture() async -> Result<Void, CallScreenError> {
            .failure(.pictureInPictureNotAvailable)
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
                                                        clientID: "ru.implica.stalk",
                                                        elementCallBaseURL: "https://call.stalk.implica.ru",
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
