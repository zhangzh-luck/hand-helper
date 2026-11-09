import QuartzCore
import SwiftUI
import UIKit

/// A privacy-preserving, opt-in measurement of a single native tab transition.
///
/// Reports contain only tab identifiers and monotonic timings. They intentionally
/// never contain account, course, grade, network, or authentication information.
struct TabSwitchDiagnosticReport: Identifiable, Equatable {
    let id: UUID
    let source: AppTab
    let destination: AppTab
    let tapToSelectionMilliseconds: Int?
    let tapToStateAppliedMilliseconds: Int?
    let tapToPageReadyMilliseconds: Int?
    let cacheState: CacheState?
    let sampleDurationMilliseconds: Int
    let frameCount: Int
    let maxFrameIntervalMilliseconds: Int?
    let p95FrameIntervalMilliseconds: Int?
    let intervalsOverTwentyMilliseconds: Int
    let displayMaximumFramesPerSecond: Int

    enum CacheState: String, Equatable {
        case hit = "命中"
        case miss = "未命中"
        case retained = "已保留"
    }

    var summary: String {
        let selection = tapToSelectionMilliseconds.map { "选中 \($0)ms" } ?? "选中未记录"
        let state = tapToStateAppliedMilliseconds.map { "状态 \($0)ms" } ?? "状态未记录"
        let ready = tapToPageReadyMilliseconds.map { "页面 \($0)ms" } ?? "页面未记录"
        let frame = maxFrameIntervalMilliseconds.map { "最大帧间隔 \($0)ms" } ?? "无帧样本"
        return "\(source.title) → \(destination.title)：\(selection)，\(state)，\(ready)，\(frame)"
    }

    var exportLine: String {
        let selection = tapToSelectionMilliseconds.map(String.init) ?? "—"
        let state = tapToStateAppliedMilliseconds.map(String.init) ?? "—"
        let ready = tapToPageReadyMilliseconds.map(String.init) ?? "—"
        let cache = cacheState?.rawValue ?? "—"
        let maximum = maxFrameIntervalMilliseconds.map(String.init) ?? "—"
        let p95 = p95FrameIntervalMilliseconds.map(String.init) ?? "—"
        return "\(source.title)->\(destination.title) selection_ms=\(selection) state_ms=\(state) page_ms=\(ready) cache=\(cache) sample_ms=\(sampleDurationMilliseconds) frames=\(frameCount) max_frame_ms=\(maximum) p95_frame_ms=\(p95) over_20ms=\(intervalsOverTwentyMilliseconds) display_max_fps=\(displayMaximumFramesPerSecond)"
    }
}

final class TabSwitchDiagnostics: NSObject, ObservableObject {
    private static let enabledKey = "tab_switch_performance_diagnostics_enabled"
    private static let sampleDuration: TimeInterval = 0.7
    private static let maximumHistoryCount = 20

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSampling = false
    @Published private(set) var reports: [TabSwitchDiagnosticReport] = []

    private let preferences: UserDefaults
    private let now: () -> TimeInterval
    private let samplesFrames: Bool
    private var active: ActiveSample?
    private var displayLink: CADisplayLink?
    private var stopTask: Task<Void, Never>?

    init(preferences: UserDefaults = .standard,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         samplesFrames: Bool = true) {
        self.preferences = preferences
        self.now = now
        self.samplesFrames = samplesFrames
        isEnabled = preferences.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        preferences.set(enabled, forKey: Self.enabledKey)
        if !enabled { finishActiveSample() }
    }

