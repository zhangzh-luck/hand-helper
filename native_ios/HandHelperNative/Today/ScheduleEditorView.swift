import SwiftUI
import UIKit

typealias ScheduleEditorSaveAction = (Int?, String, Date, String, String?) throws -> Void

struct ScheduleEditorRoute: Identifiable {
    let id = UUID()
    let schedule: CustomSchedule?
    let now: Date
    let revision: Int
    let onSave: ScheduleEditorSaveAction
}

@MainActor
final class ScheduleEditorCoordinator: ObservableObject {
    @Published private(set) var route: ScheduleEditorRoute?
    @Published private(set) var isVisible = false
    @Published private(set) var sourceHidden = false
    private var isDismissing = false
    private weak var sourceView: UIView?
    private weak var rootView: UIView?
    private weak var targetView: UIView?

    func setAnchor(_ view: UIView, kind: ScheduleEditorAnchor.Kind) {
        switch kind {
        case .source: sourceView = view
        case .root: rootView = view
        case .target: targetView = view
        }
    }

    func frames() -> (source: CGRect, target: CGRect)? {
        guard let root = rootView, let source = sourceView, let target = targetView,
              let window = root.window, source.window === window, target.window === window else { return nil }
        let sourceFrame = source.convert(source.bounds, to: root)
        let targetFrame = target.convert(target.bounds, to: root)
        var visible = root.bounds
        var ancestor = source.superview
        while let view = ancestor, view !== window {
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: root)) }
            ancestor = view.superview
        }
        guard ScheduleEditorMotion.valid(source: sourceFrame, target: targetFrame, visible: visible) else { return nil }
        return (sourceFrame, targetFrame)
    }

    func hideSource(id: UUID) {
        guard route?.id == id, !isDismissing else { return }
        sourceHidden = true
    }

    func restoreSource(id: UUID) {
        guard route == nil || route?.id == id else { return }
        sourceHidden = false
    }

    var isPresenting: Bool { route != nil }

    func present(schedule: CustomSchedule?, now: Date, revision: Int,
                 onSave: @escaping ScheduleEditorSaveAction) {
        guard route == nil else { return }
        route = ScheduleEditorRoute(schedule: schedule, now: now, revision: revision, onSave: onSave)
        isVisible = false
        isDismissing = false
    }

    func show(id: UUID) {
        guard route?.id == id, !isDismissing, !isVisible else { return }
        isVisible = true
    }

    func prepareDismissal(id: UUID) -> Bool {
        guard route?.id == id, isVisible, !isDismissing else { return false }
        isDismissing = true
        return true
    }

    func hide(id: UUID) {
        guard route?.id == id, isDismissing, isVisible else { return }
        isVisible = false
    }

    func finishDismissal(id: UUID) {
        guard route?.id == id, isDismissing, !isVisible else { return }
        route = nil
        sourceHidden = false
        isDismissing = false
    }

    func clear() {
        guard route != nil || isVisible || isDismissing else { return }
        route = nil
        isVisible = false
        sourceHidden = false
        isDismissing = false
    }
}

struct ScheduleEditorAnchor: UIViewRepresentable {
    enum Kind { case source, root, target }
    let coordinator: ScheduleEditorCoordinator
    let kind: Kind

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        coordinator.setAnchor(view, kind: kind)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { coordinator.setAnchor(view, kind: kind) }
}

enum ScheduleEditorMotion {
    static let openingDuration = 0.32

    static func phase(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        guard end > start else { return 0 }
        return min(max((progress - start) / (end - start), 0), 1)
    }

    static func matches(_ first: CGRect, _ second: CGRect) -> Bool {
        let a = [first.minX, first.minY, first.width, first.height]
        let b = [second.minX, second.minY, second.width, second.height]
        return zip(a, b).allSatisfy { pair in
            pair.0.isFinite && pair.1.isFinite && abs(pair.0 - pair.1) < 0.5
        }
    }
    static func mayMorph(reduceMotion: Bool, isEditing: Bool) -> Bool {
        !reduceMotion && !isEditing
    }

    static func valid(source: CGRect, target: CGRect, visible: CGRect) -> Bool {
        let values = [source.minX, source.minY, source.width, source.height,
                      target.minX, target.minY, target.width, target.height,
                      visible.minX, visible.minY, visible.width, visible.height]
        return values.allSatisfy(\.isFinite) && source.width > 0 && source.height > 0 &&
            target.width > 0 && target.height > 0 && visible.contains(source)
    }

    static func interpolate(_ a: CGRect, _ b: CGRect, progress: CGFloat) -> CGRect {
        interpolateCurved(a, b, progress: TimetableDetailMotion.geometryProgress(progress))
    }

