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
}

enum TimetableDetailPhase: Equatable {
    case idle, opening, open, closing
}

enum TimetableDetailLayout {
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
    static let openingDuration = 0.26
    static let closingDuration = 0.20
    static let reducedDuration = 0.15

    static func scale(visible: Bool, reduceMotion: Bool) -> CGFloat {
        visible || reduceMotion ? 1 : 0.96
    }

    static func verticalOffset(visible: Bool, reduceMotion: Bool) -> CGFloat {
        visible || reduceMotion ? 0 : 6
    }

    static func scrimOpacity(dark: Bool) -> Double { dark ? 0.42 : 0.32 }
}

@MainActor
final class TimetableCourseDetailCoordinator: ObservableObject {
    @Published private(set) var route: TimetableDetailRoute?
    @Published private(set) var phase: TimetableDetailPhase = .idle
    private(set) var pagerBusy = false
    private weak var rootView: UIView?

    var isPresenting: Bool { route != nil }

    func setRootView(_ view: UIView) { rootView = view }
    var windowSafeArea: UIEdgeInsets { rootView?.window?.safeAreaInsets ?? .zero }

    func setPagerBusy(_ busy: Bool) { pagerBusy = busy }

    @discardableResult
    func open(course: CourseSession, context: TimetableDetailContext, color: Color) -> Bool {
        guard phase == .idle, !pagerBusy else { return false }
        route = TimetableDetailRoute(course: course, context: context, courseColor: color)
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

    func finish(id: UUID) {
        guard route?.id == id, phase == .closing else { return }
        route = nil
        phase = .idle
    }

    func clear() {
        route = nil
        phase = .idle
        pagerBusy = false
    }

    func invalidate(termID: Int?, snapshotRevision: Int, authenticationRevision: Int) {
        guard let context = route?.context else { return }
        if context.termID != termID || context.snapshotRevision != snapshotRevision ||
            context.authenticationRevision != authenticationRevision { clear() }
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
