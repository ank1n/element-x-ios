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
    var mirror: Bool = false
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDirect {
                DirectCallLayout(roomManager: roomManager)
            } else {
                GroupCallLayout(roomManager: roomManager)
            }
        }
    }
}

// MARK: - 1:1 Direct Call Layout

/// Fullscreen remote video with a draggable self-view PiP in the corner.
private struct DirectCallLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    @State private var selfViewOffset: CGSize = .zero
    @State private var selfViewCorner: PipCorner = .topRight

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

                // Local self-view — small draggable PiP in corner
                if let localTrack = roomManager.localVideoTrack {
                    selfViewPip(track: localTrack, in: geometry)
                }
            }
        }
    }

    private var firstRemoteVideoTrack: VideoTrack? {
        for participant in roomManager.remoteParticipants {
            if let track = participant.firstCameraVideoTrack {
                return track
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

        let anchor = selfViewCorner.position(
            in: geometry.size,
            pipSize: CGSize(width: pipWidth, height: pipHeight),
            padding: padding,
            safeArea: safeArea
        )

        NativeCallVideoView(track: track, mirror: true)
            .frame(width: pipWidth, height: pipHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
            .position(x: anchor.x + selfViewOffset.width, y: anchor.y + selfViewOffset.height)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        selfViewOffset = value.translation
                    }
                    .onEnded { value in
                        let finalPoint = CGPoint(
                            x: anchor.x + value.translation.width,
                            y: anchor.y + value.translation.height
                        )
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selfViewCorner = PipCorner.nearest(
                                to: finalPoint,
                                in: geometry.size,
                                pipSize: CGSize(width: pipWidth, height: pipHeight),
                                padding: padding,
                                safeArea: safeArea
                            )
                            selfViewOffset = .zero
                        }
                    }
            )
    }
}

// MARK: - Group Call Grid Layout

/// 2-column grid for group calls with participant name tags, speaking indicators, and mute icons.
private struct GroupCallLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager

    var body: some View {
        GeometryReader { geometry in
            let items = participantItems
            let columnCount = items.count <= 1 ? 1 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount)
            let spacing: CGFloat = 4

            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(items) { item in
                        ParticipantTile(item: item)
                            .aspectRatio(tileAspectRatio(for: items.count, geometry: geometry), contentMode: .fill)
                            .clipped()
                    }
                }
                .padding(spacing)
            }
            .scrollDisabled(items.count <= 4)
        }
        .background(Color.black)
    }

    private var participantItems: [ParticipantItem] {
        var items: [ParticipantItem] = []

        // Local participant
        if let local = roomManager.localParticipant {
            items.append(ParticipantItem(
                id: local.identity?.stringValue ?? "local",
                videoTrack: roomManager.localVideoTrack,
                displayName: SL10n.callsYou,
                isLocal: true,
                isSpeaking: local.isSpeaking,
                isAudioMuted: local.firstAudioPublication?.isMuted ?? true
            ))
        }

        // Remote participants
        for participant in roomManager.remoteParticipants {
            items.append(ParticipantItem(
                id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString,
                videoTrack: participant.firstCameraVideoTrack,
                displayName: participant.name ?? participant.identity?.stringValue,
                isLocal: false,
                isSpeaking: participant.isSpeaking,
                isAudioMuted: participant.firstAudioPublication?.isMuted ?? false
            ))
        }

        return items
    }

    private func tileAspectRatio(for count: Int, geometry: GeometryProxy) -> CGFloat {
        switch count {
        case 1:
            // Single participant fills the screen
            return geometry.size.width / max(geometry.size.height, 1)
        case 2:
            // Two participants: portrait-ish tiles stacked vertically in 1 column each
            return 3.0 / 4.0
        case 3, 4:
            return 1.0
        default:
            return 4.0 / 3.0
        }
    }
}

// MARK: - Participant Item

private struct ParticipantItem: Identifiable {
    let id: String
    let videoTrack: VideoTrack?
    let displayName: String?
    let isLocal: Bool
    let isSpeaking: Bool
    let isAudioMuted: Bool
}

// MARK: - Participant Tile

/// A single tile: video (or camera-off placeholder) + name tag + mute/speaking indicators.
private struct ParticipantTile: View {
    let item: ParticipantItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Video or placeholder
            if let track = item.videoTrack {
                NativeCallVideoView(
                    track: track,
                    mirror: item.isLocal,
                    contentMode: .fill
                )
            } else {
                // Camera off — show initials
                Color(white: 0.1)
                    .overlay {
                        VStack(spacing: 8) {
                            Text(initials(from: item.displayName ?? "?"))
                                .font(.system(size: 36, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.5))
                            Image(systemName: "video.slash.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
            }

            // Bottom gradient for name readability
            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 48)
            .allowsHitTesting(false)

            // Name tag + mute indicator
            HStack(spacing: 4) {
                if item.isAudioMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.9))
                }
                if let name = item.displayName {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(8)
        }
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            // Speaking indicator — green border
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(item.isSpeaking ? Color.green : Color.clear, lineWidth: 2)
        )
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
            return CGPoint(
                x: padding + halfW,
                y: safeArea.top + padding + halfH + 44 // 44 for toolbar
            )
        case .topRight:
            return CGPoint(
                x: containerSize.width - padding - halfW,
                y: safeArea.top + padding + halfH + 44
            )
        case .bottomLeft:
            return CGPoint(
                x: padding + halfW,
                y: containerSize.height - safeArea.bottom - padding - halfH - bottomReserved
            )
        case .bottomRight:
            return CGPoint(
                x: containerSize.width - padding - halfW,
                y: containerSize.height - safeArea.bottom - padding - halfH - bottomReserved
            )
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
