//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//
// sTalk: Native LiveKit video views for CallScreen.
// Replaces WebView-based video rendering with native SwiftUI views using LiveKit SDK.

import LiveKit
import SwiftUI

// MARK: - Single Video View (LiveKit VideoView wrapper)

/// sTalk: Wraps LiveKit's `VideoView` for use in SwiftUI.
struct NativeCallVideoView: UIViewRepresentable {
    let track: VideoTrack
    var mirror = false
    var contentMode: VideoView.LayoutMode = .fill

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = contentMode
        view.mirrorMode = mirror ? .mirror : .auto
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.track = track
        uiView.layoutMode = contentMode
        uiView.mirrorMode = mirror ? .mirror : .auto
    }
}

// MARK: - Native Call Grid View (1:1 and group layouts)

/// sTalk: Displays native LiveKit video in either 1:1 spotlight or group grid layout.
struct NativeCallGridView: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    let isDirect: Bool
    var isMinimized = false
    var isLocalVideoEnabled = true
    var isLocalAudioMuted = false
    var participants: [CallParticipantInfo] = []
    var mediaProvider: MediaProviderProtocol?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDirect {
                DirectCallLayout(roomManager: roomManager, isMinimized: isMinimized)
            } else if isMinimized {
                // Mini mode: show only the active speaker (or first remote participant)
                ActiveSpeakerMiniView(roomManager: roomManager,
                                      participants: participants,
                                      mediaProvider: mediaProvider)
            } else {
                GroupCallLayout(roomManager: roomManager,
                                isLocalVideoEnabled: isLocalVideoEnabled,
                                isLocalAudioMuted: isLocalAudioMuted,
                                participants: participants,
                                mediaProvider: mediaProvider)
            }
        }
    }
}

// MARK: - 1:1 Direct Call Layout

