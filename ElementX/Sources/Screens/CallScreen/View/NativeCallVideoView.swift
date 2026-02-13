//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

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
        GeometryReader { geometry in
            if isDirect {
                directCallLayout(in: geometry)
            } else {
                groupCallLayout(in: geometry)
            }
        }
        .background(Color.black)
    }

    // MARK: - 1:1 Layout

    @ViewBuilder
    private func directCallLayout(in geometry: GeometryProxy) -> some View {
        ZStack {
            // Remote video: fullscreen
            if let remoteTrack = firstRemoteVideoTrack {
                NativeCallVideoView(track: remoteTrack)
                    .ignoresSafeArea()
            } else {
                // No remote video — show black with placeholder
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        Image(systemName: "video.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.3))
                    }
            }

            // Local self-view: small pip in corner
            if let localTrack = roomManager.localVideoTrack {
                VStack {
                    HStack {
                        Spacer()
                        NativeCallVideoView(track: localTrack, mirror: true)
                            .frame(width: 120, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.5), radius: 8)
                            .padding(.trailing, 16)
                            .padding(.top, 80) // Below toolbar
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Group Layout

    @ViewBuilder
    private func groupCallLayout(in geometry: GeometryProxy) -> some View {
        let allTracks = allVideoTracks
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 2)

        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(allTracks.enumerated()), id: \.offset) { _, item in
                    ZStack(alignment: .bottomLeading) {
                        NativeCallVideoView(
                            track: item.track,
                            mirror: item.isLocal
                        )
                        .aspectRatio(3 / 4, contentMode: .fill)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        // Name tag
                        if let name = item.displayName {
                            Text(name)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.8), radius: 2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    .background(Color(white: 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(4)
        }
    }

    // MARK: - Helpers

    private var firstRemoteVideoTrack: VideoTrack? {
        for participant in roomManager.remoteParticipants {
            for publication in participant.videoTracks {
                if let track = publication.track as? VideoTrack, !publication.isMuted {
                    return track
                }
            }
        }
        return nil
    }

    private struct VideoTrackItem {
        let track: VideoTrack
        let displayName: String?
        let isLocal: Bool
    }

    private var allVideoTracks: [VideoTrackItem] {
        var items: [VideoTrackItem] = []

        // Local
        if let localTrack = roomManager.localVideoTrack {
            items.append(VideoTrackItem(track: localTrack, displayName: "Вы", isLocal: true))
        }

        // Remote
        for participant in roomManager.remoteParticipants {
            for publication in participant.videoTracks {
                if let track = publication.track as? VideoTrack, !publication.isMuted {
                    items.append(VideoTrackItem(
                        track: track,
                        displayName: participant.name ?? participant.identity?.stringValue,
                        isLocal: false
                    ))
                }
            }
        }

        return items
    }
}
