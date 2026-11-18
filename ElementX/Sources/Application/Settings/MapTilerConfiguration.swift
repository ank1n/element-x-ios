//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Конфигурация карт — карты OpenFreeMap (решение dp 18.11): стили MapLibre без ключа,
/// MapTiler больше не используется, поэтому отправка и показ локаций доступны всегда.
struct MapTilerConfiguration {
    /// Стиль MapLibre для светлой темы.
    let lightStyleURL: URL
    /// Стиль MapLibre для тёмной темы.
    let darkStyleURL: URL
    
    /// Карты OpenFreeMap (решение dp 18.11): стили по умолчанию, пока сервер не задал свой.
    static let openFreeMap = MapTilerConfiguration(lightStyleURL: "https://tiles.openfreemap.org/styles/liberty",
                                                   darkStyleURL: "https://tiles.openfreemap.org/styles/dark")
    
    /// Стиль из `/.well-known/matrix/client` (`m.tile_server.map_style_url`) приоритетнее констант
    /// и идёт на обе темы; без него — стили OpenFreeMap.
    static func withServerStyleURL(_ styleURL: URL?) -> MapTilerConfiguration {
        guard let styleURL else { return openFreeMap }
        return MapTilerConfiguration(lightStyleURL: styleURL, darkStyleURL: styleURL)
    }
}
