import CryptoKit
import Foundation

struct CourseSnapshot: Codable, Equatable {
    var calendarSessions: [CourseSession]
    var terms: [TermInfo]
    var periods: [PeriodInfo]
    var manualRules: [ManualCourseRule]
    var schedules: [CustomSchedule]
    var profile: TodayProfile
    var lastRefreshDate: String?
    var serverSchedulesImported: Bool
    var deletedRemoteScheduleIDs: [Int]

    static let empty = CourseSnapshot(
        calendarSessions: [], terms: [], periods: [], manualRules: [], schedules: [],
        profile: TodayProfile(displayName: "航的助手", avatarDataURL: nil, homeWallpaperDataURL: nil),
        lastRefreshDate: nil, serverSchedulesImported: false, deletedRemoteScheduleIDs: []
    )
}

@MainActor
protocol CourseRepository {
    var sessionCookie: String? { get }
    var canEditSchedules: Bool { get }
    func cached() throws -> CourseSnapshot?
    func refresh(on date: Date) async throws -> CourseSnapshot
    func refreshStrict(on date: Date, isCurrent: @escaping @MainActor () -> Bool) async throws -> CourseSnapshot
    func localSchedules(on date: Date) throws -> [CustomSchedule]
    func allLocalSchedules() throws -> [CustomSchedule]
    func saveSchedule(_ schedule: CustomSchedule) throws
    func deleteSchedule(id: Int) throws
    func saveManualRule(_ rule: ManualCourseRule) throws
    func saveProfile(_ profile: TodayProfile) throws
}

extension CourseRepository {
    func refreshStrict(on date: Date, isCurrent: @escaping @MainActor () -> Bool) async throws -> CourseSnapshot {
        throw APIError.invalidResponse
    }
}

@MainActor
final class DiskCourseRepository: CourseRepository {
    private let api: any APIClientProtocol
    private let session: any SessionStore
    private let baseURL: URL
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let localStore: LocalScheduleStore
    var sessionCookie: String? { session.cookie }
    var canEditSchedules: Bool { (try? account.requireOwner(cookie: session.cookie)) != nil }
    private let account: VerifiedAccountContext
    private var refreshGeneration = 0

    init(api: any APIClientProtocol, session: any SessionStore, account: VerifiedAccountContext,
         baseURL: URL = APIConfiguration.development.baseURL,
         directory: URL? = nil, localStore: LocalScheduleStore? = nil) {
        self.api = api
        self.session = session
        self.account = account
        self.baseURL = baseURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.localStore = localStore ?? LocalScheduleStore(session: session, account: account,
                                                           baseURL: baseURL, directory: directory)
    }

    private var file: URL? {
        guard let cookie = session.cookie, !cookie.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(baseURL.absoluteString)|\(cookie)".utf8))
        return directory.appendingPathComponent("course_snapshot_\(digest.map { String(format: "%02x", $0) }.joined()).json")
    }

    func cached() throws -> CourseSnapshot? {
        _ = try account.requireOwner(cookie: session.cookie)
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try decoder.decode(CourseSnapshot.self, from: Data(contentsOf: file))
    }

