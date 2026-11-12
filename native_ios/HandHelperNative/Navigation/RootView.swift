import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var timetableDetail = TimetableCourseDetailCoordinator()
    @StateObject private var gradeDetail = GradeDetailCoordinator()
    @StateObject private var deleteConfirmation = DestructiveConfirmationCoordinator()
    @State private var avatarPreview: TodayAvatarPreviewRoute?
    @State private var avatarPreviewVisible = false

    private var presentation: some View {
        ZStack {
            switch state.entry {
            case .login:
                LoginView(state: state)
            case .verifying:
                AuthenticationStatusView(title: "正在验证登录状态", message: "确认账号后即可进入航的助手。", retry: nil)
            case .offline:
                AuthenticationStatusView(title: "暂时无法验证登录状态", message: "请检查网络连接后重试。", retry: {
                    Task { await state.retrySessionVerification() }
                })
            case .credentialRecovery:
                AuthenticationStatusView(title: "无法清除旧登录凭据",
                                         message: state.credentialRemovalError ?? "请重试清理设备钥匙串。",
                                         retry: { _ = state.retryCredentialRemoval() })
            case .main:
                NativeTabContainer(state: state, onAvatarPreview: showAvatarPreview,
                                   timetableDetail: timetableDetail, gradeDetail: gradeDetail,
                                   deleteConfirmation: deleteConfirmation)
                    .ignoresSafeArea()
                    .allowsHitTesting(avatarPreview == nil && !timetableDetail.isPresenting &&
                                      !gradeDetail.isPresenting && !deleteConfirmation.isPresenting)
                    .accessibilityHidden(avatarPreview != nil || timetableDetail.isPresenting ||
                                         gradeDetail.isPresenting || deleteConfirmation.isPresenting)
            }
            if let avatarPreview,
               state.entry == .main, state.selectedTab == .today,
               state.canAccessPrivateData,
               avatarPreview.revision == state.authenticationRevision {
                TodayAvatarLightboxView(image: avatarPreview.image,
                                        sourceFrameInGlobal: avatarPreview.sourceFrameInGlobal,
                                        isVisible: avatarPreviewVisible,
                                        reduceMotion: reduceMotion,
                                        onClose: closeAvatarPreview)
                    .zIndex(1)
                    .allowsHitTesting(!deleteConfirmation.isPresenting)
                    .accessibilityHidden(deleteConfirmation.isPresenting)
                    .onAppear {
                        withAnimation(avatarPreviewAnimation) {
                            avatarPreviewVisible = true
                        }
                    }
            }
            if state.entry == .main {
                TimetableCourseDetailOverlay(detail: timetableDetail,
                                             confirmation: deleteConfirmation,
                                             reduceMotion: reduceMotion)
                    .zIndex(2)
                    .allowsHitTesting(!deleteConfirmation.isPresenting)
                    .accessibilityHidden(deleteConfirmation.isPresenting)
                GradeDetailOverlay(detail: gradeDetail, reduceMotion: reduceMotion)
                    .zIndex(3)
                    .allowsHitTesting(!deleteConfirmation.isPresenting)
                    .accessibilityHidden(deleteConfirmation.isPresenting)
            }
        }
        .alert(deleteConfirmation.request?.kind.title ?? "",
               isPresented: Binding(get: { deleteConfirmation.alertVisible },
                                    set: { deleteConfirmation.setAlertVisible($0) }),
               presenting: deleteConfirmation.request) { request in
            Button(request.kind.deleteTitle, role: .destructive) {
                deleteConfirmation.confirm(id: request.id)
            }
            Button("取消", role: .cancel) {
                deleteConfirmation.cancel(id: request.id)
            }
        } message: { request in
            Text(request.kind.message)
        }
    }

    private var presentationLifecycle: some View {
        presentation
        .onChange(of: state.authenticationRevision) { _, _ in
            syncLiveActivities(reason: "authentication_revision")
            clearAvatarPreview()
            timetableDetail.clear()
            gradeDetail.clear()
            deleteConfirmation.clear()
        }
        .onChange(of: state.currentProfile.avatarData) { _, _ in
            // The route owns a snapshot UIImage. Close it instead of allowing an
            // already-open preview to present an avatar that has since changed.
            clearAvatarPreview()
        }
        .onChange(of: state.selectedTab) { oldTab, tab in
            if tab != .today { clearAvatarPreview() }
            if tab != .timetable { timetableDetail.clear() }
            // AnalysisView owns the active-analysis exit cleanup. Avoid publishing the
            // same clear twice during one tab transition.
            if oldTab != .analysis, tab != .analysis { gradeDetail.clear() }
            deleteConfirmation.clear()
        }
        .onChange(of: state.entry) { _, entry in
            syncLiveActivities(reason: "entry_changed")
            if entry != .main {
                clearAvatarPreview()
                timetableDetail.clear()
                gradeDetail.clear()
                deleteConfirmation.clear()
            }
        }
        .onChange(of: timetableDetail.isPresenting) { _, presenting in
            if presenting { clearAvatarPreview() }
        }
        .onChange(of: gradeDetail.isPresenting) { _, presenting in
            if presenting {
                clearAvatarPreview()
                timetableDetail.clear()
            }
        }
    }

    var body: some View {
        presentationLifecycle
        .onChange(of: scenePhase) { _, phase in
            syncLiveActivities(reason: "scene_\(phase)")
            if phase != .active {
                timetableDetail.clear()
                gradeDetail.clear()
            }
        }
        .onChange(of: state.liveActivitiesEnabled) { _, _ in syncLiveActivities(reason: "app_switch") }
        .onChange(of: state.courseSnapshotVersion) { _, _ in syncLiveActivities(reason: "course_snapshot") }
        .onChange(of: state.localManualCourseChange) { _, _ in syncLiveActivities(reason: "manual_course") }
        .onChange(of: state.localScheduleVersion) { _, _ in syncLiveActivities(reason: "local_schedule") }
        .onOpenURL { url in
            guard url.scheme == "handhelper", url.host == "today",
                  state.entry == .main, state.canAccessPrivateData else { return }
            state.selectedTab = .today
        }
        .task { syncLiveActivities(reason: "root_task") }
    }

    private func syncLiveActivities(reason: String) {
        state.liveActivityCoordinator.synchronize(state: state, foreground: scenePhase == .active,
                                                  reason: reason)
    }

    private func showAvatarPreview(_ route: TodayAvatarPreviewRoute) {
        guard state.entry == .main, state.selectedTab == .today,
              state.canAccessPrivateData,
              route.revision == state.authenticationRevision,
              avatarPreview == nil, !timetableDetail.isPresenting,
              !gradeDetail.isPresenting, !deleteConfirmation.isPresenting else { return }
        avatarPreviewVisible = false
        avatarPreview = route
    }

    private func closeAvatarPreview() {
        guard let preview = avatarPreview, avatarPreviewVisible else { return }
        withAnimation(avatarPreviewAnimation, completionCriteria: .logicallyComplete) {
            avatarPreviewVisible = false
        } completion: {
            guard avatarPreview?.id == preview.id, !avatarPreviewVisible else { return }
            avatarPreview = nil
        }
    }

    private var avatarPreviewAnimation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.28)
    }

    private func clearAvatarPreview() {
        let needsClear = AvatarPreviewClearPolicy.needsClear(isVisible: avatarPreviewVisible,
                                                             hasPreview: avatarPreview != nil)
        guard needsClear else { return }
        if avatarPreviewVisible { avatarPreviewVisible = false }
        if avatarPreview != nil { avatarPreview = nil }
    }
}

