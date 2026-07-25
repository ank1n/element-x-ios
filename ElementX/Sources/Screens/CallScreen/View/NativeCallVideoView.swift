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

// STMOB-204: detect screen-share by source too, not just by track name.
// Web / other clients publish the share track with an EMPTY name but
// source == .screenShareVideo, so the name-only check missed it and the
// shared screen never rendered. Mirrors LiveKitRoomManager's detection.
private extension TrackPublication {
    var isScreenShareTrack: Bool {
        name == Track.screenShareVideoName || source == .screenShareVideo
    }
}

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

/// sTalk: Displays native LiveKit video in either 1:1 spotlight or group grid/speaker layout.
struct NativeCallGridView: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    let isDirect: Bool
    var isMinimized = false
    var isLocalVideoEnabled = true
    var isLocalAudioMuted = false
    var participants: [CallParticipantInfo] = []
    var mediaProvider: MediaProviderProtocol?
    // STMOB-113
    var layoutMode: CallLayoutMode = .grid
    var pinnedParticipantSID: String?
    var onTogglePin: ((String) -> Void)?
    // STMOB-218: tap the speaker PiP in landscape screen-share → request portrait.
    var onRequestPortrait: (() -> Void)?

    // STMOB-218: on iPhone, landscape ⇒ verticalSizeClass == .compact.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDirect {
                DirectCallLayout(roomManager: roomManager,
                                 isMinimized: isMinimized,
                                 isLocalVideoEnabled: isLocalVideoEnabled)
            } else if isMinimized {
                // Mini mode: show only the active speaker (or first remote participant)
                ActiveSpeakerMiniView(roomManager: roomManager,
                                      participants: participants,
                                      mediaProvider: mediaProvider)
            } else if verticalSizeClass == .compact, roomManager.hasRemoteScreenShare {
                // STMOB-218: landscape + active screen-share → give the share the WHOLE
                // screen (no participant strip), with a single draggable PiP of the
                // active speaker. Tap the PiP to snap back to portrait.
                LandscapeScreenShareLayout(roomManager: roomManager,
                                           participants: participants,
                                           mediaProvider: mediaProvider,
                                           onRequestPortrait: onRequestPortrait)
            } else if layoutMode == .speaker {
                // STMOB-113: Speaker layout — focused main + bottom strip.
                SpeakerCallLayout(roomManager: roomManager,
                                  isLocalVideoEnabled: isLocalVideoEnabled,
                                  isLocalAudioMuted: isLocalAudioMuted,
                                  participants: participants,
                                  mediaProvider: mediaProvider,
                                  pinnedSID: pinnedParticipantSID,
                                  onTogglePin: onTogglePin)
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

// MARK: - Aspect-aware fullscreen video

/// Следит за dimensions трека через TrackDelegate (приходят асинхронно с первым кадром).
private final class TrackDimensionsObserver: NSObject, ObservableObject, TrackDelegate {
    @Published var dimensions: Dimensions?

    init(track: VideoTrack) {
        super.init()
        dimensions = track.dimensions
        track.add(delegate: self)
    }

    nonisolated func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
        Task { @MainActor in
            self.dimensions = dimensions
        }
    }
}

/// Полноэкранный рендер удалённого трека с contentMode по аспекту САМОГО ТРЕКА.
/// Корень «зума и мыла в 1:1 при норме в группе» (репорт dp): фуллскрин в 1:1
/// ЗАПОЛНЯЛ портретный экран горизонтальным видео с веба (16:9) — кроп боков до
/// узкой центральной полосы = зум, а её растяжка = «упавшее качество»; в группе
/// те же кадры живут в тайлах без кропа. Горизонтальный трек теперь вписывается
/// (.fit, letterbox), портретный (другой телефон) — заполняет экран как раньше.
/// При смене трека пересоздавать через .id(track.sid) — observer держит трек с init.
private struct AspectAwareRemoteVideoView: View {
    let track: VideoTrack
    @StateObject private var observer: TrackDimensionsObserver

    init(track: VideoTrack) {
        self.track = track
        _observer = StateObject(wrappedValue: TrackDimensionsObserver(track: track))
    }

    var body: some View {
        let isTrackLandscape = observer.dimensions.map { $0.width > $0.height } ?? false
        NativeCallVideoView(track: track, contentMode: isTrackLandscape ? .fit : .fill)
    }
}

// MARK: - 1:1 Direct Call Layout

