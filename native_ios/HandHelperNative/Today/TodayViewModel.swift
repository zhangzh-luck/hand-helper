import SwiftUI

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var snapshot: CourseSnapshot?
    @Published private(set) var now: Date
    @Published private(set) var errorMessage: String?
    @Published private(set) var wallpaperData: Data?
    @Published private(set) var isLoading = false
    @Published private(set) var openScheduleID: Int?
    @Published private(set) var localSchedules: [CustomSchedule] = []

    private let repository: any CourseRepository
    private let wallpaperStore: WallpaperStore
    private let clock: any TodayClock
    private var refreshGeneration = 0

    init(repository: any CourseRepository, wallpaperStore: WallpaperStore, clock: any TodayClock = SystemTodayClock()) {
        self.repository = repository
        self.wallpaperStore = wallpaperStore
        self.clock = clock
        now = clock.now
    }

    var profile: TodayProfile {
        snapshot?.profile ?? .init(displayName: "航的助手", avatarDataURL: nil, homeWallpaperDataURL: nil)
    }

    var courses: [CourseSession] {
        guard let snapshot else { return [] }
        let local = CourseScheduleCalculator.expandedManualCourses(
            on: now, rules: snapshot.manualRules, terms: snapshot.terms, periods: snapshot.periods
        )
        let remote = CourseScheduleCalculator.sessions(for: now, from: snapshot.calendarSessions)
        let localRemoteIDs = Set(snapshot.manualRules.compactMap(\.remoteID))
        return (remote.filter { $0.source != "MANUAL" || !localRemoteIDs.contains($0.manualCourseID ?? Int.min) } + local)
            .sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
    }

    var schedules: [CustomSchedule] {
        let key = CourseScheduleCalculator.dateKey(now)
        return localSchedules.filter { $0.date == key }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
    }

    var active: CourseSession? { CourseScheduleCalculator.active(in: courses, at: now) }
    var upcoming: CourseSession? { CourseScheduleCalculator.upcoming(in: courses, at: now) }

    var status: String {
        if let active, let end = active.end {
            return "正在上 \(active.name)，距下课约 \(CourseScheduleCalculator.countdown(until: end, from: now))"
        }
        if let upcoming, let start = upcoming.start {
            return "下一节 \(upcoming.name)，\(CourseScheduleCalculator.countdown(until: start, from: now))后上课"
        }
        if !schedules.isEmpty { return "今天有 \(schedules.count) 项自定义安排" }
        return "今天的课程已经结束"
    }

    var hasCourseData: Bool { snapshot?.lastRefreshDate != nil || snapshot?.manualRules.isEmpty == false }
    var canEditSchedules: Bool { repository.canEditSchedules }

    private func reloadSchedules() {
        localSchedules = []
        guard repository.canEditSchedules else { return }
        do { localSchedules = try repository.allLocalSchedules() }
        catch { errorMessage = "本机安排无法读取：\(error.localizedDescription)" }
    }

    func load(allowPrivateCache: Bool = true, allowLocalSchedules: Bool = true) {
        errorMessage = nil
        if allowLocalSchedules { reloadSchedules() } else { localSchedules = [] }
        guard allowPrivateCache else {
            snapshot = nil
            wallpaperData = nil
            return
        }
        do {
            snapshot = try repository.cached()
            wallpaperData = try wallpaperStore.load() ?? WallpaperStore.decodeDataURL(snapshot?.profile.homeWallpaperDataURL)
            if errorMessage == nil { errorMessage = snapshot == nil ? "课程数据暂不可用" : nil }
        } catch {
            errorMessage = "本机数据无法读取：\(error.localizedDescription)"
        }
    }

    func authenticationDidChange(allowPrivateCache: Bool, allowLocalSchedules: Bool = true) {
        refreshGeneration += 1
        isLoading = false
        snapshot = nil
        wallpaperData = nil
        closeActions()
        load(allowPrivateCache: allowPrivateCache, allowLocalSchedules: allowLocalSchedules)
    }

    @discardableResult
    func refresh() async -> Bool {
        guard let requestCookie = repository.sessionCookie else { return false }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }
        do {
            let fresh = try await repository.refresh(on: clock.now)
            guard generation == refreshGeneration, repository.sessionCookie == requestCookie else { return false }
            snapshot = fresh
            reloadSchedules()
            now = clock.now
            wallpaperData = (try? wallpaperStore.load()) ?? WallpaperStore.decodeDataURL(fresh.profile.homeWallpaperDataURL)
            errorMessage = nil
            return false
        } catch {
            guard generation == refreshGeneration else { return false }
            guard repository.sessionCookie == requestCookie || repository.sessionCookie == nil else { return false }
            reloadSchedules()
            if let apiError = error as? APIError, case .unauthorized = apiError {
                snapshot = nil
                wallpaperData = nil
                closeActions()
                errorMessage = apiError.localizedDescription
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func tick(allowLocalSchedules: Bool = true) -> Bool {
        let previous = CourseScheduleCalculator.dateKey(now)
        now = clock.now
        let changed = previous != CourseScheduleCalculator.dateKey(now)
        if changed { closeActions() }
        if changed && allowLocalSchedules { reloadSchedules() }
        return changed
    }

    func showActions(for id: Int) { openScheduleID = id }
    func closeActions() { openScheduleID = nil }

    func saveSchedule(id: Int?, title: String, date: Date, time: String) throws {
        guard repository.canEditSchedules else { throw APIError.unauthorized(message: "请先登录后编辑本机安排。") }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw TodayInputError.invalidTitle }
        let parts = time.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { throw TodayInputError.invalidTime }
        if let id, !localSchedules.contains(where: { $0.id == id }) {
            throw TodayInputError.missingSchedule
        }
        try repository.saveSchedule(CustomSchedule(id: id ?? 0, title: name,
                                                   date: CourseScheduleCalculator.dateKey(date), time: time))
        reloadSchedules()
        closeActions()
    }

    func deleteSchedule(id: Int) throws {
        guard repository.canEditSchedules else { throw APIError.unauthorized(message: "请先登录后编辑本机安排。") }
        try repository.deleteSchedule(id: id)
        reloadSchedules()
        closeActions()
    }

    func setWallpaper(_ data: Data) throws {
        guard repository.canEditSchedules else { throw APIError.unauthorized(message: "请先登录后设置壁纸。") }
        try wallpaperStore.save(data)
        wallpaperData = data
    }

    func removeWallpaper() throws {
        guard repository.canEditSchedules else { throw APIError.unauthorized(message: "请先登录后设置壁纸。") }
        try wallpaperStore.remove()
        if var profile = snapshot?.profile {
            profile.homeWallpaperDataURL = nil
            try repository.saveProfile(profile)
            snapshot = try repository.cached()
        }
        wallpaperData = nil
    }
}

enum TodayInputError: LocalizedError {
    case invalidTitle, invalidTime, missingSchedule
    var errorDescription: String? {
        switch self {
        case .invalidTitle: "安排事项需为 1 至 200 个字符。"
        case .invalidTime: "时间格式无效。"
        case .missingSchedule: "这项安排已不存在，请返回今日页面重试。"
        }
    }
}
