import QuartzCore
import SwiftUI
import UIKit

/// The four anonymous destinations shared by the production app and Tab Lab.
enum TabSwitchDiagnosticTab: Int, CaseIterable, Equatable {
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

/// Anonymous milestones recorded only for an opted-in native tab transition.
enum TabSwitchDiagnosticStage: String, Equatable {
    case shouldSelect
    case didSelect
    case selectedTabAssignmentBegin
    case selectedTabAssignmentEnd
    case nativeContainerUpdateBegin
    case nativeContainerUpdateEnd
    case nativeApplyBegin
    case nativeApplyEnd
    case rootSelectedTabChangeBegin
    case rootSelectedTabChangeEnd
    case todaySelectedTabChangeBegin
    case todaySelectedTabChangeEnd
    case timetableSelectedTabChangeBegin
    case timetableSelectedTabChangeEnd
    case analysisSelectedTabChangeBegin
    case analysisSelectedTabChangeEnd
    case settingsSelectedTabChangeBegin
    case settingsSelectedTabChangeEnd
    case timetableTaskCreated
    case timetableTaskStarted
    case timetableUpdateBegin
    case timetableUpdateEnd
    case timetablePagerUpdateBegin
    case timetablePagerUpdateEnd
    case timetablePagerIdentityChanged
    case timetablePagerIdentityUnchanged
    case timetablePagerPageCreated
    case avatarPreviewClearSkipped
    case avatarPreviewCleared
    case todayDerivedCacheHit
    case todayDerivedRebuildBegin
    case todayDerivedRebuildEnd
}

struct TabSwitchDiagnosticEvent: Equatable {
    let stage: TabSwitchDiagnosticStage
    let offsetMilliseconds: Int
}

/// A privacy-preserving, opt-in measurement of one native tab transition.
struct TabSwitchDiagnosticReport: Identifiable, Equatable {
    let id: UUID
    let context: String
    let source: TabSwitchDiagnosticTab
    let destination: TabSwitchDiagnosticTab
    let tapToSelectionMilliseconds: Int?
    let tapToStateAppliedMilliseconds: Int?
    let tapToPageReadyMilliseconds: Int?
    let tapToFirstFrameCallbackMilliseconds: Int?
    let cacheState: CacheState?
    let sampleDurationMilliseconds: Int
    let frameCount: Int
    let maxFrameIntervalMilliseconds: Int?
    let p95FrameIntervalMilliseconds: Int?
    let intervalsOverTwentyMilliseconds: Int
    let displayMaximumFramesPerSecond: Int
    let interrupted: Bool
    let events: [TabSwitchDiagnosticEvent]

    enum CacheState: String, Equatable {
        case hit = "命中"
        case miss = "未命中"
        case retained = "已保留"
    }

    var summary: String {
        let selection = tapToSelectionMilliseconds.map { "选中 \($0)ms" } ?? "选中未记录"
        let state = tapToStateAppliedMilliseconds.map { "状态 \($0)ms" } ?? "状态未记录"
        let ready = tapToPageReadyMilliseconds.map { "页面 \($0)ms" } ?? "页面未记录"
        let firstFrame = tapToFirstFrameCallbackMilliseconds.map { "首帧 \($0)ms" } ?? "首帧未记录"
        let frame = maxFrameIntervalMilliseconds.map { "最大帧间隔 \($0)ms" } ?? "无有效帧间隔"
        return "[\(context)] \(source.title) → \(destination.title)：\(selection)，\(state)，\(ready)，\(firstFrame)，\(frame)\(interrupted ? "（被下一次切换中断）" : "")"
    }