    static func interpolateCurved(_ a: CGRect, _ b: CGRect, progress p: CGFloat) -> CGRect {
        return CGRect(x: a.minX + (b.minX - a.minX) * p,
                      y: a.minY + (b.minY - a.minY) * p,
                      width: a.width + (b.width - a.width) * p,
                      height: a.height + (b.height - a.height) * p)
    }

    static func contentTransform(source: CGRect, destination: CGRect, curvedProgress: CGFloat) -> (scale: CGFloat, offset: CGSize) {
        let values = [source.minX, source.minY, source.width, source.height,
                      destination.minX, destination.minY, destination.width, destination.height, curvedProgress]
        guard values.allSatisfy(\.isFinite), source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0 else { return (1, .zero) }
        let p = min(max(curvedProgress, 0), 1)
        let rect = interpolateCurved(source, destination, progress: p)
        return (0.35 + 0.65 * p,
                CGSize(width: rect.midX - destination.midX, height: rect.midY - destination.midY))
    }
}

struct ScheduleEditorOverlay: View {
    @ObservedObject var coordinator: ScheduleEditorCoordinator
    let reduceMotion: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let route = coordinator.route {
            ScheduleEditorTransitionSurface(coordinator: coordinator, route: route,
                                            reduceMotion: reduceMotion,
                                            reduceTransparency: reduceTransparency,
                                            dismiss: { dismiss(routeID: route.id) })
                .id(route.id)
        }
    }

    private var animation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.22)
    }

    private func dismiss(routeID: UUID) {
        guard coordinator.prepareDismissal(id: routeID) else { return }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            coordinator.hide(id: routeID)
        } completion: {
            coordinator.finishDismissal(id: routeID)
        }
    }
}

private struct ScheduleEditorTransitionSurface: View {
    @ObservedObject var coordinator: ScheduleEditorCoordinator
    let route: ScheduleEditorRoute
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let dismiss: () -> Void
    @State private var source: CGRect?
    @State private var destination: CGRect?
    @State private var progress: CGFloat = 0
    @State private var opening = false
    @State private var started = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ScheduleEditorAnchor(coordinator: coordinator, kind: .root)
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                        validateOpeningGeometry()
                    }
                Color.black.opacity(reduceTransparency ? 0.56 : 0.34)
                    .ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
                    .opacity(opening ? Double(progress) : (coordinator.isVisible ? 1 : 0))
                if opening, let source, let destination {
                    ScheduleEditorOpeningShape(progress: progress, source: source, destination: destination)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ScheduleEditorView(schedule: route.schedule, now: route.now,
                                   maximumFormHeight: ScheduleEditorLayout.maximumFormHeight(in: geometry.size.height - 48),
                                   onSave: route.onSave, onClose: dismiss,
                                   readyForFocus: coordinator.isVisible && !opening)
                    .frame(maxWidth: 520)
                    .modifier(ScheduleEditorContentReveal(progress: progress, destination: destination,
                                                          source: source, opening: opening))
                    .background(ScheduleEditorAnchor(coordinator: coordinator, kind: .target))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                        validateOpeningGeometry()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(opening || coordinator.isVisible ? 1 : 0)
                    .scaleEffect(opening || reduceMotion ? 1 : (coordinator.isVisible ? 1 : 0.96))
                    .allowsHitTesting(coordinator.isVisible && !opening)
                    .accessibilityHidden(!coordinator.isVisible || opening)
                    .accessibilityAddTraits(.isModal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Two layout turns allow the form's intrinsic height to settle; an
            // unstable or unavailable measurement falls back to the existing fade.
            DispatchQueue.main.async {
                let first = coordinator.frames()
                DispatchQueue.main.async { start(first: first) }
            }
        }
        .onDisappear { coordinator.restoreSource(id: route.id) }
    }

    private func start(first: (source: CGRect, target: CGRect)?) {
        guard !started, coordinator.route?.id == route.id else { return }
        started = true
        guard ScheduleEditorMotion.mayMorph(reduceMotion: reduceMotion, isEditing: route.schedule != nil),
              let first, let current = coordinator.frames(),
              first.source == current.source, first.target == current.target else {
            withAnimation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.22)) {
                coordinator.show(id: route.id)
            }
            return
        }
        source = current.source
        destination = current.target
        opening = true
        coordinator.hideSource(id: route.id)
        DispatchQueue.main.async {
            guard coordinator.route?.id == route.id else { return }
            guard let latest = coordinator.frames(), latest.source == current.source,
                  latest.target == current.target else {
                opening = false
                coordinator.restoreSource(id: route.id)
                withAnimation(.easeOut(duration: 0.22)) { coordinator.show(id: route.id) }
                return
            }
            coordinator.show(id: route.id)
            withAnimation(.linear(duration: ScheduleEditorMotion.openingDuration), completionCriteria: .removed) {
                progress = 1
            } completion: {
                guard coordinator.route?.id == route.id, opening else { return }
                guard let final = coordinator.frames(),
                      ScheduleEditorMotion.matches(final.target, current.target),
                      ScheduleEditorMotion.matches(final.source, current.source) else {
                    finishOpening()
                    return
                }
                finishOpening()
            }
        }
    }

    private func validateOpeningGeometry() {
        guard opening, let source, let destination else { return }
        DispatchQueue.main.async {
            guard opening, coordinator.route?.id == route.id else { return }
            guard let current = coordinator.frames(),
                  ScheduleEditorMotion.matches(current.source, source),
                  ScheduleEditorMotion.matches(current.target, destination) else {
                finishOpening()
                return
            }
        }
    }

    private func finishOpening() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            opening = false
            progress = 1
            coordinator.show(id: route.id)
            coordinator.restoreSource(id: route.id)
        }
    }
}

