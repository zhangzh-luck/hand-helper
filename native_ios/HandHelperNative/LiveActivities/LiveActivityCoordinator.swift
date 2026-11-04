import ActivityKit
import Foundation

struct LiveActivityRecord: Equatable {
    let systemID: String
    let itemID: String
    let state: HandHelperActivityAttributes.ContentState
    var status: ActivityState = .active
    var isCurrent: Bool { status == .active || status == .stale }
}

@MainActor
protocol LiveActivityDriving {
    var isAvailable: Bool { get }
    func records() -> [LiveActivityRecord]
    func start(item: CurrentActivityItem) async throws -> String
    func update(systemID: String, item: CurrentActivityItem) async
    func end(systemID: String) async
}

@MainActor
struct ActivityKitDriver: LiveActivityDriving {
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func records() -> [LiveActivityRecord] {
        Activity<HandHelperActivityAttributes>.activities.map {
            LiveActivityRecord(systemID: $0.id, itemID: $0.attributes.itemID,
                               state: $0.content.state, status: $0.activityState)
        }
    }

    func start(item: CurrentActivityItem) async throws -> String {
        let activity = try Activity<HandHelperActivityAttributes>.request(
            attributes: HandHelperActivityAttributes(itemID: item.id),
            content: ActivityContent(state: item.activityState, staleDate: item.end), pushType: nil)
        return activity.id
    }

    func update(systemID: String, item: CurrentActivityItem) async {
        guard let activity = Activity<HandHelperActivityAttributes>.activities.first(where: { $0.id == systemID }) else { return }
        await activity.update(ActivityContent(state: item.activityState, staleDate: item.end))
    }

    func end(systemID: String) async {
        guard let activity = Activity<HandHelperActivityAttributes>.activities.first(where: { $0.id == systemID }) else { return }
        await activity.end(ActivityContent(state: activity.content.state, staleDate: nil),
                           dismissalPolicy: .immediate)
    }
}

private extension CurrentActivityItem {
    var activityState: HandHelperActivityAttributes.ContentState {
        .init(kind: kind.rawValue, title: title, start: start, end: end, location: location)
    }
}

enum LiveActivityReconciliation {
    enum Action: Equatable {
        case end(String)
        case start(CurrentActivityItem)
        case update(String, CurrentActivityItem)
    }

    static func plan(records: [LiveActivityRecord], item: CurrentActivityItem?,
                     allowed: Bool, foreground: Bool) -> [Action] {
        let currentRecords = records.filter(\.isCurrent)
        guard allowed, let item else { return currentRecords.map { .end($0.systemID) } }
        let matching = currentRecords.first { $0.itemID == item.id }
        var actions = currentRecords.filter { $0.systemID != matching?.systemID }.map { Action.end($0.systemID) }
        if let matching {
            if matching.state != item.activityState { actions.append(.update(matching.systemID, item)) }
        } else if foreground {
            actions.append(.start(item))
        }
        return actions
    }
}

@MainActor
enum LiveActivityActionExecutor {
    static func execute(_ actions: [LiveActivityReconciliation.Action],
                        driver: any LiveActivityDriving, diagnostics: LiveActivityDiagnostics,
                        version: Int, reason: String, selected: String, foreground: Bool,
                        isCurrent: @MainActor () -> Bool) async {
        for action in actions {
            guard isCurrent() else { return }
            switch action {
            case .end(let id):
                diagnostics.record("end id=\(id) sync=\(version) source=\(reason) selected=\(selected)")
                await driver.end(systemID: id)
                diagnostics.record("ended id=\(id) remaining=\(driver.records().count)")
            case .update(let id, let item):
                diagnostics.record("update id=\(id) sync=\(version) title=\(item.title)")
                await driver.update(systemID: id, item: item)
            case .start(let item):
                guard foreground else { continue }
                diagnostics.record("request begin sync=\(version) title=\(item.title) " +
                    "start=\(item.start) end=\(item.end)")
                do {
                    let id = try await driver.start(item: item)
                    let observed = driver.records()
                    diagnostics.record("request succeeded id=\(id) " +
                        "activities=\(observed.count) states=\(observed.map { String(describing: $0.status) })",
                        outcome: true)
                } catch {
                    diagnostics.recordFailure(error, operation: "request")
                }
            }
        }
    }
}

@MainActor
final class LiveActivityCoordinator {
    let diagnostics = LiveActivityDiagnostics()
    private let driver: any LiveActivityDriving
    private var running = false
    private var requested = false
    private var generation = 0
    private var foreground = false
    private var boundaryTask: Task<Void, Never>?
    private var lastReason = "startup"
    #if DEBUG
    private var diagnosticItem: CurrentActivityItem?
    #endif