    var exportLine: String {
        let selection = tapToSelectionMilliseconds.map(String.init) ?? "—"
        let state = tapToStateAppliedMilliseconds.map(String.init) ?? "—"
        let ready = tapToPageReadyMilliseconds.map(String.init) ?? "—"
        let firstFrame = tapToFirstFrameCallbackMilliseconds.map(String.init) ?? "—"
        let cache = cacheState?.rawValue ?? "—"
        let maximum = maxFrameIntervalMilliseconds.map(String.init) ?? "—"
        let p95 = p95FrameIntervalMilliseconds.map(String.init) ?? "—"
        let eventText = events.map { "\($0.stage.rawValue):\($0.offsetMilliseconds)" }.joined(separator: ",")
        return "switch_id=\(id.uuidString.prefix(8)) context=\(context) \(source.title)->\(destination.title) selection_ms=\(selection) state_ms=\(state) page_ms=\(ready) first_frame_ms=\(firstFrame) cache=\(cache) sample_ms=\(sampleDurationMilliseconds) frames=\(frameCount) max_frame_ms=\(maximum) p95_frame_ms=\(p95) over_20ms=\(intervalsOverTwentyMilliseconds) interrupted=\(interrupted) display_max_fps=\(displayMaximumFramesPerSecond) events=\(eventText)"
    }
}

final class TabSwitchDiagnostics: NSObject, ObservableObject {
    private static let enabledKey = "tab_switch_performance_diagnostics_enabled"
    private static let sampleDuration: TimeInterval = 0.7
    private static let maximumHistoryCount = 20
    private static let minimumFramesForP95 = 10
    private static let maximumEventsPerSample = 48

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSampling = false
    @Published private(set) var reports: [TabSwitchDiagnosticReport] = []

    private let preferences: UserDefaults
    private let now: () -> TimeInterval
    private let samplesFrames: Bool
    private var reportContext: String
    private var active: ActiveSample?
    private var displayLink: CADisplayLink?
    private var stopTask: Task<Void, Never>?

    init(preferences: UserDefaults = .standard, reportContext: String = "正式版",
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         samplesFrames: Bool = true) {
        self.preferences = preferences
        self.reportContext = reportContext
        self.now = now
        self.samplesFrames = samplesFrames
        isEnabled = preferences.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        preferences.set(enabled, forKey: Self.enabledKey)
        if !enabled { finishActiveSample(interrupted: true) }
    }

    func setReportContext(_ context: String) {
        guard reportContext != context else { return }
        finishActiveSample(interrupted: true)
        reportContext = context
    }

