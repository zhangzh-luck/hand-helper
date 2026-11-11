import SwiftUI

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var snapshot: CourseSnapshot?
    @Published private(set) var now: Date
    @Published private(set) var errorMessage: String?
    @Published private(set) var wallpaperData: Data?
    @Published private(set) var wallpaperImage: UIImage?
    @Published private(set) var isLoading = false
    @Published private(set) var localSchedules: [CustomSchedule] = []

    private let repository: any CourseRepository
    private let wallpaperStore: WallpaperStore
    private let clock: any TodayClock
    private var refreshGeneration = 0
    private var hasReadPrivateCache = false
    private var hasReadLocalSchedules = false

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
        return CourseScheduleCalculator.mergeManualCourses(remote: remote, local: local,
                                                           rules: snapshot.manualRules)
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

    private func setSnapshot(_ value: CourseSnapshot?) {
        guard snapshot != value else { return }
        snapshot = value
    }

    private func setErrorMessage(_ value: String?) {
        guard errorMessage != value else { return }
        errorMessage = value
    }

    private func setLocalSchedules(_ value: [CustomSchedule]) {
        guard localSchedules != value else { return }
        localSchedules = value
    }

    private func setWallpaperData(_ value: Data?) {
        guard wallpaperData != value else { return }
        wallpaperData = value
        // Decode once when the stored wallpaper changes. SwiftUI body evaluation
        // can then reuse this image during tab selection and layout passes.
        wallpaperImage = value.flatMap(UIImage.init(data:))
    }

    private func reloadSchedules() {
        guard repository.canEditSchedules else {
            hasReadLocalSchedules = false
            setLocalSchedules([])
            return
        }
        do {
            setLocalSchedules(try repository.allLocalSchedules())
            hasReadLocalSchedules = true
        } catch {
            hasReadLocalSchedules = false
            setErrorMessage("本机安排无法读取：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func load(allowPrivateCache: Bool = true, allowLocalSchedules: Bool = true,
              forceDiskRead: Bool = false) -> Bool {
        if !forceDiskRead,
           let cacheAvailable = restoreInMemoryIfAvailable(allowPrivateCache: allowPrivateCache,
                                                            allowLocalSchedules: allowLocalSchedules) {
            return cacheAvailable
        }
        setErrorMessage(nil)
        if allowLocalSchedules {
            reloadSchedules()
        } else {
            hasReadLocalSchedules = false
            setLocalSchedules([])
        }
        guard allowPrivateCache else {
            hasReadPrivateCache = false
            hasReadLocalSchedules = false
            setSnapshot(nil)
            setWallpaperData(nil)
            return false
        }
        do {
            setSnapshot(try repository.cached())
            hasReadPrivateCache = true
            setWallpaperData(try? wallpaperStore.load())
            if errorMessage == nil { setErrorMessage(snapshot == nil ? "课程数据暂不可用" : nil) }
            return snapshot != nil
        } catch {
            hasReadPrivateCache = false
            setErrorMessage("本机数据无法读取：\(error.localizedDescription)")
            return false
        }
    }

    /// Returns nil only when a disk read is still required. This is intentionally
    /// invalidated by authentication and explicit local-data changes, rather than
    /// acting as a permanent `hasLoaded` flag.
    @discardableResult
    func restoreInMemoryIfAvailable(allowPrivateCache: Bool, allowLocalSchedules: Bool) -> Bool? {
        guard allowPrivateCache, hasReadPrivateCache,
              (!allowLocalSchedules || hasReadLocalSchedules) else { return nil }
        return snapshot != nil
    }

    func authenticationDidChange(allowPrivateCache: Bool, allowLocalSchedules: Bool = true) {
        refreshGeneration += 1
        isLoading = false
        hasReadPrivateCache = false
        hasReadLocalSchedules = false
        setSnapshot(nil)
        setWallpaperData(nil)
        _ = load(allowPrivateCache: allowPrivateCache, allowLocalSchedules: allowLocalSchedules,
                 forceDiskRead: true)
    }

    @discardableResult
    func refresh(isCurrent: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        (await refreshInternal(strict: false, isCurrent: isCurrent)).unauthorized
    }

    func refreshStrict(isCurrent: @escaping @MainActor () -> Bool) async -> (unauthorized: Bool, completed: Bool) {
        await refreshInternal(strict: true, isCurrent: isCurrent)
    }

    private func refreshInternal(strict: Bool, isCurrent: @escaping @MainActor () -> Bool)
        async -> (unauthorized: Bool, completed: Bool) {
        guard let requestCookie = repository.sessionCookie, isCurrent() else { return (false, false) }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }
        do {
            let fresh: CourseSnapshot
            if strict {
                fresh = try await repository.refreshStrict(on: clock.now, isCurrent: isCurrent)
            } else {
                fresh = try await repository.refresh(on: clock.now, isCurrent: isCurrent)
            }
            guard generation == refreshGeneration, repository.sessionCookie == requestCookie,
                  isCurrent() else { return (false, false) }
            setSnapshot(fresh)
            hasReadPrivateCache = true
            reloadSchedules()
            let currentNow = clock.now
            if now != currentNow { now = currentNow }
            setErrorMessage(nil)
            return (false, true)
        } catch {
            guard generation == refreshGeneration, isCurrent() else { return (false, false) }
            guard repository.sessionCookie == requestCookie || repository.sessionCookie == nil else {
                return (false, false)
            }
            reloadSchedules()
            if let apiError = error as? APIError, case .unauthorized = apiError {
                hasReadPrivateCache = false
                setSnapshot(nil)
                setWallpaperData(nil)
                setErrorMessage(apiError.localizedDescription)
                return (true, false)
            }
            setErrorMessage(error.localizedDescription)
            return (false, false)
        }
    }
    func tick(allowLocalSchedules: Bool = true) -> Bool {
        let previous = CourseScheduleCalculator.dateKey(now)
        let currentNow = clock.now
        if now != currentNow { now = currentNow }
        let changed = previous != CourseScheduleCalculator.dateKey(now)
        if changed && allowLocalSchedules { reloadSchedules() }
        return changed
    }

    func saveSchedule(id: Int?, title: String, date: Date, time: String, endTime: String? = nil) throws {
        guard repository.canEditSchedules else { throw APIError.unauthorized(message: "请先登录后编辑本机安排。") }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw TodayInputError.invalidTitle }
        guard ScheduleTimeRange.minutes(time) != nil,
              endTime == nil || ScheduleTimeRange.valid(start: time, end: endTime!) else {
            throw TodayInputError.invalidTime
        }
        if let id, !localSchedules.contains(where: { $0.id == id }) {
            throw TodayInputError.missingSchedule
        }
        try repository.saveSchedule(CustomSchedule(id: id ?? 0, title: name,
                                                   date: CourseScheduleCalculator.dateKey(date),
                                                   time: time, endTime: endTime))
        reloadSchedules()
    }

    func deleteSchedule(id: Int) throws {
        guard repository.canEditSchedules else { throw APIError.unauthorized(message: "请先登录后编辑本机安排。") }
        try repository.deleteSchedule(id: id)
        reloadSchedules()
    }

    func reloadWallpaper() throws {
        setWallpaperData(try wallpaperStore.load())
    }
}

enum TodayInputError: LocalizedError {
    case invalidTitle, invalidTime, missingSchedule
    var errorDescription: String? {
        switch self {
        case .invalidTitle: "安排事项需为 1 至 200 个字符。"
        case .invalidTime: "结束时间必须晚于同一天的开始时间。"
        case .missingSchedule: "这项安排已不存在，请返回今日页面重试。"
        }
    }
}
