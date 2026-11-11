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
    private let tabSwitchDiagnostics: TabSwitchDiagnostics?
    private var refreshGeneration = 0
    private var hasReadPrivateCache = false
    private var hasReadLocalSchedules = false
    private var cachedPresentation: TodayPresentation?
    private(set) var derivedPresentationBuildCount = 0

    init(repository: any CourseRepository, wallpaperStore: WallpaperStore, clock: any TodayClock = SystemTodayClock(),
         tabSwitchDiagnostics: TabSwitchDiagnostics? = nil) {
        self.repository = repository
        self.wallpaperStore = wallpaperStore
        self.clock = clock
        self.tabSwitchDiagnostics = tabSwitchDiagnostics
        now = clock.now
    }

    var profile: TodayProfile { snapshot?.profile ?? .init(displayName: "航的助手", avatarDataURL: nil, homeWallpaperDataURL: nil) }
    var courses: [CourseSession] { presentation.courses }
    var schedules: [CustomSchedule] { presentation.schedules }
    var active: CourseSession? { presentation.active }
    var upcoming: CourseSession? { presentation.upcoming }
    var status: String { presentation.status }
    var hasCourseData: Bool { presentation.hasCourseData }

    private var presentation: TodayPresentation {
        if let cachedPresentation {
            tabSwitchDiagnostics?.recordTodayDerivedCacheHit()
            return cachedPresentation
        }
        tabSwitchDiagnostics?.beginTodayDerivedCacheRebuild()
        let courses: [CourseSession]
        if let snapshot {
            let local = CourseScheduleCalculator.expandedManualCourses(
                on: now, rules: snapshot.manualRules, terms: snapshot.terms, periods: snapshot.periods)
            let remote = CourseScheduleCalculator.sessions(for: now, from: snapshot.calendarSessions)
            courses = CourseScheduleCalculator.mergeManualCourses(remote: remote, local: local,
                                                                  rules: snapshot.manualRules)
        } else {
            courses = []
        }
        let dateKey = CourseScheduleCalculator.dateKey(now)
        let schedules = localSchedules.filter { $0.date == dateKey }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        let active = CourseScheduleCalculator.active(in: courses, at: now)
        let upcoming = CourseScheduleCalculator.upcoming(in: courses, at: now)
        let status: String
        if let active, let end = active.end {
            status = "正在上 \(active.name)，距下课约 \(CourseScheduleCalculator.countdown(until: end, from: now))"
        } else if let upcoming, let start = upcoming.start {
            status = "下一节 \(upcoming.name)，\(CourseScheduleCalculator.countdown(until: start, from: now))后上课"
        } else if !schedules.isEmpty {
            status = "今天有 \(schedules.count) 项自定义安排"
        } else {
            status = "今天的课程已经结束"
        }
        let value = TodayPresentation(courses: courses, schedules: schedules, active: active, upcoming: upcoming,
                                      status: status, hasCourseData: snapshot?.lastRefreshDate != nil || snapshot?.manualRules.isEmpty == false)
        cachedPresentation = value
        derivedPresentationBuildCount += 1
        tabSwitchDiagnostics?.endTodayDerivedCacheRebuild()
        return value
    }
    var canEditSchedules: Bool { repository.canEditSchedules }

    private func setSnapshot(_ value: CourseSnapshot?) {
        guard snapshot != value else { return }
        snapshot = value
        invalidatePresentation()
    }

    private func setErrorMessage(_ value: String?) {
        guard errorMessage != value else { return }
        errorMessage = value
    }

    private func setLocalSchedules(_ value: [CustomSchedule]) {
        guard localSchedules != value else { return }
        localSchedules = value
        invalidatePresentation()
    }

    private func setWallpaperData(_ value: Data?) {
        guard wallpaperData != value else { return }
        wallpaperData = value
        // Decode once when the stored wallpaper changes. SwiftUI body evaluation
        // can then reuse this image during tab selection and layout passes.
        wallpaperImage = value.flatMap(UIImage.init(data:))
    }

    private func setNow(_ value: Date) {
        guard now != value else { return }
        now = value
        invalidatePresentation()
    }

    private func invalidatePresentation() { cachedPresentation = nil }

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
              forceDiskRead: Bool = true) -> Bool {
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
            setNow(currentNow)
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
        setNow(currentNow)
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

private struct TodayPresentation {
    let courses: [CourseSession]
    let schedules: [CustomSchedule]
    let active: CourseSession?
    let upcoming: CourseSession?
    let status: String
    let hasCourseData: Bool
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
