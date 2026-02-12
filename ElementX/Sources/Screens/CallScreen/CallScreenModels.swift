//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Foundation

enum CallScreenViewModelAction {
    case pictureInPictureIsAvailable(AVPictureInPictureController)
    case pictureInPictureStarted
    case pictureInPictureStopped
    case minimizeCall
    case dismiss
    case showRecordingConsent
}

struct CallScreenViewState: BindableState {
    let script: String?
    var url: URL?
    let isGenericCallLink: Bool

    let certificateValidator: CertificateValidatorHookProtocol

    // Recording state
    var recordingState: RecordingState = .idle
    var isRecordingEnabled: Bool = true

    // sTalk: call participant info
    var roomDisplayName: String?
    var callStatus: CallStatus = .connecting
    var callElapsedTime: TimeInterval = 0
    var isDirect: Bool = false
    var totalMembersCount: Int = 0
    var callParticipantsCount: Int = 0
    var participants: [CallParticipantInfo] = []
    var mediaProvider: MediaProviderProtocol?

    // sTalk: native call control state
    var isMuted: Bool = false
    var isVideoEnabled: Bool = true
    var isSpeakerOn: Bool = true
    var isHandRaised: Bool = false
    var wasConnected: Bool = false
    /// sTalk: Whether the call is shown as a mini floating window
    var isMinimized: Bool = false

    var callStatusText: String {
        switch callStatus {
        case .connecting:
            return "Вызов..."
        case .connected:
            let m = Int(callElapsedTime) / 60
            let s = Int(callElapsedTime) % 60
            let timeStr = String(format: "%d:%02d", m, s)
            if isDirect {
                return timeStr
            } else {
                return "\(timeStr) · \(callParticipantsCount) из \(totalMembersCount) участников"
            }
        case .reconnecting:
            return "Переподключение..."
        }
    }

    /// Stacked avatar info for StackedAvatarsView
    var stackedAvatars: [StackedAvatarInfo] {
        participants.prefix(3).map {
            StackedAvatarInfo(url: $0.avatarURL, name: $0.displayName, contentID: $0.userID)
        }
    }

    var bindings = Bindings()
}

struct Bindings {
    var javaScriptEvaluator: ((String) async throws -> Any)?
    var requestPictureInPictureHandler: (() async -> Result<Void, CallScreenError>)?
    var showSpeakerPickerHandler: (() -> Void)?

    var alertInfo: AlertInfo<UUID>?
}

enum CallScreenViewAction {
    case urlChanged(URL?)
    case pictureInPictureIsAvailable(AVPictureInPictureController)
    case navigateBack
    case pictureInPictureWillStop
    case endCall
    case mediaCapturePermissionGranted
    case outputDeviceSelected(deviceID: String)
    case widgetAction(message: String)
    // Recording actions
    case toggleRecording
    case confirmStartRecording
    // Native call control actions
    case toggleMute
    case toggleVideo
    case showSpeakerPicker
    case toggleHandRaise
    case handRaiseStateChanged(raised: Bool)
    /// sTalk: Restore from minimized mini-window to fullscreen
    case restoreFromMinimized
}

enum CallScreenError: Error {
    case pictureInPictureNotAvailable
}

// MARK: - sTalk Call Status

enum CallStatus: Equatable {
    case connecting
    case connected
    case reconnecting
}

// MARK: - sTalk Call Participant Info

struct CallParticipantInfo: Identifiable {
    let userID: String
    let displayName: String?
    let avatarURL: URL?

    var id: String { userID }
}

/// Identifies each event handler used by the CallScreen webview
///
/// The names of the enum need to always match the name of the handlers on the webview.
enum CallScreenJavaScriptMessageName: String, CaseIterable {
    /// Widget actions's handler.
    case widgetAction
    /// Used to show the native AVRoutePickerView.
    case showNativeOutputDevicePicker
    /// Used to determine if the webview has selected the earpiece or not.
    case onOutputDeviceSelect
    /// Used to handle the webview back button
    case onBackButtonPressed
    /// sTalk: Used to detect when Element Call returns to lobby (remote hangup)
    case onLobbyDetected
    /// sTalk: Used to detect hand raise state changes from WebView
    case onHandRaiseStateChanged
    
