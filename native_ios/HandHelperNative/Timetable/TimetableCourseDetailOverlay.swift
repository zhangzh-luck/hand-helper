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
    @State private var destination: CGRect?
    @State private var visible = false
    @State private var closing = false
    @State private var focusTitle = false

    private var targetWidth: CGFloat {
        TimetableDetailLayout.frame(in: bounds, safeArea: safeArea, preferredHeight: 0).width
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let destination {
                Color.black.opacity(visible ? TimetableDetailMotion.scrimOpacity(dark: colorScheme == .dark) : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)

                ScrollView(.vertical) {
                    TimetableDetailContent(course: route.course, courseColor: route.courseColor,
                                           focusTitle: focusTitle, onClose: close)
                        .frame(width: destination.width)
                }
                .frame(width: destination.width, height: destination.height)
                // An opaque semantic surface keeps details legible over photos and
                // when the system requests reduced transparency.
                .background(Color(uiColor: .systemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.24 : 0.08),
                                  lineWidth: 0.5))
                .shadow(color: .black.opacity(visible ? 0.16 : 0), radius: 16, y: 6)
                .scaleEffect(TimetableDetailMotion.scale(visible: visible, reduceMotion: reduceMotion))
                .offset(y: TimetableDetailMotion.verticalOffset(visible: visible, reduceMotion: reduceMotion))
                .opacity(visible ? 1 : 0)
                .position(x: destination.midX, y: destination.midY)
                .allowsHitTesting(visible && !closing)
                .accessibilityHidden(!visible || closing)
                .onAppear(perform: open)
            } else {
                // Measure once at the final width, before the visible presentation begins.
                TimetableDetailContent(course: route.course, courseColor: route.courseColor,
                                       focusTitle: false, onClose: {})
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
            guard destination == nil, height > 0, detail.route?.id == route.id else { return }
            destination = TimetableDetailLayout.frame(in: bounds, safeArea: safeArea,
                                                       preferredHeight: height)
        }
        .onChange(of: bounds.size) { _, _ in close() }
    }

    private func open() {
        guard detail.route?.id == route.id, detail.phase == .opening else { return }
        let animation: Animation = reduceMotion
            ? .easeOut(duration: TimetableDetailMotion.reducedDuration)
            : .smooth(duration: TimetableDetailMotion.openingDuration, extraBounce: 0)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            visible = true
        } completion: {
            guard detail.route?.id == route.id, detail.phase == .opening else { return }
            detail.markOpen(id: route.id)
            focusTitle = true
        }
    }

    private func close() {
        guard !closing, detail.beginClose(id: route.id) else { return }
        closing = true
        focusTitle = false
        let animation: Animation = reduceMotion
            ? .easeOut(duration: TimetableDetailMotion.reducedDuration)
            : .smooth(duration: TimetableDetailMotion.closingDuration, extraBounce: 0)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            visible = false
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
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭课程详情")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(TimetableDetailInformation.rows(for: course)) { row in
                    detailRow(row)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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