    init(driver: (any LiveActivityDriving)? = nil) {
        self.driver = driver ?? ActivityKitDriver()
    }

    func synchronize(state: AppState, foreground: Bool, reason: String = "unspecified") {
        self.foreground = foreground
        generation += 1
        lastReason = reason
        diagnostics.record("sync id=\(generation) reason=\(reason) foreground=\(foreground)")
        requested = true
        boundaryTask?.cancel()
        boundaryTask = nil
        guard !running else { return }
        running = true
        Task { await drain(state: state) }
    }

    private func drain(state: AppState) async {
        while requested {
            requested = false
            let version = generation
            let reason = lastReason
            let now = Date()
            let owner = try? state.requireCurrentAccount(revision: state.authenticationRevision)
            let systemEnabled = driver.isAvailable
            let allowed = state.liveActivitiesEnabled && systemEnabled && owner != nil
            var snapshot = CourseSnapshot.empty
            var schedules: [CustomSchedule] = []
            var item: CurrentActivityItem?
            var candidateCount = 0
            if let owner {
                let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                                      account: state.verifiedAccount)
                do { snapshot = try repository.cached() ?? .empty }
                catch { diagnostics.recordFailure(error, operation: "cache_read") }
                do { schedules = try repository.allLocalSchedules() }
                catch { diagnostics.recordFailure(error, operation: "schedule_read") }
                let resolution = CurrentActivityResolver.resolve(snapshot: snapshot, schedules: schedules,
                                                                 owner: owner, at: now)
                candidateCount = resolution.candidateCount
                item = resolution.selected
            }
            #if DEBUG
            if let diagnosticItem, diagnosticItem.end > now, allowed { item = diagnosticItem }
            else if diagnosticItem != nil { self.diagnosticItem = nil }
            #endif
            let records = driver.records()
            let selected = item.map { "\($0.kind.rawValue) \($0.title) \($0.start)–\($0.end)" } ?? "无"
            diagnostics.update(LiveActivityDiagnosticSnapshot(systemEnabled: systemEnabled,
                appEnabled: state.liveActivitiesEnabled, verified: owner != nil, foreground: foreground,
                candidateCount: candidateCount, selected: selected,
                activities: records.map { "\($0.systemID) \($0.status)" }))
            diagnostics.record("evaluate id=\(version) appEnabled=\(state.liveActivitiesEnabled) " +
                "areActivitiesEnabled=\(systemEnabled) verified=\(owner != nil) " +
                "candidates=\(candidateCount) selected=\(selected) activities=\(records.count)")
            let actions = LiveActivityReconciliation.plan(records: records, item: item,
                                                          allowed: allowed, foreground: foreground)
            await LiveActivityActionExecutor.execute(actions, driver: driver, diagnostics: diagnostics,
                version: version, reason: reason, selected: selected, foreground: foreground,
                isCurrent: { version == self.generation })
            if version == generation {
                var observed = diagnostics.snapshot
                observed.activities = driver.records().map { "\($0.systemID) \($0.status)" }
                diagnostics.update(observed)
            }
            guard version == generation, foreground else { continue }
            var next = CurrentActivityResolver.nextBoundary(snapshot: snapshot, schedules: schedules, after: now)
            #if DEBUG
            if let diagnosticItem, diagnosticItem.end > now {
                next = min(next ?? diagnosticItem.end, diagnosticItem.end)
            }
            #endif
            if let next {
                let seconds = min(max(next.timeIntervalSinceNow, 0.1), 86_400)
                boundaryTask = Task { [weak self, weak state] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled, let self, let state else { return }
                    self.synchronize(state: state, foreground: true, reason: "time_boundary")
                }
            }
        }
        running = false
    }

    #if DEBUG
    func startDiagnosticTest(state: AppState, foreground: Bool,
                             duration: LiveActivityDiagnosticDuration = .tenMinutes,
                             scenario: LiveActivityDiagnosticScenario = .standard) {
        guard foreground, state.liveActivitiesEnabled, driver.isAvailable,
              (try? state.requireCurrentAccount(revision: state.authenticationRevision)) != nil else {
            diagnostics.record("test rejected: foreground, switch, system permission or verified account missing", outcome: true)
            return
        }
        let now = Date()
        diagnosticItem = CurrentActivityItem(
            id: "diagnostic:\(UUID().uuidString)", kind: .course,
            title: scenario.title, start: now, end: now.addingTimeInterval(duration.rawValue),
            location: scenario.location)
        synchronize(state: state, foreground: true, reason: "diagnostic_start")
    }

    func endDiagnosticTest(state: AppState, foreground: Bool) {
        diagnosticItem = nil
        synchronize(state: state, foreground: foreground, reason: "diagnostic_end")
    }
    #endif
}