    /// Call immediately before UIKit selects a different tab item.
    func beginSwitch(from source: AppTab, to destination: AppTab, screen: UIScreen?) {
        guard isEnabled, source != destination else { return }
        finishActiveSample()
        active = ActiveSample(id: UUID(), source: source, destination: destination, startedAt: now(),
                              displayMaximumFramesPerSecond: screen?.maximumFramesPerSecond ?? 0)
        isSampling = true
        guard samplesFrames else { return }

        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        let id = active?.id
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.sampleDuration))
            guard !Task.isCancelled else { return }
            self?.finishActiveSample(id: id)
        }
    }

    func recordSelectionApplied(for tab: AppTab) {
        updateActive(for: tab) { sample in
            if sample.selectionAppliedAt == nil { sample.selectionAppliedAt = now() }
        }
    }

    func recordStateApplied(for tab: AppTab) {
        updateActive(for: tab) { sample in
            if sample.stateAppliedAt == nil { sample.stateAppliedAt = now() }
        }
    }

    /// Records only cache availability, never cache contents or an account identifier.
    func recordPageReady(for tab: AppTab, cacheState: TabSwitchDiagnosticReport.CacheState) {
        updateActive(for: tab) { sample in
            if sample.pageReadyAt == nil {
                sample.pageReadyAt = now()
                sample.cacheState = cacheState
            }
        }
    }

    func clearReports() {
        finishActiveSample()
        reports = []
    }

    var exportText: String {
        guard !reports.isEmpty else { return "Hand Helper Tab 切换性能诊断：暂无记录。" }
        return (["Hand Helper Tab 切换性能诊断（不含账号、课程、成绩或网络请求内容）"] +
                reports.map(\.exportLine)).joined(separator: "\n")
    }

    // Internal for unit tests. Production samples use the display-link callback below.
    func recordFrameIntervalForTesting(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        active?.frameIntervals.append(interval)
    }

    func finishForTesting() {
        finishActiveSample()
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard var active else { return }
        if let previousTimestamp = active.lastFrameTimestamp {
            let interval = link.timestamp - previousTimestamp
            if interval > 0 { active.frameIntervals.append(interval) }
        }
        active.lastFrameTimestamp = link.timestamp
        self.active = active
    }

    private func updateActive(for tab: AppTab, update: (inout ActiveSample) -> Void) {
        guard var active, active.destination == tab else { return }
        update(&active)
        self.active = active
    }

    private func finishActiveSample(id: UUID? = nil) {
        guard let active, id == nil || active.id == id else { return }
        stopTask?.cancel()
        stopTask = nil
        displayLink?.invalidate()
        displayLink = nil
        self.active = nil
        isSampling = false

        let intervals = active.frameIntervals.sorted()
        let p95Index = intervals.isEmpty ? nil : min(intervals.count - 1,
                                                       max(0, Int(ceil(Double(intervals.count) * 0.95)) - 1))
        let report = TabSwitchDiagnosticReport(
            id: active.id,
            source: active.source,
            destination: active.destination,
            tapToSelectionMilliseconds: milliseconds(from: active.startedAt, to: active.selectionAppliedAt),
            tapToStateAppliedMilliseconds: milliseconds(from: active.startedAt, to: active.stateAppliedAt),
            tapToPageReadyMilliseconds: milliseconds(from: active.startedAt, to: active.pageReadyAt),
            cacheState: active.cacheState,
            sampleDurationMilliseconds: max(0, Int(((now() - active.startedAt) * 1_000).rounded())),
            frameCount: intervals.count,
            maxFrameIntervalMilliseconds: intervals.last.map(milliseconds),
            p95FrameIntervalMilliseconds: p95Index.map { milliseconds(intervals[$0]) },
            intervalsOverTwentyMilliseconds: intervals.filter { $0 > 0.020 }.count,
            displayMaximumFramesPerSecond: active.displayMaximumFramesPerSecond
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
        let source: AppTab
        let destination: AppTab
        let startedAt: TimeInterval
        let displayMaximumFramesPerSecond: Int
        var selectionAppliedAt: TimeInterval?
        var stateAppliedAt: TimeInterval?
        var pageReadyAt: TimeInterval?
        var cacheState: TabSwitchDiagnosticReport.CacheState?
        var lastFrameTimestamp: TimeInterval?
        var frameIntervals: [TimeInterval] = []
    }
}
