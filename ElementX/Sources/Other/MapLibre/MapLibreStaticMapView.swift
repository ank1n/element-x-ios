//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation
import CryptoKit
import MapLibre
import SwiftUI

struct MapLibreStaticMapView<PinAnnotation: View>: View {
    private let coordinates: CLLocationCoordinate2D
    private let zoomLevel: Double
    private let mapURLBuilder: MapTilerURLBuilderProtocol
    private let mapTilerAttributionPlacement: MapTilerAttributionPlacement
    private let mapSize: CGSize
    private let pinAnnotationView: PinAnnotation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var fetchAttempt = 0
    @State private var snapshot: UIImage?
    @State private var snapshotFailed = false
    
    init(coordinates: CLLocationCoordinate2D,
         zoomLevel: Double,
         attributionPlacement: MapTilerAttributionPlacement,
         mapURLBuilder: MapTilerURLBuilderProtocol,
         mapSize: CGSize,
         @ViewBuilder pinAnnotationView: () -> PinAnnotation) {
        self.coordinates = coordinates
        self.zoomLevel = zoomLevel
        self.mapURLBuilder = mapURLBuilder
        mapTilerAttributionPlacement = attributionPlacement
        self.mapSize = mapSize
        self.pinAnnotationView = pinAnnotationView()
    }
    
    var body: some View {
        GeometryReader { geometry in
            Group {
                // Карты OpenFreeMap (решение dp 18.11): у OpenFreeMap нет API статичных картинок,
                // поэтому превью рендерим сами через MLNMapSnapshotter тем же стилем, что и карта.
                if let snapshot {
                    ZStack {
                        Image(uiImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                        pinAnnotationView
                    }
                    .overlay(alignment: mapTilerAttributionPlacement.alignment) {
                        if mapTilerAttributionPlacement != .hidden {
                            MapAttributionLabel()
                        }
                    }
                } else if snapshotFailed {
                    errorView
                } else {
                    placeholderImage
                }
            }
            .position(x: geometry.frame(in: .local).midX, y: geometry.frame(in: .local).midY)
        }
        .task(id: snapshotRequestID) {
            await loadSnapshot()
        }
    }
    
    private var snapshotRequestID: String {
        "\(colorScheme.mapStyle)-\(fetchAttempt)"
    }
    
    private func loadSnapshot() async {
        guard let styleURL = mapURLBuilder.interactiveMapURL(for: colorScheme.mapStyle) else {
            snapshot = nil
            snapshotFailed = false
            return
        }
        
        // temporary using a fixed size since the refresh doesn't work properly on the UITableView based timeline
        let image = await MapSnapshotCache.shared.snapshot(styleURL: styleURL,
                                                           coordinates: coordinates,
                                                           zoomLevel: zoomLevel,
                                                           size: mapSize,
                                                           scale: displayScale)
        guard !Task.isCancelled else { return }
        snapshot = image
        snapshotFailed = image == nil
    }

    private var placeholderImage: some View {
        Image(asset: Asset.Images.mapBlurred)
            .resizable()
            .scaledToFill()
    }

    private var errorView: some View {
        Button {
            snapshotFailed = false
            fetchAttempt += 1
        } label: {
            placeholderImage
                .overlay {
                    VStack(spacing: 0) {
                        Image(systemName: "arrow.clockwise")
                        Text(L10n.actionStaticMapLoad)
                    }
                }
        }
    }
}

private extension ColorScheme {
    var mapStyle: MapTilerStyle {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        @unknown default:
            return .light
        }
    }
}

private extension MapTilerAttributionPlacement {
    var alignment: Alignment {
        switch self {
        case .bottomRight, .hidden: .bottomTrailing
        case .bottomLeft: .bottomLeading
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        }
    }
}

/// Подпись источников — карты OpenFreeMap (решение dp 18.11) требуют атрибуцию
/// и на интерактивной карте, и на превью локации в ленте.
struct MapAttributionLabel: View {
    static let text = "© OpenFreeMap © OpenMapTiles © OpenStreetMap"
    
