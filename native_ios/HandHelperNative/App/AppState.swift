import SwiftUI

enum AppTab: Int, CaseIterable {
    case today, timetable, analysis, settings

    var title: String {
        switch self {
        case .today: "今日"
        case .timetable: "课程表"
        case .analysis: "分析"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .today: "house"
        case .timetable: "calendar"
        case .analysis: "chart.bar"
        case .settings: "gearshape"
        }
    }
}

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .today
    @Published private(set) var appearance: AppearanceMode
    @Published var isDetailPresented = false
    @Published var homeAvatar: UIImage?
    @Published private(set) var isAuthenticated = false

    let api: any APIClientProtocol
    let sessionStore: any SessionStore
    private let preferences: UserDefaults
    private static let appearanceKey = "appearance_mode"

    init(
        api: (any APIClientProtocol)? = nil,
        sessionStore: any SessionStore = KeychainSessionStore(),
        preferences: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.preferences = preferences
        appearance = AppearanceMode(rawValue: preferences.string(forKey: Self.appearanceKey) ?? "") ?? .system
        self.api = api ?? APIClient(configuration: .development, sessionStore: sessionStore)
    }

    func setAppearance(_ mode: AppearanceMode) {
        appearance = mode
        preferences.set(mode.rawValue, forKey: Self.appearanceKey)
    }

    func handleUnauthorized() {
        isAuthenticated = false
        sessionStore.clear()
        homeAvatar = nil
    }
}
