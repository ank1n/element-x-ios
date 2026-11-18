//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation
import MapKit
import SwiftUI

/// Превью локации в ленте — карты Apple MapKit на iOS (решение dp 18.11): картинку рисует
/// MKMapSnapshotter в текущей теме, без ключа и сторонних сервисов. Имя типа оставлено от MapLibre.
struct MapLibreStaticMapView<PinAnnotation: View>: View {
    private let coordinates: CLLocationCoordinate2D
    private let zoomLevel: Double
    private let mapSize: CGSize
    private let pinAnnotationView: PinAnnotation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var fetchAttempt = 0
    @State private var snapshot: UIImage?
    @State private var snapshotFailed = false
    
    init(coordinates: CLLocationCoordinate2D,
         zoomLevel: Double,
         mapSize: CGSize,
         @ViewBuilder pinAnnotationView: () -> PinAnnotation) {
        self.coordinates = coordinates
        self.zoomLevel = zoomLevel
        self.mapSize = mapSize
        self.pinAnnotationView = pinAnnotationView()
    }
    
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let snapshot {
                    ZStack {
                        Image(uiImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                        pinAnnotationView
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
        "\(colorScheme)-\(fetchAttempt)"
    }
    
    private func loadSnapshot() async {
        // temporary using a fixed size since the refresh doesn't work properly on the UITableView based timeline
        let image = await MapSnapshotCache.shared.snapshot(coordinates: coordinates,
                                                           zoomLevel: zoomLevel,
                                                           size: mapSize,
                                                           colorScheme: colorScheme,
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

/// Кэш снимков карты для превью локаций — карты Apple MapKit на iOS (решение dp 18.11).
/// Ключ — координаты, зум, размер, масштаб экрана и тема.
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]
    
    private init() {
        cache.countLimit = 50
    }
    
    func snapshot(coordinates: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize, colorScheme: ColorScheme, scale: CGFloat) async -> UIImage? {
        let isDark = colorScheme == .dark
        let key = String(format: "%.6f,%.6f|%.2f|%dx%d@%.0f|%@",
                         coordinates.latitude,
                         coordinates.longitude,
                         zoomLevel,
                         Int(size.width),
                         Int(size.height),
                         scale,
                         isDark ? "dark" : "light")
        
        if let image = cache.object(forKey: key as NSString) {
            return image
        }
        
        if let task = inFlightTasks[key] {
            return await task.value
        }
        
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinates, zoomLevel: zoomLevel, width: size.width)
        options.size = size
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = isDark ? .dark : .light
            traits.displayScale = scale
        }
        
        let task = Task<UIImage?, Never> {
            do {
                return try await MKMapSnapshotter(options: options).start().image
            } catch {
                MXLog.error("Failed rendering map snapshot: \(error)")
                return nil
            }
        }
        
        inFlightTasks[key] = task
        let image = await task.value
        inFlightTasks[key] = nil
        
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}

struct MapLibreStaticMapView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        MapLibreStaticMapView(coordinates: CLLocationCoordinate2D(),
                              zoomLevel: 15,
                              mapSize: .init(width: 300, height: 200)) {
            Image(systemName: "mappin.circle.fill")
                .padding(.bottom, 35)
        }
    }
}