/// Fullscreen remote video with a draggable self-view PiP in the corner.
private struct DirectCallLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    var isMinimized = false
    @State private var selfViewOffset: CGSize = .zero
    @State private var selfViewCorner: PipCorner = .bottomRight

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Remote video — fullscreen
                if let remoteTrack = firstRemoteVideoTrack {
                    NativeCallVideoView(track: remoteTrack)
                        .ignoresSafeArea()
                } else {
                    // No remote video — show placeholder with name/initials
                    remotePlaceholder
                }

                // Local self-view — only in fullscreen mode, hide in minimized
                if !isMinimized, let localTrack = roomManager.localVideoTrack {
                    selfViewPip(track: localTrack, in: geometry)
                }
            }
        }
    }

    private var firstRemoteVideoTrack: VideoTrack? {
        // STMOB-112 build 136: приоритет screen-share. Если кто-то из remote
        // расшарил экран — main view сразу показывает его экран, а не camera.
        // Раньше main view приоритезировал camera, screen share виделся только
        // в grid/side-panel.
        for participant in roomManager.remoteParticipants {
            if let screenPub = participant.videoTracks.first(where: { $0.name == Track.screenShareVideoName }),
               screenPub.isSubscribed,
               let track = screenPub.track as? VideoTrack {
                return track
            }
        }
        for participant in roomManager.remoteParticipants {
            if let track = participant.firstCameraVideoTrack {
                return track
            }
            for pub in participant.videoTracks where pub.isSubscribed {
                if let track = pub.track as? VideoTrack {
                    return track
                }
            }
        }
        return nil
    }

    private var remoteParticipant: RemoteParticipant? {
        roomManager.remoteParticipants.first
    }

    private var remotePlaceholder: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 16) {
                if let name = remoteParticipant?.name ?? remoteParticipant?.identity?.stringValue {
                    Text(initials(from: name))
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 110, height: 110)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                    Text(name)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Image(systemName: "video.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.2))
                }
            }
        }
    }

    @ViewBuilder
    private func selfViewPip(track: VideoTrack, in geometry: GeometryProxy) -> some View {
        let pipWidth: CGFloat = 120
        let pipHeight: CGFloat = 160
        let padding: CGFloat = 12
        let safeArea = geometry.safeAreaInsets

        let anchor = selfViewCorner.position(in: geometry.size,
                                             pipSize: CGSize(width: pipWidth, height: pipHeight),
                                             padding: padding,
                                             safeArea: safeArea)

        ZStack(alignment: .topTrailing) {
            NativeCallVideoView(track: track, mirror: true)

            // Camera flip button
            Button {
                Task { try? await roomManager.switchCamera() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .padding(6)

            // "Вы" label at bottom-left
            VStack {
                Spacer()
                HStack {
                    Text(SL10n.callsYou)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                    Spacer()
                }
            }
        }
        .frame(width: pipWidth, height: pipHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
        .position(x: anchor.x + selfViewOffset.width, y: anchor.y + selfViewOffset.height)
        .simultaneousGesture(DragGesture(minimumDistance: 10)
            .onChanged { value in
                selfViewOffset = value.translation
            }
            .onEnded { value in
                let finalPoint = CGPoint(x: anchor.x + value.translation.width,
                                         y: anchor.y + value.translation.height)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selfViewCorner = PipCorner.nearest(to: finalPoint,
                                                       in: geometry.size,
                                                       pipSize: CGSize(width: pipWidth, height: pipHeight),
                                                       padding: padding,
                                                       safeArea: safeArea)
                    selfViewOffset = .zero
                }
            })
    }
}

// MARK: - Active Speaker Mini View (PiP for group calls)

/// Shows only the active speaker (or first remote participant) in minimized mode.
private struct ActiveSpeakerMiniView: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    let participants: [CallParticipantInfo]
    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let speaker = activeSpeaker {
                if let track = speaker.videoTrack {
                    NativeCallVideoView(track: track, contentMode: .fill)
                } else {
                    // No video — show avatar
                    Color(white: 0.1)
                        .overlay {
                            LoadableAvatarImage(url: speaker.avatarURL,
                                                name: speaker.name,
                                                contentID: speaker.identity,
                                                avatarSize: .custom(48),
                                                mediaProvider: mediaProvider)
                        }
                }

                // Name label
                if let name = speaker.name {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(6)
                }
            } else {
                Color(white: 0.1)
                    .overlay {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.3))
                    }
            }
        }
        .background(Color.black)
    }

    private struct SpeakerInfo {
        let identity: String
        let name: String?
        let videoTrack: VideoTrack?
        let avatarURL: URL?
    }

    private var activeSpeaker: SpeakerInfo? {
        let remotes = roomManager.remoteParticipants

        // Priority 1: anyone sharing screen
        for remote in remotes {
            if let screenPub = remote.videoTracks.first(where: { $0.name == Track.screenShareVideoName }),
               !screenPub.isMuted,
               let track = screenPub.track as? VideoTrack {
                let identity = remote.identity?.stringValue ?? ""
                return SpeakerInfo(identity: identity,
                                   name: "\(remote.name ?? "?") — экран",
                                   videoTrack: track,
                                   avatarURL: nil)
            }
        }

        // STMOB-100 v2: использовать `roomManager.activeSpeakers` (auto-maintained
        // LiveKit SDK через RoomDelegate `didUpdateSpeakingParticipants`,
        // sorted by audioLevel desc). Раньше пытались sort по audioLevel
        // локально, но `audioLevel` не @Published — SwiftUI не пересчитывал
        // computed property. Теперь @Published activeSpeakers триггерит
        // re-render когда SDK сообщает об изменении speakers.
        //
        // Filter remote-only (исключаем local participant — себя в PiP не показываем),
        // exclude muted (echo/false-positive defense), fallback на первого remote.
        let speakingRemoteIDs = Set(roomManager.activeSpeakers
            .compactMap { ($0 as? RemoteParticipant)?.identity?.stringValue })
        let speakingRemotes = remotes
            .filter { speakingRemoteIDs.contains($0.identity?.stringValue ?? "") }
            .filter { !($0.firstAudioPublication?.isMuted ?? false) }
        let speaker = speakingRemotes.first ?? remotes.first
        guard let speaker else { return nil }

        let identity = speaker.identity?.stringValue ?? ""
        let avatarURL = findAvatarURL(for: identity)
        let cameraPub = speaker.videoTracks.first(where: { $0.name != Track.screenShareVideoName })
        let videoMuted = cameraPub?.isMuted ?? true
        let track = videoMuted ? nil : speaker.firstCameraVideoTrack

        return SpeakerInfo(identity: identity,
                           name: resolveSpeakerName(for: speaker, identity: identity),
                           videoTrack: track,
                           avatarURL: avatarURL)
    }

    /// STMOB: same fuzzy lookup as resolveDisplayName в GroupCallLayout.
    /// Доступ к Matrix participants array → красивое отображаемое имя
    /// вместо сырого identity вида `@user:server:DEVICEID`.
    private func resolveSpeakerName(for participant: RemoteParticipant, identity: String) -> String {
        if let name = participant.name, !name.isEmpty { return name }
        if let match = participants.first(where: { $0.userID == identity }),
           let name = match.displayName, !name.isEmpty { return name }
        if let match = participants.first(where: { identity.hasPrefix($0.userID) }),
           let name = match.displayName, !name.isEmpty { return name }
        if let match = participants.first(where: { $0.userID.hasPrefix(identity) }),
           let name = match.displayName, !name.isEmpty { return name }
        if let lastColon = identity.lastIndex(of: ":") {
            let after = identity[identity.index(after: lastColon)...]
            if !after.isEmpty { return String(after) }
        }
        return identity
    }

    private func findAvatarURL(for identity: String) -> URL? {
        if let match = participants.first(where: { $0.userID == identity }) {
            return match.avatarURL
        }
        if let match = participants.first(where: { identity.hasPrefix($0.userID) }) {
            return match.avatarURL
        }
        if let match = participants.first(where: { $0.userID.hasPrefix(identity) }) {
            return match.avatarURL
        }
        return nil
    }
}

