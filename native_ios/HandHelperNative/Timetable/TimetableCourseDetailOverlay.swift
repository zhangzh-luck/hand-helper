import SwiftUI

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
        .allowsHitTesting(detail.route != nil)
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
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
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
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                detailRow("日期", value: course.date)
                detailRow("时间", value: TimetableCourseDetailText.time(course))
                detailRow("教室", value: TimetableCourseDetailText.nonempty(course.room))
                detailRow("教师", value: TimetableCourseDetailText.nonempty(course.teacher))
                if let weeks = course.weekExpression, !weeks.isEmpty {
                    detailRow("周次", value: weeks)
                }
                if let first = course.startPeriod, let last = course.endPeriod {
                    detailRow("节次", value: "第 \(first)–\(last) 节")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onChange(of: focusTitle) { _, value in titleFocused = value }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
