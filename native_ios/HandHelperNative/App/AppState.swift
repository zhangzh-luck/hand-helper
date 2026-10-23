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
    enum AuthenticationStatus: Equatable {
        case signedOut, verifying, signedIn(String), offline, expired
    }

    @Published var selectedTab: AppTab = .today
    @Published private(set) var appearance: AppearanceMode
    @Published var isDetailPresented = false
    @Published var homeAvatar: UIImage?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authenticationStatus: AuthenticationStatus = .signedOut
    @Published private(set) var authenticationRevision = 0
    @Published var isLoginPresented = false
    @Published private(set) var isLoginSubmitting = false
    @Published private(set) var loginError: String?

    let api: any APIClientProtocol
    let sessionStore: any SessionStore
    let verifiedAccount = VerifiedAccountContext()
    private let authentication: any AuthenticationClientProtocol
    private let preferences: UserDefaults
    private var authenticationGeneration = 0
    private var didStartRestore = false
    private static let appearanceKey = "appearance_mode"

    init(
        api: (any APIClientProtocol)? = nil,
        sessionStore: any SessionStore = KeychainSessionStore(),
        authentication: (any AuthenticationClientProtocol)? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.preferences = preferences
        appearance = AppearanceMode(rawValue: preferences.string(forKey: Self.appearanceKey) ?? "") ?? .system
        authenticationStatus = sessionStore.cookie == nil ? .signedOut : .verifying
        self.api = api ?? APIClient(configuration: .development, sessionStore: sessionStore)
        self.authentication = authentication ?? AuthenticationClient()
    }

    func setAppearance(_ mode: AppearanceMode) {
        appearance = mode
        preferences.set(mode.rawValue, forKey: Self.appearanceKey)
    }

    func requireCurrentAccount(revision: Int) throws -> String {
        guard isAuthenticated, revision == authenticationRevision else {
            throw APIError.unauthorized(message: "登录状态已变化，请重新打开安排。")
        }
        return try verifiedAccount.requireOwner(cookie: sessionStore.cookie)
    }

    func restoreSession() async {
        guard !didStartRestore else { return }
        didStartRestore = true
        guard let cookie = sessionStore.cookie, !cookie.isEmpty else {
            authenticationStatus = .signedOut
            return
        }
        authenticationGeneration += 1
        let generation = authenticationGeneration
        authenticationStatus = .verifying
        do {
            let identity = try await authentication.verify(cookie: cookie)
            guard generation == authenticationGeneration, sessionStore.cookie == cookie else { return }
            guard identity.authenticated else { throw APIError.invalidResponse }
            try verifiedAccount.confirm(username: identity.username, cookie: cookie)
            authenticationStatus = .signedIn(identity.username)
            isAuthenticated = true
            authenticationRevision += 1
        } catch {
            guard generation == authenticationGeneration, sessionStore.cookie == cookie else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError {
                handleUnauthorized()
            } else {
                authenticationStatus = .offline
                isAuthenticated = false
                authenticationRevision += 1
            }
        }
    }

    func retrySessionVerification() async {
        guard authenticationStatus == .offline, !isLoginSubmitting else { return }
        didStartRestore = false
        await restoreSession()
    }

    func login(username: String, password: String) async {
        guard !isLoginSubmitting else { return }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            loginError = "请输入账号和密码。"
            return
        }
        isLoginSubmitting = true
        loginError = nil
        authenticationGeneration += 1
        let generation = authenticationGeneration
        defer { if generation == authenticationGeneration { isLoginSubmitting = false } }
        do {
            let result = try await authentication.login(username: trimmed, password: password)
            guard generation == authenticationGeneration, !Task.isCancelled else { return }
            guard result.identity.authenticated,
                  !result.identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.cookie.isEmpty else { throw APIError.invalidResponse }
            sessionStore.save(cookie: result.cookie)
            guard sessionStore.cookie == result.cookie else {
                loginError = "无法保存登录状态，请检查设备钥匙串。"
                return
            }
            try verifiedAccount.confirm(username: result.identity.username, cookie: result.cookie)
            authenticationStatus = .signedIn(result.identity.username)
            isAuthenticated = true
            authenticationRevision += 1
            isLoginPresented = false
        } catch {
            guard generation == authenticationGeneration, !Task.isCancelled else { return }
            if isAuthenticated && sessionStore.cookie == nil { handleUnauthorized() }
            loginError = error.localizedDescription
        }
    }

    func logout() async {
        let cookie = sessionStore.cookie
        authenticationGeneration += 1
        isLoginSubmitting = false
        sessionStore.clear()
        verifiedAccount.clear()
        authenticationStatus = .signedOut
        isAuthenticated = false
        homeAvatar = nil
        loginError = nil
        authenticationRevision += 1
        if let cookie { try? await authentication.logout(cookie: cookie) }
    }

    func handleUnauthorized() {
        authenticationGeneration += 1
        isLoginSubmitting = false
        isAuthenticated = false
        sessionStore.clear()
        verifiedAccount.clear()
        homeAvatar = nil
        authenticationStatus = .expired
        authenticationRevision += 1
    }
}
