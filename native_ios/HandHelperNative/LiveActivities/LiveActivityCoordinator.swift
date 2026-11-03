import ActivityKit
import Foundation

struct LiveActivityRecord: Equatable {
    let systemID: String
    let itemID: String
    let state: HandHelperActivityAttributes.ContentState
}

@MainActor
protocol LiveActivityDriving {
    var isAvailable: Bool { get }
    func records() -> [LiveActivityRecord]
    func start(item: CurrentActivityItem) async throws
    func update(systemID: String, item: CurrentActivityItem) async
    func end(systemID: String) async
}

@MainActor
struct ActivityKitDriver: LiveActivityDriving {
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func records() -> [LiveActivityRecord] {
        Activity<HandHelperActivityAttributes>.activities.map {
            LiveActivityRecord(systemID: $0.id, itemID: $0.attributes.itemID, state: $0.content.state)
        }
    }

    func start(item: CurrentActivityItem) async throws {
        _ = try Activity<HandHelperActivityAttributes>.request(
            attributes: HandHelperActivityAttributes(itemID: item.id),
            content: ActivityContent(state: item.activityState, staleDate: item.end), pushType: nil)
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
        guard allowed, let item else { return records.map { .end($0.systemID) } }
        let matching = records.first { $0.itemID == item.id }
        var actions = records.filter { $0.systemID != matching?.systemID }.map { Action.end($0.systemID) }
        if let matching {
            if matching.state != item.activityState { actions.append(.update(matching.systemID, item)) }
        } else if foreground {
            actions.append(.start(item))
        }
        return actions
    }
}

@MainActor
final class LiveActivityCoordinator {
    private let driver: any LiveActivityDriving
    private var running = false
    private var requested = false
    private var generation = 0
    private var foreground = false
    private var boundaryTask: Task<Void, Never>?

    init(driver: any LiveActivityDriving = ActivityKitDriver()) {
        self.driver = driver
    }

    func synchronize(state: AppState, foreground: Bool) {
        self.foreground = foreground
        generation += 1
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
            let now = Date()
            let owner = try? state.requireCurrentAccount(revision: state.authenticationRevision)
            let allowed = state.liveActivitiesEnabled && driver.isAvailable && owner != nil
            var snapshot = CourseSnapshot.empty
            var schedules: [CustomSchedule] = []
            var item: CurrentActivityItem?
            if allowed, let owner {
                let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                                      account: state.verifiedAccount)
                snapshot = (try? repository.cached()) ?? .empty
                schedules = (try? repository.allLocalSchedules()) ?? []
                item = CurrentActivityResolver.current(snapshot: snapshot, schedules: schedules,
                                                       owner: owner, at: now)
            }
            let actions = LiveActivityReconciliation.plan(records: driver.records(), item: item,
                                                          allowed: allowed, foreground: foreground)
            for action in actions {
                guard version == generation else { break }
                switch action {
                case .end(let id): await driver.end(systemID: id)
                case .update(let id, let item): await driver.update(systemID: id, item: item)
                case .start(let item):
                    do { try await driver.start(item: item) }
                    catch { /* Live Activities can be disabled or at the system limit. */ }
                }
            }
            guard version == generation, foreground else { continue }
            let next = CurrentActivityResolver.nextBoundary(snapshot: snapshot, schedules: schedules, after: now)
            if let next {
                let seconds = min(max(next.timeIntervalSinceNow, 0.1), 86_400)
                boundaryTask = Task { [weak self, weak state] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled, let self, let state else { return }
                    self.synchronize(state: state, foreground: true)
                }
            }
        }
        running = false
    }
}
