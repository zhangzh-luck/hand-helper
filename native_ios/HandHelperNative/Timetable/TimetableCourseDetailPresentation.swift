import SwiftUI
import UIKit

/// Identifies the verified snapshot from which a course detail was opened.
struct TimetableDetailContext: Hashable {
    let authenticationRevision: Int
    let termID: Int
    let week: Int
    let snapshotRevision: Int
    let courseID: Int
    let placementIndex: Int
}

struct TimetableDetailRoute: Identifiable {
    let id = UUID()
    let course: CourseSession
    let context: TimetableDetailContext
    let courseColor: Color
    let editableManualCourse: TimetableManualCourseIdentity?
    var source: TimetableDetailSource? = nil
}

struct TimetableDetailSource: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let viewportSize: CGSize

    var isValid: Bool {
        let values = [frame.minX, frame.minY, frame.width, frame.height,
                      visibleFrame.minX, visibleFrame.minY, visibleFrame.width, visibleFrame.height,
                      viewportSize.width, viewportSize.height]
        return values.allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0 &&
            visibleFrame.width > 0 && visibleFrame.height > 0 && frame.intersects(visibleFrame) &&
            viewportSize.width > 0 && viewportSize.height > 0
    }
}

struct TimetableManualCourseIdentity: Equatable {
    let owner: String
    let ruleID: Int
}

enum TimetableManualCourseAction: Equatable { case edit, delete }

struct TimetableManualCourseActionRequest: Identifiable {
    let id = UUID()
    let action: TimetableManualCourseAction
    let identity: TimetableManualCourseIdentity
    let context: TimetableDetailContext
}

enum TimetableDetailPhase: Equatable {
    case idle, opening, open, closing
}

enum TimetableDetailLayout {
    static func needsScrolling(contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard contentHeight.isFinite, viewportHeight.isFinite else { return false }
        // Absorb sub-point measurement differences without enabling an empty bounce.
        return contentHeight > viewportHeight + 1
    }

    static func frame(in bounds: CGRect, safeArea: UIEdgeInsets,
                      preferredHeight: CGFloat) -> CGRect {
        let top = bounds.minY + safeArea.top + 16
        let bottom = max(top, bounds.maxY - safeArea.bottom - 16)
        let width = min(420, max(0, bounds.width - 32))
        let height = min(520, max(0, preferredHeight), bottom - top)
        return CGRect(x: bounds.midX - width / 2,
                      y: top + (bottom - top - height) / 2,
                      width: width, height: height)
    }
}

enum TimetableDetailMotion {
    static let openingDuration = 0.32
    static let closingDuration = 0.22
    static let reducedDuration = 0.15
    static let morphDuration = 0.26

    static func canReturn(to original: TimetableDetailSource?, current: TimetableDetailSource?, viewport: CGSize) -> Bool {
        guard let original, let current, original.isValid, current.isValid,
              original.viewportSize == viewport, current.viewportSize == viewport else { return false }
        let a = original.frame, b = current.frame
        return abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 &&
            abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    static func scale(visible: Bool, reduceMotion: Bool) -> CGFloat {
        visible || reduceMotion ? 1 : 0.92
    }

    static func verticalOffset(visible: Bool, reduceMotion: Bool) -> CGFloat {
        visible || reduceMotion ? 0 : 10
    }

    static func scrimOpacity(dark: Bool) -> Double { dark ? 0.42 : 0.32 }

    static func animation(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: reducedDuration) }
        return .spring(duration: opening ? openingDuration : closingDuration, bounce: 0.06)
    }
}

enum TimetableDetailSurfaceKind: Equatable {
    case glass, material, opaque

    static func current(reduceTransparency: Bool, increasedContrast: Bool,
                        supportsGlass: Bool) -> Self {
        if reduceTransparency || increasedContrast { return .opaque }
        return supportsGlass ? .glass : .material
    }
}

@MainActor
final class TimetableCourseDetailCoordinator: ObservableObject {
    @Published private(set) var route: TimetableDetailRoute?
    @Published private(set) var phase: TimetableDetailPhase = .idle
    @Published private(set) var readyAction: TimetableManualCourseActionRequest?
    @Published private(set) var pendingDelete: TimetableManualCourseActionRequest?
    @Published private(set) var deletionError: String?
    @Published private(set) var hiddenSource: TimetableDetailContext?
    private(set) var pagerBusy = false
    private var closingAction: TimetableManualCourseActionRequest?
    private weak var rootView: UIView?
    private var sourceViews: [TimetableDetailContext: WeakTimetableSource] = [:]

    var isPresenting: Bool { route != nil }

    func setRootView(_ view: UIView) { rootView = view }
    func setSourceView(_ view: UIView, context: TimetableDetailContext) {
        sourceViews = sourceViews.filter { $0.value.view != nil }
        sourceViews[context] = WeakTimetableSource(view)
    }

