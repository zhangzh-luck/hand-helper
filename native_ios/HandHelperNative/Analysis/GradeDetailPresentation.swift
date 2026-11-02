import SwiftUI
import UIKit

struct GradeDetailContext: Equatable {
    let owner: String
    let authenticationRevision: Int
    let termID: Int
    let gradeID: Int
}

struct GradeDetailRoute: Identifiable {
    let id = UUID()
    let grade: GradeRecord
    let context: GradeDetailContext
}

enum GradeDetailPhase: Equatable { case idle, opening, open, closing }

enum GradeDetailLayout {
    static func frame(in bounds: CGRect, safeArea: UIEdgeInsets,
                      contentHeight: CGFloat) -> CGRect {
        let top = bounds.minY + safeArea.top + 16
        let bottom = max(top, bounds.maxY - safeArea.bottom - 16)
        let width = min(420, max(0, bounds.width - 32))
        let height = min(520, max(0, contentHeight), bottom - top)
        return CGRect(x: bounds.midX - width / 2,
                      y: top + (bottom - top - height) / 2,
                      width: width, height: height)
    }

    static func needsScrolling(contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentHeight.isFinite && viewportHeight.isFinite && contentHeight > viewportHeight + 1
    }
}

enum GradeDetailSurfaceKind: Equatable {
    case glass, material, opaque

    static func current(reduceTransparency: Bool, increasedContrast: Bool,
                        supportsGlass: Bool) -> Self {
        if reduceTransparency || increasedContrast { return .opaque }
        return supportsGlass ? .glass : .material
    }
}

@MainActor
final class GradeDetailCoordinator: ObservableObject {
    @Published private(set) var route: GradeDetailRoute?
    @Published private(set) var phase: GradeDetailPhase = .idle
    private weak var rootView: UIView?

    var isPresenting: Bool { route != nil }
    var windowSafeArea: UIEdgeInsets { rootView?.window?.safeAreaInsets ?? .zero }

    func setRootView(_ view: UIView) { rootView = view }

    @discardableResult
    func open(grade: GradeRecord, context: GradeDetailContext) -> Bool {
        guard phase == .idle, grade.id == context.gradeID,
              grade.termID == context.termID else { return false }
        route = GradeDetailRoute(grade: grade, context: context)
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
        clear()
    }

    func invalidate(owner: String?, authenticationRevision: Int,
                    termID: Int?, grade: GradeRecord?) {
        guard let route else { return }
        if route.context.owner != owner ||
            route.context.authenticationRevision != authenticationRevision ||
            route.context.termID != termID ||
            route.context.gradeID != grade?.id || route.grade != grade {
            clear()
        }
    }

    func clear() {
        route = nil
        phase = .idle
    }
}

/// Reads the containing window's safe area; no course-card coordinate tracking is needed.
struct GradeDetailRootAnchor: UIViewRepresentable {
    let detail: GradeDetailCoordinator

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        detail.setRootView(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { detail.setRootView(view) }
}