// MARK: - Group Call Grid Layout

/// Adaptive grid for group calls: column count grows with participant count.
/// - 1 participant: full screen
/// - 2: 1 column, 2 rows
/// - 3–4: 2x2
/// - 5–6: 2x3
/// - 7–8: 2x4
/// - 9+: 3 columns, scrollable
private struct GroupCallLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    let isLocalVideoEnabled: Bool
    let isLocalAudioMuted: Bool
    let participants: [CallParticipantInfo]
    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        GeometryReader { geometry in
            let items = participantItems
            let screenShares = items.filter(\.isScreenShare)
            let regularItems = items.filter { !$0.isScreenShare }
            let hasScreenShare = !screenShares.isEmpty
            let layout = gridLayout(for: regularItems.count)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: layout.columns)
            let spacing: CGFloat = 4

            ScrollView {
                VStack(spacing: spacing) {
                    // Screen share — full width, prominent
                    ForEach(screenShares) { item in
                        ParticipantTile(item: item, mediaProvider: mediaProvider)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Regular participants grid
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(regularItems) { item in
                            ParticipantTile(item: item, mediaProvider: mediaProvider)
                                .aspectRatio(hasScreenShare
                                    ? 1.0 // compact squares when screen share is visible
                                    : tileAspectRatio(for: regularItems.count, columns: layout.columns, geometry: geometry),
                                    contentMode: .fill)
                                .clipped()
                        }
                    }
                }
                .padding(spacing)
            }
            .scrollDisabled(!layout.scrollable && !hasScreenShare)
        }
        .background(Color.black)
    }

    private struct GridConfig {
        let columns: Int
        let scrollable: Bool
    }

    private func gridLayout(for count: Int) -> GridConfig {
        switch count {
        case 0, 1:
            return GridConfig(columns: 1, scrollable: false)
        case 2:
            return GridConfig(columns: 1, scrollable: false)
        case 3, 4:
            return GridConfig(columns: 2, scrollable: false)
        case 5, 6:
            return GridConfig(columns: 2, scrollable: false)
        case 7, 8:
            return GridConfig(columns: 2, scrollable: false)
        default:
            // 9+ participants: 3 columns, scrollable
            return GridConfig(columns: 3, scrollable: true)
        }
    }

    private var participantItems: [ParticipantItem] {
        var items: [ParticipantItem] = []

        // Screen share tracks first (shown prominently)
        for participant in roomManager.remoteParticipants {
            if let screenPub = participant.videoTracks.first(where: { $0.name == Track.screenShareVideoName }),
               !screenPub.isMuted,
               let track = screenPub.track as? VideoTrack {
                let identity = participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString
                let name = participant.name ?? participant.identity?.stringValue ?? "?"
                items.append(ParticipantItem(id: "\(identity)-screen",
                                             videoTrack: track,
                                             displayName: "\(name) — экран",
                                             avatarURL: nil,
                                             isLocal: false,
                                             isSpeaking: false,
                                             isAudioMuted: false,
                                             isVideoMuted: false,
                                             isScreenShare: true))
            }
        }

        // Local participant
        if let local = roomManager.localParticipant {
            let identity = local.identity?.stringValue ?? "local"
            // STMOB: для local участника НЕ показываем зелёную speaking
            // рамку — LiveKit voice activity срабатывает на любой шум/echo
            // даже когда mic muted/idle и отвлекает пользователя. Local
            // sees their own state без подсказки.
            items.append(ParticipantItem(id: identity,
                                         videoTrack: roomManager.localVideoTrack,
                                         displayName: SL10n.callsYou,
                                         avatarURL: findAvatarURL(for: identity),
                                         isLocal: true,
                                         isSpeaking: false,
                                         isAudioMuted: isLocalAudioMuted,
                                         isVideoMuted: !isLocalVideoEnabled,
                                         isScreenShare: false))
        }

        // Remote participants (camera tracks)
        for participant in roomManager.remoteParticipants {
            let cameraPub = participant.videoTracks.first(where: { $0.name != Track.screenShareVideoName })
            let videoMuted = cameraPub?.isMuted ?? true
            let identity = participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString
            let audioMuted = participant.firstAudioPublication?.isMuted ?? false
            // STMOB: speaking рамку показываем только если micrоphone unmuted —
            // иначе LiveKit может считать speaking при echo на чужой стороне.
            let speaking = participant.isSpeaking && !audioMuted
            items.append(ParticipantItem(id: identity,
                                         videoTrack: participant.firstCameraVideoTrack,
                                         displayName: resolveDisplayName(for: participant, identity: identity),
                                         avatarURL: findAvatarURL(for: identity),
                                         isLocal: false,
                                         isSpeaking: speaking,
                                         isAudioMuted: audioMuted,
                                         isVideoMuted: videoMuted,
                                         isScreenShare: false))
        }

        return items
    }

    /// STMOB: resolve nice display name for a remote LiveKit participant.
    /// Приоритет: 1) participant.name (если выставлен через JWT) →
    /// 2) lookup в Matrix participants array по identity (фuzzy как в
    /// findAvatarURL) → 3) короткий суффикс identity (после последнего ":") →
    /// 4) полный identity. Гарантирует что под тайлом всегда есть имя,
    /// даже если LiveKit ещё не получил metadata от широгателя.
    private func resolveDisplayName(for participant: RemoteParticipant, identity: String) -> String {
        if let name = participant.name, !name.isEmpty {
            return name
        }
        if let match = participants.first(where: { $0.userID == identity }),
           let name = match.displayName, !name.isEmpty {
            return name
        }
        if let match = participants.first(where: { identity.hasPrefix($0.userID) }),
           let name = match.displayName, !name.isEmpty {
            return name
        }
        if let match = participants.first(where: { $0.userID.hasPrefix(identity) }),
           let name = match.displayName, !name.isEmpty {
            return name
        }
        // Fallback: identity суффикс (после последнего ":") или полный identity.
        if let lastColon = identity.lastIndex(of: ":") {
            let after = identity[identity.index(after: lastColon)...]
            if !after.isEmpty { return String(after) }
        }
        return identity
    }

    /// Match LiveKit identity to Matrix participant.
    /// LiveKit identity may be "@user:server:DEVICEID" while participants use "@user:server".
    private func findAvatarURL(for identity: String) -> URL? {
        // Exact match first
        if let match = participants.first(where: { $0.userID == identity }) {
            return match.avatarURL
        }
        // Fuzzy: identity starts with userID (handles :DEVICEID suffix)
        if let match = participants.first(where: { identity.hasPrefix($0.userID) }) {
            return match.avatarURL
        }
        // Fuzzy: userID starts with identity
        if let match = participants.first(where: { $0.userID.hasPrefix(identity) }) {
            return match.avatarURL
        }
        return nil
    }

    private func tileAspectRatio(for count: Int, columns: Int, geometry: GeometryProxy) -> CGFloat {
        let rows = ceil(Double(count) / Double(columns))
        // Reserve space: 120pt for bottom call controls overlay
        let bottomReserved: CGFloat = 120
        let availableHeight = geometry.size.height - bottomReserved - CGFloat(rows - 1) * 4 - 8
        let availableWidth = geometry.size.width - CGFloat(columns - 1) * 4 - 8
        let tileWidth = availableWidth / CGFloat(columns)
        let tileHeight = availableHeight / CGFloat(rows)
        // Use calculated ratio so tiles fill the visible area without scrolling
        if count <= 8 {
            return tileWidth / max(tileHeight, 1)
        }
        // Scrollable: fixed landscape ratio
        return 4.0 / 3.0
    }
}

