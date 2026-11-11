import SwiftUI
import UIKit

/// UIKit owns the horizontal gesture and its completion decision. The model owns the selected week.
@MainActor
struct TimetableWeekPager<Page: View>: UIViewControllerRepresentable {
    let model: TimetableViewModel
    let authenticationRevision: Int
    let renderRevision: Int
    let wallpaperVisible: Bool
    let layoutScale: CGFloat
    let reduceMotion: Bool
    let diagnostics: TabSwitchDiagnostics = TabSwitchDiagnostics()
    var onTransitionStateChange: ((Bool) -> Void)? = nil
    let content: (WeeklyTimetableProjection) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll,
                                              navigationOrientation: .horizontal)
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        for scrollView in controller.view.subviews.compactMap({ $0 as? UIScrollView }) {
            scrollView.backgroundColor = .clear
            scrollView.isOpaque = false
        }
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.install(in: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        diagnostics.record(.timetablePagerUpdateBegin, for: .timetable)
        context.coordinator.update(self, in: controller)
        diagnostics.record(.timetablePagerUpdateEnd, for: .timetable)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private var parent: TimetableWeekPager
        private var pages: [Int: WeekHost<Page>] = [:]
        private var identity: Identity?
        private var visibleWeek: Int?
        private var interacting = false
        private var programmatic = false
        private var transitionToken = 0

        init(_ parent: TimetableWeekPager) { self.parent = parent }

        func install(in controller: UIPageViewController) {
            identity = currentIdentity
            let week = parent.model.selectedWeek
            guard let page = page(for: week) else { return }
            visibleWeek = week
            controller.setViewControllers([page], direction: .forward, animated: false)
            warmNeighbours(of: week)
        }

        func update(_ newParent: TimetableWeekPager, in controller: UIPageViewController) {
            parent = newParent
            let nextIdentity = currentIdentity
            if nextIdentity != identity {
                parent.diagnostics.record(.timetablePagerIdentityChanged, for: .timetable)
                // A changed account or snapshot invalidates every hosted course view.
                // Defer same-account refresh until an interactive turn has settled.
                if (interacting || programmatic) &&
                    identity?.authenticationRevision == nextIdentity.authenticationRevision {
                    return
                }
                transitionToken += 1
                identity = nextIdentity
                pages.removeAll()
                visibleWeek = nil
                programmatic = false
                parent.onTransitionStateChange?(false)
                let week = parent.model.selectedWeek
                if let page = page(for: week) {
                    visibleWeek = week
                    controller.setViewControllers([page], direction: .forward, animated: false)
                    warmNeighbours(of: week)
                }
                return
            }
            parent.diagnostics.record(.timetablePagerIdentityUnchanged, for: .timetable)
            guard !interacting && !programmatic else { return }
            let desired = parent.model.selectedWeek
            guard desired != visibleWeek, let target = page(for: desired) else { return }
            let prior = visibleWeek ?? desired
            let adjacent = abs(desired - prior) == 1
            programmatic = true
            parent.onTransitionStateChange?(true)
            transitionToken += 1
            let token = transitionToken
            controller.setViewControllers([target], direction: desired > prior ? .forward : .reverse,
                                          animated: adjacent && !parent.reduceMotion) { [weak self, weak controller] _ in
                guard let self, let controller, self.transitionToken == token else { return }
                self.programmatic = false
                self.parent.onTransitionStateChange?(false)
                self.visibleWeek = desired
                self.warmNeighbours(of: desired)
                self.prune(around: desired)
                // A second button press may have arrived during the transition.
                self.update(self.parent, in: controller)
            }
        }

        private var currentIdentity: Identity {
            Identity(authenticationRevision: parent.authenticationRevision,
                     termID: parent.model.selectedTermID,
                     snapshotRevision: parent.model.snapshotRevision,
                     renderRevision: parent.renderRevision,
                     wallpaperVisible: parent.wallpaperVisible,
                     layoutScale: parent.layoutScale)
        }

        private func page(for week: Int) -> WeekHost<Page>? {
            if let cached = pages[week] { return cached }
            guard let projection = parent.model.projection(for: week) else { return nil }
            let hosted = WeekHost(week: week, rootView: parent.content(projection))
            hosted.view.backgroundColor = .clear
            hosted.view.isOpaque = false
            pages[week] = hosted
            parent.diagnostics.record(.timetablePagerPageCreated, for: .timetable)
            return hosted
        }

        private func warmNeighbours(of week: Int) {
            _ = page(for: week - 1)
            _ = page(for: week + 1)
        }

        private func prune(around week: Int) {
            pages = pages.filter { abs($0.key - week) <= 1 }
        }

        func pageViewController(_ controller: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? WeekHost<Page> else { return nil }
            return self.page(for: page.week - 1)
        }

        func pageViewController(_ controller: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? WeekHost<Page> else { return nil }
            return self.page(for: page.week + 1)
        }

        func pageViewController(_ controller: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            interacting = true
            parent.onTransitionStateChange?(true)
        }

        func pageViewController(_ controller: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            interacting = false
            parent.onTransitionStateChange?(false)
            guard let displayed = controller.viewControllers?.first as? WeekHost<Page> else { return }
            let externalSelection = parent.model.selectedWeek != visibleWeek
            if identity != currentIdentity {
                update(parent, in: controller)
                return
            }
            if let committed = TimetablePageTransition.committedWeek(
                from: visibleWeek, to: displayed.week, completed: completed), !externalSelection {
                if committed != visibleWeek { AppHaptics.trigger(.discreteSelection) }
                visibleWeek = committed
                parent.model.selectWeek(committed)
            }
            let settled = visibleWeek ?? displayed.week
            warmNeighbours(of: settled)
            prune(around: settled)
            update(parent, in: controller)
        }
    }
}

private struct Identity: Equatable {
    let authenticationRevision: Int
    let termID: Int?
    let snapshotRevision: Int
    let renderRevision: Int
    let wallpaperVisible: Bool
    let layoutScale: CGFloat
}

private final class WeekHost<Page: View>: UIHostingController<Page> {
    let week: Int

    init(week: Int, rootView: Page) {
        self.week = week
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The delegate only commits a completed, single-page interactive transition.
enum TimetablePageTransition {
    static func committedWeek(from current: Int?, to displayed: Int, completed: Bool) -> Int? {
        guard completed, let current, abs(displayed - current) == 1 else { return nil }
        return displayed
    }
}