private struct ScheduleEditorContentReveal: AnimatableModifier {
    var progress: CGFloat
    let destination: CGRect?
    let source: CGRect?
    let opening: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let curved = TimetableDetailMotion.geometryProgress(p)
        let transform = source.flatMap { source in
            destination.map { ScheduleEditorMotion.contentTransform(source: source, destination: $0, curvedProgress: curved) }
        }
        return content
            .scaleEffect(opening ? (transform?.scale ?? 1) : 1, anchor: .center)
            .offset(x: opening ? (transform?.offset.width ?? 0) : 0,
                    y: opening ? (transform?.offset.height ?? 0) : 0)
            .opacity(opening ? Double(ScheduleEditorMotion.phase(p, from: 0.08, to: 0.55)) : 1)
            .mask(alignment: .topLeading) {
                if opening, let source, let destination {
                    let rect = ScheduleEditorMotion.interpolateCurved(source, destination, progress: curved)
                    let corner = source.height / 2 + (22 - source.height / 2) * curved
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX - destination.minX, y: rect.minY - destination.minY)
                } else {
                    // Leave room for the existing card shadow once the transition ends.
                    Rectangle().padding(-64)
                }
            }
    }
}

private struct ScheduleEditorOpeningShape: View, Animatable {
    var progress: CGFloat
    let source: CGRect
    let destination: CGRect
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        let p = min(max(progress, 0), 1)
        let curved = TimetableDetailMotion.geometryProgress(p)
        let rect = ScheduleEditorMotion.interpolateCurved(source, destination, progress: curved)
        let corner = source.height / 2 + (22 - source.height / 2) * curved
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(uiColor: .systemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.accentColor.opacity(Double(1 - ScheduleEditorMotion.phase(p, from: 0.20, to: 0.65))))
            }
            .overlay(alignment: .topLeading) {
                Label("添加安排", systemImage: "plus")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: source.width, height: source.height)
                    .opacity(Double(max(0, 1 - p * 4)))
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

struct ScheduleEditorView: View {
    let schedule: CustomSchedule?
    let now: Date
    let maximumFormHeight: CGFloat
    let onSave: ScheduleEditorSaveAction
    let onClose: () -> Void
    let readyForFocus: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AccessibilityFocusState private var titleIsFocused: Bool
    @State private var title: String
    @State private var date: Date
    @State private var time: Date
    @State private var hasEndTime: Bool
    @State private var endTime: Date
    @State private var error: String?
    @State private var showDiscardConfirmation = false
    @State private var measuredFormHeight: CGFloat?