// MARK: - Participant Item

private struct ParticipantItem: Identifiable {
    let id: String
    let videoTrack: VideoTrack?
    let displayName: String?
    let avatarURL: URL?
    let isLocal: Bool
    let isSpeaking: Bool
    let isAudioMuted: Bool
    let isVideoMuted: Bool
    let isScreenShare: Bool
}

// MARK: - Participant Tile

/// A single tile: video (or camera-off placeholder) + name tag + mute/speaking indicators.
private struct ParticipantTile: View {
    let item: ParticipantItem
    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Video or avatar placeholder
            if let track = item.videoTrack, !item.isVideoMuted {
                NativeCallVideoView(track: track,
                                    mirror: item.isLocal && !item.isScreenShare,
                                    contentMode: item.isScreenShare ? .fit : .fill)
            } else {
                // Camera off — show user's avatar
                Color(white: 0.1)
                    .overlay {
                        VStack(spacing: 6) {
                            LoadableAvatarImage(url: item.avatarURL,
                                                name: item.displayName,
                                                contentID: item.id,
                                                avatarSize: .custom(96),
                                                mediaProvider: mediaProvider)
                            Image(systemName: "video.slash.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
            }

            // Bottom gradient for name readability
            LinearGradient(colors: [.clear, .black.opacity(0.5)],
                           startPoint: .center,
                           endPoint: .bottom)
                .frame(height: 48)
                .allowsHitTesting(false)

            // Name tag (bottom-left)
            if let name = item.displayName {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }

            // Mute indicator (top-right)
            if item.isAudioMuted {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Circle())
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(// Speaking indicator — green border
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(item.isSpeaking ? Color.green : Color.clear, lineWidth: 2))
    }
}

// MARK: - PiP Corner Position

private enum PipCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    func position(in containerSize: CGSize, pipSize: CGSize, padding: CGFloat, safeArea: EdgeInsets) -> CGPoint {
        let halfW = pipSize.width / 2
        let halfH = pipSize.height / 2
        // Reserve 140pt from bottom for call control buttons
        let bottomReserved: CGFloat = 140

        switch self {
        case .topLeft:
            return CGPoint(x: padding + halfW,
                           y: safeArea.top + padding + halfH + 44 // 44 for toolbar
            )
        case .topRight:
            return CGPoint(x: containerSize.width - padding - halfW,
                           y: safeArea.top + padding + halfH + 44)
        case .bottomLeft:
            return CGPoint(x: padding + halfW,
                           y: containerSize.height - safeArea.bottom - padding - halfH - bottomReserved)
        case .bottomRight:
            return CGPoint(x: containerSize.width - padding - halfW,
                           y: containerSize.height - safeArea.bottom - padding - halfH - bottomReserved)
        }
    }

    static func nearest(to point: CGPoint, in containerSize: CGSize, pipSize: CGSize, padding: CGFloat, safeArea: EdgeInsets) -> PipCorner {
        let corners: [PipCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        return corners.min { a, b in
            let aPos = a.position(in: containerSize, pipSize: pipSize, padding: padding, safeArea: safeArea)
            let bPos = b.position(in: containerSize, pipSize: pipSize, padding: padding, safeArea: safeArea)
            return hypot(point.x - aPos.x, point.y - aPos.y) < hypot(point.x - bPos.x, point.y - bPos.y)
        } ?? .topRight
    }
}

// MARK: - Helpers

private func initials(from name: String) -> String {
    let components = name.split(separator: " ")
    if components.count >= 2 {
        return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
    }
    return String(name.prefix(2)).uppercased()
}
