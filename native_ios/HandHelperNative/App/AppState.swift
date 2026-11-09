import SwiftUI

enum AppTab: Int, CaseIterable, Hashable {
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

struct LocalManualCourseChange: Equatable {
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
    @Published private(set) var activeNavigationDestinationTokens: [AppTab: Set<UUID>] = [:]
    @Published private(set) var currentProfile: LocalProfile = .empty
    @Published private(set) var profileError: String?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authenticationStatus: AuthenticationStatus = .signedOut
    @Published private(set) var authenticationRevision = 0
    @Published private(set) var courseDataInvalidation: CourseDataInvalidation?
    @Published private(set) var completedCourseRefresh: CourseDataInvalidation?
    @Published private(set) var localManualCourseChange: LocalManualCourseChange?
    @Published private(set) var courseSnapshotVersion = 0
    @Published private(set) var localScheduleVersion = 0
    @Published private(set) var liveActivitiesEnabled: Bool
    @Published private(set) var wallpaperVersion = 0
    @Published private(set) var timetableWallpaperVersion = 0
    @Published private(set) var analysisWallpaperVersion = 0
    private var wallpaperContainerSizes: [WallpaperKind: CGSize] = [:]
    private var courseDataSequence = 0
    private var localManualCourseSequence = 0
    @Published private(set) var pendingTimetableImport: PendingTimetableImport?
    private var timetableUploadCancellation: (() -> Void)?
    @Published private(set) var pendingGradeImport: PendingGradeImport?
    private var gradeUploadCancellation: (() -> Void)?
    @Published private(set) var pendingAcademicTimeWrites: [PendingAcademicTimeWrite] = []
    private var academicTimeReconcileInFlight = false
    private var academicTimeReconcileRequested = false
    private var rotationPendingCourseOwner: String?
    @Published private(set) var isLoginSubmitting = false
    @Published private(set) var loginError: String?
    @Published private(set) var loginFailureFeedback: LoginFailureFeedbackEvent?
    @Published private(set) var credentialRemovalError: String?

    let api: any APIClientProtocol
    let sessionStore: any SessionStore
    let verifiedAccount = VerifiedAccountContext()
    let liveActivityCoordinator = LiveActivityCoordinator()
    let tabSwitchDiagnostics: TabSwitchDiagnostics
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
    private static let liveActivitiesKey = "live_activities_enabled"

    /// `NavigationStack` lives inside each UIKit tab host, so UIKit cannot infer pushed
    /// destinations through `hidesBottomBarWhenPushed`. Destinations register their own
    /// lifetime here; the selected tab alone determines whether the native bar is hidden.
    var shouldHideTabBarForNavigation: Bool {
        !(activeNavigationDestinationTokens[selectedTab] ?? []).isEmpty
    }

    func setNavigationDestinationVisible(_ isVisible: Bool, token: UUID, in tab: AppTab) {
        var tokens = activeNavigationDestinationTokens[tab] ?? []
        let changed: Bool
        if isVisible {
            changed = tokens.insert(token).inserted
        } else {
            changed = tokens.remove(token) != nil
        }
        guard changed else { return }
        if tokens.isEmpty {
            activeNavigationDestinationTokens.removeValue(forKey: tab)
        } else {
            activeNavigationDestinationTokens[tab] = tokens
        }
    }

    func clearNavigationDestinationTokens() {
        guard !activeNavigationDestinationTokens.isEmpty else { return }
        activeNavigationDestinationTokens.removeAll()
    }

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
        tabSwitchDiagnostics = TabSwitchDiagnostics(preferences: preferences)
        appearance = AppearanceMode(rawValue: preferences.string(forKey: Self.appearanceKey) ?? "") ?? .system
        liveActivitiesEnabled = preferences.bool(forKey: Self.liveActivitiesKey)
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

    func wallpaperDidChange(revision: Int) throws {
        _ = try requireCurrentAccount(revision: revision)
        wallpaperVersion += 1
    }

