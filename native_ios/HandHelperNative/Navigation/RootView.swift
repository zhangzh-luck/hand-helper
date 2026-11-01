import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var timetableDetail = TimetableCourseDetailCoordinator()
    @State private var avatarPreview: TodayAvatarPreviewRoute?
    @State private var avatarPreviewVisible = false

    var body: some View {
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
                                   timetableDetail: timetableDetail)
                    .ignoresSafeArea()
                    .allowsHitTesting(avatarPreview == nil && !timetableDetail.isPresenting)
                    .accessibilityHidden(avatarPreview != nil || timetableDetail.isPresenting)
            }
            if let avatarPreview,
               state.entry == .main, state.selectedTab == .today,
               state.canAccessPrivateData,
               avatarPreview.revision == state.authenticationRevision {
                TodayAvatarLightboxView(image: avatarPreview.image,
                                        isVisible: avatarPreviewVisible,
                                        onClose: closeAvatarPreview)
                    .zIndex(1)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.22)) {
                            avatarPreviewVisible = true
                        }
                    }
            }
            if state.entry == .main {
                TimetableCourseDetailOverlay(detail: timetableDetail, reduceMotion: reduceMotion)
                    .zIndex(2)
            }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            clearAvatarPreview()
            timetableDetail.clear()
        }
        .onChange(of: state.selectedTab) { _, tab in
            if tab != .today { clearAvatarPreview() }
            if tab != .timetable { timetableDetail.clear() }
        }
        .onChange(of: state.entry) { _, entry in
            if entry != .main {
                clearAvatarPreview()
                timetableDetail.clear()
            }
        }
        .onChange(of: timetableDetail.isPresenting) { _, presenting in
            if presenting { clearAvatarPreview() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { timetableDetail.clear() }
        }
    }

    private func showAvatarPreview(_ route: TodayAvatarPreviewRoute) {
        guard state.entry == .main, state.selectedTab == .today,
              state.canAccessPrivateData,
              route.revision == state.authenticationRevision,
              !timetableDetail.isPresenting else { return }
        avatarPreviewVisible = false
        avatarPreview = route
    }

    private func closeAvatarPreview() {
        guard let preview = avatarPreview else { return }
        withAnimation(.easeInOut(duration: 0.2)) { avatarPreviewVisible = false }
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard avatarPreview?.id == preview.id, !avatarPreviewVisible else { return }
            avatarPreview = nil
        }
    }

    private func clearAvatarPreview() {
        avatarPreviewVisible = false
        avatarPreview = nil
    }
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

    func makeUIViewController(context: Context) -> NativeTabController {
        let controller = NativeTabController(state: state, onAvatarPreview: onAvatarPreview,
                                             timetableDetail: timetableDetail)
        controller.selectedTabDidChange = { [weak state] tab in state?.selectedTab = tab }
        return controller
    }

    func updateUIViewController(_ controller: NativeTabController, context: Context) {
        controller.apply(state: state)
    }
}

final class NativeTabController: UITabBarController, UITabBarControllerDelegate {
    private var keyboardCoversBottom = false
    private var detailPresented = false

    init(state: AppState, onAvatarPreview: @escaping @MainActor (TodayAvatarPreviewRoute) -> Void = { _ in },
         timetableDetail: TimetableCourseDetailCoordinator? = nil) {
        super.init(nibName: nil, bundle: nil)
        viewControllers = AppTab.allCases.map { tab in
            let page: AnyView
            switch tab {
            case .today: page = AnyView(TodayView(state: state, onAvatarPreview: onAvatarPreview))
            case .settings: page = AnyView(SettingsView(state: state))
            case .analysis: page = AnyView(AnalysisView(state: state))
            case .timetable: page = AnyView(TimetableView(state: state,
                detail: timetableDetail ?? TimetableCourseDetailCoordinator()))
            }
            let host = UIHostingController(rootView: page)
            host.tabBarItem = UITabBarItem(title: nil, image: UIImage(systemName: tab.symbol), tag: tab.rawValue)
            host.tabBarItem.accessibilityLabel = tab.title
            return host
        }
        delegate = self
        selectedIndex = state.selectedTab.rawValue
        configureAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(state:)") }

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
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        if selectedIndex != state.selectedTab.rawValue { selectedIndex = state.selectedTab.rawValue }
        if detailPresented != state.isDetailPresented {
            detailPresented = state.isDetailPresented
            updateTabVisibility()
        }
        let image = state.homeAvatar?.withRenderingMode(.alwaysOriginal) ?? UIImage(systemName: AppTab.today.symbol)
        viewControllers?.first?.tabBarItem.image = image
        viewControllers?.first?.tabBarItem.selectedImage = state.homeAvatar?.withRenderingMode(.alwaysOriginal)
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        selectedTabDidChange?(AppTab(rawValue: selectedIndex) ?? .today)
    }

    var selectedTabDidChange: ((AppTab) -> Void)?

    private func updateTabVisibility() {
        let shouldHide = detailPresented || keyboardCoversBottom
        guard tabBar.isHidden != shouldHide else { return }
        tabBar.isHidden = shouldHide
        // UITabBarController recalculates child safe areas when the bar changes.
        view.setNeedsLayout()
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
