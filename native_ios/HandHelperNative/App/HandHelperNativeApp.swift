import SwiftUI

@main
struct HandHelperNativeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(state.appearance.colorScheme)
                .task { await state.restoreSession() }
        }
    }
}
