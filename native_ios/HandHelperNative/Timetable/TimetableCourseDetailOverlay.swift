import SwiftUI
import UIKit
import os

enum TimetableMotionDiagnostics {
    #if DEBUG
    private static let log = OSLog(subsystem: "com.handhelper.timetable", category: "detail-motion")
    #endif
    static func event(_ name: StaticString) {
        #if DEBUG
        os_signpost(.event, log: log, name: name)
        #endif
    }
}

#if DEBUG
/// Launch arguments affect only debug builds and never persist between launches.
private enum TimetableMotionExperiment {
    static let opaque = ProcessInfo.processInfo.arguments.contains("-TimetableMotionOpaque")
    static let noClip = ProcessInfo.processInfo.arguments.contains("-TimetableMotionNoClip")
}

@MainActor
private final class TimetableMotionFrameSampler: NSObject {
    private let log = OSLog(subsystem: "com.handhelper.timetable", category: "detail-motion-frames")
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var maxInterval: CFTimeInterval = 0
    private var count = 0
    private var longCount = 0
    private var label = ""

    func start(_ label: String) {
        stop(interrupted: true)
        self.label = label
        previous = nil
        maxInterval = 0
        count = 0
        longCount = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { previous = link.timestamp }
        guard let previous else { return }
        let interval = link.timestamp - previous
        guard interval > 0 else { return }
        count += 1
        maxInterval = max(maxInterval, interval)
        if interval > (link.targetTimestamp - link.timestamp) * 1.5 { longCount += 1 }
    }

    func stop(interrupted: Bool = false) {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        os_log("phase=%{public}@ frames=%{public}d long=%{public}d max_ms=%{public}.2f interrupted=%{public}d opaque=%{public}d no_clip=%{public}d",
               log: log, type: .info, label as NSString, count, longCount,
               maxInterval * 1000, interrupted ? 1 : 0,
               TimetableMotionExperiment.opaque ? 1 : 0, TimetableMotionExperiment.noClip ? 1 : 0)
    }
}
#endif

/// The root overlay sits above NativeTabContainer, including its UIKit tab bar.
struct TimetableCourseDetailOverlay: View {
    @ObservedObject var detail: TimetableCourseDetailCoordinator
    let confirmation: DestructiveConfirmationCoordinator
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TimetableDetailRootAnchor(detail: detail)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                if let route = detail.route {
                    TimetableDetailSurface(detail: detail, confirmation: confirmation, route: route,
                                           bounds: CGRect(origin: .zero, size: geometry.size),
                                           safeArea: detail.windowSafeArea,
                                           reduceMotion: reduceMotion)
                        .id(route.id)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(detail.isPresenting)
        .alert("无法操作课程", isPresented: Binding(
            get: { detail.deletionError != nil },
            set: { if !$0 { detail.dismissDeletionError() } }
        )) {
            Button("好", role: .cancel) { detail.dismissDeletionError() }
        } message: {
            Text(detail.deletionError ?? "请重试。")
        }
    }
}

private struct TimetableDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TimetableDetailSurface: View {
    @ObservedObject var detail: TimetableCourseDetailCoordinator
    let confirmation: DestructiveConfirmationCoordinator
    let route: TimetableDetailRoute
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
    @State private var morphProgress: CGFloat = 0
    @State private var panelOpacity: Double = 1
    @State private var useMorph = false
    #if DEBUG
    @State private var frameSampler = TimetableMotionFrameSampler()
    #endif

    private var targetWidth: CGFloat {
        TimetableDetailLayout.frame(in: bounds, safeArea: safeArea, preferredHeight: 0).width
    }