/// Fullscreen remote video with a draggable self-view PiP in the corner.
private struct DirectCallLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    var isMinimized = false
    /// STMOB-235: PiP рендерился по одному лишь `localVideoTrack != nil`, без гейта
    /// по состоянию камеры — «защита в глубину» от застывшего кадра в 1:1.
    var isLocalVideoEnabled = true
    @State private var selfViewOffset: CGSize = .zero
    @State private var selfViewCorner: PipCorner = .bottomRight
    // Landscape: PiP-бокс переворачивается вместе с камерой (120×160 ↔ 160×120)
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Remote video — fullscreen, contentMode по аспекту трека (зум-фикс 1:1)
                if let remoteTrack = firstRemoteVideoTrack {
                    AspectAwareRemoteVideoView(track: remoteTrack)
                        .id(remoteTrack.sid?.stringValue ?? remoteTrack.name)
                        .ignoresSafeArea()
                } else {
                    // No remote video — show placeholder with name/initials
                    remotePlaceholder
                }

                // Local self-view — only in fullscreen mode, hide in minimized
                if !isMinimized, isLocalVideoEnabled, let localTrack = roomManager.localVideoTrack {
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
        for participant in roomManager.displayParticipants {
            if let screenPub = participant.videoTracks.first(where: { $0.isScreenShareTrack }),
               screenPub.isSubscribed,
               let track = screenPub.track as? VideoTrack {
                return track
            }
        }
        for participant in roomManager.displayParticipants {
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
        roomManager.displayParticipants.first
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
        let isLandscapeUI = verticalSizeClass == .compact
        let pipWidth: CGFloat = isLandscapeUI ? 160 : 120
        let pipHeight: CGFloat = isLandscapeUI ? 120 : 160
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
        let remotes = roomManager.displayParticipants

        // Priority 1: anyone sharing screen
        for remote in remotes {
            if let screenPub = remote.videoTracks.first(where: { $0.isScreenShareTrack }),
               !screenPub.isMuted,
               let track = screenPub.track as? VideoTrack {
                let identity = remote.identity?.stringValue ?? ""
                return SpeakerInfo(identity: identity,
                                   name: String(format: NSLocalizedString("stalk_call_screen_share_name", tableName: "Localizable", value: "%@ — экран", comment: "Screen share tile name: <participant> — screen"), remote.name ?? "?"),
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
        let cameraPub = speaker.videoTracks.first(where: { !$0.isScreenShareTrack })
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
        let raw: String = {
            // STMOB-232: JWT-name берём ТОЛЬКО если это не сырой Matrix ID.
            // Сервер для юзеров без profile display name кладёт в JWT name=userID,
            // и он раньше затенял настоящее имя из Matrix-массива (регрессия имён).
            if let name = participant.name, !name.isEmpty, !name.hasPrefix("@") { return name }
            if let match = participants.first(where: { $0.userID == identity }),
               let name = match.displayName, !name.isEmpty { return name }
            if let match = participants.first(where: { identity.hasPrefix($0.userID) }),
               let name = match.displayName, !name.isEmpty { return name }
            if let match = participants.first(where: { $0.userID.hasPrefix(identity) }),
               let name = match.displayName, !name.isEmpty { return name }
            if let name = participant.name, !name.isEmpty { return name }
            return identity
        }()
        // STMOB-232: если всё равно сырой Matrix ID → localpart.
        return prettifyParticipantName(raw)
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
    // STMOB-218: landscape — портретная раскладка (VStack + reserve снизу +
    // «1 крупный сверху») в широкой-низкой геометрии ломается и переобрезает
    // видео. В landscape используем ровный grid с .fit-тайлами.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geometry in
            let items = participantItems
            let screenShares = items.filter(\.isScreenShare)
            let regularItems = items.filter { !$0.isScreenShare }
            let hasScreenShare = !screenShares.isEmpty
            let isLandscape = verticalSizeClass == .compact
            let columnCount = isLandscape ? landscapeColumns(for: regularItems.count) : gridLayout(for: regularItems.count).columns
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount)
            let spacing: CGFloat = 4

            ScrollView {
                VStack(spacing: spacing) {
                    // Screen share — full width, prominent
                    ForEach(screenShares) { item in
                        ParticipantTile(item: item, mediaProvider: mediaProvider)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // STMOB-119 build 144: 3 уч. = 1 крупный сверху + 2 в ряд снизу
                    // (без пустой ячейки 2x2). В landscape — обычный grid (портретный
                    // «1 крупный сверху» в широкой геометрии выглядит растянутым).
                    if regularItems.count == 3, !hasScreenShare, !isLandscape {
                        threeParticipantsLayout(items: regularItems, geometry: geometry, spacing: spacing)
                    } else {
                        // Regular participants grid
                        LazyVGrid(columns: columns, spacing: spacing) {
                            ForEach(regularItems) { item in
                                ParticipantTile(item: item, mediaProvider: mediaProvider)
                                    .aspectRatio(tileAspect(hasScreenShare: hasScreenShare,
                                                            isLandscape: isLandscape,
                                                            count: regularItems.count,
                                                            columns: columnCount,
                                                            geometry: geometry),
                                                 contentMode: .fill)
                                    .clipped()
                            }
                        }
                    }
                }
                .padding(spacing)
            }
            // Landscape: аспект тайлов считается из геометрии → ряды всегда влезают,
            // скролл не нужен (он и давал «уехавшую вниз» сетку)
            .scrollDisabled(isLandscape ? !hasScreenShare : (!gridLayout(for: regularItems.count).scrollable && !hasScreenShare))
        }
        .background(Color.black)
    }

    /// STMOB-218: число колонок в landscape — широкая геометрия, тайлы в ряд.
    private func landscapeColumns(for count: Int) -> Int {
        switch count {
        case 0, 1: return 1
        case 2: return 2
        case 3, 4: return count // один ряд портретных тайлов
        case 5, 6: return 3
        default: return 4
        }
    }

    /// Aspect для тайла. В landscape — из геометрии, чтобы ряды ВЛЕЗАЛИ по высоте:
    /// прежний хардкод 3:4 (портрет) при корректной ориентации кадров переполнял
    /// экран по вертикали — сетка уезжала в скролл, «тайлы слишком низко» (dp).
    private func tileAspect(hasScreenShare: Bool, isLandscape: Bool, count: Int, columns: Int, geometry: GeometryProxy) -> CGFloat {
        if isLandscape {
            let cols = max(columns, 1)
            let rows = max(1, Int(ceil(Double(max(count, 1)) / Double(cols))))
            let spacing: CGFloat = 4
            let colWidth = (geometry.size.width - CGFloat(cols + 1) * spacing) / CGFloat(cols)
            let rowHeight = (geometry.size.height - CGFloat(rows + 1) * spacing) / CGFloat(rows)
            guard rowHeight > 0, colWidth > 0 else { return 4.0 / 3.0 }
            return colWidth / rowHeight
        }
        if hasScreenShare { return 1.0 }
        return tileAspectRatio(for: count, columns: columns, geometry: geometry)
    }

    /// STMOB-119 build 144: 3 участника = 1 крупный сверху + 2 маленьких снизу
    /// (без пустой ячейки 2x2). Заполняет всю высоту minus controls reserve.
    @ViewBuilder
    private func threeParticipantsLayout(items: [ParticipantItem], geometry: GeometryProxy, spacing: CGFloat) -> some View {
        let bottomReserved: CGFloat = 120
        let availableHeight = geometry.size.height - bottomReserved - spacing * 2 - 8
        // Top tile = 60% от availableHeight, bottom row = 40%.
        let topHeight = availableHeight * 0.6
        let bottomHeight = availableHeight * 0.4
        VStack(spacing: spacing) {
            ParticipantTile(item: items[0], mediaProvider: mediaProvider)
                .frame(height: topHeight)
                .clipped()
            HStack(spacing: spacing) {
                ParticipantTile(item: items[1], mediaProvider: mediaProvider)
                    .frame(maxWidth: .infinity)
                    .frame(height: bottomHeight)
                    .clipped()
                ParticipantTile(item: items[2], mediaProvider: mediaProvider)
                    .frame(maxWidth: .infinity)
                    .frame(height: bottomHeight)
                    .clipped()
            }
        }
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

        // STMOB-131 build 151: local participant identity для фильтрации дублей
        // в remote loop. Element Call для screen share может создать отдельный
        // virtual participant с identity того же юзера (suffix ":screen") —
        // его НЕ нужно дублировать как camera-tile в remote loop.
        let localIdentityString = roomManager.localParticipant?.identity?.stringValue

        // STMOB-234 (dp, лог 145): СВОЙ экран себе НЕ показываем. Тайл «Ваш экран»
        // (был здесь с build 160) занимал всю ширину первым в сетке и выдавливал
        // вниз и себя, и собеседника, а внутри давал бесконечную рекурсию —
        // in-app capture снимает наше же окно, где уже нарисован этот тайл.
        // Смысла в нём нет: то, что трансляция идёт, видно по подсветке ••• и
        // плашке «Вы транслируете экран» на экране звонка. Заодно уходит перекос
        // раскладки: hasScreenShare (ниже) переставал считаться от своего шаринга,
        // а он меняет аспект тайлов, отключает раскладку «1+2» и включает скролл.
        // Чужой шаринг показываем как раньше.

        // Screen share tracks first (shown prominently)
        for participant in roomManager.displayParticipants {
            // isSubscribed обязателен: без него сетка рисовала чужой шаринг, который
            // hasRemoteScreenShare (он требует подписки) не считает — и раскладка не
            // уходила в speaker, а landscape-фуллскрин не включался. Рассинхронные
            // условия давали «тайл есть, а поведение как без шаринга».
            if let screenPub = participant.videoTracks.first(where: { $0.isScreenShareTrack }),
               screenPub.isSubscribed,
               !screenPub.isMuted,
               let track = screenPub.track as? VideoTrack {
                let identity = participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString
                // STMOB-131-класс: SFU может отдать виртуального участника с НАШЕЙ
                // identity (суффикс ":screen") — иначе свой экран вернулся бы сюда
                // с чужого входа. В камерном цикле ниже такой skip уже есть.
                if let localID = localIdentityString,
                   identity == localID || identity.hasPrefix("\(localID):") || identity == "\(localID)-screen" {
                    continue
                }
                let name = participant.name ?? participant.identity?.stringValue ?? "?"
                items.append(ParticipantItem(id: "\(identity)-screen",
                                             videoTrack: track,
                                             displayName: String(format: NSLocalizedString("stalk_call_screen_share_name", tableName: "Localizable", value: "%@ — экран", comment: "Screen share tile name: <participant> — screen"), name),
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
                                         isScreenShare: false,
                                         isHandRaised: roomManager.isHandRaised))
        }

        // Remote participants (camera tracks)
        for participant in roomManager.displayParticipants {
            let identity = participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString
            // STMOB-131 build 151: skip virtual screen-share participant который
            // имеет ту же identity что local (или с суффиксом). Они уже учтены
            // как screen-share tile сверху + local participant в self-tile.
            if let localID = localIdentityString,
               identity == localID || identity.hasPrefix("\(localID):") || identity == "\(localID)-screen" {
                continue
            }
            let cameraPub = participant.videoTracks.first(where: { !$0.isScreenShareTrack })
            let videoMuted = cameraPub?.isMuted ?? true
            let audioMuted = participant.firstAudioPublication?.isMuted ?? false
            let speaking = participant.isSpeaking && !audioMuted
            // STMOB-120: handRaised из set'а raisedHandsSIDs (обновляется через
            // RoomDelegate.didUpdateMetadata).
            let sid = participant.sid?.stringValue ?? ""
            let handRaised = roomManager.raisedHandsSIDs.contains(sid)
            items.append(ParticipantItem(id: identity,
                                         videoTrack: participant.firstCameraVideoTrack,
                                         displayName: resolveDisplayName(for: participant, identity: identity),
                                         avatarURL: findAvatarURL(for: identity),
                                         isLocal: false,
                                         isSpeaking: speaking,
                                         isAudioMuted: audioMuted,
                                         isVideoMuted: videoMuted,
                                         isScreenShare: false,
                                         isHandRaised: handRaised))
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
        let raw: String = {
            // STMOB-232: JWT-name берём ТОЛЬКО если это не сырой Matrix ID — иначе
            // name=userID (юзеры без profile display name) затеняет настоящее имя
            // из Matrix-массива. Это и была регрессия (@dp.bondar:... вместо имени).
            if let name = participant.name, !name.isEmpty, !name.hasPrefix("@") {
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
            if let name = participant.name, !name.isEmpty {
                return name
            }
            return identity
        }()
        // STMOB-232: если имя оказалось сырым Matrix ID — показываем localpart
        // (раньше fallback брал суффикс после ПОСЛЕДНЕГО ":" = server, что неверно;
        // а JWT name юзеров без display name = полный @user:server).
        return prettifyParticipantName(raw)
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
        if count <= 8 {
            // STMOB-119 build 144: ограничиваем aspect ratio в [0.75, 1.33].
            // Раньше для 4 уч. был ≈0.53 (узкий portrait), что в .fill режиме
            // обрезало landscape camera (1.33) ОЧЕНЬ агрессивно — у юзеров
            // были видны только пол-лица справа/слева. Теперь tiles ближе
            // к квадрату, обрезка минимальная.
            let raw = tileWidth / max(tileHeight, 1)
            return max(0.75, min(1.33, raw))
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
    /// STMOB-120: участник поднял руку (через participant.metadata).
    var isHandRaised = false
}

// MARK: - Participant Tile

/// A single tile: video (or camera-off placeholder) + name tag + mute/speaking indicators.
private struct ParticipantTile: View {
    let item: ParticipantItem
    let mediaProvider: MediaProviderProtocol?
    // STMOB-218: в landscape (verticalSizeClass == .compact) видео рендерим в
    // .fit — .fill переобрезает портретный видеопоток в широкую плитку и даёт
    // «растягивание»/гигантский зум лица. .fit сохраняет нормальные пропорции.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Video or avatar placeholder
            if let track = item.videoTrack, !item.isVideoMuted {
                let isLandscape = verticalSizeClass == .compact
                NativeCallVideoView(track: track,
                                    mirror: item.isLocal && !item.isScreenShare,
                                    contentMode: (item.isScreenShare || isLandscape) ? .fit : .fill)
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

            // STMOB-120: Hand raise indicator (top-left)
            if item.isHandRaised {
                VStack {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(width: 28, height: 28)
                            .background(Color.yellow)
                            .clipShape(Circle())
                            .padding(8)
                        Spacer()
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

// MARK: - STMOB-113: Speaker Layout (focused main + bottom strip)

/// Большой главный участник (по приоритету: pinned > screen-share > active speaker > first
/// remote) + горизонтальная полоса миниатюр всех остальных снизу. Tap по миниатюре
/// — pin/unpin. Default-режим становится включённым автоматически в группах > 8 человек.
private struct SpeakerCallLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    let isLocalVideoEnabled: Bool
    let isLocalAudioMuted: Bool
    let participants: [CallParticipantInfo]
    let mediaProvider: MediaProviderProtocol?
    let pinnedSID: String?
    let onTogglePin: ((String) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            // STMOB-128 build 163/164: strip + main заполняют ВСЁ пространство
            // до controls overlay (callControlButtons ~120pt от низа). Strip
            // height теперь dynamic — при малом количестве участников (1-2)
            // тайлы заметно больше, чтобы не было пустого чёрного gap'а:
            //   1 strip tile  → 220pt
            //   2 strip tiles → 200pt
            //   3+ strip tiles → 150pt (текущий)
            let bottomReserved: CGFloat = 120
            let visibleCount = stripParticipants.count + (roomManager.displayParticipants.count > 3 ? 1 : 0)
            let stripHeight: CGFloat = {
                switch visibleCount {
                case ...1: return 220
                case 2: return 200
                default: return 150
                }
            }()
            let mainHeight = max(0, geometry.size.height - bottomReserved - stripHeight)
            VStack(spacing: 0) {
                // Main focused area
                ZStack {
                    Color.black
                    if let track = focusedVideoTrack {
                        NativeCallVideoView(track: track, contentMode: .fit)
                    } else {
                        placeholder
                    }
                    // Pin indicator
                    if let pinnedSID, focusedSID == pinnedSID {
                        VStack {
                            HStack {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Capsule())
                                    .padding(12)
                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    // STMOB-223: подпись чей экран расшарен (bottom-left main area).
                    // Раньше в main-области не было НИКАКОЙ подписи у шаринга —
                    // непонятно чей экран. Показываем «<имя> — экран».
                    if let screenShareLabel {
                        VStack {
                            Spacer()
                            HStack {
                                Label(screenShareLabel, systemImage: "rectangle.on.rectangle")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .padding(12)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(height: mainHeight)

                stripView(in: geometry, height: stripHeight)
                    .padding(.bottom, bottomReserved)
            }
        }
    }

    /// STMOB-128 build 148: тайлы strip растягиваются по ширине поровну.
    /// 1 тайл = full width, 2-6 — делятся равномерно, >6 — горизонтальный scroll
    /// с фикс-шириной.
    @ViewBuilder
    private func stripView(in geometry: GeometryProxy, height: CGFloat) -> some View {
        let visibleParticipants = stripParticipants
        let overflow = roomManager.displayParticipants.count - visibleParticipants.count
        let totalTiles = visibleParticipants.count + (overflow > 0 ? 1 : 0)
        let hpadding: CGFloat = 12
        let spacing: CGFloat = 8
        let availableWidth = geometry.size.width - hpadding * 2
        let tileHeight = height - 16 // vertical padding
        let computedWidth = totalTiles > 0
            ? (availableWidth - spacing * CGFloat(max(0, totalTiles - 1))) / CGFloat(totalTiles)
            : 0
        // STMOB build 164: убрали cap 220 — при 1-2 тайлах ширина раньше
        // ограничивалась 220pt → пустые поля справа. Теперь тайл занимает
        // всю доступную ширину поровну. Min 72pt для overflow scroll сценария.
        let tileWidth = max(72, computedWidth)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(visibleParticipants, id: \.sid) { participant in
                    speakerStripTile(for: participant, width: tileWidth, height: tileHeight)
                }
                if overflow > 0 {
                    overflowTile(count: overflow, width: tileWidth, height: tileHeight)
                }
            }
            .padding(.horizontal, hpadding)
            .padding(.vertical, 8)
        }
        .frame(height: height)
        .background(Color.black.opacity(0.6))
    }

    /// STMOB-117 build 143: для strip берём не более 3 участников.
    /// Приоритет: (1) pinned, (2) с camera/screen-share track, (3) последний
    /// active speaker, (4) первые remote по списку.
    private var stripParticipants: [RemoteParticipant] {
        let allRemotes = roomManager.displayParticipants
        guard allRemotes.count > 3 else { return allRemotes }
        var ordered: [RemoteParticipant] = []
        var seen = Set<String>()
        func add(_ p: RemoteParticipant) {
            guard let sid = p.sid?.stringValue, !seen.contains(sid) else { return }
            ordered.append(p)
            seen.insert(sid)
        }
        // 1. pinned
        if let pinnedSID, let p = allRemotes.first(where: { $0.sid?.stringValue == pinnedSID }) { add(p) }
        // 2. с любым subscribed video track (camera или screen)
        for p in allRemotes where p.videoTracks.contains(where: \.isSubscribed) {
            if ordered.count >= 3 { break }
            add(p)
        }
        // 3. active speakers
        for sp in roomManager.activeSpeakers {
            if ordered.count >= 3 { break }
            if let p = sp as? RemoteParticipant { add(p) }
        }
        // 4. fallback — первые остальные
        for p in allRemotes {
            if ordered.count >= 3 { break }
            add(p)
        }
        return ordered
    }

    private func overflowTile(count: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black
            Text("+\(count)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: focused track resolver

    /// SID участника которого показываем в main view.
    /// Приоритет: pinned > screen-share > active speaker > first remote.
    private var focusedSID: String? {
        if let pinnedSID,
           roomManager.displayParticipants.contains(where: { $0.sid?.stringValue == pinnedSID }) {
            return pinnedSID
        }
        // Screen share appears as separate track but на том же participant — в SID не отражается.
        // Берём active speaker.
        if let speakingSID = roomManager.activeSpeakers
            .compactMap({ ($0 as? RemoteParticipant)?.sid?.stringValue })
            .first(where: { sid in roomManager.displayParticipants.contains(where: { $0.sid?.stringValue == sid }) }) {
            return speakingSID
        }
        return roomManager.displayParticipants.first?.sid?.stringValue
    }

    private var focusedParticipant: RemoteParticipant? {
        guard let sid = focusedSID else { return nil }
        return roomManager.displayParticipants.first(where: { $0.sid?.stringValue == sid })
    }

    /// Track для main view. Screen share (даже у не-focused участника) приоритетнее camera.
    private var focusedVideoTrack: VideoTrack? {
        // Если у focused-участника есть screen share — приоритет ему.
        if let p = focusedParticipant,
           let screenPub = p.videoTracks.first(where: { $0.isScreenShareTrack }),
           screenPub.isSubscribed,
           let track = screenPub.track as? VideoTrack {
            return track
        }
        // Иначе — screen share от любого remote (если кто-то расшарил).
        for p in roomManager.displayParticipants {
            if let screenPub = p.videoTracks.first(where: { $0.isScreenShareTrack }),
               screenPub.isSubscribed,
               let track = screenPub.track as? VideoTrack {
                return track
            }
        }
        // Camera focused-участника.
        if let p = focusedParticipant, let track = p.firstCameraVideoTrack {
            return track
        }
        return nil
    }

    /// STMOB-223: участник, чей screen-share сейчас отображается в main-области
    /// (если шаринг активен). Тот же приоритет, что в `focusedVideoTrack`:
    /// сперва focused-участник, иначе любой remote с share-треком.
    private var focusedScreenShareOwner: RemoteParticipant? {
        if let p = focusedParticipant,
           p.videoTracks.contains(where: { $0.isScreenShareTrack && $0.isSubscribed }) {
            return p
        }
        return roomManager.displayParticipants.first { p in
            p.videoTracks.contains(where: { $0.isScreenShareTrack && $0.isSubscribed })
        }
    }

    /// STMOB-223: подпись «<имя> — экран» для main-области. nil — если шаринга нет.
    private var screenShareLabel: String? {
        guard let owner = focusedScreenShareOwner else { return nil }
        let identity = owner.identity?.stringValue ?? ""
        let name = participants.first(where: { $0.userID == identity })?.displayName
            ?? participants.first(where: { identity.hasPrefix($0.userID) })?.displayName
            ?? owner.name
            ?? "?"
        return String(format: NSLocalizedString("stalk_call_screen_share_name", tableName: "Localizable", value: "%@ — экран", comment: "Screen share tile name: <participant> — screen"), name)
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.08)
            if let p = focusedParticipant {
                let identity = p.identity?.stringValue ?? ""
                let displayName = participants.first(where: { $0.userID == identity })?.displayName ?? p.name ?? "?"
                Text(initials(from: displayName))
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: strip tile

    @ViewBuilder
    private func speakerStripTile(for participant: RemoteParticipant, width: CGFloat, height: CGFloat) -> some View {
        let sid = participant.sid?.stringValue ?? ""
        let isPinned = pinnedSID == sid
        let cameraTrack = participant.firstCameraVideoTrack
        let hasScreenShare = participant.videoTracks
            .contains(where: { $0.isScreenShareTrack && $0.isSubscribed })
        // STMOB-120
        let isHandRaised = roomManager.raisedHandsSIDs.contains(sid)

        ZStack {
            Color.black
            if let track = cameraTrack {
                NativeCallVideoView(track: track, contentMode: .fill)
            } else {
                let identity = participant.identity?.stringValue ?? ""
                let name = participants.first(where: { $0.userID == identity })?.displayName ?? participant.name ?? "?"
                Text(initials(from: name))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            // Overlays
            VStack {
                HStack {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    if isHandRaised {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .padding(3)
                            .background(Color.yellow)
                            .clipShape(Circle())
                    }
                    Spacer()
                    if hasScreenShare {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                Spacer()
            }
            .padding(4)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isPinned ? Color.white : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            onTogglePin?(sid)
        }
    }
}

// MARK: - STMOB-218: Landscape Fullscreen Screen-Share

/// Шаринг экрана занимает ВЕСЬ экран (максимум площади под контент), без полосы
/// участников. Поверх — один draggable PiP активного говорящего; тап по нему
/// возвращает в портретный режим.
private struct LandscapeScreenShareLayout: View {
    @ObservedObject var roomManager: LiveKitRoomManager
    let participants: [CallParticipantInfo]
    let mediaProvider: MediaProviderProtocol?
    let onRequestPortrait: (() -> Void)?

    @State private var pipOffset: CGSize = .zero
    @State private var pipCorner: PipCorner = .topRight

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Шаринг на весь экран.
                if let shareTrack = screenShareTrack {
                    NativeCallVideoView(track: shareTrack, contentMode: .fit)
                        .ignoresSafeArea()
                } else {
                    Color(white: 0.06).ignoresSafeArea()
                }

                // Подпись чей экран (top-left).
                if let label = screenShareLabel {
                    VStack {
                        HStack {
                            Label(label, systemImage: "rectangle.on.rectangle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                                .padding(12)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // PiP активного говорящего — draggable, тап → портрет.
                speakerPip(in: geometry)
            }
        }
    }

    // MARK: speaker PiP

    @ViewBuilder
    private func speakerPip(in geometry: GeometryProxy) -> some View {
        let pipWidth: CGFloat = 132
        let pipHeight: CGFloat = 92
        let padding: CGFloat = 12
        let anchor = pipCorner.position(in: geometry.size,
                                        pipSize: CGSize(width: pipWidth, height: pipHeight),
                                        padding: padding,
                                        safeArea: geometry.safeAreaInsets)

        ZStack(alignment: .bottomLeading) {
            Color.black
            if let speaker = activeSpeaker {
                if let track = speaker.videoTrack {
                    NativeCallVideoView(track: track, contentMode: .fill)
                } else {
                    LoadableAvatarImage(url: speaker.avatarURL,
                                        name: speaker.name,
                                        contentID: speaker.identity,
                                        avatarSize: .custom(40),
                                        mediaProvider: mediaProvider)
                }
                if let name = speaker.name {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Подсказка «вернуться в портрет» (top-right).
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .padding(5)
                }
                Spacer()
            }
        }
        .frame(width: pipWidth, height: pipHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
        .position(x: anchor.x + pipOffset.width, y: anchor.y + pipOffset.height)
        .onTapGesture { onRequestPortrait?() }
        .simultaneousGesture(DragGesture(minimumDistance: 10)
            .onChanged { value in pipOffset = value.translation }
            .onEnded { value in
                let finalPoint = CGPoint(x: anchor.x + value.translation.width,
                                         y: anchor.y + value.translation.height)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    pipCorner = PipCorner.nearest(to: finalPoint,
                                                  in: geometry.size,
                                                  pipSize: CGSize(width: pipWidth, height: pipHeight),
                                                  padding: padding,
                                                  safeArea: geometry.safeAreaInsets)
                    pipOffset = .zero
                }
            })
    }

    // MARK: resolvers

    private var screenShareTrack: VideoTrack? {
        for p in roomManager.displayParticipants {
            if let pub = p.videoTracks.first(where: { $0.isScreenShareTrack }),
               pub.isSubscribed, let track = pub.track as? VideoTrack {
                return track
            }
        }
        return nil
    }

    private var screenShareLabel: String? {
        guard let owner = roomManager.displayParticipants.first(where: { p in
            p.videoTracks.contains { $0.isScreenShareTrack && $0.isSubscribed }
        }) else { return nil }
        let identity = owner.identity?.stringValue ?? ""
        let name = participants.first(where: { $0.userID == identity })?.displayName
            ?? participants.first(where: { identity.hasPrefix($0.userID) })?.displayName
            ?? owner.name
            ?? "?"
        return String(format: NSLocalizedString("stalk_call_screen_share_name", tableName: "Localizable", value: "%@ — экран", comment: "Screen share tile name: <participant> — screen"), name)
    }

    private struct SpeakerInfo {
        let identity: String
        let name: String?
        let videoTrack: VideoTrack?
        let avatarURL: URL?
    }

    /// Активный говорящий (НЕ screen-share трек): speaking remote → первый remote.
    private var activeSpeaker: SpeakerInfo? {
        let remotes = roomManager.displayParticipants
        let speakingIDs = Set(roomManager.activeSpeakers
            .compactMap { ($0 as? RemoteParticipant)?.identity?.stringValue })
        let speaking = remotes
            .filter { speakingIDs.contains($0.identity?.stringValue ?? "") }
            .filter { !($0.firstAudioPublication?.isMuted ?? false) }
        guard let speaker = speaking.first ?? remotes.first else { return nil }
        let identity = speaker.identity?.stringValue ?? ""
        let cameraPub = speaker.videoTracks.first(where: { !$0.isScreenShareTrack })
        let videoMuted = cameraPub?.isMuted ?? true
        let name = participants.first(where: { $0.userID == identity })?.displayName
            ?? participants.first(where: { identity.hasPrefix($0.userID) })?.displayName
            ?? speaker.name
        let avatarURL = participants.first(where: { $0.userID == identity })?.avatarURL
            ?? participants.first(where: { identity.hasPrefix($0.userID) })?.avatarURL
        return SpeakerInfo(identity: identity,
                           name: name,
                           videoTrack: videoMuted ? nil : speaker.firstCameraVideoTrack,
                           avatarURL: avatarURL)
    }
}

// MARK: - Helpers

/// STMOB-232: если имя — сырой Matrix ID (`@localpart:server[:device]`), показываем
/// `localpart`. Юзеры без выставленного profile display name (dp.bondar, Троцкий)
/// приходят в LiveKit JWT с `name = @user:server` и отображались у собеседников как
/// `@dp.bondar:stalk.implica.ru`. Прячем сырой ID и из JWT-name, и из Matrix displayName.
private func prettifyParticipantName(_ name: String) -> String {
    guard name.hasPrefix("@"), let colon = name.firstIndex(of: ":") else { return name }
    let localpart = name[name.index(after: name.startIndex)..<colon]
    return localpart.isEmpty ? name : String(localpart)
}

private func initials(from name: String) -> String {
    let components = name.split(separator: " ")
    if components.count >= 2 {
        return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
    }
    return String(name.prefix(2)).uppercased()
}
