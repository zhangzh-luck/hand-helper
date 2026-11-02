import SwiftUI
import UIKit

/// The root overlay sits above NativeTabContainer, including its UIKit tab bar.
struct TimetableCourseDetailOverlay: View {
    @ObservedObject var detail: TimetableCourseDetailCoordinator
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TimetableDetailRootAnchor(detail: detail)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                if let route = detail.route {
                    TimetableDetailSurface(detail: detail, route: route,
                                           bounds: CGRect(origin: .zero, size: geometry.size),
                                           safeArea: detail.windowSafeArea,
                                           reduceMotion: reduceMotion)
                        .id(route.id)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(detail.isPresenting)
        .confirmationDialog("删除“\(detail.route?.course.name ?? "手动课程")”？", isPresented: Binding(
            get: { detail.pendingDelete != nil },
            set: { if !$0 { detail.cancelDelete() } }
        )) {
            Button("删除课程", role: .destructive) { _ = detail.confirmDelete() }
            Button("取消", role: .cancel) { detail.cancelDelete() }
        } message: {
            Text("删除后这门手动课程将从本机课程表移除。")
        }
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

    private var targetWidth: CGFloat {
        TimetableDetailLayout.frame(in: bounds, safeArea: safeArea, preferredHeight: 0).width
    }

    private var surfaceKind: TimetableDetailSurfaceKind {
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

    private var panelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: TimetableDetailMotion.scale(visible: false, reduceMotion: false))
            .combined(with: .offset(y: TimetableDetailMotion.verticalOffset(visible: false,
                                                                            reduceMotion: false)))
            .combined(with: .opacity)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let destination {
                Color.black.opacity(TimetableDetailMotion.scrimOpacity(dark: colorScheme == .dark))
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .transition(.opacity)

                panelSurface(ScrollView(.vertical) {
                    TimetableDetailContent(course: route.course, courseColor: route.courseColor,
                                           focusTitle: focusTitle, onClose: { close() },
                                           glassHeader: surfaceKind == .glass,
                                           onAction: route.editableManualCourse == nil ? nil : { action in
                                               if action == .delete { _ = detail.requestDelete(id: route.id) }
                                               else { close(action: action) }
                                           })
                        .frame(width: destination.width)
                }
                .scrollDisabled(!TimetableDetailLayout.needsScrolling(
                    contentHeight: measuredContentHeight, viewportHeight: destination.height))
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(width: destination.width, height: destination.height))
                .clipShape(panelShape)
                .overlay(panelShape.strokeBorder(Color.primary.opacity(borderOpacity),
                                                 lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .transition(panelTransition)
                .position(x: destination.midX, y: destination.midY)
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
            open(at: TimetableDetailLayout.frame(in: bounds, safeArea: safeArea,
                                                 preferredHeight: height),
                 contentHeight: height)
        }
        .onChange(of: bounds.size) { _, _ in close() }
    }

    private func open(at frame: CGRect, contentHeight: CGFloat) {
        // Animate the insertion controlled by the measured destination itself.
        // The panel is never inserted at its final height before this transaction.
        withAnimation(TimetableDetailMotion.animation(opening: true, reduceMotion: reduceMotion),
                      completionCriteria: .removed) {
            measuredContentHeight = contentHeight
            destination = frame
        } completion: {
            guard detail.route?.id == route.id, detail.phase == .opening else { return }
            detail.markOpen(id: route.id)
            focusTitle = true
        }
    }

    private func close(action: TimetableManualCourseAction? = nil) {
        guard !closing else { return }
        if let action {
            guard detail.beginAction(action, id: route.id) else { return }
        } else {
            guard detail.beginClose(id: route.id) else { return }
        }
        closing = true
        focusTitle = false
        withAnimation(TimetableDetailMotion.animation(opening: false, reduceMotion: reduceMotion),
                      completionCriteria: .removed) {
            destination = nil
        } completion: {
            guard detail.route?.id == route.id, detail.phase == .closing else { return }
            detail.finish(id: route.id)
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }
}

struct TimetableDetailContent: View {
    let course: CourseSession
    let courseColor: Color
    let focusTitle: Bool
    let onClose: () -> Void
    var glassHeader = false
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
