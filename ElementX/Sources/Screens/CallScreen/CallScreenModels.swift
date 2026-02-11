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
    var participantCount: Int = 0
    var participants: [CallParticipantInfo] = []
    var mediaProvider: MediaProviderProtocol?

    // sTalk: native call control state
    var isMuted: Bool = false
    var isVideoEnabled: Bool = true
    var wasConnected: Bool = false

    var callStatusText: String {
        switch callStatus {
        case .connecting:
            return "Вызов..."
        case .connected:
            let m = Int(callElapsedTime) / 60
            let s = Int(callElapsedTime) % 60
            if isDirect {
                return String(format: "%d:%02d", m, s)
            } else {
                return "\(participantCount) участн. · " + String(format: "%d:%02d", m, s)
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

                /* Dark background — full viewport coverage */
                body { background: #000 !important; margin: 0 !important; padding: 0 !important; overflow: hidden !important; }
                #root { background: #000 !important; position: fixed !important; inset: 0 !important; width: 100% !important; height: 100% !important; overflow: hidden !important; }
                #root > * { position: absolute !important; inset: 0 !important; width: 100% !important; height: 100% !important; }

                /* _inRoom: override CSS Grid to single cell filling entire viewport */
                [class*="_inRoom"] {
                    background: #000 !important;
                    overflow: hidden !important;
                    position: fixed !important;
                    inset: 0 !important;
                    width: 100vw !important;
                    height: 100vh !important;
                    display: grid !important;
                    grid-template-rows: 1fr !important;
                    grid-template-columns: 1fr !important;
                }
                /* All children of _inRoom collapse into the single grid cell */
                [class*="_inRoom"] > * {
                    grid-row: 1 / -1 !important;
                    grid-column: 1 / -1 !important;
                }

                /* Hide header bar completely */
                [class*="_header_110p2"], [class*="_header_"] { display: none !important; height: 0 !important; min-height: 0 !important; max-height: 0 !important; visibility: hidden !important; }
                [class*="_filler_110p2"], [class*="_filler_"] { display: none !important; height: 0 !important; min-height: 0 !important; max-height: 0 !important; visibility: hidden !important; }
                [class*="_bar_32sbm"],
                [class*="_bar_32sbm"] * { display: none !important; height: 0 !important; min-height: 0 !important; max-height: 0 !important; overflow: hidden !important; border: none !important; visibility: hidden !important; }

                /* Hide logo and layout switch in footer */
                [class*="_logo_110p2"] { display: none !important; }
                [class*="_layout_110p2"] { display: none !important; }

                /* ALL tiles/spotlights/grids — fill screen, no gaps, no radius */
                [class*="_spotlight"],
                [class*="_fixedGrid"],
                [class*="_scrollingGrid"],
                [class*="_grid_"] {
                    position: fixed !important;
                    inset: 0 !important;
                    width: 100vw !important;
                    height: 100vh !important;
                    max-width: none !important;
                    max-height: none !important;
                    aspect-ratio: unset !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    pointer-events: initial !important;
                }
                [class*="_slot"],
                [class*="_slot"] > * {
                    width: 100% !important;
                    height: 100% !important;
                    max-width: none !important;
                    max-height: none !important;
                }

                [class*="_tile_110p2"],
                [class*="_tile_31vx3"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    max-width: none !important;
                    max-height: none !important;
                }
                [class*="_tile_31vx3"],
                [class*="_tile_31vx3"] * {
                    --media-view-border-radius: 0px !important;
                    border-radius: 0 !important;
                }
                [class*="_tile_31vx3"] {
                    outline: none !important;
                    border: none !important;
                }
                [class*="_tile_31vx3"]:hover { outline: none !important; }
                [class*="_tile_31vx3"]::before { display: none !important; }
                [class*="_contents_18q5h"] { border-radius: 0 !important; border: none !important; }

                video {
                    object-fit: cover !important;
                    border-radius: 0 !important;
                    width: 100vw !important;
                    height: 100vh !important;
                    position: fixed !important;
                    inset: 0 !important;
                }

                /* Footer — completely hidden, native SwiftUI buttons used instead */
                [class*="_footer_110p2"],
                [class*="_footer_110p2"] * {
                    display: none !important;
                    height: 0 !important;
                    min-height: 0 !important;
                    overflow: hidden !important;
                    visibility: hidden !important;
                }

                /* Hide non-essential buttons (emoji, settings, invite, screenshare, raise hand) */
                [class*="_invite_110p2"],
                [class*="_shareScreen"],
                [class*="_screenshare"],
                [class*="_settings"],
                [class*="_settingsModal"],
                [class*="_emoji"],
                [class*="_reaction"],
                [class*="_raiseHand"],
                [class*="_buttons_110p2"] {
                    display: none !important;
                }

                /* Kill ALL dashed borders on layout containers */
                [class*="_inRoom"], [class*="_inRoom"] *,
                [class*="_spotlight"], [class*="_spotlight"] *,
                [class*="_grid"], [class*="_grid"] *,
                [class*="_tile"], [class*="_tile"] *,
                [class*="_slot"], [class*="_slot"] *,
                [class*="_footer"], [class*="_footer"] *,
                [class*="_bar_"], [class*="_bar_"] *,
                [class*="_maximised"], [class*="_maximised"] *,
                #root, #root > * {
                    border: 0 none !important;
                    border-style: none !important;
                    border-image: none !important;
                    border-width: 0 !important;
                    outline: 0 none !important;
                    outline-style: none !important;
                }

                /* WebView buttons hidden — native SwiftUI buttons used */

                /* Kill ALL outlines, dashed borders, scrollbars */
                * { outline: none !important; }
                ::-webkit-scrollbar { display: none !important; width: 0 !important; }
                [class*="_tile"], [class*="_contents"], [class*="_spotlight"], [class*="_slot"],
                [class*="_bar_"], [class*="_inRoom"], [class*="_header"], [class*="_filler"],
                [class*="_footer"], [class*="_grid"], [class*="_maximised"] {
                    border: none !important;
                    outline: none !important;
                    box-shadow: none !important;
                    border-style: none !important;
                }
                /* Nuclear: kill ALL borders on ALL elements */
                *, *::before, *::after {
                    border-style: none !important;
                    border-width: 0 !important;
                    border-image: none !important;
                }
                /* Kill separator lines between content and footer */
                hr, [role="separator"] {
                    display: none !important;
                }
                /* Hide participant names — shown natively in toolbar */
                [class*="_displayName"], [class*="_nameTag"] {
                    display: none !important;
                }

                /* Hide stuff */
                [class*="_bottomRightButtons_18q5h"] { display: none !important; }
                [class*="_volumeSlider_31vx3"] { display: none !important; }
                [class*="_muteIcon_31vx3"] { opacity: 0.4 !important; }

                /* Elements marked hidden by JS */
                .stalk-hidden {
                    display: none !important;
                    visibility: hidden !important;
                }

                /* Hide debug overlay text, stats, WebRTC info */
                [class*="_debug"], [class*="_stats"], [class*="_debugInfo"],
                [class*="_framerate"], [class*="_resolution"],
                [class*="_statsOverlay"], [class*="_connectionStats"],
                [class*="_mediaInfo"], [class*="_videoInfo"],
                pre, code { display: none !important; visibility: hidden !important; opacity: 0 !important; }
                /* Hide ALL non-essential elements inside media tiles (stats overlays, debug text) */
                [class*="_tile_31vx3"] > div:not([class*="_contents"]),
                [class*="_tile"] [class*="_info"],
                [class*="_tile"] [class*="_stat"],
                [class*="_tile"] pre,
                [class*="_tile"] code,
                [class*="_tile"] [class*="_debug"],
                [class*="_mediaView"] > :not(video):not(canvas):not([class*="_avatar"]):not([class*="_displayName"]):not([class*="_nameTag"]) {
                    display: none !important;
                    visibility: hidden !important;
                }
            `;
            document.head.appendChild(style);

            // 2. DOM manipulation via MutationObserver
            function applyTelegramLayout() {
                // Force _inRoom grid to single row/column (override CSS Grid template)
                document.querySelectorAll('[class*="_inRoom"]').forEach(function(el) {
                    el.style.setProperty('position', 'fixed', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100vw', 'important');
                    el.style.setProperty('height', '100vh', 'important');
                    el.style.setProperty('grid-template-rows', '1fr', 'important');
                    el.style.setProperty('grid-template-columns', '1fr', 'important');
                    el.style.setProperty('overflow', 'hidden', 'important');
                });
                // All children of _inRoom into single cell
                document.querySelectorAll('[class*="_inRoom"] > *').forEach(function(el) {
                    el.style.setProperty('grid-row', '1 / -1', 'important');
                    el.style.setProperty('grid-column', '1 / -1', 'important');
                });

                // Force all spotlight/grid containers to fill screen
                document.querySelectorAll('[class*="spotlight"], [class*="_fixedGrid"], [class*="_scrollingGrid"], [class*="_grid_"]').forEach(function(el) {
                    el.style.setProperty('position', 'fixed', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100vw', 'important');
                    el.style.setProperty('height', '100vh', 'important');
                    el.style.setProperty('max-width', 'none', 'important');
                    el.style.setProperty('max-height', 'none', 'important');
                    el.style.setProperty('aspect-ratio', 'unset', 'important');
                    el.style.setProperty('margin', '0', 'important');
                });

                // Force tiles to fill parent
                document.querySelectorAll('[class*="_tile_110p2"], [class*="_tile_31vx3"]').forEach(function(el) {
                    el.style.setProperty('position', 'absolute', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('border-radius', '0', 'important');
                    el.style.setProperty('border', 'none', 'important');
                    el.style.setProperty('outline', 'none', 'important');
                });
                document.querySelectorAll('[class*="_contents_18q5h"]').forEach(function(el) {
                    el.style.setProperty('border-radius', '0', 'important');
                    el.style.setProperty('border', 'none', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                });

                // Kill ALL dashed/dotted borders via inline styles (highest priority)
                document.querySelectorAll('*').forEach(function(el) {
                    var cs = getComputedStyle(el);
                    if (cs.borderTopStyle === 'dashed' || cs.borderTopStyle === 'dotted' ||
                        cs.borderBottomStyle === 'dashed' || cs.borderBottomStyle === 'dotted' ||
                        cs.outlineStyle === 'dashed' || cs.outlineStyle === 'dotted') {
                        el.style.setProperty('border', 'none', 'important');
                        el.style.setProperty('border-style', 'none', 'important');
                        el.style.setProperty('outline', 'none', 'important');
                    }
                });

                // Hide WebRTC stats overlays (text with "frame", "Size:", "fps")
                document.querySelectorAll('[class*="_tile"] div, [class*="_tile"] span, [class*="_tile"] p').forEach(function(el) {
                    var txt = el.textContent || '';
                    if (txt.match(/frame|Size:|fps|bitrate|resolution|codec|Observed|Requested/i) && !el.querySelector('video') && !el.querySelector('canvas')) {
                        el.style.setProperty('display', 'none', 'important');
                    }
                });

                // All WebView buttons hidden — native SwiftUI controls used
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
