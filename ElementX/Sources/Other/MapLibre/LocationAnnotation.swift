//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MapKit
import SwiftUI

/// Карты Apple MapKit на iOS (решение dp 18.11).
final class LocationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let anchorPoint: CGPoint
    let view: AnyView
    
    // MARK: - Setup
    
    init(coordinate: CLLocationCoordinate2D,
         anchorPoint: CGPoint = .init(x: 0.5, y: 0.5),
         @ViewBuilder label: () -> some View) {
        self.coordinate = coordinate
        self.anchorPoint = anchorPoint
        view = AnyView(label())
        super.init()
    }
}

final class LocationAnnotationView: MKAnnotationView {
    // MARK: - Setup
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier:
            reuseIdentifier)
    }
    
    convenience init(annotation: LocationAnnotation) {
        self.init(annotation: annotation, reuseIdentifier: "\(Self.self)")
        let view: UIView = UIHostingController(rootView: annotation.view).view
        view.backgroundColor = .clear
        addSubview(view)
        view.frame.size = view.intrinsicContentSize
        frame.size = view.frame.size
        // MapKit ставит центр вью в координату — сдвигаем, чтобы в координате была точка привязки
        centerOffset = CGPoint(x: (0.5 - annotation.anchorPoint.x) * frame.width,
                               y: (0.5 - annotation.anchorPoint.y) * frame.height)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }
}