    private var postMessageScript: String {
        switch self {
        case .widgetAction:
            """
            window.addEventListener(
                "message",
                (event) => {
                    let message = {data: event.data, origin: event.origin};
                    if (message.data.response && message.data.api == "toWidget"
                    || !message.data.response && message.data.api == "fromWidget") {
                        window.webkit.messageHandlers.\(rawValue).postMessage(JSON.stringify(message.data));
                    } else {
                        console.log("-- skipped event handling by the client because it is send from the client itself.");
                    }
                },
                false,
            );
            """
        case .showNativeOutputDevicePicker:
            """
            window.controls.\(rawValue) = () => {
                window.webkit.messageHandlers.\(rawValue).postMessage("");
            };
            """
        case .onOutputDeviceSelect:
            """
            window.controls.\(rawValue) = (id) => {
                window.webkit.messageHandlers.\(rawValue).postMessage(id);
            };
            """
        case .onBackButtonPressed:
            """
            window.controls.\(rawValue) = () => {
                window.webkit.messageHandlers.\(rawValue).postMessage("");
            }
            """
        case .onLobbyDetected:
            """
            // sTalk: Detect lobby state (remote hangup) via MutationObserver
            (function() {
                var lobbyNotified = false;
                function checkForLobby() {
                    if (lobbyNotified) return;
                    // Element Call lobby has a "Join" or "Join call" button
                    var joinBtn = document.querySelector('[data-testid="lobby_joinCall"]');
                    if (!joinBtn) {
                        // Fallback: look for lobby container class
                        joinBtn = document.querySelector('[class*="_lobby"]');
                    }
                    if (joinBtn) {
                        lobbyNotified = true;
                        window.webkit.messageHandlers.\(rawValue).postMessage("lobby");
                    }
                }
                var lobbyObserver = new MutationObserver(function() { checkForLobby(); });
                lobbyObserver.observe(document.body || document.documentElement, { childList: true, subtree: true });
                // Also check periodically
                setInterval(checkForLobby, 2000);
            })();
            """
        case .onHandRaiseStateChanged:
            """
            // sTalk: Toggle hand raise via DOM click and observe state changes
            window.stalkToggleHandRaise = function() {
                var btn = document.querySelector('[class*="_raiseHand"] button');
                if (!btn) btn = document.querySelector('[class*="_raiseHand"]');
                if (btn) btn.click();
                return !!btn;
            };
            // Observe hand raise state: Element Call toggles aria-pressed or a CSS class on the button
            (function() {
                var lastState = false;
                function checkHandRaise() {
                    var btn = document.querySelector('[class*="_raiseHand"] button');
                    if (!btn) return;
                    var raised = btn.getAttribute('aria-pressed') === 'true' || btn.classList.contains('active');
                    if (raised !== lastState) {
                        lastState = raised;
                        window.webkit.messageHandlers.\(rawValue).postMessage(raised ? "raised" : "lowered");
                    }
                }
                var hrObserver = new MutationObserver(function() { checkHandRaise(); });
                hrObserver.observe(document.body || document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['aria-pressed', 'class'] });
                setInterval(checkHandRaise, 1000);
            })();
            """
        }
    }
    
    static var allCasesInjectionScript: String {
        allCases.map(\.postMessageScript).joined(separator: "\n") + "\n" + telegramStyleInjectionScript
    }

    // MARK: - sTalk Telegram-style CSS Injection

