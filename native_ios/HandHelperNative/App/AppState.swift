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

enum AppearanceMode: String, CaseIterable, Hashable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct CourseDataInvalidation: Equatable {
    let owner: String
    let authenticationRevision: Int
    let sequence: Int
}

struct PendingAcademicTimeWrite: Identifiable, Equatable {
    enum Phase: Equatable { case submitting, awaitingConfirmation }
    let id: UUID
    let owner: String
    let target: AcademicTimeWriteTarget
    var phase: Phase
    var message: String?
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
    @Published private(set) var currentProfile: LocalProfile = .empty
    @Published private(set) var profileError: String?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authenticationStatus: AuthenticationStatus = .signedOut
    @Published private(set) var authenticationRevision = 0
    @Published private(set) var courseDataInvalidation: CourseDataInvalidation?
    private var courseDataSequence = 0
    @Published private(set) var pendingAcademicTimeWrites: [PendingAcademicTimeWrite] = []
    private var academicTimeReconcileInFlight = false
    private var academicTimeReconcileRequested = false
    private var rotationPendingCourseOwner: String?
    @Published private(set) var isLoginSubmitting = false
    @Published private(set) var loginError: String?
    @Published private(set) var credentialRemovalError: String?

    let api: any APIClientProtocol
    let sessionStore: any SessionStore
    let verifiedAccount = VerifiedAccountContext()
    private let authentication: any AuthenticationClientProtocol
    private let preferences: UserDefaults
    private let profileDirectory: URL?
    private var cachedHomeAvatar: UIImage?
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
        preferences: UserDefaults = .standard,
        profileDirectory: URL? = nil
    ) {
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.profileDirectory = profileDirectory
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

    var homeAvatar: UIImage? { cachedHomeAvatar }

    private var profileStore: LocalProfileStore {
        LocalProfileStore(session: sessionStore, account: verifiedAccount, directory: profileDirectory)
    }

    private func applyProfile(_ profile: LocalProfile) {
        cachedHomeAvatar = Self.tabAvatar(from: profile.avatarData)
        currentProfile = profile
    }

    private func clearProfile() {
        cachedHomeAvatar = nil
        currentProfile = .empty
        profileError = nil
    }

    private func loadLocalProfile() {
        do {
            applyProfile(try profileStore.load())
            profileError = nil
        } catch {
            applyProfile(.empty)
            profileError = "本机个人资料无法读取：\(error.localizedDescription)"
        }
    }

    func saveLocalProfile(_ profile: LocalProfile, revision: Int) throws {
        _ = try requireCurrentAccount(revision: revision)
        let saved = try profileStore.save(profile)
        _ = try requireCurrentAccount(revision: revision)
        applyProfile(saved)
        profileError = nil
    }

    private static func tabAvatar(from data: Data?) -> UIImage? {
        guard let data, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let side: CGFloat = 28
        let scale = max(side / image.size.width, side / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let imageRect = CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            image.draw(in: imageRect)
        }
    }

    func requireCurrentAccount(revision: Int) throws -> String {
        guard isAuthenticated, revision == authenticationRevision else {
            throw APIError.unauthorized(message: "登录状态已变化，请重新打开安排。")
        }
        return try verifiedAccount.requireOwner(cookie: sessionStore.cookie)
    }

    func invalidateCourses(for owner: String, authenticationRevision revision: Int) throws {
        guard try requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "登录账号已变化。")
        }
        courseDataSequence += 1
        courseDataInvalidation = CourseDataInvalidation(
            owner: owner, authenticationRevision: revision, sequence: courseDataSequence)
    }

    func pendingCourseInvalidation(after appliedSequence: Int?) -> CourseDataInvalidation? {
        guard let marker = courseDataInvalidation,
              marker.sequence != appliedSequence,
              marker.authenticationRevision == authenticationRevision,
              (try? requireCurrentAccount(revision: marker.authenticationRevision)) == marker.owner else {
            return nil
        }
        return marker
    }

    var visiblePendingAcademicTimeWrites: [PendingAcademicTimeWrite] {
        guard let owner = try? requireCurrentAccount(revision: authenticationRevision) else { return [] }
        return pendingAcademicTimeWrites.filter { $0.owner == owner && $0.phase == .awaitingConfirmation }
    }

    func beginAcademicTimeWrite(_ target: AcademicTimeWriteTarget, revision: Int) throws -> UUID {
        let owner = try requireCurrentAccount(revision: revision)
        guard !pendingAcademicTimeWrites.contains(where: {
            $0.owner == owner && $0.target.key == target.key &&
            ($0.phase == .submitting || $0.target == target)
        }) else {
            throw APIError.server(status: 409, message: "请先重新核对该项上次保存的结果。")
        }
        let id = UUID()
        pendingAcademicTimeWrites.append(PendingAcademicTimeWrite(
            id: id, owner: owner, target: target, phase: .submitting, message: nil))
        return id
    }

    @discardableResult
    func acceptAcademicTimeWrite(_ id: UUID) -> Bool {
        guard let accepted = pendingAcademicTimeWrites.first(where: { $0.id == id }) else { return false }
        // A newer accepted value supersedes an unresolved value for the same field.
        pendingAcademicTimeWrites.removeAll {
            $0.id != id && $0.owner == accepted.owner && $0.target.key == accepted.target.key
        }
        guard let index = pendingAcademicTimeWrites.firstIndex(where: { $0.id == id }) else { return false }
        pendingAcademicTimeWrites[index].phase = .awaitingConfirmation
        pendingAcademicTimeWrites[index].message = nil
        return true
    }

    func abandonAcademicTimeWrite(_ id: UUID) {
        pendingAcademicTimeWrites.removeAll { $0.id == id }
    }

    func hasPendingAcademicTimeWrite(_ id: UUID) -> Bool {
        pendingAcademicTimeWrites.contains { $0.id == id }
    }

    func reconcilePendingAcademicTimeWrites() async {
        if academicTimeReconcileInFlight {
            academicTimeReconcileRequested = true
            return
        }
        academicTimeReconcileInFlight = true
        defer {
            academicTimeReconcileInFlight = false
            if academicTimeReconcileRequested {
                academicTimeReconcileRequested = false
                Task { await self.reconcilePendingAcademicTimeWrites() }
            }
        }
        var attempted = Set<UUID>()
        while let item = pendingAcademicTimeWrites.first(where: {
            $0.phase == .awaitingConfirmation && !attempted.contains($0.id)
        }) {
            attempted.insert(item.id)
            let revision = authenticationRevision
            guard (try? requireCurrentAccount(revision: revision)) == item.owner else { return }
            do {
                let matched = try await AcademicTimeService(api: api).confirms(item.target)
                guard !Task.isCancelled,
                      (try? requireCurrentAccount(revision: revision)) == item.owner,
                      let index = pendingAcademicTimeWrites.firstIndex(where: {
                          $0.id == item.id && $0.phase == .awaitingConfirmation && $0.target == item.target
                      }) else { return }
                if matched {
                    try invalidateCourses(for: item.owner, authenticationRevision: revision)
                    pendingAcademicTimeWrites.remove(at: index)
                } else {
                    pendingAcademicTimeWrites[index].message = "服务端当前值与待确认值不一致，请稍后重新核对。"
                }
            } catch {
                guard (try? requireCurrentAccount(revision: revision)) == item.owner,
                      let index = pendingAcademicTimeWrites.firstIndex(where: { $0.id == item.id }) else { return }
                pendingAcademicTimeWrites[index].message = "读回未确认：\(error.localizedDescription)"
            }
        }
    }

    private func resumeAcademicTimeAfterVerification(owner: String) async {
        pendingAcademicTimeWrites.removeAll { $0.owner != owner }
        if courseDataInvalidation?.owner != owner { courseDataInvalidation = nil }
        if rotationPendingCourseOwner == owner {
            courseDataSequence += 1
            courseDataInvalidation = CourseDataInvalidation(
                owner: owner, authenticationRevision: authenticationRevision, sequence: courseDataSequence)
        }
        rotationPendingCourseOwner = nil
        if pendingAcademicTimeWrites.contains(where: { $0.phase == .awaitingConfirmation }) {
            await reconcilePendingAcademicTimeWrites()
        }
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
        clearProfile()
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
            loadLocalProfile()
            if let owner = verifiedAccount.owner { await resumeAcademicTimeAfterVerification(owner: owner) }
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
            loadLocalProfile()
            if let owner = verifiedAccount.owner { await resumeAcademicTimeAfterVerification(owner: owner) }
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
        clearProfile()
        if let marker = courseDataInvalidation { rotationPendingCourseOwner = marker.owner }
        courseDataInvalidation = nil
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
            loadLocalProfile()
            if let owner = verifiedAccount.owner { await resumeAcademicTimeAfterVerification(owner: owner) }
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
        courseDataInvalidation = nil
        pendingAcademicTimeWrites = []
        rotationPendingCourseOwner = nil
        rotationExpectedOwner = nil
        verifyingCookie = nil
        selectedTab = .today
        isDetailPresented = false
        authenticationStatus = .signedOut
        isAuthenticated = false
        clearProfile()
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
        courseDataInvalidation = nil
        pendingAcademicTimeWrites = []
        rotationPendingCourseOwner = nil
        rotationExpectedOwner = nil
        verifyingCookie = nil
        selectedTab = .today
        isDetailPresented = false
        clearProfile()
        authenticationStatus = .expired
        authenticationRevision += 1
        _ = retryCredentialRemoval()
    }
}
