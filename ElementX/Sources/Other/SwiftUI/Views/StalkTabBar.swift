//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI
import UIKit

// MARK: - sTalk Adaptive Colors

extension Color {
    static let stalkBadgeGreen = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.29, green: 0.70, blue: 0.35, alpha: 1)
            : UIColor(red: 0.33, green: 0.78, blue: 0.39, alpha: 1)
    })

    static let stalkOnlineGreen = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.25, green: 0.72, blue: 0.32, alpha: 1)
            : UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    })

    static let stalkBubbleOutgoing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.37, blue: 0.22, alpha: 1)
            : UIColor(red: 0.88, green: 0.99, blue: 0.78, alpha: 1)
    })

    static let stalkBubbleIncoming = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
            : UIColor.white
    })
}

/// Stalk-style tab bar item configuration
struct StalkTabItem: Identifiable {
    let id: String
    let title: String
    let sfSymbol: String?
    let sfSymbolSelected: String?
    let lottieAnimation: String?
    var badgeCount = 0

    init(id: String, title: String,
         sfSymbol: String? = nil, sfSymbolSelected: String? = nil,
         lottieAnimation: String? = nil,
         badgeCount: Int = 0) {
        self.id = id
        self.title = title
        self.sfSymbol = sfSymbol
        self.sfSymbolSelected = sfSymbolSelected
        self.lottieAnimation = lottieAnimation
        self.badgeCount = badgeCount
    }
}

// MARK: - Concave Notch Tab Bar Shape

/// Dark rounded bar with a notch that tightly wraps the circle using an actual arc.
/// Bezier S-curves transition smoothly from flat edge into the arc.
struct NotchTabBarShape: Shape {
    var notchFraction: CGFloat
    var circleRadius: CGFloat = 38
    /// Circle center Y relative to bar top (positive = below bar top)
    var circleCenterY: CGFloat = 24
    var gapSize: CGFloat = 5
    var cornerRadius: CGFloat = 30

    var animatableData: CGFloat {
        get { notchFraction }
        set { notchFraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let cr = cornerRadius
        let centerX = rect.minX + rect.width * notchFraction
        let top = rect.minY

        // Arc matches circle center and curvature + gap
        let arcR = circleRadius + gapSize
        let arcCY = top + circleCenterY // arc center Y matches actual circle center

        // Arc wraps from equator (middle) of circle, around the top, back to equator
        // clockwise:true in CG = counter-clockwise on screen (Y-down)
        // 180° = left equator, 360° = right equator, passing through 270° (top)
        let arcStart = Angle.degrees(183)
        let arcEnd = Angle.degrees(357)

        // Compute arc start/end points
        let startPt = CGPoint(x: centerX + arcR * CGFloat(cos(arcStart.radians)),
                              y: arcCY + arcR * CGFloat(sin(arcStart.radians)))
        let endPt = CGPoint(x: centerX + arcR * CGFloat(cos(arcEnd.radians)),
                            y: arcCY + arcR * CGFloat(sin(arcEnd.radians)))

        // Wide shoulder for gradual descent from flat top into arc around FAB
        let shoulder: CGFloat = 44

        // STMOB-283: плечо УКОРАЧИВАЕМ, если до края панели его длины не хватает.
        //
        // Форма молча рассчитывала, что по обе стороны от центра выреза есть
        // arcR + shoulder ≈ 79 pt панели. При пяти вкладках во всю ширину у
        // крайних есть только половина ячейки: на 402 pt это 40 pt, вдвое
        // меньше нужного. entryX уходил в минус (−39 pt на «Контактах»),
        // exitX — за правый край (441 pt на «Настройках»), и управляющая точка
        // кривой оказывалась ВНЕ прямоугольника. У верхнего угла заливка не
        // доходила до края, там проступал фон и тень кружка — грязное пятно
        // на скриншотах dp от 20.08 (замер: 217 против 240 на чистом крае,
        // при этом противоположный край того же снимка чистый).
        //
        // Отсечения одного лишь прямого участка не хватало: он пропускался,
        // а кривая всё равно строилась от вылезшего entryX. Поэтому ограничиваем
        // саму длину плеча — переход у крайних вкладок становится круче, но
        // панель остаётся целой. Ширины, при которой влезало бы полное плечо,
        // у телефонов не бывает: нужна панель ~794 pt.
        let leftShoulder = min(shoulder, max(startPt.x - (rect.minX + cr), 0))
        let rightShoulder = min(shoulder, max((rect.maxX - cr) - endPt.x, 0))
        let entryX = startPt.x - leftShoulder
        let exitX = endPt.x + rightShoulder

        // How far the arc start/end dip below bar top
        let dipY = max(startPt.y - top, 1)

        var path = Path()

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top + cr))
        path.addQuadCurve(to: CGPoint(x: rect.minX + cr, y: top),
                          control: CGPoint(x: rect.minX, y: top))

