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

                /* Dark background */
                body { background: #000 !important; margin: 0 !important; overflow: hidden !important; }
                #root { background: #000 !important; height: 100vh !important; overflow: hidden !important; }
                [class*="_inRoom_110p2"] { background: #000 !important; overflow: hidden !important; }

                /* Hide header bar completely */
                [class*="_header_110p2"] { display: none !important; }
                [class*="_filler_110p2"] { display: none !important; }
                [class*="_bar_32sbm"] { height: 0 !important; min-height: 0 !important; overflow: hidden !important; }
                [class*="_bar_32sbm"] > header { display: none !important; }

                /* Hide logo and layout switch in footer */
                [class*="_logo_110p2"] { display: none !important; }
                [class*="_layout_110p2"] { display: none !important; }

                /* ALL tiles/spotlights/grids — fill screen, no gaps, no radius */
                [class*="_spotlight"],
                [class*="_fixedGrid_110p2"],
                [class*="_scrollingGrid_110p2"],
                [class*="_grid_"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    max-width: none !important;
                    max-height: none !important;
                    aspect-ratio: unset !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    pointer-events: initial !important;
                }
                [class*="_slot"] {
                    width: 100% !important;
                    height: 100% !important;
                }

                [class*="_tile_110p2"] {
                    position: absolute !important;
                    inset: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
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
                    width: 100% !important;
                    height: 100% !important;
                }

                /* Footer — gradient overlay over video */
                [class*="_footer_110p2"] {
                    background: linear-gradient(to top, rgba(0,0,0,0.75) 0%, rgba(0,0,0,0.3) 60%, transparent 100%) !important;
                    padding-block-end: 44px !important;
                    padding-block-start: 60px !important;
                    grid-template-columns: 1fr auto 1fr !important;
                    grid-template-areas: ". buttons ." !important;
                    position: absolute !important;
                    bottom: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    z-index: 10 !important;
                    border: none !important;
                    border-top: none !important;
                }
                [class*="_footer_110p2"][class*="_overlay_110p2"] {
                    background: linear-gradient(to top, rgba(0,0,0,0.75) 0%, rgba(0,0,0,0.3) 60%, transparent 100%) !important;
                }
                @media (max-width: 660px) {
                    [class*="_footer_110p2"] {
                        grid-template-columns: 1fr auto 1fr !important;
                        grid-template-areas: ". buttons ." !important;
                    }
                }

                /* Buttons area — centered, Telegram spacing */
                [class*="_buttons_110p2"] {
                    display: flex !important;
                    gap: 16px !important;
                    justify-content: center !important;
                    align-items: center !important;
                }
                /* Force show invite and raiseHand buttons (Element Call hides them by default) */
                [class*="_invite_110p2"],
                [class*="_raiseHand_110p2"] {
                    display: flex !important;
                }

                /* All control buttons → round semi-transparent circles */
                [class*="_buttons_110p2"] > button,
                [class*="_buttons_110p2"] > [class*="_icon-button"] {
                    width: 48px !important;
                    height: 48px !important;
                    min-width: 48px !important;
                    min-height: 48px !important;
                    max-width: 48px !important;
                    border-radius: 50% !important;
                    background: rgba(255,255,255,0.15) !important;
                    backdrop-filter: blur(10px) !important;
                    -webkit-backdrop-filter: blur(10px) !important;
                    border: none !important;
                    padding: 0 !important;
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                }

                /* Active/toggled — solid white */
                [class*="_buttons_110p2"] > button[aria-pressed="true"],
                [class*="_buttons_110p2"] > button[data-state="on"],
                [class*="_buttons_110p2"] > [class*="_icon-button"][aria-pressed="true"] {
                    background: rgba(255,255,255,0.9) !important;
                }
                [class*="_buttons_110p2"] > button[aria-pressed="true"] svg,
                [class*="_buttons_110p2"] > button[data-state="on"] svg,
                [class*="_buttons_110p2"] > [class*="_icon-button"][aria-pressed="true"] svg {
                    color: #1a1a1a !important;
                }

                /* White icons */
                [class*="_buttons_110p2"] > button svg,
                [class*="_buttons_110p2"] > [class*="_icon-button"] svg {
                    color: #ffffff !important;
                    width: 24px !important;
                    height: 24px !important;
                }

                /* End Call — RED circle (higher specificity to override button style) */
                [class*="_buttons_110p2"] > button[class*="_endCall"],
                [class*="_buttons_110p2"] > [class*="_endCall"],
                button[class*="_endCall_bwclo"],
                [class*="_endCall_bwclo"] {
                    background: #FF3B30 !important;
                    width: 48px !important;
                    height: 48px !important;
                    min-width: 48px !important;
                    max-width: 48px !important;
                    border-radius: 50% !important;
                    backdrop-filter: none !important;
                    -webkit-backdrop-filter: none !important;
                    border: none !important;
                }
                [class*="_endCall_bwclo"]:hover { background: #E5342B !important; }
                [class*="_endCall_bwclo"] svg { color: #fff !important; }

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
                /* Nuclear: kill ALL borders on layout elements */
                div, section, article, main, nav, aside, header, footer {
                    border-style: none !important;
                    border-width: 0 !important;
                }
                /* Kill separator lines between content and footer */
                hr, [role="separator"] {
                    display: none !important;
                }
                /* Show participant names — Telegram style */
                [class*="_displayName"], [class*="_nameTag"] {
                    display: block !important;
                    color: #fff !important;
                    text-shadow: 0 1px 3px rgba(0,0,0,0.8) !important;
                    font-size: 14px !important;
                    font-weight: 600 !important;
                }

                /* Hide stuff */
                [class*="_bottomRightButtons_18q5h"] { display: none !important; }
                [class*="_volumeSlider_31vx3"] { display: none !important; }
                [class*="_muteIcon_31vx3"] { opacity: 0.4 !important; }

                /* Elements marked hidden by JS */
                .stalk-hidden { display: none !important; }
            `;
            document.head.appendChild(style);

            // 2. DOM manipulation via MutationObserver
            function applyTelegramLayout() {
                // Force show invite and raiseHand buttons (Element Call hides them)
                document.querySelectorAll('[class*="_invite_110p2"], [class*="_raiseHand_110p2"]').forEach(function(el) {
                    el.style.setProperty('display', 'flex', 'important');
                });

                // Force all spotlight containers to fill screen
                document.querySelectorAll('[class*="spotlight"]').forEach(function(el) {
                    el.style.setProperty('position', 'absolute', 'important');
                    el.style.setProperty('inset', '0', 'important');
                    el.style.setProperty('width', '100%', 'important');
                    el.style.setProperty('height', '100%', 'important');
                    el.style.setProperty('max-width', 'none', 'important');
                    el.style.setProperty('max-height', 'none', 'important');
                    el.style.setProperty('aspect-ratio', 'unset', 'important');
                    el.style.setProperty('margin', '0', 'important');
                });

                // Force tiles to fill parent
                document.querySelectorAll('[class*="_tile_110p2"], [class*="_tile_31vx3"]').forEach(function(el) {
                    el.style.setProperty('border-radius', '0', 'important');
                    el.style.setProperty('border', 'none', 'important');
                    el.style.setProperty('outline', 'none', 'important');
                });
                document.querySelectorAll('[class*="_contents_18q5h"]').forEach(function(el) {
                    el.style.setProperty('border-radius', '0', 'important');
                    el.style.setProperty('border', 'none', 'important');
                });
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
