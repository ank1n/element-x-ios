//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Foundation
import LiveKit

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
    /// sTalk: Remote recording detected (started by another participant)
    var isRemoteRecording: Bool = false

    // sTalk: call participant info
    var roomDisplayName: String?
    var callStatus: CallStatus = .connecting
    var callElapsedTime: TimeInterval = 0
    var isDirect: Bool = false
    var totalMembersCount: Int = 0
    var callParticipantsCount: Int = 0
    var participants: [CallParticipantInfo] = []
    var activeCallParticipantIDs: [String] = []
    var mediaProvider: MediaProviderProtocol?

    // sTalk: native call control state
    var isMuted: Bool = false
    var isVideoEnabled: Bool = true
    var isSpeakerOn: Bool = true
    var isHandRaised: Bool = false
    var wasConnected: Bool = false
    /// sTalk: Whether the call is shown as a mini floating window
    var isMinimized: Bool = false
    /// sTalk: Native LiveKit room manager for rendering video
    var liveKitRoomManager: LiveKitRoomManager?

    var callStatusText: String {
        switch callStatus {
        case .connecting:
            return SL10n.callCalling
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
            return SL10n.callReconnecting
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
    var showSpeakerPickerHandler: (() -> Void)?
    /// sTalk: Removes WebView from view hierarchy to kill IOSurface compositing.
    /// evaluateJavaScript() continues working — it's IPC to WebContent process.
    var hideWebViewHandler: (() -> Void)?

    var alertInfo: AlertInfo<UUID>?
}

enum CallScreenViewAction {
    case urlChanged(URL?)
    case pictureInPictureIsAvailable(AVPictureInPictureController)
    case navigateBack
    case pictureInPictureWillStop
    case endCall
    case mediaCapturePermissionGranted
    case widgetAction(message: String)
    // Recording actions
    case toggleRecording
    case confirmStartRecording
    // Native call control actions
    case toggleMute
    case toggleVideo
    case showSpeakerPicker
    case toggleSpeaker
    case toggleHandRaise
    case handRaiseStateChanged(raised: Bool)
    /// sTalk: Restore from minimized mini-window to fullscreen
    case restoreFromMinimized
    /// sTalk: LiveKit credentials intercepted from Element Call WebSocket
    case liveKitCredentialsIntercepted(url: String, token: String)
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
    /// sTalk: Used to detect when Element Call returns to lobby (remote hangup)
    case onLobbyDetected
    /// sTalk: Used to detect hand raise state changes from WebView
    case onHandRaiseStateChanged
    /// sTalk: LiveKit WebSocket credentials intercepted from Element Call
    case onLiveKitCredentials
    
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
        case .onLobbyDetected:
            """
            // sTalk: Detect remote hangup via 3 methods:
            // 1. Lobby "Join" button appears (data-testid, dynamically added/removed by EC)
            // 2. All video MediaStreams die (srcObject.active becomes false)
            // 3. Number of video elements drops to 0 after having 1+
            // NOTE: [class*="_lobby"] fallback REMOVED — it stays in DOM permanently, breaking hasLeftLobby.
            (function() {
                var hasLeftLobby = false;
                var hadActiveMedia = false;
                var hadVideoElements = false;
                var notified = false;

                function notifyCallEnded(reason) {
                    if (notified) return;
                    notified = true;
                    window.webkit.messageHandlers.\(rawValue).postMessage(reason);
                }

                function checkForCallEnd() {
                    // Method 1: Lobby "Join" button (only exists when EC is in lobby state)
                    var joinBtn = document.querySelector('[data-testid="lobby_joinCall"]');
                    if (joinBtn) {
                        if (hasLeftLobby) {
                            notifyCallEnded("lobby");
                            return;
                        }
                    } else {
                        hasLeftLobby = true;
                    }

                    // Method 2: Video MediaStream died
                    var videos = document.querySelectorAll('video');
                    var activeStreamCount = 0;
                    videos.forEach(function(v) {
                        if (v.srcObject && v.srcObject.active) {
                            activeStreamCount++;
                        }
                    });

                    if (activeStreamCount > 0) {
                        hadActiveMedia = true;
                    } else if (hadActiveMedia && hasLeftLobby) {
                        notifyCallEnded("mediaEnded");
                        return;
                    }

                    // Method 3: Video elements removed from DOM
                    if (videos.length > 0) {
                        hadVideoElements = true;
                    } else if (hadVideoElements && hasLeftLobby) {
                        notifyCallEnded("videoRemoved");
                        return;
                    }
                }

                var lobbyObserver = new MutationObserver(function() { checkForCallEnd(); });
                lobbyObserver.observe(document.body || document.documentElement, { childList: true, subtree: true });
                setInterval(checkForCallEnd, 1500);
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
        case .onLiveKitCredentials:
            // No injection needed — credentials are captured via atDocumentStart script
            ""
        }
    }

    /// sTalk: JS script injected at `.atDocumentStart` BEFORE Element Call loads.
    /// 1. Hides ALL Element Call UI via visibility:hidden, shows ONLY <video> elements.
    /// 2. MutationObserver makes video elements fullscreen as they appear.
    /// 3. Intercepts LiveKit WebSocket URL — logs credentials (pass-through, no blocking).
    /// 4. KS-Bridge: forwards E2EE encryption_keys to key-server for recording/guests.
    /// Element Call handles all signaling and media via its own WebSocket connection.
    static var webSocketInterceptionScript: String {
        """
        (function() {
            // === 1. CSS: Make all EC UI transparent, keep video pixel rendering ===
            // Strategy: color/background/border → transparent. Layout 100% preserved.
            // <video> renders pixel data from stream regardless of CSS colors.
            // This hides text, icons, buttons, avatars — but keeps grid/flex layout intact.
            (function() {
                var s = document.createElement('style');
                s.textContent = [
                    'html, body { background:#000!important; margin:0!important; padding:0!important; overflow:hidden!important }',
                    // Make all UI decorations invisible
                    'body * { color:transparent!important; background:transparent!important; border-color:transparent!important; box-shadow:none!important; outline:none!important; text-shadow:none!important; caret-color:transparent!important }',
                    // Hide SVG icons, images (avatars), canvases
                    'svg, img { opacity:0!important }',
                    // Ensure video background is black (for when no stream yet)
                    'video { background:#000!important }',
                ].join('\\n');
                (document.documentElement || document).appendChild(s);
            })();

            // === 3. Intercept LiveKit WebSocket — log credentials, pass through ===
            var OrigWS = window.WebSocket;
            var _intercepted = false;
            window.WebSocket = function(url, protocols) {
                var u = String(url);
                if (u.indexOf('/rtc') !== -1 && u.indexOf('access_token=') !== -1) {
                    if (!_intercepted) {
                        _intercepted = true;
                        var token = (u.match(/access_token=([^&]+)/) || [])[1] || '';
                        try {
                            window.webkit.messageHandlers.onLiveKitCredentials.postMessage(
                                JSON.stringify({ url: u, token: token })
                            );
                        } catch(e) {}
                        console.log('[sTalk] LiveKit credentials captured (pass-through)');
                    }
                }
                // Pass through ALL WebSockets — EC handles signaling and media
                return protocols !== undefined ? new OrigWS(url, protocols) : new OrigWS(url);
            };
            window.WebSocket.prototype = OrigWS.prototype;
            window.WebSocket.CONNECTING = 0;
            window.WebSocket.OPEN = 1;
            window.WebSocket.CLOSING = 2;
            window.WebSocket.CLOSED = 3;

            // === 4. KS-Bridge: Forward E2EE encryption_keys to key-server ===
            // Mirrors element-web KS-Bridge v7: intercepts fetch() calls that send
            // encryption_keys via sendToDevice or room events, and forwards per-participant
            // keys to key-server so recording-api and meet-app guests can decrypt media.
            (function() {
                var KS_BASE = '/api/keys/pp';

                function ksPost(url, body, token) {
                    var x = new XMLHttpRequest();
                    x.open('POST', url, true);
                    x.setRequestHeader('Content-Type', 'application/json');
                    if (token) x.setRequestHeader('Authorization', 'Bearer ' + token);
                    x.onload = function() { console.log('[KS-Bridge-iOS] POST ' + url.substring(0, 60) + ' -> ' + x.status); };
                    x.onerror = function() { console.warn('[KS-Bridge-iOS] XHR error'); };
                    x.send(body);
                }

                function getMatrixToken() {
                    try { return localStorage.getItem('mx_access_token') || ''; } catch(e) { return ''; }
                }

                function forwardKeys(roomId, identity, keysArr) {
                    crypto.subtle.digest('SHA-256', new TextEncoder().encode(roomId + '|m.call#ROOM')).then(function(hash) {
                        var lkRoom = btoa(String.fromCharCode.apply(null, new Uint8Array(hash))).replace(/=+$/, '');
                        var token = getMatrixToken();
                        console.log('[KS-Bridge-iOS] forwarding ' + keysArr.length + ' key(s) for ' + identity + ' lkRoom=' + lkRoom.substring(0, 20));
                        keysArr.forEach(function(k) {
                            if (!k.key) return;
                            ksPost(
                                KS_BASE + '/' + encodeURIComponent(lkRoom) + '/' + encodeURIComponent(identity),
                                JSON.stringify({ key: k.key, keyIndex: k.index || 0 }),
                                token
                            );
                        });
                    }).catch(function(e) { console.warn('[KS-Bridge-iOS] SHA error:', e); });
                }

                // Intercept fetch() — catches Widget Driver HTTP calls to Synapse
                var _fetch = window.fetch;
                window.fetch = function(url, opts) {
                    var s = (typeof url === 'string') ? url : (url instanceof URL) ? url.href : (url && url.url) || '';
                    if (opts && opts.body && opts.method && opts.method.toUpperCase() === 'PUT') {
                        // sendToDevice path
                        if (s.indexOf('/sendToDevice/') !== -1 && s.indexOf('encryption_keys') !== -1) {
                            try {
                                var body = JSON.parse(opts.body);
                                var msgs = body.messages;
                                if (msgs) {
                                    var fu = Object.keys(msgs)[0], fd = Object.keys(msgs[fu])[0], c = msgs[fu][fd];
                                    var roomId = c.room_id;
                                    var senderId = c.member ? c.member.id : '';
                                    var senderDevice = c.member ? c.member.claimed_device_id : '';
                                    var keys = c.keys;
                                    if (roomId && keys && senderId) {
                                        forwardKeys(roomId, senderId + ':' + senderDevice, Array.isArray(keys) ? keys : [keys]);
                                    }
                                }
                            } catch(e) { console.warn('[KS-Bridge-iOS] fetch parse error:', e); }
                        }
                        // Room event path
                        if (s.indexOf('/send/') !== -1 && s.indexOf('encryption_keys') !== -1) {
                            try {
                                var body2 = JSON.parse(opts.body);
                                var keys2 = body2.keys;
                                if (keys2) {
                                    var rm = s.match(/\\/rooms\\/([^/]+)\\/send\\//);
                                    var rid = rm ? decodeURIComponent(rm[1]) : null;
                                    var uid = localStorage.getItem('mx_user_id') || '';
                                    var did = localStorage.getItem('mx_device_id') || '';
                                    if (rid && uid) {
                                        forwardKeys(rid, uid + ':' + did, Array.isArray(keys2) ? keys2 : [keys2]);
                                    }
                                }
                            } catch(e) { console.warn('[KS-Bridge-iOS] room event parse error:', e); }
                        }
                    }
                    return _fetch.apply(this, arguments);
                };

                console.log('[KS-Bridge-iOS] v1 initialized (fetch intercept)');
            })();
        })();
        """
    }

    static var allCasesInjectionScript: String {
        allCases.map(\.postMessageScript).joined(separator: "\n")
    }

    // sTalk: domClearingScript removed — WebView is in off-screen UIWindow,
    // IOSurface doesn't render in visible area. No DOM manipulation needed.
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