        // Flat top to left shoulder entry
        if entryX > rect.minX + cr {
            path.addLine(to: CGPoint(x: entryX, y: top))
        }

        // Left bezier: gradual descent — starts flat, slowly dips, then wraps into arc
        // cp1 stays on top line far along → long flat run before dipping
        // cp2 near arc entry with gradual vertical approach
        path.addCurve(to: startPt,
                      control1: CGPoint(x: entryX + leftShoulder * 0.65, y: top),
                      control2: CGPoint(x: startPt.x - leftShoulder * 0.08, y: top + dipY * 0.55))

        // Arc wrapping around the circle
        path.addArc(center: CGPoint(x: centerX, y: arcCY),
                    radius: arcR,
                    startAngle: arcStart,
                    endAngle: arcEnd,
                    clockwise: true)

        // Right bezier: mirror — gradual ascent from arc back to flat top
        path.addCurve(to: CGPoint(x: exitX, y: top),
                      control1: CGPoint(x: endPt.x + rightShoulder * 0.08, y: top + dipY * 0.55),
                      control2: CGPoint(x: exitX - rightShoulder * 0.65, y: top))

        // Flat top to right corner
        if exitX < rect.maxX - cr {
            path.addLine(to: CGPoint(x: rect.maxX - cr, y: top))
        }

        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + cr),
                          control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        path.closeSubpath()
        return path
    }
}

// MARK: - Stalk Tab Bar

struct StalkTabBar: View {
    let items: [StalkTabItem]
    @Binding var selectedIndex: Int
    @AppStorage("stalk_design_theme") private var designTheme = "cosmos"

    @State private var animatingIndex: Int?

    private var isCosmos: Bool {
        designTheme == "cosmos"
    }

    var body: some View {
        if isCosmos {
            cosmosBody
        } else {
            classicBody
        }
    }

    // MARK: - Cosmos design

    private let barHeight: CGFloat = 74
    private let barPadH: CGFloat = 0 // edge to edge
    private let barCorner: CGFloat = 0 // no corner rounding, edge to edge
    private let circleSize: CGFloat = 61

    // Circle center ABOVE bar top — ~55% above, 45% inside
    private let circleOffset: CGFloat = -6
    private let notchGap: CGFloat = 5 // small visible gap between FAB circle and bar notch

    // Active circle: white background with blue icon
    private let accentCircle = Color.white
    private let accentIcon = Color(red: 0.38, green: 0.42, blue: 0.96) // sTalk blue