    private func write(_ snapshot: CourseSnapshot) throws {
        _ = try account.requireOwner(cookie: session.cookie)
        guard let file else { throw APIError.unauthorized(message: "请先登录后查看本机安排。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    func refresh(on date: Date) async throws -> CourseSnapshot {
        try await refreshInternal(on: date, strict: false, isCurrent: { true })
    }

    func refreshStrict(on date: Date, isCurrent: @escaping @MainActor () -> Bool) async throws -> CourseSnapshot {
        try await refreshInternal(on: date, strict: true, isCurrent: isCurrent)
    }

    private func refreshInternal(on date: Date, strict: Bool,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws -> CourseSnapshot {
        guard let originalCookie = session.cookie else { throw APIError.unauthorized(message: "请先登录后查看今日课程。") }
        let expectedOwner = try account.requireOwner(cookie: originalCookie)
        refreshGeneration += 1
        let requestGeneration = refreshGeneration
        let identity: AuthIdentity = try await api.request("GET", path: "/api/v1/auth/me", body: nil, preserveSessionOnPasswordError: false)
        guard session.cookie == originalCookie else { throw APIError.unauthorized(message: "登录状态已变化") }
        guard expectedOwner == "user:\(identity.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" else {
            session.clear()
            throw APIError.unauthorized(message: "账号身份已变化")
        }
        let sessions: [CourseSession] = try await api.request("GET", path: "/api/v1/timetable", body: nil, preserveSessionOnPasswordError: false)
        guard session.cookie == originalCookie else { throw APIError.unauthorized(message: "登录状态已变化") }
        var snapshot = (try? cached()) ?? .empty
        snapshot.calendarSessions = sessions
        snapshot.lastRefreshDate = CourseScheduleCalculator.dateKey(date)
        // These are the same timetable inputs Flutter uses for local manual
        // courses. A failure leaves the last valid terms and periods intact.
        if strict {
            let terms: [TermInfo] = try await api.request("GET", path: "/api/v1/terms", body: nil,
                                                          preserveSessionOnPasswordError: false)
            let periods: [PeriodInfo] = try await api.request("GET", path: "/api/v1/settings/period-times",
                                                              body: nil, preserveSessionOnPasswordError: false)
            snapshot.terms = terms
            snapshot.periods = periods
        } else {
            if let terms: [TermInfo] = try? await api.request("GET", path: "/api/v1/terms", body: nil, preserveSessionOnPasswordError: false) {
                snapshot.terms = terms
            }
            if let periods: [PeriodInfo] = try? await api.request("GET", path: "/api/v1/settings/period-times", body: nil, preserveSessionOnPasswordError: false) {
                snapshot.periods = periods
            }
        }
        guard !Task.isCancelled, requestGeneration == refreshGeneration, isCurrent(),
              session.cookie == originalCookie,
              (try? account.requireOwner(cookie: originalCookie)) == expectedOwner else {
            throw APIError.unauthorized(message: "登录状态已变化")
        }
        if snapshot.serverSchedulesImported && !snapshot.schedules.isEmpty {
            try? localStore.importServerOnce(snapshot.schedules)
        }
        if !snapshot.serverSchedulesImported,
           let imported: [CustomSchedule] = try? await api.request("GET", path: "/api/v1/custom-schedules", body: nil, preserveSessionOnPasswordError: false) {
            let existing = Set(snapshot.schedules.map(\.id))
            let deleted = Set(snapshot.deletedRemoteScheduleIDs)
            let eligible = imported.filter { !deleted.contains($0.id) }
            guard !Task.isCancelled, requestGeneration == refreshGeneration, isCurrent(), session.cookie == originalCookie,
                  (try? account.requireOwner(cookie: originalCookie)) == expectedOwner else {
                throw APIError.unauthorized(message: "登录状态已变化")
            }
            try localStore.importServerOnce(eligible)
            snapshot.schedules += eligible.filter { !existing.contains($0.id) }
            snapshot.serverSchedulesImported = true
        }
        guard !Task.isCancelled, requestGeneration == refreshGeneration, isCurrent(),
              session.cookie == originalCookie,
              (try? account.requireOwner(cookie: originalCookie)) == expectedOwner else {
            throw APIError.unauthorized(message: "登录状态已失效")
        }
        // MainActor methods can interleave at each await. Keep edits made while
        // the requests were in flight instead of writing an older local copy.
        if let latest = try? cached() {
            snapshot.manualRules = latest.manualRules
            snapshot.profile = latest.profile
            let latestIDs = Set(latest.schedules.map(\.id))
            snapshot.deletedRemoteScheduleIDs = latest.deletedRemoteScheduleIDs
            snapshot.schedules = latest.schedules + snapshot.schedules.filter {
                !latestIDs.contains($0.id) && !latest.deletedRemoteScheduleIDs.contains($0.id)
            }
            if latest.serverSchedulesImported { snapshot.serverSchedulesImported = true }
        }
        if strict {
            try write(snapshot) // A pending time change is not complete until the new cache is durable.
        } else {
            try? write(snapshot) // Preserve the existing offline-tolerant normal refresh.
        }
        return snapshot
    }

    func saveSchedule(_ schedule: CustomSchedule) throws {
        try localStore.save(schedule)
    }

    func deleteSchedule(id: Int) throws {
        try localStore.delete(id: id)
    }

    func localSchedules(on date: Date) throws -> [CustomSchedule] { try localStore.forDate(date) }
    func allLocalSchedules() throws -> [CustomSchedule] { try localStore.all() }

    func saveManualRule(_ rule: ManualCourseRule) throws {
        var snapshot = try cached() ?? .empty
        snapshot.manualRules.removeAll { $0.id == rule.id }
        snapshot.manualRules.append(rule)
        try write(snapshot)
    }

    func saveProfile(_ profile: TodayProfile) throws {
        var snapshot = try cached() ?? .empty
        snapshot.profile = profile
        try write(snapshot)
    }
}
