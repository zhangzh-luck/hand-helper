import SwiftUI
import UIKit

/// Presented above NativeTabContainer so its scrim also covers the UIKit tab bar.
struct GradeDetailOverlay: View {
    @ObservedObject var detail: GradeDetailCoordinator
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GradeDetailRootAnchor(detail: detail)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                if let route = detail.route {
                    GradeDetailSurface(detail: detail, route: route,
                                       bounds: CGRect(origin: .zero, size: geometry.size),
                                       safeArea: detail.windowSafeArea,
                                       reduceMotion: reduceMotion)
                        .id(route.id)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(detail.isPresenting)
    }
}

private struct GradeDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum GradeDetailMotion {
    static let openingDuration = 0.32
    static let closingDuration = 0.22
    static let reducedDuration = 0.15

    static func scrimOpacity(dark: Bool) -> Double { dark ? 0.42 : 0.32 }

    static func animation(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: reducedDuration) }
        return .spring(duration: opening ? openingDuration : closingDuration, bounce: 0.06)
    }
}

private struct GradeDetailSurface: View {
    @ObservedObject var detail: GradeDetailCoordinator
    let route: GradeDetailRoute
    let bounds: CGRect
    let safeArea: UIEdgeInsets
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var destination: CGRect?
    @State private var measuredContentHeight: CGFloat = 0
    @State private var closing = false
    @State private var focusTitle = false

    private var targetWidth: CGFloat {
        GradeDetailLayout.frame(in: bounds, safeArea: safeArea, contentHeight: 0).width
    }

    private var surfaceKind: GradeDetailSurfaceKind {
        let supportsGlass: Bool
        if #available(iOS 26.0, *) { supportsGlass = true }
        else { supportsGlass = false }
        return .current(reduceTransparency: reduceTransparency,
                        increasedContrast: contrast == .increased,
                        supportsGlass: supportsGlass)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    @ViewBuilder
    private func panelSurface<Content: View>(_ content: Content) -> some View {
        switch surfaceKind {
        case .glass:
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: panelShape)
            }
        case .material:
            content.background(.thickMaterial, in: panelShape)
        case .opaque:
            content.background(Color(uiColor: .systemGroupedBackground), in: panelShape)
        }
    }

    private var panelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: 0.92)
            .combined(with: .offset(y: 10))
            .combined(with: .opacity)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let destination {
                Color.black.opacity(GradeDetailMotion.scrimOpacity(dark: colorScheme == .dark))
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .transition(.opacity)

                panelSurface(ScrollView(.vertical) {
                    GradeDetailView(grade: route.grade, focusTitle: focusTitle, onClose: { close() },
                                    glassHeader: surfaceKind == .glass)
                        .frame(width: destination.width)
                }
                .scrollDisabled(!GradeDetailLayout.needsScrolling(
                    contentHeight: measuredContentHeight, viewportHeight: destination.height))
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(width: destination.width, height: destination.height))
                .clipShape(panelShape)
                .overlay(panelShape.strokeBorder(Color.primary.opacity(
                    surfaceKind == .glass ? 0 : contrast == .increased ? 0.24 : 0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .transition(panelTransition)
                .position(x: destination.midX, y: destination.midY)
                .allowsHitTesting(!closing)
                .accessibilityHidden(closing)
            } else {
                GradeDetailView(grade: route.grade, focusTitle: false, onClose: {},
                                glassHeader: surfaceKind == .glass)
                    .frame(width: targetWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: GradeDetailHeightKey.self,
                                               value: proxy.size.height)
                    })
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .onPreferenceChange(GradeDetailHeightKey.self) { height in
            guard destination == nil, height > 0, detail.route?.id == route.id,
                  detail.phase == .opening else { return }
            open(at: GradeDetailLayout.frame(in: bounds, safeArea: safeArea,
                                             contentHeight: height), contentHeight: height)
        }
        .onChange(of: bounds.size) { _, _ in close(userInitiated: false) }
    }

    private func open(at frame: CGRect, contentHeight: CGFloat) {
        withAnimation(GradeDetailMotion.animation(opening: true, reduceMotion: reduceMotion),
                      completionCriteria: .removed) {
            measuredContentHeight = contentHeight
            destination = frame
        } completion: {
            guard detail.route?.id == route.id, detail.phase == .opening else { return }
            detail.markOpen(id: route.id)
            focusTitle = true
        }
    }

    private func close(userInitiated: Bool = true) {
        guard !closing, detail.beginClose(id: route.id) else { return }
        if userInitiated { AppHaptics.trigger(.detailClosed) }
        closing = true
        focusTitle = false
        guard destination != nil else { detail.finish(id: route.id); return }
        withAnimation(GradeDetailMotion.animation(opening: false, reduceMotion: reduceMotion),
                      completionCriteria: .removed) {
            destination = nil
        } completion: {
            guard detail.route?.id == route.id, detail.phase == .closing else { return }
            detail.finish(id: route.id)
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }
}