    func timetableWallpaperDidChange(revision: Int) throws {
        _ = try requireCurrentAccount(revision: revision)
        timetableWallpaperVersion += 1
    }

    func analysisWallpaperDidChange(revision: Int) throws {
        _ = try requireCurrentAccount(revision: revision)
        analysisWallpaperVersion += 1
    }

    /// The tab controller supplies actual page-host dimensions, so a wallpaper
    /// crop uses the receiving page's layout ratio rather than a screen ratio.
    func updateWallpaperContainerSize(_ size: CGSize, for kind: WallpaperKind) {
        guard size.width > 0, size.height > 0 else { return }
        wallpaperContainerSizes[kind] = size
    }

    func wallpaperContainerAspectRatio(for kind: WallpaperKind) -> CGFloat? {
        guard let size = wallpaperContainerSizes[kind], size.width > 0, size.height > 0 else {
            return nil
        }
        return size.width / size.height
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
        completedCourseRefresh = nil
    }

    func publishLocalManualCourseChange(for owner: String, authenticationRevision revision: Int) throws {
        guard try requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "登录账号已变化。")
        }
        localManualCourseSequence += 1
        localManualCourseChange = LocalManualCourseChange(owner: owner,
            authenticationRevision: revision, sequence: localManualCourseSequence)
    }

    func courseSnapshotDidChange(revision: Int) throws {
        _ = try requireCurrentAccount(revision: revision)
        courseSnapshotVersion += 1
    }

    func localScheduleDidChange(revision: Int) throws {
        _ = try requireCurrentAccount(revision: revision)
        localScheduleVersion += 1
    }

    func setLiveActivitiesEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: Self.liveActivitiesKey)
        liveActivitiesEnabled = enabled
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

    var visibleGradeImport: PendingGradeImport? {
        guard let pendingGradeImport,
              (try? requireCurrentAccount(revision: authenticationRevision)) == pendingGradeImport.owner else {
            return nil
        }
        return pendingGradeImport
    }

    func beginGradeImport(revision: Int) throws -> UUID {
        let owner = try requireCurrentAccount(revision: revision)
        guard pendingGradeImport == nil else {
            throw APIError.server(status: 409, message: "请先关闭上一次成绩预览。")
        }
        let id = UUID()
        pendingGradeImport = PendingGradeImport(id: id, owner: owner, phase: .uploading)
        return id
    }

    func setGradeUploadCancellation(_ cancel: @escaping () -> Void, id: UUID) {
        guard pendingGradeImport?.id == id else { cancel(); return }
        gradeUploadCancellation = cancel
    }

    func acceptGradePreview(_ preview: GradeImportPreview, id: UUID) {
        guard let pendingGradeImport, pendingGradeImport.id == id,
              case .uploading = pendingGradeImport.phase else { return }
        gradeUploadCancellation = nil
        self.pendingGradeImport?.phase = .ready(preview)
        // A rotated Cookie leaves the preview hidden until /auth/me verifies the
        // original owner again. A different account can never adopt this ticket.
    }

    func failGradeImport(_ message: String, id: UUID) {
        guard let pendingGradeImport, pendingGradeImport.id == id,
              case .uploading = pendingGradeImport.phase else { return }
        gradeUploadCancellation = nil
        self.pendingGradeImport?.phase = .failed(message)
    }

    func discardGradeImport(id: UUID) {
        guard pendingGradeImport?.id == id else { return }
        gradeUploadCancellation?()
        gradeUploadCancellation = nil
        pendingGradeImport = nil
    }

    var visibleTimetableImport: PendingTimetableImport? {
        guard let pendingTimetableImport,
              (try? requireCurrentAccount(revision: authenticationRevision)) == pendingTimetableImport.owner else {
            return nil
        }
        return pendingTimetableImport
    }

    func beginTimetableImport(revision: Int) throws -> UUID {
        let owner = try requireCurrentAccount(revision: revision)
        if let pendingTimetableImport {
            guard case .refreshCompleted = pendingTimetableImport.phase else {
                throw APIError.server(status: 409, message: "请先处理上一次课表导入的结果。")
            }
        }
        let id = UUID()
        pendingTimetableImport = PendingTimetableImport(id: id, owner: owner,
                                                        phase: .uploading, inspection: nil)
        return id
    }

    func setTimetableUploadCancellation(_ cancel: @escaping () -> Void, id: UUID) {
        guard pendingTimetableImport?.id == id else { cancel(); return }
        timetableUploadCancellation = cancel
    }

    func acceptTimetableImport(_ result: TimetableImportResult, id: UUID) {
        guard let operation = pendingTimetableImport, operation.id == id,
              case .uploading = operation.phase else { return }
        timetableUploadCancellation = nil
        pendingTimetableImport?.phase = .accepted(result)
        reconcileTimetableImport()
    }

    func markTimetableImportUnconfirmed(_ message: String, id: UUID) {
        guard let operation = pendingTimetableImport, operation.id == id,
              case .uploading = operation.phase else { return }
        timetableUploadCancellation = nil
        pendingTimetableImport?.phase = .unconfirmed(message)
        reconcileTimetableImport(forceUnconfirmedRefresh: true)
    }

    func noteTimetableInspection(_ inspection: TimetableImportInspection, id: UUID,
                                 owner: String, revision: Int) {
        guard (try? requireCurrentAccount(revision: revision)) == owner,
              pendingTimetableImport?.id == id, pendingTimetableImport?.owner == owner else { return }
        if let phase = pendingTimetableImport?.phase, case .unconfirmed = phase {
            pendingTimetableImport?.inspection = inspection
        }
    }

    func discardTimetableImport(id: UUID) {
        guard pendingTimetableImport?.id == id else { return }
        timetableUploadCancellation?()
        timetableUploadCancellation = nil
        pendingTimetableImport = nil
    }

    private func reconcileTimetableImport(forceUnconfirmedRefresh: Bool = false) {
        guard let operation = pendingTimetableImport,
              (try? requireCurrentAccount(revision: authenticationRevision)) == operation.owner else { return }
        do {
            switch operation.phase {
            case .accepted(let result):
                try invalidateCourses(for: operation.owner, authenticationRevision: authenticationRevision)
                if let marker = courseDataInvalidation {
                    pendingTimetableImport?.phase = .refreshPending(result, sequence: marker.sequence)
                }
            case .unconfirmed:
                if forceUnconfirmedRefresh || courseDataInvalidation?.owner != operation.owner ||
                    courseDataInvalidation?.authenticationRevision != authenticationRevision {
                    try invalidateCourses(for: operation.owner, authenticationRevision: authenticationRevision)
                }
            case .uploading, .refreshPending, .refreshCompleted:
                break
            }
        } catch { /* Keep the result pending until this account is verified again. */ }
    }

    func acknowledgeCourseRefresh(_ marker: CourseDataInvalidation) {
        guard marker == courseDataInvalidation,
              (try? requireCurrentAccount(revision: marker.authenticationRevision)) == marker.owner else { return }
        completedCourseRefresh = marker
        guard let operation = pendingTimetableImport, operation.owner == marker.owner,
              case .refreshPending(let result, let sequence) = operation.phase,
              marker.sequence >= sequence else { return }
        pendingTimetableImport?.phase = .refreshCompleted(result)
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
        if courseDataInvalidation?.owner != owner {
            courseDataInvalidation = nil
            completedCourseRefresh = nil
        }
        if let pendingTimetableImport, pendingTimetableImport.owner != owner {
            timetableUploadCancellation?()
            timetableUploadCancellation = nil
            self.pendingTimetableImport = nil
        }
        let acceptedImport: Bool
        if let pendingTimetableImport, case .accepted = pendingTimetableImport.phase {
            acceptedImport = true
        } else {
            acceptedImport = false
        }
        if rotationPendingCourseOwner == owner && !acceptedImport {
            courseDataSequence += 1
            courseDataInvalidation = CourseDataInvalidation(
                owner: owner, authenticationRevision: authenticationRevision, sequence: courseDataSequence)
            completedCourseRefresh = nil
        }
        rotationPendingCourseOwner = nil
        reconcileTimetableImport()
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
            clearNavigationDestinationTokens()
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
            presentLoginError(credentialRemovalError ?? "请先清除旧登录凭据。", feedback: .recoverable)
            return
        }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            loginError = "请输入账号和密码。"
            return
        }
        isLoginSubmitting = true
        loginError = nil
        loginFailureFeedback = nil
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
                presentLoginError("无法保存登录状态，请检查设备钥匙串。", feedback: .recoverable)
                return
            }
            try verifiedAccount.confirm(username: result.identity.username, cookie: result.cookie)
            rotationExpectedOwner = nil
            verifyingCookie = nil
            clearNavigationDestinationTokens()
            selectedTab = .today
            authenticationStatus = .signedIn(result.identity.username)
            isAuthenticated = true
            authenticationRevision += 1
            loadLocalProfile()
            if let owner = verifiedAccount.owner { await resumeAcademicTimeAfterVerification(owner: owner) }
        } catch {
            guard generation == authenticationGeneration, !Task.isCancelled else { return }
            if isAuthenticated && sessionStore.cookie == nil { handleUnauthorized() }
            presentLoginError(error.localizedDescription, feedback: LoginFailureFeedback.classify(error))
        }
    }

    private func presentLoginError(_ message: String, feedback: LoginFailureFeedback) {
        loginError = message
        loginFailureFeedback = LoginFailureFeedbackEvent(feedback: feedback)
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
        completedCourseRefresh = nil
        localManualCourseChange = nil
        if let pendingTimetableImport,
           case .refreshPending(let result, _) = pendingTimetableImport.phase {
            self.pendingTimetableImport?.phase = .accepted(result)
        }
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
        timetableUploadCancellation?()
        timetableUploadCancellation = nil
        pendingTimetableImport = nil
        gradeUploadCancellation?()
        gradeUploadCancellation = nil
        pendingGradeImport = nil
        isLoginSubmitting = false
        verifiedAccount.clear()
        courseDataInvalidation = nil
        completedCourseRefresh = nil
        localManualCourseChange = nil
        pendingAcademicTimeWrites = []
        rotationPendingCourseOwner = nil
        rotationExpectedOwner = nil
        verifyingCookie = nil
        clearNavigationDestinationTokens()
        selectedTab = .today
        isDetailPresented = false
        authenticationStatus = .signedOut
        isAuthenticated = false
        clearProfile()
        loginError = nil
        loginFailureFeedback = nil
        authenticationRevision += 1
        _ = retryCredentialRemoval()
        if let cookie { try? await authentication.logout(cookie: cookie) }
    }

    func handleUnauthorized() {
        authenticationGeneration += 1
        (api as? APIClient)?.invalidatePendingSessionRequests()
        timetableUploadCancellation?()
        timetableUploadCancellation = nil
        pendingTimetableImport = nil
        gradeUploadCancellation?()
        gradeUploadCancellation = nil
        pendingGradeImport = nil
        isLoginSubmitting = false
        isAuthenticated = false
        verifiedAccount.clear()
        courseDataInvalidation = nil
        completedCourseRefresh = nil
        localManualCourseChange = nil
        pendingAcademicTimeWrites = []
        rotationPendingCourseOwner = nil
        rotationExpectedOwner = nil
        verifyingCookie = nil
        clearNavigationDestinationTokens()
        selectedTab = .today
        isDetailPresented = false
        clearProfile()
        authenticationStatus = .expired
        authenticationRevision += 1
        _ = retryCredentialRemoval()
    }
}
