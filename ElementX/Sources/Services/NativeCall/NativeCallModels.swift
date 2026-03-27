//
// NativeCallModels.swift
// sTalk — Native call session models
//

import Foundation

// MARK: - Session State

enum NativeCallSessionState: Equatable {
    static func == (lhs: NativeCallSessionState, rhs: NativeCallSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.starting, .starting), (.widgetReady, .widgetReady),
             (.waitingForCredentials, .waitingForCredentials),
             (.connecting, .connecting), (.connected, .connected),
             (.disconnecting, .disconnecting), (.disconnected, .disconnected):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }

    case starting
    case widgetReady
    case waitingForCredentials
    case connecting
    case connected
    case disconnecting
    case disconnected
    case failed(Error)
}

// MARK: - LiveKit Credentials

struct LiveKitCredentials {
    let url: String
    let jwt: String
    let roomName: String?
    let identity: String?
}

// MARK: - E2EE Key Info

struct E2EEKeyInfo {
    let key: String // base64
    let index: Int
    let participantId: String // @user:server:deviceId
}

// MARK: - Widget API Message Parsing

struct WidgetAPIMessage {
    let api: String // "toWidget" or "fromWidget"
    let action: String
    let widgetId: String
    let requestId: String
    let data: [String: Any]?
    let rawJSON: [String: Any]

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = json["api"] as? String,
              let action = json["action"] as? String else {
            return nil
        }
        self.api = api
        self.action = action
        self.widgetId = json["widgetId"] as? String ?? ""
        self.requestId = json["requestId"] as? String ?? ""
        self.data = json["data"] as? [String: Any]
        self.rawJSON = json
    }

    /// Check if this is a toWidget message with a specific event type
    var eventType: String? {
        data?["type"] as? String
    }

    /// Extract call.member content for LiveKit focus info
    var callMemberContent: [String: Any]? {
        data?["content"] as? [String: Any]
    }

    /// Extract E2EE encryption keys
    func extractEncryptionKeys() -> E2EEKeyInfo? {
        guard let content = data?["content"] as? [String: Any],
              let keysObj = content["keys"] as? [String: Any],
              let key = keysObj["key"] as? String,
              let index = keysObj["index"] as? Int else {
            return nil
        }

        let sender = data?["sender"] as? String ?? ""
        let deviceId = (content["member"] as? [String: Any])?["claimed_device_id"] as? String ?? ""
        let participantId = sender.isEmpty ? "" : "\(sender):\(deviceId)"

        return E2EEKeyInfo(key: key, index: index, participantId: participantId)
    }

    /// Extract LiveKit focus from call.member event
    func extractLiveKitFocus() -> LiveKitCredentials? {
        guard let content = callMemberContent else { return nil }

        // Try memberships array → foci_preferred
        if let memberships = content["memberships"] as? [[String: Any]] {
            for membership in memberships {
                if let foci = membership["foci_preferred"] as? [[String: Any]] ?? membership["foci_active"] as? [[String: Any]] {
                    for focus in foci {
                        if let type = focus["type"] as? String, type == "livekit",
                           let url = focus["livekit_service_url"] as? String {
                            return LiveKitCredentials(url: url, jwt: "", roomName: nil, identity: nil)
                        }
                    }
                }
            }
        }

        // Direct focus format
        if let focus = content["focus_active"] as? [String: Any],
           let type = focus["type"] as? String, type == "livekit",
           let url = focus["livekit_service_url"] as? String {
            return LiveKitCredentials(url: url, jwt: "", roomName: nil, identity: nil)
        }

        return nil
    }
}