    func sourceGeometry(for context: TimetableDetailContext) -> TimetableDetailSource? {
        guard let root = rootView, let source = sourceViews[context]?.view,
              let window = root.window, source.window === window else { return nil }
        let frame = source.convert(source.bounds, to: root)
        var visible = root.bounds
        var ancestor = source.superview
        while let view = ancestor, view !== window {
            if view.clipsToBounds {
                visible = visible.intersection(view.convert(view.bounds, to: root))
            }
            ancestor = view.superview
        }
        let geometry = TimetableDetailSource(frame: frame, visibleFrame: visible,
                                             viewportSize: root.bounds.size)
        return geometry.isValid ? geometry : nil
    }

    func hideSource(id: UUID) {
        guard let route, route.id == id, phase == .opening, route.source != nil else { return }
        hiddenSource = route.context
    }

    func restoreSource() {
        if hiddenSource != nil { hiddenSource = nil }
    }
    var windowSafeArea: UIEdgeInsets { rootView?.window?.safeAreaInsets ?? .zero }

    func setPagerBusy(_ busy: Bool) { pagerBusy = busy }

    @discardableResult
    func open(course: CourseSession, context: TimetableDetailContext, color: Color,
              editableManualCourse: TimetableManualCourseIdentity? = nil,
              source: TimetableDetailSource? = nil) -> Bool {
        guard phase == .idle, !pagerBusy, readyAction == nil else { return false }
        route = TimetableDetailRoute(course: course, context: context, courseColor: color,
                                     editableManualCourse: editableManualCourse, source: source)
        phase = .opening
        return true
    }

    func markOpen(id: UUID) {
        guard route?.id == id, phase == .opening else { return }
        phase = .open
    }

    @discardableResult
    func beginClose(id: UUID) -> Bool {
        guard route?.id == id, phase == .opening || phase == .open else { return false }
        phase = .closing
        return true
    }

    func beginAction(_ action: TimetableManualCourseAction, id: UUID) -> Bool {
        guard let route, route.id == id, let identity = route.editableManualCourse,
              beginClose(id: id) else { return false }
        closingAction = TimetableManualCourseActionRequest(action: action, identity: identity,
                                                           context: route.context)
        return true
    }

    @discardableResult
    func requestDelete(id: UUID) -> Bool {
        guard let route, route.id == id, let identity = route.editableManualCourse,
              phase == .opening || phase == .open,
              pendingDelete == nil, readyAction == nil else { return false }
        pendingDelete = TimetableManualCourseActionRequest(action: .delete,
            identity: identity, context: route.context)
        return true
    }

    func cancelDelete() { pendingDelete = nil }

    @discardableResult
    func confirmDelete() -> Bool {
        guard let request = pendingDelete, let route,
              let identity = route.editableManualCourse,
              route.context == request.context,
              identity == request.identity,
              phase == .opening || phase == .open,
              readyAction == nil else { return false }
        pendingDelete = nil
        readyAction = request
        return true
    }

    func reportDeletionError(_ message: String) { deletionError = message }
    func dismissDeletionError() { deletionError = nil }

    func finish(id: UUID) {
        guard route?.id == id, phase == .closing else { return }
        restoreSource()
        route = nil
        phase = .idle
        readyAction = closingAction
        closingAction = nil
    }

    func takeReadyAction() -> TimetableManualCourseActionRequest? {
        let action = readyAction
        readyAction = nil
        return action
    }

    @discardableResult
    func clear() -> Bool {
        guard closingAction != nil || readyAction != nil || pendingDelete != nil || deletionError != nil ||
                route != nil || phase != .idle || pagerBusy || hiddenSource != nil else { return false }
        restoreSource()
        closingAction = nil
        readyAction = nil
        pendingDelete = nil
        deletionError = nil
        route = nil
        phase = .idle
        pagerBusy = false
        return true
    }

    func invalidate(termID: Int?, snapshotRevision: Int, authenticationRevision: Int) {
        guard let context = route?.context else { return }
        if context.termID != termID || context.snapshotRevision != snapshotRevision ||
            context.authenticationRevision != authenticationRevision { clear() }
    }
}

private final class WeakTimetableSource {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

struct TimetableDetailSourceAnchor: UIViewRepresentable {
    let detail: TimetableCourseDetailCoordinator
    let context: TimetableDetailContext
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        detail.setSourceView(view, context: self.context)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        detail.setSourceView(view, context: self.context)
    }
}

/// Reads the containing UIWindow safe area without tracking course card frames.
struct TimetableDetailRootAnchor: UIViewRepresentable {
    let detail: TimetableCourseDetailCoordinator

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        detail.setRootView(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { detail.setRootView(view) }
}