    var body: some View {
        Text(Self.text)
            .font(.system(size: 9))
            .foregroundColor(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.7))
            .accessibilityHidden(true)
    }
}

/// Кэш снимков карты для превью локаций — карты OpenFreeMap (решение dp 18.11).
/// В памяти (NSCache) и на диске (Caches/MapSnapshots); ключ — стиль (он же тема),
/// координаты, зум, размер и масштаб экрана.
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]
    private let diskDirectory = URL.cachesDirectory.appendingPathComponent("MapSnapshots", isDirectory: true)
    
    private init() {
        memoryCache.countLimit = 50
    }
    
    func snapshot(styleURL: URL, coordinates: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize, scale: CGFloat) async -> UIImage? {
        let key = String(format: "%@|%.6f,%.6f|%.2f|%dx%d@%.0f",
                         styleURL.absoluteString,
                         coordinates.latitude,
                         coordinates.longitude,
                         zoomLevel,
                         Int(size.width),
                         Int(size.height),
                         scale)
        
        if let image = memoryCache.object(forKey: key as NSString) {
            return image
        }
        
        if let task = inFlightTasks[key] {
            return await task.value
        }
        
        let fileURL = diskFileURL(for: key)
        let task = Task<UIImage?, Never> {
            if let image = await Self.readImage(at: fileURL, scale: scale) {
                return image
            }
            
            guard let image = await Self.renderSnapshot(styleURL: styleURL, coordinates: coordinates, zoomLevel: zoomLevel, size: size, scale: scale) else {
                return nil
            }
            
            await Self.writeImage(image, to: fileURL)
            return image
        }
        
        inFlightTasks[key] = task
        let image = await task.value
        inFlightTasks[key] = nil
        
        if let image {
            memoryCache.setObject(image, forKey: key as NSString)
        }
        return image
    }
    
    // MARK: - Private
    
    private func diskFileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent("\(hash).png", isDirectory: false)
    }
    
    private static func renderSnapshot(styleURL: URL, coordinates: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize, scale: CGFloat) async -> UIImage? {
        let options = MLNMapSnapshotOptions(styleURL: styleURL,
                                            camera: MLNMapCamera(lookingAtCenter: coordinates, altitude: 0, pitch: 0, heading: 0),
                                            size: size)
        options.zoomLevel = zoomLevel
        options.scale = scale
        // Логотип и атрибуцию стиля в картинку не рисуем — подпись накладывается поверх (MapAttributionLabel).
        options.showsLogo = false
        options.showsAttribution = false
        
        let snapshotter = MLNMapSnapshotter(options: options)
        return await withCheckedContinuation { continuation in
            snapshotter.start { snapshot, error in
                // Снимальщик держим до конца рендера, иначе он освободится раньше времени.
                withExtendedLifetime(snapshotter) {
                    if let error {
                        MXLog.error("Failed rendering map snapshot: \(error)")
                    }
                    continuation.resume(returning: snapshot?.image)
                }
            }
        }
    }
    
    private nonisolated static func readImage(at fileURL: URL, scale: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data, scale: scale)
    }
    
    private nonisolated static func writeImage(_ image: UIImage, to fileURL: URL) async {
        guard let data = image.pngData() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            MXLog.error("Failed caching map snapshot: \(error)")
        }
    }
}

struct MapLibreStaticMapView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        MapLibreStaticMapView(coordinates: CLLocationCoordinate2D(),
                              zoomLevel: 15,
                              attributionPlacement: .bottomLeft,
                              mapURLBuilder: MapTilerURLBuilderMock(),
                              mapSize: .init(width: 300, height: 200)) {
            Image(systemName: "mappin.circle.fill")
                .padding(.bottom, 35)
        }
    }
}

private struct MapTilerURLBuilderMock: MapTilerURLBuilderProtocol {
    func interactiveMapURL(for style: MapTilerStyle) -> URL? {
        nil
    }
}
