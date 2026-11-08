import SwiftUI

/// Marks a pushed SwiftUI navigation destination as a secondary page for one root tab.
///
/// The app keeps a UIKit `UITabBarController` outside the SwiftUI `NavigationStack`s,
/// so the system's SwiftUI tab-bar toolbar visibility does not own this bar. A token is
/// retained for the destination's real view lifetime instead: multiple pushed pages keep
/// the bar hidden, an interactive back-swipe that is cancelled keeps its token, and
/// switching to a different root tab does not hide that tab's bar.
@MainActor
struct TabBarHiddenNavigationDestination<Content: View>: View {
    @ObservedObject private var state: AppState
    private let tab: AppTab
    private let content: Content
    @State private var token = UUID()

    init(state: AppState, tab: AppTab, @ViewBuilder content: () -> Content) {
        self.state = state
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        content
            .onAppear {
                state.setNavigationDestinationVisible(true, token: token, in: tab)
            }
            .onDisappear {
                state.setNavigationDestinationVisible(false, token: token, in: tab)
            }
    }
}
