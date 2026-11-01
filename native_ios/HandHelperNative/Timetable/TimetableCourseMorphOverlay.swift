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
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(morph.route != nil)
    }
}

private struct TimetableMorphSurface: View {
    @ObservedObject var morph: TimetableCourseMorphCoordinator
    let route: TimetableMorphRoute
    let bounds: CGRect
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var progress: CGFloat = 0
    @State private var closingOrigin: CGRect?
    @State private var frozenFadeRect: CGRect?
    @State private var fadingOut = false
    @State private var closing = false
    @AccessibilityFocusState private var titleFocused: Bool

    private var destination: CGRect {
        TimetableMorphGeometry.destination(in: bounds, safeArea: morph.windowSafeArea)
    }

    private var visibleRect: CGRect {
        if fadingOut { return frozenFadeRect ?? destination }
        if reduceMotion || route.sourceRect == nil { return destination }
        return TimetableMorphGeometry.interpolate(closingOrigin ?? route.sourceRect!, destination,
                                                   progress: progress)
    }

    private var contentProgress: Double {
        max(0, min(1, (Double(progress) - 0.27) / 0.20))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity((colorScheme == .dark ? 0.45 : 0.34) * Double(progress))
                .contentShape(Rectangle())
                .onTapGesture { close() }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: TimetableMorphGeometry.cornerRadius(progress: progress))
                    .fill(Color(uiColor: .systemBackground).opacity(Double(progress)))
                RoundedRectangle(cornerRadius: TimetableMorphGeometry.cornerRadius(progress: progress))
                    .fill(Color(uiColor: .secondarySystemGroupedBackground)
                        .opacity((route.wallpaperVisible ? 0.78 : 1) * (1 - Double(progress))))
                RoundedRectangle(cornerRadius: TimetableMorphGeometry.cornerRadius(progress: progress))
                    .fill(route.courseColor.opacity((route.wallpaperVisible ? 0.36 : 0.28) *
                                                    (1 - Double(progress))))
                if route.sourceRect != nil && !reduceMotion && !fadingOut {
                    Text(route.course.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(3)
                        .padding(3)
                        .frame(width: route.sourceRect!.width, height: route.sourceRect!.height,
                               alignment: .topLeading)
                        .opacity(max(0, 1 - Double(progress) / 0.34))
                        .accessibilityHidden(true)
                }
                detail
                    .frame(width: destination.width, height: destination.height)
                    .opacity(contentProgress)
                    .allowsHitTesting(progress >= 1 && !closing)
            }
            .frame(width: visibleRect.width, height: visibleRect.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: TimetableMorphGeometry.cornerRadius(progress: progress)))
            .overlay(RoundedRectangle(cornerRadius: TimetableMorphGeometry.cornerRadius(progress: progress))
                .strokeBorder(route.courseColor.opacity(0.55 * (1 - Double(progress))), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18 * Double(progress)), radius: 18 * progress, y: 8 * progress)
            .opacity(fadingOut ? Double(progress) : 1)
            .position(x: visibleRect.midX, y: visibleRect.midY)
            .accessibilityElement(children: .contain)
        }
        .frame(width: bounds.width, height: bounds.height)
        .onAppear {
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.26)) { progress = 1 }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: reduceMotion ? 170_000_000 : 280_000_000)
                morph.markOpen(id: route.id)
                titleFocused = true
            }
        }
        .onChange(of: bounds.size) { _, _ in close(allowSource: false) }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(route.courseColor)
                    .frame(width: 5, height: 30)
                    .accessibilityHidden(true)
                Text(route.course.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: 0)
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("关闭课程详情")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    detailRow("日期", value: route.course.date)
                    detailRow("时间", value: TimetableCourseDetailText.time(route.course))
                    detailRow("教室", value: TimetableCourseDetailText.nonempty(route.course.room))
                    detailRow("教师", value: TimetableCourseDetailText.nonempty(route.course.teacher))
                    if let weeks = route.course.weekExpression, !weeks.isEmpty {
                        detailRow("周次", value: weeks)
                    }
                    if let first = route.course.startPeriod, let last = route.course.endPeriod {
                        detailRow("节次", value: "第 \(first)–\(last) 节")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func close(allowSource: Bool = true) {
        guard !closing, morph.phase == .open || morph.phase == .opening else { return }
        closing = true
        let currentRect = visibleRect
        closingOrigin = morph.beginClose(id: route.id, allowSource: allowSource)
        fadingOut = closingOrigin == nil
        if fadingOut { frozenFadeRect = currentRect }
        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.26)) { progress = 0 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 170_000_000 : 280_000_000)
            morph.finish(id: route.id)
        }
    }
}
