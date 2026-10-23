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
    func cached() throws -> CourseSnapshot?
    func refresh(on date: Date) async throws -> CourseSnapshot
    func saveSchedule(_ schedule: CustomSchedule) throws
    func deleteSchedule(id: Int) throws
    func saveManualRule(_ rule: ManualCourseRule) throws
    func saveProfile(_ profile: TodayProfile) throws
}

@MainActor
final class DiskCourseRepository: CourseRepository {
    private let api: any APIClientProtocol
    private let session: any SessionStore
    private let baseURL: URL
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(api: any APIClientProtocol, session: any SessionStore, baseURL: URL = APIConfiguration.development.baseURL,
         directory: URL? = nil) {
        self.api = api
        self.session = session
        self.baseURL = baseURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var file: URL? {
        guard let cookie = session.cookie, !cookie.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(baseURL.absoluteString)|\(cookie)".utf8))
        return directory.appendingPathComponent("course_snapshot_\(digest.map { String(format: "%02x", $0) }.joined()).json")
    }

    func cached() throws -> CourseSnapshot? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try decoder.decode(CourseSnapshot.self, from: Data(contentsOf: file))
    }

    private func write(_ snapshot: CourseSnapshot) throws {
        guard let file else { throw APIError.unauthorized(message: "请先登录后查看本机安排。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    func refresh(on date: Date) async throws -> CourseSnapshot {
        guard session.cookie != nil else { throw APIError.unauthorized(message: "请先登录后查看今日课程。") }
        let _: AuthIdentity = try await api.request("GET", path: "/api/v1/auth/me", body: nil, preserveSessionOnPasswordError: false)
        let sessions: [CourseSession] = try await api.request("GET", path: "/api/v1/timetable", body: nil, preserveSessionOnPasswordError: false)
        var snapshot = (try? cached()) ?? .empty
        snapshot.calendarSessions = sessions
        snapshot.lastRefreshDate = CourseScheduleCalculator.dateKey(date)
        // These are the same timetable inputs Flutter uses for local manual
        // courses. A failure leaves the last valid terms and periods intact.
        if let terms: [TermInfo] = try? await api.request("GET", path: "/api/v1/terms", body: nil, preserveSessionOnPasswordError: false) {
            snapshot.terms = terms
        }
        if let periods: [PeriodInfo] = try? await api.request("GET", path: "/api/v1/settings/period-times", body: nil, preserveSessionOnPasswordError: false) {
            snapshot.periods = periods
        }
        if !snapshot.serverSchedulesImported,
           let imported: [CustomSchedule] = try? await api.request("GET", path: "/api/v1/custom-schedules", body: nil, preserveSessionOnPasswordError: false) {
            let existing = Set(snapshot.schedules.map(\.id))
            let deleted = Set(snapshot.deletedRemoteScheduleIDs)
            snapshot.schedules += imported.filter { !existing.contains($0.id) && !deleted.contains($0.id) }
            snapshot.serverSchedulesImported = true
        }
        guard session.cookie != nil else {
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
        try? write(snapshot) // Storage errors must not suppress live courses.
        return snapshot
    }

    func saveSchedule(_ schedule: CustomSchedule) throws {
        var snapshot = try cached() ?? .empty
        snapshot.schedules.removeAll { $0.id == schedule.id }
        snapshot.schedules.append(schedule)
        try write(snapshot)
    }

    func deleteSchedule(id: Int) throws {
        var snapshot = try cached() ?? .empty
        snapshot.schedules.removeAll { $0.id == id }
        if id > 0 && !snapshot.deletedRemoteScheduleIDs.contains(id) {
            snapshot.deletedRemoteScheduleIDs.append(id)
        }
        try write(snapshot)
    }

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