    init(schedule: CustomSchedule?, now: Date,
         maximumFormHeight: CGFloat,
         onSave: @escaping ScheduleEditorSaveAction, onClose: @escaping () -> Void,
         readyForFocus: Bool = true) {
        self.schedule = schedule
        self.now = now
        self.maximumFormHeight = maximumFormHeight
        self.onSave = onSave
        self.onClose = onClose
        self.readyForFocus = readyForFocus
        _title = State(initialValue: schedule?.title ?? "")
        let parsedDate: Date?
        if let raw = schedule?.date {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            parsedDate = parts.count == 3
                ? Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
                : nil
        } else {
            parsedDate = nil
        }
        let initialDate = parsedDate ?? now
        _date = State(initialValue: initialDate)
        _time = State(initialValue: CourseScheduleCalculator.dateTime(day: initialDate,
                            clock: schedule?.time ?? "09:00") ?? initialDate)
        _hasEndTime = State(initialValue: schedule?.endTime != nil)
        _endTime = State(initialValue: CourseScheduleCalculator.dateTime(day: initialDate,
                            clock: schedule?.endTime ?? "10:00") ?? initialDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                formContent
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ScheduleEditorFormHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    }
            }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(height: ScheduleEditorLayout.formViewportHeight(
                    contentHeight: measuredFormHeight, maximum: maximumFormHeight), alignment: .top)
            Divider()
            saveAction
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .confirmationDialog("放弃未保存的更改？", isPresented: $showDiscardConfirmation) {
            Button("放弃更改", role: .destructive) { onClose() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("当前填写的安排尚未保存。") }
        .onPreferenceChange(ScheduleEditorFormHeightKey.self) { height in
            guard height > 0,
                  measuredFormHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
            measuredFormHeight = height
        }
        .onAppear { if readyForFocus { titleIsFocused = true } }
        .onChange(of: readyForFocus) { _, ready in
            if ready { titleIsFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(schedule == nil ? "添加安排" : "编辑安排")
                .font(.headline)
                .accessibilityFocused($titleIsFocused)
            Spacer(minLength: 0)
            GlassCloseButton(accessibilityLabel: "关闭", diameter: 36, onDarkBackground: false,
                             action: close)
                .frame(width: 44, height: 44)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(minHeight: 56)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            formSurface
            Text("只能添加今天及以后的安排；结束时间须晚于同一天的开始时间。未设置结束时间的安排仍按开始时间排序。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 15)
            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .accessibilityIdentifier("scheduleEditorError")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var formFields: some View {
        VStack(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text("安排事项").font(.system(size: 16))
                    titleField
                }
                .padding(.vertical, 12)
            } else {
                HStack {
                    Text("安排事项").font(.system(size: 16))
                    titleField
                }
                .frame(minHeight: 57)
            }
            Divider()
            DatePicker("日期", selection: $date, in: Calendar.current.startOfDay(for: now)...,
                       displayedComponents: .date)
                .frame(minHeight: 57)
            Divider()
            DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                .frame(minHeight: 57)
            Divider()
            Toggle("设置结束时间", isOn: $hasEndTime)
                .frame(minHeight: 57)
            Divider()
            DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                .frame(minHeight: 57)
                .disabled(!hasEndTime)
                .opacity(hasEndTime ? 1 : 0.42)
                .accessibilityHint(hasEndTime ? "" : "请先开启设置结束时间")
        }
    }

    @ViewBuilder
    private var formSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
            formFields
                .padding(.horizontal, 15)
                .glassEffect(.regular, in: shape)
        } else if reduceTransparency || colorSchemeContrast == .increased {
            formFields
                .padding(.horizontal, 15)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        } else {
            formFields
                .padding(.horizontal, 15)
                .background(.regularMaterial, in: shape)
        }
    }

    private var titleField: some View {
        TextField("例如：提交课程作业", text: $title)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .onChange(of: title) { _, newValue in
                if newValue.count > 200 { title = String(newValue.prefix(200)) }
            }
            .accessibilityIdentifier("scheduleEditorTitle")
    }

    private var saveAction: some View {
        let button = Button(schedule == nil ? "保存安排" : "保存更改") { save() }
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .tint(TodayStyle.color(0x2563eb))
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("scheduleEditorSave")

        return Group {
            if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var hasUnsavedChanges: Bool {
        ScheduleEditorState.isDirty(schedule: schedule, title: title, date: date,
                                    time: timeValue, endTime: endTimeValue, now: now)
    }

    private var timeValue: String { clockValue(time) }
    private var endTimeValue: String? { hasEndTime ? clockValue(endTime) : nil }

    private func clockValue(_ value: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func close() {
        if hasUnsavedChanges { showDiscardConfirmation = true }
        else { onClose() }
    }

    private func save() {
        do {
            try onSave(schedule?.id, title, date, timeValue, endTimeValue)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ScheduleEditorState {
    static func isDirty(schedule: CustomSchedule?, title: String, date: Date,
                        time: String, endTime: String? = nil, now: Date) -> Bool {
        let originalDate = schedule?.date ?? CourseScheduleCalculator.dateKey(now)
        let originalTime = schedule?.time ?? "09:00"
        return title.trimmingCharacters(in: .whitespacesAndNewlines) !=
            (schedule?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ||
            CourseScheduleCalculator.dateKey(date) != originalDate || time != originalTime ||
            endTime != schedule?.endTime
    }
}

private enum ScheduleEditorFormHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ScheduleEditorLayout {
    private static let fixedChromeHeight: CGFloat = 132

    static func maximumFormHeight(in availableCardHeight: CGFloat) -> CGFloat {
        max(120, availableCardHeight - fixedChromeHeight)
    }

    static func formViewportHeight(contentHeight: CGFloat?, maximum: CGFloat) -> CGFloat {
        min(contentHeight ?? maximum, maximum)
    }
}
