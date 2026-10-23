import SwiftUI

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var snapshot: CourseSnapshot?
    @Published private(set) var now: Date
    @Published private(set) var errorMessage: String?
    @Published private(set) var wallpaperData: Data?
    @Published private(set) var isLoading = false
    @Published private(set) var openScheduleID: Int?

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
        return snapshot?.schedules.filter { $0.date == key }.sorted { ($0.time, $0.id) < ($1.time, $1.id) } ?? []
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
    var canEditSchedules: Bool { snapshot != nil }

    func load() {
        do {
            snapshot = try repository.cached()
            wallpaperData = try wallpaperStore.load() ?? WallpaperStore.decodeDataURL(snapshot?.profile.homeWallpaperDataURL)
            errorMessage = snapshot == nil ? "课程数据暂不可用" : nil
        } catch {
            errorMessage = "本机数据无法读取：\(error.localizedDescription)"
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }
        do {
            let fresh = try await repository.refresh(on: clock.now)
            guard generation == refreshGeneration else { return }
            snapshot = fresh
            now = clock.now
            wallpaperData = (try? wallpaperStore.load()) ?? WallpaperStore.decodeDataURL(fresh.profile.homeWallpaperDataURL)
            errorMessage = nil
        } catch {
            guard generation == refreshGeneration else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError {
                snapshot = nil
                wallpaperData = nil
                closeActions()
            }
            errorMessage = error.localizedDescription
        }
    }

    func tick() -> Bool {
        let previous = CourseScheduleCalculator.dateKey(now)
        now = clock.now
        let changed = previous != CourseScheduleCalculator.dateKey(now)
        if changed { closeActions() }
        return changed
    }

    func showActions(for id: Int) { openScheduleID = id }
    func closeActions() { openScheduleID = nil }

    func saveSchedule(id: Int?, title: String, date: Date, time: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw TodayInputError.invalidTitle }
        let parts = time.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { throw TodayInputError.invalidTime }
        if let id, snapshot?.schedules.contains(where: { $0.id == id }) != true {
            throw TodayInputError.missingSchedule
        }
        let nextID = (snapshot?.schedules.map(\.id).filter { $0 < 0 }.min() ?? 0) - 1
        try repository.saveSchedule(CustomSchedule(id: id ?? nextID, title: name,
                                                   date: CourseScheduleCalculator.dateKey(date), time: time))
        snapshot = try repository.cached()
        closeActions()
    }

    func deleteSchedule(id: Int) throws {
        try repository.deleteSchedule(id: id)
        snapshot = try repository.cached()
        closeActions()
    }

    func setWallpaper(_ data: Data) throws {
        try wallpaperStore.save(data)
        wallpaperData = data
    }

    func removeWallpaper() throws {
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