    /// JavaScript that injects Telegram-style CSS + DOM manipulation into Element Call.
    /// Uses CSS Module attribute selectors ([class*="..."]) to match hashed class names,
    /// plus MutationObserver for dynamic DOM manipulation (hiding extra buttons, forcing full-screen tiles).
    private static var telegramStyleInjectionScript: String {
        """
        (function() {
            if (document.getElementById('stalk-telegram-style')) return;

            // 1. Inject CSS
            var style = document.createElement('style');
            style.id = 'stalk-telegram-style';
            style.textContent = `
                /* ===== sTalk: Telegram-style Call Screen ===== */

                /* ===== LAYOUT: Full-viewport video ===== */

                /* Body + #root: fixed fullscreen */
                body { background: #000 !important; margin: 0 !important; padding: 0 !important; overflow: hidden !important; }
                #root { background: #000 !important; position: fixed !important; inset: 0 !important; width: 100% !important; height: 100% !important; overflow: hidden !important; }
                #root > * { position: absolute !important; inset: 0 !important; width: 100% !important; height: 100% !important; }

                /* _inRoom: block (not flex!) so hidden children leave no gaps */
                [class*="_inRoom"] {
                    background: #000 !important;
                    overflow: hidden !important;
                    position: fixed !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    display: block !important;
                }

                /* ===== HIDE: header, footer, lobby and ALL non-video containers ===== */
                [class*="_header_"], [class*="_header_"] * { display: none !important; height: 0 !important; overflow: hidden !important; }
                [class*="_filler_"], [class*="_filler_"] * { display: none !important; height: 0 !important; }
                [class*="_footer_"], [class*="_footer_"] * { display: none !important; height: 0 !important; visibility: hidden !important; }
                [class*="_bar_"], [class*="_bar_"] * { display: none !important; height: 0 !important; }
                [class*="_logo_"], [class*="_layout_"] { display: none !important; height: 0 !important; }
                [class*="_lobby"] { display: none !important; }

                /* ===== 1:1 (direct): hide scrollingGrid, show spotlight fullscreen ===== */
                body.stalk-direct [class*="_scrollingGrid"] { display: none !important; }
                body.stalk-direct [class*="_spotlight"] { display: block !important; }

                /* ===== Group: hide spotlight, show scrollingGrid as grid ===== */
                body.stalk-group [class*="_spotlight"] { display: none !important; }
                body.stalk-group [class*="_scrollingGrid"] {
                    display: grid !important;
                    grid-template-columns: repeat(2, 1fr) !important;
                    gap: 4px !important;
                    padding: 4px !important;
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    overflow: hidden !important;
                }

                /* Group tile: rounded, dark background */
                body.stalk-group [class*="_scrollingGrid"] [class*="_tile"] {
                    border-radius: 12px !important;
                    overflow: hidden !important;
                    background: #1a1a1a !important;
                    position: relative !important;
                }

                /* Group tile video: cover */
                body.stalk-group [class*="_scrollingGrid"] video {
                    object-fit: cover !important;
                    width: 100% !important;
                    height: 100% !important;
                    border-radius: 12px !important;
                }

                /* Group: show name tags on tiles */
                body.stalk-group [class*="_scrollingGrid"] [class*="_nameTag"],
                body.stalk-group [class*="_scrollingGrid"] [class*="_displayName"] {
                    display: block !important;
                    position: absolute !important;
                    bottom: 8px !important;
                    left: 8px !important;
                    color: white !important;
                    font-size: 13px !important;
                    text-shadow: 0 1px 3px rgba(0,0,0,0.8) !important;
                    z-index: 10 !important;
                }

                /* Default: hide scrollingGrid until body class is set */
                [class*="_scrollingGrid"] { display: none !important; }

                /* ===== fixedGrid: fill entire _inRoom ===== */
                [class*="_fixedGrid"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                }

                /* ===== CRITICAL: spotlight — remove grid/aspect-ratio 16/9, fill parent ===== */
                [class*="_spotlight"] {
                    display: block !important;
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    max-width: none !important;
                    max-height: none !important;
                    aspect-ratio: unset !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    container-type: normal !important;
                }

                /* slot: fill spotlight absolutely */
                [class*="_slot"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    inline-size: 100% !important;
                    block-size: 100% !important;
                    max-width: none !important;
                    max-height: none !important;
                    background: #000 !important;
                }

                /* tile: fill slot */
                [class*="_tile_110p2"],
                [class*="_tile_110p2"][class*="_maximised"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    flex-grow: 1 !important;
                }

                /* media tile: fill parent, no radius */
                [class*="_tile_31vx3"],
                [class*="_tile_31vx3"] * {
                    --media-view-border-radius: 0px !important;
                    border-radius: 0 !important;
                }
                [class*="_tile_31vx3"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    outline: none !important;
                    border: none !important;
                }

                /* contents wrapper: fill tile */
                [class*="_contents_18q5h"] {
                    width: 100% !important;
                    height: 100% !important;
                    border-radius: 0 !important;
                    border: none !important;
                }

                /* media view: fill contents */
                [class*="_media_1yzvo"],
                [class*="_media"] {
                    width: 100% !important;
                    height: 100% !important;
                    border-radius: 0 !important;
                    container-type: normal !important;
                }

                /* video element: cover entire area */
                video {
                    object-fit: cover !important;
                    object-position: center center !important;
                    border-radius: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                }

                /* ===== HIDE: avatar/noVideo overlay ===== */
                [class*="_noVideo"],
                [class*="_avatar"],
                [class*="_avatarContainer"],
                [class*="_videoMuted"] {
                    display: none !important;
                    visibility: hidden !important;
                    opacity: 0 !important;
                    height: 0 !important;
                    overflow: hidden !important;
                }

                /* ===== HIDE: non-essential UI ===== */
                [class*="_invite_110p2"],
                [class*="_shareScreen"],
                [class*="_screenshare"],
                [class*="_settings"],
                [class*="_settingsModal"],
                [class*="_emoji"],
                [class*="_reaction"],
                [class*="_buttons_110p2"],
                [class*="_bottomRightButtons"],
                [class*="_volumeSlider"],
                [class*="_switchCamera"],
                [class*="_debug"], [class*="_stats"],
                pre, code { display: none !important; }

                /* _raiseHand: off-screen but clickable for JS DOM click */
                [class*="_raiseHand"] {
                    position: fixed !important;
                    left: -9999px !important;
                    opacity: 0 !important;
                    pointer-events: auto !important;
                }

                /* _displayName, _nameTag: hidden by default, shown in group grid via body.stalk-group */
                body:not(.stalk-group) [class*="_displayName"],
                body:not(.stalk-group) [class*="_nameTag"] {
                    display: none !important;
                }

                /* mute icon: semi-transparent */
                [class*="_muteIcon_31vx3"] { opacity: 0.4 !important; }

                /* ===== KILL: all borders, outlines, scrollbars ===== */
                *, *::before, *::after {
                    border-style: none !important;
                    border-width: 0 !important;
                    outline: none !important;
                }
                ::-webkit-scrollbar { display: none !important; width: 0 !important; }
                hr, [role="separator"] { display: none !important; }

                .stalk-hidden { display: none !important; }
            `;
            document.head.appendChild(style);

            // 2. DOM manipulation via MutationObserver
            function applyTelegramLayout() {
                // _inRoom: fill viewport
                document.querySelectorAll('[class*="_inRoom"]').forEach(function(el) {
                    el.style.setProperty('position', 'fixed', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('overflow', 'hidden', 'important');
                });

                // fixedGrid: absolute, fill _inRoom
                document.querySelectorAll('[class*="_fixedGrid"]').forEach(function(el) {
                    el.style.setProperty('position', 'absolute', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                });

                // CRITICAL: spotlight — remove grid/aspect-ratio 16/9, fill parent
                document.querySelectorAll('[class*="_spotlight"]').forEach(function(el) {
                    el.style.setProperty('display', 'block', 'important');
                    el.style.setProperty('position', 'absolute', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('max-width', 'none', 'important');
                    el.style.setProperty('max-height', 'none', 'important');
                    el.style.setProperty('aspect-ratio', 'unset', 'important');
                    el.style.setProperty('margin', '0', 'important');
                    el.style.setProperty('padding', '0', 'important');
                    el.style.setProperty('container-type', 'normal', 'important');
                });

                // slot: fill spotlight
                document.querySelectorAll('[class*="_slot"]').forEach(function(el) {
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('inline-size', '100%', 'important');
                    el.style.setProperty('block-size', '100%', 'important');
                });

                // tiles: fill slot
                document.querySelectorAll('[class*="_tile_110p2"], [class*="_tile_31vx3"]').forEach(function(el) {
                    el.style.setProperty('position', 'absolute', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('border-radius', '0', 'important');
                });

                // contents + media: fill tile
                document.querySelectorAll('[class*="_contents_18q5h"], [class*="_media"]').forEach(function(el) {
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('border-radius', '0', 'important');
                    el.style.setProperty('container-type', 'normal', 'important');
                });

                // Hide avatar/noVideo overlays
                document.querySelectorAll('[class*="_noVideo"], [class*="_avatar"], [class*="_avatarContainer"], [class*="_videoMuted"]').forEach(function(el) {
                    el.style.setProperty('display', 'none', 'important');
                    el.style.setProperty('visibility', 'hidden', 'important');
                });

                // video: cover, centered
                document.querySelectorAll('video').forEach(function(el) {
                    el.style.setProperty('object-fit', 'cover', 'important');
                    el.style.setProperty('object-position', 'center center', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                });

                // sTalk: Walk up from <video> element — definitive fix for avatar/whitespace/position
                ensureVideoFullscreen();
            }

            // sTalk: For 1:1 calls — walk up from <video>, hide non-video siblings,
            // make each ancestor absolutely fill its parent with black background.
            // This definitively fixes: avatar-at-top, white stripes, video position.
            function ensureVideoFullscreen() {
                if (!document.body.classList.contains('stalk-direct')) return;
                var video = document.querySelector('video');
                if (!video) return;
                var current = video;
                while (current.parentElement && current.parentElement !== document.body && current.parentElement !== document.documentElement) {
                    var parent = current.parentElement;
                    // Each container in the chain: absolute, fill parent, black bg
                    if (current !== video) {
                        current.style.setProperty('position', 'absolute', 'important');
                        current.style.setProperty('inset', '0', 'important');
                        current.style.setProperty('width', '100%', 'important');
                        current.style.setProperty('height', '100%', 'important');
                        current.style.setProperty('overflow', 'hidden', 'important');
                        current.style.setProperty('background', '#000', 'important');
                        current.style.setProperty('margin', '0', 'important');
                        current.style.setProperty('padding', '0', 'important');
                        current.style.setProperty('container-type', 'normal', 'important');
                    }
                    // Hide all siblings that are NOT on the path to video
                    Array.from(parent.children).forEach(function(child) {
                        if (child !== current && child.tagName !== 'STYLE' && child.tagName !== 'SCRIPT') {
                            child.style.setProperty('display', 'none', 'important');
                        }
                    });
                    current = parent;
                }
            }

            // Run immediately and on DOM changes
            applyTelegramLayout();
            var observer = new MutationObserver(function() { applyTelegramLayout(); });
            observer.observe(document.body || document.documentElement, { childList: true, subtree: true });

            // Also run after delays (React renders asynchronously)
            setTimeout(applyTelegramLayout, 500);
            setTimeout(applyTelegramLayout, 1500);
            setTimeout(applyTelegramLayout, 3000);
            setTimeout(applyTelegramLayout, 5000);

            // End of Telegram-style injection
        })();
        """
    }
}

struct DecodedWidgetMessage: Decodable {
    private static let decoder = JSONDecoder()
    private static let contentLoadedAction = "content_loaded"
    private static let fromWidget = "fromWidget"
    
    let action: String?
    let api: String?
    
    static func decode(message: String) throws -> DecodedWidgetMessage? {
        guard let data = message.data(using: .utf8) else {
            return nil
        }
        return try decoder.decode(DecodedWidgetMessage.self, from: data)
    }
    
    var hasLoaded: Bool {
        action == Self.contentLoadedAction && api == Self.fromWidget
    }
}
