//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MapKit
import SwiftUI

/// Интерактивная карта — карты Apple MapKit на iOS (решение dp 18.11): без ключа и сторонних
/// сервисов, тёмная/светлая тема следует системе сама. Имя типа оставлено от MapLibre.
struct MapLibreMapView: UIViewRepresentable {
    struct Options {
        /// the final zoom level used when the first user location emit
        let zoomLevel: Double
        /// The initial zoom level used when the map it firstly loaded and the user location is not yet available, in case of annotations this property is not being used
        let initialZoomLevel: Double
        
        /// The initial map center
        let mapCenter: CLLocationCoordinate2D
        
        /// Map annotations
        let annotations: [LocationAnnotation]

        init(zoomLevel: Double, initialZoomLevel: Double, mapCenter: CLLocationCoordinate2D, annotations: [LocationAnnotation] = []) {
            self.zoomLevel = zoomLevel
            self.initialZoomLevel = initialZoomLevel
            self.mapCenter = mapCenter
            self.annotations = annotations
        }
    }
    
    // MARK: - Properties
    
    let options: Options
    
    /// Behavior mode of the current user's location, can be hidden, only shown and shown following the user
    @Binding var showsUserLocationMode: ShowUserLocationMode
    /// Bind view errors if any
    @Binding var error: MapLibreError?
    /// Coordinate of the center of the map
    @Binding var mapCenterCoordinate: CLLocationCoordinate2D?
    @Binding var isLocationAuthorized: Bool?
    /// The radius of uncertainty for the location, measured in meters.
    @Binding var geolocationUncertainty: CLLocationAccuracy?
    
    /// Called when the user pan on the map
    var userDidPan: (() -> Void)?
    
    // MARK: - UIViewRepresentable
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = makeMapView()
        mapView.delegate = context.coordinator
        context.coordinator.addGestureObservers(to: mapView)
        setupMap(mapView: mapView, with: options)
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.mapLibreView = self
        showUserLocation(in: mapView, locationManager: context.coordinator.locationManager)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - Private

    private func setupMap(mapView: MKMapView, with options: Options) {
        mapView.addAnnotations(options.annotations)
        let zoomLevel = options.annotations.isEmpty ? options.initialZoomLevel : options.zoomLevel
        mapView.setRegion(.init(center: options.mapCenter, zoomLevel: zoomLevel), animated: false)
    }
    
    private func makeMapView() -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        return mapView
    }
    
    private func showUserLocation(in mapView: MKMapView, locationManager: CLLocationManager) {
        switch (showsUserLocationMode, options.annotations) {
        case (.showAndFollow, _):
            // В отличие от MapLibre, MapKit сам доступ к геопозиции не запрашивает
            locationManager.requestWhenInUseAuthorization()
            mapView.showsUserLocation = true
            if mapView.userTrackingMode != .follow {
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        case (.show, let annotations) where !annotations.isEmpty:
            // In the show mode, if there are annotations, we check the authorizationStatus,
            // if it's not determined, we wont prompt the user with a request for permissions,
            // because they should be able to see the annotations without sharing their location information.
            guard locationManager.authorizationStatus != .notDetermined else { return }
            fallthrough
        case (.show, _):
            locationManager.requestWhenInUseAuthorization()
            mapView.showsUserLocation = true
            if mapView.userTrackingMode != .none {
                mapView.setUserTrackingMode(.none, animated: false)
            }
        case (.hide, _):
            mapView.showsUserLocation = false
            if mapView.userTrackingMode != .none {
                mapView.setUserTrackingMode(.none, animated: false)
            }
        }
    }
}

// MARK: - Coordinator

extension MapLibreMapView {
    class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate, UIGestureRecognizerDelegate {
        // MARK: - Properties

        var mapLibreView: MapLibreMapView
        
        let locationManager = CLLocationManager()
        
        private var previousUserLocation: MKUserLocation?

        // MARK: - Setup

        init(_ mapLibreView: MapLibreMapView) {
            self.mapLibreView = mapLibreView
            super.init()
            locationManager.delegate = self
        }
        
        /// MapKit не сообщает причину сдвига карты, поэтому жесты пользователя ловим сами.
        func addGestureObservers(to mapView: MKMapView) {
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(userGesture(_:)))
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(userGesture(_:)))
            for gesture in [panGesture, pinchGesture] {
                gesture.delegate = self
                mapView.addGestureRecognizer(gesture)
            }
        }
        
        @objc private func userGesture(_ gesture: UIGestureRecognizer) {
            // we send the userDidPan event only for the gestures that actually will change the map center
            guard gesture.state == .began else { return }
            mapLibreView.userDidPan?()
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
        
        // MARK: - MKMapViewDelegate
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? LocationAnnotation else {
                return nil
            }
            return LocationAnnotationView(annotation: annotation)
        }
        
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            if mapLibreView.error != .failedLoadingMap {
                mapLibreView.error = .failedLoadingMap
            }
        }
        
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard userLocation.location != nil else { return }

            if previousUserLocation == nil, mapLibreView.options.annotations.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    mapView.setRegion(.init(center: userLocation.coordinate, zoomLevel: self.mapLibreView.options.zoomLevel), animated: true)
                }
            }

            previousUserLocation = userLocation
            updateGeolocationUncertainty(location: userLocation)
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Avoid `Publishing changes from within view update` warnings
            DispatchQueue.main.async { [mapLibreView] in
                mapLibreView.mapCenterCoordinate = mapView.centerCoordinate
            }
        }
        
        // MARK: - CLLocationManagerDelegate
        
        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .denied, .restricted:
                mapLibreView.isLocationAuthorized = false
            case .authorizedAlways, .authorizedWhenInUse:
                mapLibreView.isLocationAuthorized = true
            case .notDetermined:
                mapLibreView.isLocationAuthorized = nil
            @unknown default:
                break
            }
        }
        
        // MARK: Private

        private func updateGeolocationUncertainty(location: MKUserLocation) {
            guard let clLocation = location.location, clLocation.horizontalAccuracy >= 0 else {
                mapLibreView.geolocationUncertainty = nil
                return
            }

            mapLibreView.geolocationUncertainty = clLocation.horizontalAccuracy
        }
    }
}

// MARK: - MKCoordinateRegion convenient methods

extension MKCoordinateRegion {
    /// Регион с масштабом, как у уровня зума тайловых карт (256-точечные тайлы, ширина ~400 точек).
    init(center: CLLocationCoordinate2D, zoomLevel: Double, width: Double = 400) {
        let longitudeDelta = min(360, 360 / pow(2, zoomLevel) * width / 256)
        self.init(center: center, span: MKCoordinateSpan(latitudeDelta: min(170, longitudeDelta), longitudeDelta: longitudeDelta))
    }
}
