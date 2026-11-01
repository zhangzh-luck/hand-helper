import SwiftUI
import UIKit

struct TimetableMorphSourceKey: Hashable {
    let authenticationRevision: Int
    let termID: Int
    let week: Int
    let snapshotRevision: Int
    let courseID: Int
    let placementIndex: Int
}

struct TimetableMorphRoute: Identifiable {
    let id = UUID()
    let course: CourseSession
    let sourceKey: TimetableMorphSourceKey
    let sourceRect: CGRect?
    let courseColor: Color
    let wallpaperVisible: Bool
}

enum TimetableMorphPhase: Equatable {
    case idle, opening, open, closingToSource, fadingOut

    var isActive: Bool { self != .idle }
}

enum TimetableMorphGeometry {
    static func destination(in bounds: CGRect, safeArea: UIEdgeInsets,
                            preferredHeight: CGFloat = 390) -> CGRect {
        let horizontal: CGFloat = 16
        let top = bounds.minY + safeArea.top + 16
        let bottom = max(top, bounds.maxY - safeArea.bottom - 16)
        let width = min(420, max(0, bounds.width - horizontal * 2))
        let height = min(520, preferredHeight, max(0, bottom - top))
        return CGRect(x: bounds.midX - width / 2, y: top + (bottom - top - height) / 2,
                      width: width, height: height)
    }

    static func interpolate(_ start: CGRect, _ end: CGRect, progress: CGFloat) -> CGRect {
        let t = min(1, max(0, progress))
        return CGRect(x: start.minX + (end.minX - start.minX) * t,
                      y: start.minY + (end.minY - start.minY) * t,
                      width: start.width + (end.width - start.width) * t,
                      height: start.height + (end.height - start.height) * t)
    }

    static func cornerRadius(progress: CGFloat) -> CGFloat {
        8 + 14 * min(1, max(0, progress))
    }
}

@MainActor
final class TimetableCourseMorphCoordinator: ObservableObject {
    @Published private(set) var route: TimetableMorphRoute?
    @Published private(set) var phase: TimetableMorphPhase = .idle
    private weak var rootView: UIView?
    private var sources: [TimetableMorphSourceKey: WeakSource] = [:]
    private(set) var pagerBusy = false

    private final class WeakSource {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    func setRootView(_ view: UIView) { rootView = view }
    var windowSafeArea: UIEdgeInsets { rootView?.window?.safeAreaInsets ?? .zero }
    func register(_ view: UIView, for key: TimetableMorphSourceKey) {
        sources[key] = WeakSource(view)
        if sources.count > 120 { sources = sources.filter { $0.value.view != nil } }
    }

    func setPagerBusy(_ busy: Bool) { pagerBusy = busy }

    @discardableResult
    func open(course: CourseSession, key: TimetableMorphSourceKey, color: Color,
              wallpaperVisible: Bool = false) -> Bool {
        guard phase == .idle, !pagerBusy else { return false }
        let rect = visibleSourceRect(for: key)
        // A partly clipped source has no honest origin. Show the centered detail without morphing.
        route = TimetableMorphRoute(course: course, sourceKey: key, sourceRect: rect,
                                   courseColor: color, wallpaperVisible: wallpaperVisible)
        phase = .opening
        return true
    }

    func markOpen(id: UUID) {
        guard route?.id == id, phase == .opening else { return }
        phase = .open
    }

    func beginClose(id: UUID, allowSource: Bool = true) -> CGRect? {
        guard route?.id == id, phase == .open || phase == .opening else { return nil }
        let rect = !allowSource || route?.sourceRect == nil ? nil : visibleSourceRect(for: route!.sourceKey)
        phase = rect == nil ? .fadingOut : .closingToSource
        return rect
    }

    func finish(id: UUID) {
        guard route?.id == id else { return }
        route = nil
        phase = .idle
    }

    func clear() {
        route = nil
        phase = .idle
        pagerBusy = false
        sources.removeAll()
    }

    func invalidate(termID: Int?, snapshotRevision: Int, authenticationRevision: Int) {
        guard let key = route?.sourceKey else { return }
        if key.termID != termID || key.snapshotRevision != snapshotRevision ||
            key.authenticationRevision != authenticationRevision { clear() }
    }

    func isHidden(_ key: TimetableMorphSourceKey) -> Bool {
        route?.sourceKey == key && route?.sourceRect != nil
    }

    func visibleSourceRect(for key: TimetableMorphSourceKey) -> CGRect? {
        guard let source = sources[key]?.view, let rootView,
              let window = source.window, window === rootView.window,
              !source.bounds.isEmpty else { return nil }
        let rect = source.convert(source.bounds, to: rootView)
        guard rect.width > 0, rect.height > 0, rect.isFinite else { return nil }
        var ancestor = source.superview
        while let view = ancestor, view !== rootView {
            if view.clipsToBounds {
                let viewport = view.convert(view.bounds, to: rootView)
                let visible = rect.intersection(viewport)
                guard !visible.isNull, visible.width >= rect.width * 0.95,
                      visible.height >= rect.height * 0.95 else { return nil }
            }
            ancestor = view.superview
        }
        let windowBounds = window.convert(window.bounds, to: rootView)
        guard windowBounds.contains(rect) else { return nil }
        return rect
    }
}

private extension CGRect {
    var isFinite: Bool {
        [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}

struct TimetableCourseSourceAnchor: UIViewRepresentable {
    let morph: TimetableCourseMorphCoordinator
    let key: TimetableMorphSourceKey

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        morph.register(view, for: key)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { morph.register(view, for: key) }
}

struct TimetableMorphRootAnchor: UIViewRepresentable {
    let morph: TimetableCourseMorphCoordinator

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        morph.setRootView(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { morph.setRootView(view) }
}

struct TimetableSourceVisibility: ViewModifier {
    @ObservedObject var morph: TimetableCourseMorphCoordinator
    let key: TimetableMorphSourceKey

    func body(content: Content) -> some View {
        content.opacity(morph.isHidden(key) ? 0 : 1)
    }
}
