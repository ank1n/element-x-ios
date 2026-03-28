//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct RoomListFilterView: View {
    let filter: RoomListFilter
    @Binding var isActive: Bool
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    var body: some View {
        if isCosmos {
            Toggle(isOn: $isActive) {
                Text(filter.localizedName)
            }
            .toggleStyle(CosmosCapsuleToggleStyle())
        } else {
            Toggle(isOn: $isActive) {
                Text(filter.localizedName)
            }
            .toggleStyle(FilterToggleStyle())
        }
    }
}

/// Универсальный фильтр для переиспользования в Звонках, Контактах, Приложениях
struct GenericFilterView: View {
    let title: String
    @Binding var isActive: Bool

    var body: some View {
        Toggle(isOn: $isActive) {
            Text(title)
        }
        .toggleStyle(FilterToggleStyle())
    }
}

struct FilterToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(configuration.isOn ? .accentColor : Color(.systemGray))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(configuration.isOn ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isOn.toggle()
                }
            }
    }
}

/// Cosmos capsule filter style — matching Calls/Apps/Contacts screens
struct CosmosCapsuleToggleStyle: ToggleStyle {
    private let accentBlue = Color(red: 0.38, green: 0.42, blue: 0.96)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(configuration.isOn ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule()
                .fill(configuration.isOn ? accentBlue : Color(UIColor.systemGray6)))
            .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isOn.toggle()
                }
            }
    }
}

// MARK: - Previews

struct RoomListFilterView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        RoomListFilterView(filter: .people, isActive: .constant(false))
        RoomListFilterView(filter: .people, isActive: .constant(true))
    }
}
