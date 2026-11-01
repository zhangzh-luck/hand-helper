import SwiftUI

/// Lives above NativeTabContainer so the scrim covers the system tab bar too.
struct TimetableCourseMorphOverlay: View {
    @ObservedObject var morph: TimetableCourseMorphCoordinator
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TimetableMorphRootAnchor(morph: morph)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                if let route = morph.route {
                    TimetableMorphSurface(morph: morph, route: route,
                                          bounds: CGRect(origin: .zero, size: geometry.size),
                                          reduceMotion: reduceMotion)
                        .id(route.id)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(morph.route != nil)
    }
}

private struct TimetableMorphDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TimetableMorphSurface: View {
    @ObservedObject var morph: TimetableCourseMorphCoordinator
    let route: TimetableMorphRoute
    let bounds: CGRect
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var destination: CGRect?
    @State private var targetProgress: CGFloat = 0
    @State private var closingOrigin: CGRect?
    @State private var frozenFadeRect: CGRect?
    @State private var fadeStart: CGFloat = 1
    @State private var closing = false
    @State private var focusTitle = false
    @State private var presentation = TimetableMorphPresentation()

    private var targetWidth: CGFloat {
        TimetableMorphGeometry.destination(in: bounds, safeArea: morph.windowSafeArea,
                                           preferredHeight: 0).width
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let destination {
                TimetableMorphStage(
                    progress: targetProgress, presentation: presentation, route: route,
                    bounds: bounds, destination: destination,
                    source: reduceMotion ? nil : (closingOrigin ?? route.sourceRect),
                    frozenRect: frozenFadeRect, fadeStart: fadeStart,
                    colorScheme: colorScheme, isClosing: closing, reduceMotion: reduceMotion,
                    detail: { headerOpacity, bodyOpacity, bodyOffset in
                        ScrollView(.vertical) {
                            TimetableMorphDetailContent(course: route.course, courseColor: route.courseColor,
                                                        headerOpacity: headerOpacity, bodyOpacity: bodyOpacity,
                                                        bodyOffset: bodyOffset, focusTitle: focusTitle,
                                                        onClose: { close() })
                                .frame(width: destination.width)
                        }
                        .frame(width: destination.width, height: destination.height)
                    }, onClose: { close() }
                )
                .onAppear(perform: open)
            } else {
                // Measure the same content at its final width before showing any surface.
                TimetableMorphDetailContent(course: route.course, courseColor: route.courseColor,
                                            headerOpacity: 1, bodyOpacity: 1, bodyOffset: 0,
                                            focusTitle: false, onClose: {})
                    .frame(width: targetWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TimetableMorphDetailHeightKey.self,
                                               value: geometry.size.height)
                    })
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .onPreferenceChange(TimetableMorphDetailHeightKey.self) { height in
            guard destination == nil, height > 0, morph.route?.id == route.id else { return }
            let rect = TimetableMorphGeometry.destination(in: bounds, safeArea: morph.windowSafeArea,
                                                          preferredHeight: height)
            presentation.record(TimetableMorphFrame(progress: 0,
                rect: reduceMotion ? rect : (route.sourceRect ?? rect)))
            destination = rect
        }
        .onChange(of: bounds.size) { _, _ in close(allowSource: false) }
    }

    private func open() {
        guard morph.route?.id == route.id, morph.phase == .opening else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .linear(duration: 0.26),
                      completionCriteria: .logicallyComplete) {
            targetProgress = 1
        } completion: {
            guard morph.route?.id == route.id, morph.phase == .opening else { return }
            morph.markOpen(id: route.id)
            focusTitle = true
        }
    }

    private func close(allowSource: Bool = true) {
        guard !closing, morph.route?.id == route.id,
              morph.phase == .open || morph.phase == .opening else { return }
        closing = true
        let current = presentation.current()
        let source = morph.beginClose(id: route.id, allowSource: allowSource)
        if let source {
            // Re-anchor only at the completed end point; otherwise changing the
            // source during a reversal would move the displayed rectangle.
            closingOrigin = current.progress >= 0.999 ? source : route.sourceRect
        } else {
            frozenFadeRect = current.rect
            fadeStart = max(current.progress, 0.001)
        }
        let duration = reduceMotion ? 0.15 : 0.26 * Double(current.progress)
        withAnimation(.linear(duration: duration), completionCriteria: .logicallyComplete) {
            targetProgress = 0
        } completion: {
            guard morph.route?.id == route.id,
                  morph.phase == .closingToSource || morph.phase == .fadingOut else { return }
            focusTitle = false
            morph.finish(id: route.id)
        }
    }
}