    /// Dark purple gradient for cosmos bar
    private var barGradient: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.93, green: 0.94, blue: 1.0), // almost white blue top
            Color(red: 0.87, green: 0.89, blue: 0.98) // very light blue bottom
        ],
        startPoint: .top,
        endPoint: .bottom)
    }

    // Icon colors
    private let iconInactive = Color(red: 0.45, green: 0.45, blue: 0.60)
    private let iconActive = Color(white: 0.12)

    private var selectedFraction: CGFloat {
        guard items.count > 0 else { return 0.5 }
        return (CGFloat(selectedIndex) + 0.5) / CGFloat(items.count)
    }

    private var cosmosBody: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                cosmosTab(for: items[index], index: index)
            }
        }
        .frame(height: barHeight)
        .padding(.horizontal, barPadH)
        // Dark rounded bar with arc-notch following circle curvature
        .background(NotchTabBarShape(notchFraction: selectedFraction,
                                     circleRadius: circleSize / 2,
                                     circleCenterY: circleSize / 2 + circleOffset, // actual circle center Y from bar top
                                     gapSize: notchGap,
                                     cornerRadius: barCorner)
                .fill(barGradient)
                .shadow(color: Color(red: 0.50, green: 0.45, blue: 0.70).opacity(0.25), radius: 10, y: -3)
                .shadow(color: .black.opacity(0.08), radius: 4, y: -1)
                .padding(.horizontal, barPadH)
                .animation(.spring(response: 0.4, dampingFraction: 0.72), value: selectedIndex))
        // Bright circle sitting in the notch
        .overlay(alignment: .top) {
            circleOverlay
        }
        .offset(y: 22)
    }

    private var circleOverlay: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                ZStack {
                    if selectedIndex == index {
                        Circle()
                            .fill(accentCircle)
                            .frame(width: circleSize, height: circleSize)
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                            .overlay {
                                iconView(for: items[index], index: index, isActive: true, iconColor: accentIcon)
                                    .shadow(color: accentIcon.opacity(0.35), radius: 3, y: 1)
                            }
                            .offset(y: circleOffset)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, barPadH)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: selectedIndex)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cosmosTab(for item: StalkTabItem, index: Int) -> some View {
        let isActive = selectedIndex == index

        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                selectedIndex = index
            }
            animatingIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if animatingIndex == index { animatingIndex = nil }
            }
        } label: {
            ZStack {
                if isActive {
                    // Placeholder — icon is in the floating circle
                    Color.clear
                } else {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            iconView(for: item, index: index, isActive: false, iconColor: iconInactive)
                                .frame(width: 28, height: 28)

                            if item.badgeCount > 0 {
                                badgeView(count: item.badgeCount)
                                    .offset(x: 10, y: -4)
                            }
                        }
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.55))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Classic: original flat tab bar

    private var classicBody: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.compound.borderDisabled)
                .frame(height: 1 / UIScreen.main.scale)

            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    classicTab(for: items[index], index: index)
                }
            }
            .frame(height: 49)
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func classicTab(for item: StalkTabItem, index: Int) -> some View {
        let isActive = selectedIndex == index

        Button {
            selectedIndex = index
            animatingIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if animatingIndex == index { animatingIndex = nil }
            }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    iconView(for: item, index: index, isActive: isActive,
                             iconColor: isActive ? .accentColor : Color(.systemGray))
                        .frame(width: 36, height: 36)

                    if item.badgeCount > 0 {
                        badgeView(count: item.badgeCount)
                            .offset(x: 10, y: -4)
                    }
                }

                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isActive ? .accentColor : Color(.systemGray))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared

    @ViewBuilder
    private func iconView(for item: StalkTabItem, index: Int, isActive: Bool, iconColor: Color) -> some View {
        if let lottie = item.lottieAnimation {
            let lottieSize: CGFloat = isCosmos ? (isActive ? 17 : 30) : 36
            let lottieScale: CGFloat = isCosmos ? (isActive ? 0.83 : 1.52) : 1.54
            let lottieActiveUIColor = UIColor(iconColor)
            let lottieInactiveUIColor: UIColor = isCosmos
                ? UIColor(red: 0.45, green: 0.45, blue: 0.60, alpha: 1)
                : .systemGray
            LottieTabBarIcon(animationName: lottie,
                             isSelected: isActive,
                             playAnimation: animatingIndex == index,
                             iconSize: lottieSize,
                             activeColor: lottieActiveUIColor,
                             inactiveColor: lottieInactiveUIColor)
                .scaleEffect(lottieScale)
        } else if let sfSymbol = item.sfSymbol {
            let name = isActive ? (item.sfSymbolSelected ?? sfSymbol) : sfSymbol
            let fontSize: CGFloat = isCosmos ? (isActive ? 15 : 27) : 26
            Image(systemName: name)
                .font(.system(size: fontSize, weight: .light))
                .foregroundColor(iconColor)
        }
    }

    @ViewBuilder
    private func badgeView(count: Int) -> some View {
        let text = count > 99 ? "99+" : "\(count)"
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.compound.textOnSolidPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.compound.textCriticalPrimary)
            .clipShape(Capsule())
    }
}