    private var surfaceKind: TimetableDetailSurfaceKind {
        #if DEBUG
        if TimetableMotionExperiment.opaque { return .opaque }
        #endif
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

    private var borderOpacity: Double {
        if contrast == .increased { return 0.24 }
        return surfaceKind == .glass ? 0 : 0.06
    }

    @ViewBuilder
    private func panelSurface<Content: View>(_ content: Content) -> some View {
        switch surfaceKind {
        case .glass:
            if #available(iOS 26.0, *) {
                // Let the system glass render behind the header; only the information
                // area receives a readable semantic backing inside this same outline.
                content.glassEffect(.regular, in: panelShape)
            }
        case .material:
            content.background(.thickMaterial, in: panelShape)
        case .opaque:
            content.background(Color(uiColor: .systemGroupedBackground), in: panelShape)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let destination {
                TimetableOpeningMorph(progress: morphProgress,
                                      source: useMorph ? route.source : nil,
                                      destination: destination, bounds: bounds,
                                      course: route.course, color: route.courseColor,
                                      sourceStyle: route.sourceStyle,
                                      scrimOpacity: TimetableDetailMotion.scrimOpacity(dark: colorScheme == .dark),
                                      panelOpacity: panelOpacity,
                                      onBackdrop: { close() }) { transitionProgress in
                    panelSurface(ScrollView(.vertical) {
                        TimetableDetailContent(course: route.course, courseColor: route.courseColor,
                            focusTitle: focusTitle, onClose: { close() },
                            glassHeader: surfaceKind == .glass,
                            transitionProgress: useMorph ? transitionProgress : nil,
                            onAction: route.editableManualCourse == nil ? nil : { action in
                                if action == .delete { requestDelete() } else { close(action: action) }
                            })
                            .frame(width: destination.width)
                    }
                    .scrollDisabled(!TimetableDetailLayout.needsScrolling(
                        contentHeight: measuredContentHeight, viewportHeight: destination.height))
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                    .frame(width: destination.width, height: destination.height))
                    .clipShape(panelShape)
                    .overlay(panelShape.strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                }
                .allowsHitTesting(!closing)
                .accessibilityHidden(closing)
            } else {
                // Measure once at the final width, before the visible presentation begins.
                TimetableDetailContent(course: route.course, courseColor: route.courseColor,
                                       focusTitle: false, onClose: {},
                                       glassHeader: surfaceKind == .glass,
                                       onAction: route.editableManualCourse == nil ? nil : { _ in })
                    .frame(width: targetWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TimetableDetailHeightKey.self,
                                               value: proxy.size.height)
                    })
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .onPreferenceChange(TimetableDetailHeightKey.self) { height in
            guard destination == nil, height > 0, detail.route?.id == route.id,
                  detail.phase == .opening else { return }
            TimetableMotionDiagnostics.event("detail measured")
            open(at: TimetableDetailLayout.frame(in: bounds, safeArea: safeArea,
                                                 preferredHeight: height),
                 contentHeight: height)
        }
        .onChange(of: bounds.size) { _, _ in close(userInitiated: false) }
        #if DEBUG
        .onDisappear { frameSampler.stop(interrupted: true) }
        #endif
    }

    private func open(at frame: CGRect, contentHeight: CGFloat) {
        let currentSource = detail.sourceGeometry(for: route.context)
        useMorph = !reduceMotion && TimetableDetailMotion.canReturn(
            to: route.source, current: currentSource, viewport: bounds.size)
        measuredContentHeight = contentHeight
        morphProgress = 0
        panelOpacity = 1
        destination = frame
        if useMorph { detail.hideSource(id: route.id) }
        TimetableMotionDiagnostics.event("opening scheduled")
        DispatchQueue.main.async {
            guard detail.route?.id == route.id, detail.phase == .opening else { return }
            TimetableMotionDiagnostics.event("opening start")
            #if DEBUG
            frameSampler.start("opening")
            #endif
            withAnimation(.linear(duration: reduceMotion ? TimetableDetailMotion.reducedDuration : TimetableDetailMotion.morphDuration),
                          completionCriteria: .removed) {
                morphProgress = 1
            } completion: {
                guard detail.route?.id == route.id, detail.phase == .opening else { return }
                TimetableMotionDiagnostics.event("opening complete")
                #if DEBUG
                frameSampler.stop()
                #endif
                detail.markOpen(id: route.id)
                focusTitle = true
            }
        }
    }

    private func close(action: TimetableManualCourseAction? = nil, userInitiated: Bool = true) {
        guard !closing else { return }
        if let action {
            guard detail.beginAction(action, id: route.id) else { return }
        } else {
            guard detail.beginClose(id: route.id) else { return }
        }
        if userInitiated { AppHaptics.trigger(.detailClosed) }
        closing = true
        focusTitle = false
        let canReverse = useMorph && !reduceMotion && TimetableDetailMotion.canReturn(
            to: route.source, current: detail.sourceGeometry(for: route.context), viewport: bounds.size)
        TimetableMotionDiagnostics.event("closing start")
        #if DEBUG
        frameSampler.start("closing")
        #endif
        withAnimation(.linear(duration: reduceMotion ? TimetableDetailMotion.reducedDuration : TimetableDetailMotion.morphDuration),
                      completionCriteria: .removed) {
            if canReverse { morphProgress = 0 } else { panelOpacity = 0 }
        } completion: {
            guard detail.route?.id == route.id, detail.phase == .closing else { return }
            TimetableMotionDiagnostics.event("closing complete")
            #if DEBUG
            frameSampler.stop()
            #endif
            detail.finish(id: route.id)
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    private func requestDelete() {
        guard detail.requestDelete(id: route.id), let pending = detail.pendingDelete else { return }
        if !confirmation.present(.manualCourse, confirm: {
            guard detail.pendingDelete?.id == pending.id else { return }
            _ = detail.confirmDelete()
        }, cancel: {
            if detail.pendingDelete?.id == pending.id { detail.cancelDelete() }
        }) {
            detail.cancelDelete()
        }
    }
}

private struct TimetableOpeningMorph<Content: View>: View, Animatable {
    var progress: CGFloat
    let source: TimetableDetailSource?
    let destination: CGRect
    let bounds: CGRect
    let course: CourseSession
    let color: Color
    let sourceStyle: TimetableDetailSourceStyle?
    let scrimOpacity: Double
    var panelOpacity: Double
    let onBackdrop: () -> Void
    @ViewBuilder let content: (CGFloat) -> Content

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(progress, panelOpacity) }
        set { progress = newValue.first; panelOpacity = newValue.second }
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        let curved = TimetableDetailMotion.geometryProgress(p)
        let frame = source.map { interpolate($0.frame, destination, curved) } ?? destination
        let viewport = source.map { source in
            CGRect(x: bounds.minX,
                   y: source.visibleFrame.minY + (bounds.minY - source.visibleFrame.minY) * TimetableDetailMotion.phase(p, from: 0.35, to: 0.62),
                   width: bounds.width,
                   height: source.visibleFrame.height +
                       (bounds.height - source.visibleFrame.height) * TimetableDetailMotion.phase(p, from: 0.35, to: 0.62))
        } ?? bounds
        #if DEBUG
        let clippingViewport = TimetableMotionExperiment.noClip ? bounds : viewport
        #else
        let clippingViewport = viewport
        #endif
        let corner = source == nil ? 22 : 8 + 14 * curved
        ZStack(alignment: .topLeading) {
            Color.black.opacity(scrimOpacity * Double(p) * panelOpacity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onBackdrop)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(color.opacity(0.28 * Double(1 - p))))
                    .opacity(source == nil ? 0 : Double(1 - p))
                if let source, let sourceStyle {
                    TimetableCourseCardSurface(course: course, color: color, style: sourceStyle)
                    .frame(width: source.frame.width, height: source.frame.height, alignment: .topLeading)
                    .opacity(Double(1 - TimetableDetailMotion.phase(p, from: 0.18, to: 0.34)))
                    .accessibilityHidden(true)
                }
                content(p)
                    .frame(width: destination.width, height: destination.height, alignment: .topLeading)
                    .opacity(source == nil ? Double(p) : Double(TimetableDetailMotion.phase(p, from: 0.16, to: 0.26)))
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .position(x: frame.midX, y: frame.midY)
            .opacity(panelOpacity)
            .mask(alignment: .topLeading) {
                Rectangle().frame(width: max(0, clippingViewport.width), height: max(0, clippingViewport.height))
                    .offset(x: clippingViewport.minX, y: clippingViewport.minY)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
    }

    private func interpolate(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * p,
               y: a.minY + (b.minY - a.minY) * p,
               width: a.width + (b.width - a.width) * p,
               height: a.height + (b.height - a.height) * p)
    }
}

struct TimetableDetailContent: View {
    let course: CourseSession
    let courseColor: Color
    let focusTitle: Bool
    let onClose: () -> Void
    var glassHeader = false
    var transitionProgress: CGFloat? = nil
    var onAction: ((TimetableManualCourseAction) -> Void)? = nil

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(courseColor)
                    .frame(width: 4, height: 26)
                    .accessibilityHidden(true)
                Text(course.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: 0)
                GlassCloseButton(accessibilityLabel: "关闭课程详情", diameter: 44,
                                 onDarkBackground: false, action: onClose)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .opacity(transitionProgress.map { Double(TimetableDetailMotion.phase($0, from: 0.26, to: 0.41)) } ?? 1)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(TimetableDetailInformation.rows(for: course)) { row in
                    detailRow(row)
                }
                if let onAction {
                    HStack(spacing: 10) {
                        Button { onAction(.edit) } label: {
                            Label("编辑", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) { onAction(.delete) } label: {
                            Label("删除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, glassHeader ? 14 : 0)
            .padding(.bottom, 20)
            .background {
                if glassHeader {
                    Color(uiColor: .systemGroupedBackground).opacity(0.94)
                }
            }
            .opacity(transitionProgress.map { Double(TimetableDetailMotion.phase($0, from: 0.30, to: 0.45)) } ?? 1)
            .offset(y: transitionProgress.map { 14 * (1 - TimetableDetailMotion.phase($0, from: 0.30, to: 0.45)) } ?? 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onChange(of: focusTitle) { _, value in titleFocused = value }
    }

    private func detailRow(_ row: TimetableDetailInformation.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.value)
                    .font(.subheadline)
                    .foregroundStyle(row.isSecondary ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum TimetableDetailInformation {
    struct Row: Identifiable {
        let label: String
        let symbol: String
        let value: String
        var isSecondary = false
        var id: String { label }
    }

    static func rows(for course: CourseSession) -> [Row] {
        var rows = [
            Row(label: "日期与时间", symbol: "calendar",
                value: "\(course.date) · \(TimetableCourseDetailText.time(course))"),
            Row(label: "教室", symbol: "mappin.and.ellipse",
                value: TimetableCourseDetailText.nonempty(course.room)),
            Row(label: "任课教师", symbol: "person",
                value: TimetableCourseDetailText.nonempty(course.teacher))
        ]
        if let weeks = course.weekExpression, !weeks.isEmpty {
            rows.append(Row(label: "教学周", symbol: "calendar.badge.clock",
                            value: weeks, isSecondary: true))
        }
        if let first = course.startPeriod, let last = course.endPeriod {
            rows.append(Row(label: "节次", symbol: "number", value: "第 \(first)–\(last) 节",
                            isSecondary: true))
        }
        return rows
    }
}