enum AvatarPreviewClearPolicy {
    static func needsClear(isVisible: Bool, hasPreview: Bool) -> Bool { isVisible || hasPreview }
}

private struct AuthenticationStatusView: View {
    let title: String
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if retry == nil { ProgressView() }
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry { Button("重试", action: retry).buttonStyle(.borderedProminent) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct NativeTabContainer: UIViewControllerRepresentable {
    @ObservedObject var state: AppState
    let onAvatarPreview: @MainActor (TodayAvatarPreviewRoute) -> Void
    let timetableDetail: TimetableCourseDetailCoordinator
    let gradeDetail: GradeDetailCoordinator
    let deleteConfirmation: DestructiveConfirmationCoordinator

    func makeUIViewController(context: Context) -> NativeTabController {
        let controller = NativeTabController(state: state, onAvatarPreview: onAvatarPreview,
                                             timetableDetail: timetableDetail, gradeDetail: gradeDetail,
                                             deleteConfirmation: deleteConfirmation)
        controller.selectedTabDidChange = { [weak state] tab in
            guard let state else { return }
            state.selectedTab = tab
        }
        return controller
    }

    func updateUIViewController(_ controller: NativeTabController, context: Context) {
        controller.apply(state: state)
    }
}

final class NativeTabController: UITabBarController, UITabBarControllerDelegate {
    private weak var appState: AppState?
    private var keyboardCoversBottom = false
    private var detailPresented = false
    private var navigationDestinationPresented = false
    private var configuredHomeAvatarData: Data?
    private var hasConfiguredHomeAvatar = false

    init(state: AppState, onAvatarPreview: @escaping @MainActor (TodayAvatarPreviewRoute) -> Void = { _ in },
         timetableDetail: TimetableCourseDetailCoordinator? = nil,
         gradeDetail: GradeDetailCoordinator? = nil,
         deleteConfirmation: DestructiveConfirmationCoordinator? = nil) {
        super.init(nibName: nil, bundle: nil)
        appState = state
        viewControllers = AppTab.allCases.map { tab in
            let controller: UIViewController
            switch tab {
            case .today:
                controller = UIHostingController(rootView: TodayView(state: state, onAvatarPreview: onAvatarPreview,
                    deleteConfirmation: deleteConfirmation ?? DestructiveConfirmationCoordinator()))
            case .settings:
                let navigation = SettingsNavigationController(state: state)
                navigation.stackVisibilityDidChange = { [weak self] in self?.updateTabVisibility() }
                controller = navigation
            case .analysis:
                controller = UIHostingController(rootView: AnalysisView(state: state,
                    gradeDetail: gradeDetail ?? GradeDetailCoordinator(),
                    timetableDetail: timetableDetail ?? TimetableCourseDetailCoordinator(),
                    deleteConfirmation: deleteConfirmation ?? DestructiveConfirmationCoordinator()))
            case .timetable:
                controller = UIHostingController(rootView: TimetableView(state: state,
                    detail: timetableDetail ?? TimetableCourseDetailCoordinator(),
                    deleteConfirmation: deleteConfirmation ?? DestructiveConfirmationCoordinator()))
            }
            controller.tabBarItem = UITabBarItem(title: nil, image: UIImage(systemName: tab.symbol), tag: tab.rawValue)
            controller.tabBarItem.accessibilityLabel = tab.title
            return controller
        }
        delegate = self
        selectedIndex = state.selectedTab.rawValue
        configureAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(state:)") }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let appState else { return }
        for (tab, controller) in zip(AppTab.allCases, viewControllers ?? []) {
            switch tab {
            case .today: appState.updateWallpaperContainerSize(controller.view.bounds.size, for: .today)
            case .timetable: appState.updateWallpaperContainerSize(controller.view.bounds.size, for: .timetable)
            case .analysis: appState.updateWallpaperContainerSize(controller.view.bounds.size, for: .analysis)
            case .settings: continue
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for itemAppearance in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.clear]
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = UIColor.systemBlue
    }

    func apply(state: AppState) {
        let style: UIUserInterfaceStyle
        switch state.appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        if overrideUserInterfaceStyle != style {
            overrideUserInterfaceStyle = style
        }
        if selectedIndex != state.selectedTab.rawValue {
            selectedIndex = state.selectedTab.rawValue
            updateTabVisibility()
        }
        if detailPresented != state.isDetailPresented {
            detailPresented = state.isDetailPresented
            updateTabVisibility()
        }
        if navigationDestinationPresented != state.shouldHideTabBarForNavigation {
            navigationDestinationPresented = state.shouldHideTabBarForNavigation
            updateTabVisibility()
        }
        applyHomeTabImageIfNeeded(state: state)
    }

    @discardableResult
    private func applyHomeTabImageIfNeeded(state: AppState) -> Bool {
        let avatarData = state.currentProfile.avatarData
        guard !hasConfiguredHomeAvatar || configuredHomeAvatarData != avatarData else { return false }
        configuredHomeAvatarData = avatarData
        hasConfiguredHomeAvatar = true
        let image = state.homeAvatar?.withRenderingMode(.alwaysOriginal) ?? UIImage(systemName: AppTab.today.symbol)
        viewControllers?.first?.tabBarItem.image = image
        viewControllers?.first?.tabBarItem.selectedImage = state.homeAvatar?.withRenderingMode(.alwaysOriginal)
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          shouldSelect viewController: UIViewController) -> Bool {
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        let tab = AppTab(rawValue: selectedIndex) ?? .today
        guard appState?.selectedTab != tab else { return }
        // Main-tab switches intentionally have no custom haptic; other in-app
        // interactions remain mapped through AppHaptics.
        selectedTabDidChange?(tab)
    }

    var selectedTabDidChange: ((AppTab) -> Void)?

    private func updateTabVisibility() {
        // A UIKit-pushed Settings controller owns the bar's transition through
        // `hidesBottomBarWhenPushed`. Manual visibility changes would interrupt an
        // interactive pop (including a cancelled edge swipe), so leave it to UIKit.
        if selectedSettingsNavigationController?.isShowingSecondaryPage == true { return }
        let shouldHide = detailPresented || navigationDestinationPresented || keyboardCoversBottom
        guard tabBar.isHidden != shouldHide else { return }
        // UIKit owns the child safe-area inset. Change that ownership atomically so a
        // SwiftUI push/pop cannot briefly render one frame with the old inset.
        UIView.performWithoutAnimation {
            tabBar.isHidden = shouldHide
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private var selectedSettingsNavigationController: SettingsNavigationController? {
        guard selectedIndex == AppTab.settings.rawValue else { return nil }
        return viewControllers?[AppTab.settings.rawValue] as? SettingsNavigationController
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = view.window else { return }
        let frame = view.convert(window.convert(endFrame, from: window.screen.coordinateSpace), from: window)
        let overlap = view.bounds.intersection(frame)
        keyboardCoversBottom = !overlap.isNull && overlap.width > view.bounds.width / 2 && overlap.maxY >= view.bounds.maxY - 1 && overlap.height > 0
        updateTabVisibility()
    }
}