struct TimetableMorphDetailContent: View {
    let course: CourseSession
    let courseColor: Color
    let headerOpacity: CGFloat
    let bodyOpacity: CGFloat
    let bodyOffset: CGFloat
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
            .opacity(Double(headerOpacity))
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
            .opacity(Double(bodyOpacity))
            .offset(y: bodyOffset)
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

/// Only this overlay view is animated. The week pager and wallpaper are not
/// rebuilt by per-frame geometry updates.
private struct TimetableMorphStage<Detail: View>: View, Animatable {
    var progress: CGFloat
    let presentation: TimetableMorphPresentation
    let route: TimetableMorphRoute
    let bounds: CGRect
    let destination: CGRect
    let source: CGRect?
    let frozenRect: CGRect?
    let fadeStart: CGFloat
    let colorScheme: ColorScheme
    let isClosing: Bool
    let reduceMotion: Bool
    let detail: (CGFloat, CGFloat, CGFloat) -> Detail
    let onClose: () -> Void

    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            presentation.record(renderFrame)
        }
    }

    private var renderFrame: TimetableMorphFrame {
        TimetableMorphTimeline.frame(from: source ?? destination, to: destination,
                                     progress: progress, frozenRect: frozenRect)
    }

    var body: some View {
        let frame = renderFrame
        let p = frame.progress
        let fadePresentation = reduceMotion || source == nil
        let radius = fadePresentation ? CGFloat(22) : TimetableMorphGeometry.cornerRadius(progress: p)
        let tileOpacity = 1 - TimetableMorphTimeline.phase(p, from: 0.18, to: 0.34)
        let headerOpacity = TimetableMorphTimeline.phase(p, from: 0.26, to: 0.41)
        let bodyOpacity = TimetableMorphTimeline.phase(p, from: 0.30, to: 0.45)
        let backgroundOpacity = fadePresentation ? CGFloat(1) :
            TimetableMorphTimeline.phase(p, from: 0.16, to: 0.44)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(Double(p) * (colorScheme == .dark ? 0.45 : 0.34))
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground)
                        .opacity(route.wallpaperVisible ? 0.78 : 1))
                RoundedRectangle(cornerRadius: radius)
                    .fill(route.courseColor.opacity(route.wallpaperVisible ? 0.36 : 0.28))
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground)
                        .opacity(Double(backgroundOpacity)))
                if let source, frozenRect == nil {
                    Text(route.course.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(3)
                        .padding(3)
                        .frame(width: source.width, height: source.height, alignment: .topLeading)
                        .opacity(Double(tileOpacity))
                        .accessibilityHidden(true)
                }
                detail(headerOpacity, bodyOpacity, 14 * (1 - bodyOpacity))
                    .allowsHitTesting(p >= 0.999 && !isClosing)
                    .accessibilityHidden(p < 0.999 || isClosing)
            }
            .frame(width: frame.rect.width, height: frame.rect.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(route.courseColor.opacity(Double(0.4 * (1 - p))), lineWidth: 0.5))
            .shadow(color: .black.opacity(Double(0.13 * p)), radius: 12 * p, y: 5 * p)
            .opacity(fadePresentation ? Double(p) :
                (frozenRect == nil ? 1 : Double(min(1, p / fadeStart))))
            .position(x: frame.rect.midX, y: frame.rect.midY)
            .accessibilityElement(children: .contain)
        }
        .frame(width: bounds.width, height: bounds.height)
    }
}
