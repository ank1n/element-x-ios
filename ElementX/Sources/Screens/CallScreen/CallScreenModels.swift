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
}

enum CallScreenError: Error {
    case pictureInPictureNotAvailable
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
        }
    }
    
    static var allCasesInjectionScript: String {
        allCases.map(\.postMessageScript).joined(separator: "\n") + "\n" + telegramStyleInjectionScript
    }

    // MARK: - sTalk Telegram-style CSS Injection

    /// JavaScript that injects Telegram-style CSS into Element Call's DOM.
    /// Uses CSS Module attribute selectors ([class*="..."]) to match hashed class names.
    private static var telegramStyleInjectionScript: String {
        """
        (function() {
            if (document.getElementById('stalk-telegram-style')) return;
            var style = document.createElement('style');
            style.id = 'stalk-telegram-style';
            style.textContent = `
                /* ===== sTalk: Telegram-style Call Screen ===== */

                /* Dark background */
                body { background: #000 !important; }
                #root { background: #000 !important; }
                [class*="_inRoom_110p2"] { background: #000 !important; }

                /* Hide header bar completely */
                [class*="_header_110p2"] { display: none !important; }
                [class*="_filler_110p2"] { display: none !important; }
                [class*="_bar_32sbm"] {
                    height: 0 !important;
                    min-height: 0 !important;
                    overflow: hidden !important;
                }
                [class*="_bar_32sbm"] > header { display: none !important; }

                /* Hide logo and layout switch in footer */
                [class*="_logo_110p2"] { display: none !important; }
                [class*="_layout_110p2"] { display: none !important; }

                /* Full-screen tiles, no border radius */
                [class*="_tile_31vx3"] {
                    --media-view-border-radius: 0px !important;
                    outline: none !important;
                }
                [class*="_tile_31vx3"]:hover {
                    outline: none !important;
                }
                [class*="_contents_18q5h"] { border-radius: 0 !important; }
                [class*="_tile_18q5h"][class*="_maximised_18q5h"] [class*="_contents_18q5h"] {
                    border-radius: 0 !important;
                }

                /* Video fills the screen */
                video {
                    object-fit: cover !important;
                    border-radius: 0 !important;
                }

                /* Footer — semi-transparent gradient (Telegram-style) */
                [class*="_footer_110p2"] {
                    background: linear-gradient(to top, rgba(0,0,0,0.7) 0%, rgba(0,0,0,0.3) 60%, transparent 100%) !important;
                    padding-block-end: 40px !important;
                    grid-template-columns: 1fr auto 1fr !important;
                    grid-template-areas: ". buttons ." !important;
                }
                [class*="_footer_110p2"][class*="_overlay_110p2"] {
                    background: linear-gradient(to top, rgba(0,0,0,0.7) 0%, rgba(0,0,0,0.3) 60%, transparent 100%) !important;
                }

                @media (max-width: 660px) {
                    [class*="_footer_110p2"] {
                        grid-template-columns: 1fr auto 1fr !important;
                        grid-template-areas: ". buttons ." !important;
                    }
                }

                /* Control buttons row — centered, Telegram spacing */
                [class*="_controls_17lij"] {
                    gap: 20px !important;
                    justify-content: center !important;
                    align-items: center !important;
                }

                /* All control buttons → round semi-transparent circles */
                [class*="_controls_17lij"] button {
                    width: 52px !important;
                    height: 52px !important;
                    min-width: 52px !important;
                    min-height: 52px !important;
                    max-width: 52px !important;
                    border-radius: 50% !important;
                    background: rgba(255,255,255,0.15) !important;
                    backdrop-filter: blur(10px) !important;
                    -webkit-backdrop-filter: blur(10px) !important;
                    border: none !important;
                    padding: 0 !important;
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                    transition: background 0.2s ease !important;
                }
                [class*="_controls_17lij"] button:hover {
                    background: rgba(255,255,255,0.25) !important;
                }

                /* Active/toggled state — solid white (like Telegram muted mic) */
                [class*="_controls_17lij"] button[aria-pressed="true"],
                [class*="_controls_17lij"] button[data-state="on"] {
                    background: rgba(255,255,255,0.85) !important;
                }
                [class*="_controls_17lij"] button[aria-pressed="true"] svg,
                [class*="_controls_17lij"] button[data-state="on"] svg {
                    color: #1a1a1a !important;
                }

                /* White icons in control buttons */
                [class*="_controls_17lij"] button svg {
                    color: #ffffff !important;
                    width: 22px !important;
                    height: 22px !important;
                }

                /* End Call button — RED circle (Telegram-style) */
                [class*="_endCall_bwclo"] {
                    background: #FF3B30 !important;
                    width: 52px !important;
                    height: 52px !important;
                    min-width: 52px !important;
                    max-width: 52px !important;
                    border-radius: 50% !important;
                    backdrop-filter: none !important;
                    -webkit-backdrop-filter: none !important;
                    border: none !important;
                    padding: 0 !important;
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                }
                [class*="_endCall_bwclo"]:hover {
                    background: #E5342B !important;
                }
                [class*="_endCall_bwclo"] svg {
                    color: #ffffff !important;
                }

                /* Hide tile overlay buttons (fullscreen, etc.) */
                [class*="_bottomRightButtons_18q5h"] { display: none !important; }
                [class*="_volumeSlider_31vx3"] { display: none !important; }

                /* Camera switch button on tile — keep but restyle */
                [class*="_switchCamera_31vx3"] {
                    background: rgba(0,0,0,0.5) !important;
                    border: none !important;
                    border-radius: 50% !important;
                    backdrop-filter: blur(8px) !important;
                    -webkit-backdrop-filter: blur(8px) !important;
                }
            `;
            document.head.appendChild(style);
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