    /// Call before UIKit applies a changed tab selection.
    func beginSwitch(from source: TabSwitchDiagnosticTab, to destination: TabSwitchDiagnosticTab,
                     screen: UIScreen?) {
        guard isEnabled, source != destination else { return }
        finishActiveSample(interrupted: active != nil)
        let startedAt = now()
        active = ActiveSample(id: UUID(), context: reportContext, source: source, destination: destination, startedAt: startedAt,
                              displayMaximumFramesPerSecond: screen?.maximumFramesPerSecond ?? 0)
        record(.shouldSelect, for: destination)
        isSampling = true
        guard samplesFrames else { return }

        let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let id = active?.id
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.sampleDuration))
            guard !Task.isCancelled else { return }
            self?.finishActiveSample(id: id)
        }
    }

    func recordSelectionApplied(for tab: TabSwitchDiagnosticTab) {
        updateActive(for: tab) { sample in
            if sample.selectionAppliedAt == nil { sample.selectionAppliedAt = now() }
        }
        record(.didSelect, for: tab)
    }

    func recordStateApplied(for tab: TabSwitchDiagnosticTab) {
        updateActive(for: tab) { sample in
            if sample.stateAppliedAt == nil { sample.stateAppliedAt = now() }
        }
    }

    /// Records cache availability only; it does not claim that rendering is complete.
    func recordPageReady(for tab: TabSwitchDiagnosticTab, cacheState: TabSwitchDiagnosticReport.CacheState) {
        updateActive(for: tab) { sample in
            if sample.pageReadyAt == nil {
                sample.pageReadyAt = now()
                sample.cacheState = cacheState
            }
        }
    }

    /// Stores only an enum milestone and its offset from `shouldSelect`.
    func record(_ stage: TabSwitchDiagnosticStage, for tab: TabSwitchDiagnosticTab) {
        updateActive(for: tab) { sample in
            guard sample.events.count < Self.maximumEventsPerSample else { return }
            sample.events.append(TabSwitchDiagnosticEvent(stage: stage,
                offsetMilliseconds: milliseconds(from: sample.startedAt, to: now()) ?? 0))
        }
    }

    /// Records a privacy-safe milestone for whichever opted-in switch is active.
    /// This is used by retained source tabs whose work may occur after the destination changed.
    func recordForActiveSwitch(_ stage: TabSwitchDiagnosticStage) {
        guard var active else { return }
        guard active.events.count < Self.maximumEventsPerSample else { return }
        active.events.append(TabSwitchDiagnosticEvent(stage: stage,
            offsetMilliseconds: milliseconds(from: active.startedAt, to: now()) ?? 0))
        self.active = active
    }

    func clearReports() {
        finishActiveSample(interrupted: true)
        reports = []
    }

    var exportText: String {
        guard !reports.isEmpty else { return "Hand Helper Tab 切换性能诊断：暂无记录。" }
        return (["Hand Helper Tab 切换性能诊断（不含账号、课程、成绩或网络请求内容）"] +
                reports.map(\.exportLine)).joined(separator: "\n")
    }

    // Test hooks. Production timing comes from CADisplayLink.
    func recordFirstFrameForTesting() {
        guard var active else { return }
        if active.firstFrameCallbackAt == nil { active.firstFrameCallbackAt = now() }
        self.active = active
    }

    func recordFrameIntervalForTesting(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        active?.frameIntervals.append(interval)
    }

    func finishForTesting() { finishActiveSample() }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard var active else { return }
        if active.firstFrameCallbackAt == nil { active.firstFrameCallbackAt = now() }
        if let previousTimestamp = active.lastFrameTimestamp {
            let interval = link.timestamp - previousTimestamp
            if interval > 0 { active.frameIntervals.append(interval) }
        }
        active.lastFrameTimestamp = link.timestamp
        self.active = active
    }

    private func updateActive(for tab: TabSwitchDiagnosticTab, update: (inout ActiveSample) -> Void) {
        guard var active, active.destination == tab else { return }
        update(&active)
        self.active = active
    }

    private func finishActiveSample(id: UUID? = nil, interrupted: Bool = false) {
        guard let active, id == nil || active.id == id else { return }
        stopTask?.cancel()
        stopTask = nil
        displayLink?.invalidate()
        displayLink = nil
        self.active = nil
        isSampling = false

        let intervals = active.frameIntervals.sorted()
        let p95Index = intervals.count >= Self.minimumFramesForP95
            ? min(intervals.count - 1, max(0, Int(ceil(Double(intervals.count) * 0.95)) - 1))
            : nil
        let report = TabSwitchDiagnosticReport(
            id: active.id,
            context: active.context,
            source: active.source,
            destination: active.destination,
            tapToSelectionMilliseconds: milliseconds(from: active.startedAt, to: active.selectionAppliedAt),
            tapToStateAppliedMilliseconds: milliseconds(from: active.startedAt, to: active.stateAppliedAt),
            tapToPageReadyMilliseconds: milliseconds(from: active.startedAt, to: active.pageReadyAt),
            tapToFirstFrameCallbackMilliseconds: milliseconds(from: active.startedAt, to: active.firstFrameCallbackAt),
            cacheState: active.cacheState,
            sampleDurationMilliseconds: max(0, Int(((now() - active.startedAt) * 1_000).rounded())),
            frameCount: intervals.count,
            maxFrameIntervalMilliseconds: intervals.last.map(milliseconds),
            p95FrameIntervalMilliseconds: p95Index.map { milliseconds(intervals[$0]) },
            intervalsOverTwentyMilliseconds: intervals.filter { $0 > 0.020 }.count,
            displayMaximumFramesPerSecond: active.displayMaximumFramesPerSecond,
            interrupted: interrupted,
            events: active.events
        )
        reports.insert(report, at: 0)
        if reports.count > Self.maximumHistoryCount { reports.removeLast(reports.count - Self.maximumHistoryCount) }
    }

    private func milliseconds(from start: TimeInterval, to end: TimeInterval?) -> Int? {
        guard let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1_000).rounded()))
    }

    private struct ActiveSample {
        let id: UUID
        let context: String
        let source: TabSwitchDiagnosticTab
        let destination: TabSwitchDiagnosticTab
        let startedAt: TimeInterval
        let displayMaximumFramesPerSecond: Int
        var selectionAppliedAt: TimeInterval?
        var stateAppliedAt: TimeInterval?
        var pageReadyAt: TimeInterval?
        var firstFrameCallbackAt: TimeInterval?
        var cacheState: TabSwitchDiagnosticReport.CacheState?
        var lastFrameTimestamp: TimeInterval?
        var frameIntervals: [TimeInterval] = []
        var events: [TabSwitchDiagnosticEvent] = []
    }
}
