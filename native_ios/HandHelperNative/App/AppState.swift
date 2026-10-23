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

    enum Entry: Equatable {
        case login, verifying, offline, main, credentialRecovery
    }

    @Published var selectedTab: AppTab = .today
    @Published private(set) var appearance: AppearanceMode
    @Published var isDetailPresented = false
    @Published var homeAvatar: UIImage?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authenticationStatus: AuthenticationStatus = .signedOut
    @Published private(set) var authenticationRevision = 0
    @Published private(set) var isLoginSubmitting = false
    @Published private(set) var loginError: String?
    @Published private(set) var credentialRemovalError: String?

    let api: any APIClientProtocol
    let sessionStore: any SessionStore
    let verifiedAccount = VerifiedAccountContext()
    private let authentication: any AuthenticationClientProtocol
    private let preferences: UserDefaults
    private var authenticationGeneration = 0
    private var rotationExpectedOwner: String?
    private var verifyingCookie: String?
    private var didStartRestore = false
    private static let appearanceKey = "appearance_mode"
    private static let pendingCredentialRemovalKey = "pending_session_credential_removal"

    init(
        api: (any APIClientProtocol)? = nil,
        sessionStore: any SessionStore = KeychainSessionStore(),
        authentication: (any AuthenticationClientProtocol)? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.preferences = preferences
        appearance = AppearanceMode(rawValue: preferences.string(forKey: Self.appearanceKey) ?? "") ?? .system
        authenticationStatus = preferences.bool(forKey: Self.pendingCredentialRemovalKey)
            ? .signedOut : (sessionStore.cookie == nil ? .signedOut : .verifying)
        self.api = api ?? APIClient(configuration: .development, sessionStore: sessionStore)
        self.authentication = authentication ?? AuthenticationClient()
        if preferences.bool(forKey: Self.pendingCredentialRemovalKey) {
            credentialRemovalError = "无法清除设备钥匙串中的旧登录凭据，请重试。"
        }
        if let client = self.api as? APIClient {
            client.onSessionEvent = { [weak self] event in
                Task { @MainActor [weak self] in self?.handleSessionEvent(event) }
            }
        }
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

    var canAccessPrivateData: Bool {
        isAuthenticated && (try? verifiedAccount.requireOwner(cookie: sessionStore.cookie)) != nil
    }

    var entry: Entry {
        if credentialRemovalError != nil { return .credentialRecovery }
        switch authenticationStatus {
        case .signedOut, .expired: return .login
        case .offline: return .offline
        case .verifying: return .verifying
        case .signedIn: return canAccessPrivateData ? .main : .verifying
        }
    }

    private func handleSessionEvent(_ event: APISessionEvent) {
        switch event {
        case .rotated(let previous, let current):
            guard current != previous, sessionStore.cookie != nil,
                  (isAuthenticated && (try? verifiedAccount.requireOwner(cookie: previous)) != nil)
                    || (rotationExpectedOwner != nil && authenticationStatus == .verifying) else { return }
            Task { await reverifyRotatedSession() }
        case .unauthorized(let previous):
            guard (try? verifiedAccount.requireOwner(cookie: previous)) != nil
                    || (rotationExpectedOwner != nil && authenticationStatus == .verifying) else { return }
            handleUnauthorized()
        }
    }

    @discardableResult
    func retryCredentialRemoval() -> Bool {
        guard !isAuthenticated else { return false }
        guard sessionStore.clear() else {
            preferences.set(true, forKey: Self.pendingCredentialRemovalKey)
            credentialRemovalError = "无法清除设备钥匙串中的旧登录凭据，请重试。"
            return false
        }
        preferences.removeObject(forKey: Self.pendingCredentialRemovalKey)
        credentialRemovalError = nil
        return true
    }

    func restoreSession() async {
        guard !didStartRestore else { return }
        didStartRestore = true
        if preferences.bool(forKey: Self.pendingCredentialRemovalKey) {
            _ = retryCredentialRemoval()
            authenticationStatus = .signedOut
            return
        }
        guard let cookie = sessionStore.cookie, !cookie.isEmpty else {
            authenticationStatus = .signedOut
            return
        }
        authenticationGeneration += 1
        let generation = authenticationGeneration
        authenticationStatus = .verifying
        do {
            let verification = try await authentication.verifySession(cookie: cookie)
            guard generation == authenticationGeneration, sessionStore.cookie == cookie else { return }
            let identity = verification.identity
            guard identity.authenticated else { throw APIError.invalidResponse }
            if let rotationExpectedOwner,
               rotationExpectedOwner != "user:\(identity.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" {
                handleUnauthorized()
                return
            }
            if verification.cookie != cookie {
                sessionStore.save(cookie: verification.cookie)
                guard sessionStore.cookie == verification.cookie else { handleUnauthorized(); return }
            }
            try verifiedAccount.confirm(username: identity.username, cookie: verification.cookie)
            rotationExpectedOwner = nil
            verifyingCookie = nil
            selectedTab = .today
            authenticationStatus = .signedIn(identity.username)
            isAuthenticated = true
            authenticationRevision += 1
        } catch {
            guard generation == authenticationGeneration, sessionStore.cookie == cookie else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError {
                handleUnauthorized()
            } else {
                verifyingCookie = nil
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
        guard !Task.isCancelled, !isLoginSubmitting else { return }
        guard !preferences.bool(forKey: Self.pendingCredentialRemovalKey) else {
            loginError = credentialRemovalError ?? "请先清除旧登录凭据。"
            return
        }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            loginError = "请输入账号和密码。"
            return
        }
        isLoginSubmitting = true
        loginError = nil
        authenticationGeneration += 1
        (api as? APIClient)?.invalidatePendingSessionRequests()
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
            rotationExpectedOwner = nil
            verifyingCookie = nil
            selectedTab = .today
            authenticationStatus = .signedIn(result.identity.username)
            isAuthenticated = true
            authenticationRevision += 1
        } catch {
            guard generation == authenticationGeneration, !Task.isCancelled else { return }
            if isAuthenticated && sessionStore.cookie == nil { handleUnauthorized() }
            loginError = error.localizedDescription
        }
    }

    func reverifyRotatedSession() async {
        guard let cookie = sessionStore.cookie,
              let oldOwner = rotationExpectedOwner ?? verifiedAccount.owner,
              verifyingCookie != cookie,
              (try? verifiedAccount.requireOwner(cookie: cookie)) == nil else { return }
        authenticationGeneration += 1
        (api as? APIClient)?.invalidatePendingSessionRequests()
        let generation = authenticationGeneration
        rotationExpectedOwner = oldOwner
        verifyingCookie = cookie
        verifiedAccount.clear()
        isAuthenticated = false
        authenticationStatus = .verifying
        authenticationRevision += 1
        do {
            let verification = try await authentication.verifySession(cookie: cookie)
            guard generation == authenticationGeneration, sessionStore.cookie == cookie else { return }
            let identity = verification.identity
            let normalized = "user:\(identity.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            guard identity.authenticated, normalized == oldOwner else {
                handleUnauthorized()
                return
            }
            if verification.cookie != cookie {
                sessionStore.save(cookie: verification.cookie)
                guard sessionStore.cookie == verification.cookie else { handleUnauthorized(); return }
            }
            try verifiedAccount.confirm(username: identity.username, cookie: verification.cookie)
            rotationExpectedOwner = nil
            verifyingCookie = nil
            isAuthenticated = true
            authenticationStatus = .signedIn(identity.username)
            authenticationRevision += 1
        } catch {
            guard generation == authenticationGeneration, sessionStore.cookie == cookie else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError {
                handleUnauthorized()
            } else {
                verifyingCookie = nil
                authenticationStatus = .offline
                authenticationRevision += 1
            }
        }
    }

    func logout() async {
        let cookie = sessionStore.cookie
        authenticationGeneration += 1
        (api as? APIClient)?.invalidatePendingSessionRequests()
        isLoginSubmitting = false
        verifiedAccount.clear()
        rotationExpectedOwner = nil
        verifyingCookie = nil
        selectedTab = .today
        isDetailPresented = false
        authenticationStatus = .signedOut
        isAuthenticated = false
        homeAvatar = nil
        loginError = nil
        authenticationRevision += 1
        _ = retryCredentialRemoval()
        if let cookie { try? await authentication.logout(cookie: cookie) }
    }

    func handleUnauthorized() {
        authenticationGeneration += 1
        (api as? APIClient)?.invalidatePendingSessionRequests()
        isLoginSubmitting = false
        isAuthenticated = false
        verifiedAccount.clear()
        rotationExpectedOwner = nil
        verifyingCookie = nil
        selectedTab = .today
        isDetailPresented = false
        homeAvatar = nil
        authenticationStatus = .expired
        authenticationRevision += 1
        _ = retryCredentialRemoval()
    }
}
