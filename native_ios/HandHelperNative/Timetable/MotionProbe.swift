#if MOTION_PROBE
import Foundation
import UIKit
import QuartzCore

/// Test-build-only, in-memory diagnostics. Never records course or account data.
@MainActor
final class MotionProbe: NSObject {
    static let shared = MotionProbe()
    private struct Sample {
        let id: Int
        let start: CFTimeInterval
        var animation: CFTimeInterval?
        var end: CFTimeInterval?
        var first: CFTimeInterval?
        var previous: CFTimeInterval?
        var intervals: [Double] = []
        var targets: [Double] = []
        var interrupted = false
    }
    private var current: Sample?
    private var samples: [Sample] = []
    private var link: CADisplayLink?
    private var nextID = 1
    private(set) var enabled = false

    func setEnabled(_ value: Bool) {
        if !value { finish(interrupted: true) }
        enabled = value
    }

    func clear() { finish(interrupted: true); samples.removeAll(); nextID = 1 }

    func event(_ name: String) {
        guard enabled else { return }
        switch name {
        case "course tapped", "tap":
            finish(interrupted: true)
            current = Sample(id: nextID, start: CACurrentMediaTime())
            nextID += 1
            let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link = display
            display.add(to: .main, forMode: .common)
        case "opening start", "start":
            guard current != nil else { return }
            current?.animation = CACurrentMediaTime()
        case "opening complete", "complete":
            finish(interrupted: false)
        case "closing start", "cancel":
            finish(interrupted: true)
        default: break
        }
    }

    @objc private func tick(_ display: CADisplayLink) {
        guard var sample = current else { return }
        let now = CACurrentMediaTime()
        if sample.first == nil { sample.first = now }
        if let previous = sample.previous, sample.intervals.count < 240 {
            let gap = (display.timestamp - previous) * 1000
            let target = (display.targetTimestamp - display.timestamp) * 1000
            if gap > 0, target > 0 { sample.intervals.append(gap); sample.targets.append(target) }
        }
        sample.previous = display.timestamp
        current = sample
    }

    private func finish(interrupted: Bool) {
        link?.invalidate()
        link = nil
        guard var sample = current else { return }
        sample.end = CACurrentMediaTime()
        sample.interrupted = interrupted
        if samples.count == 100 { samples.removeFirst() }
        samples.append(sample)
        current = nil
    }

    func report(engine: String) -> String {
        var lines = ["Hand Helper Motion Probe v1", "engine=\(engine)",
                     "clock=CADisplayLink/CACurrentMediaTime; frames=callback intervals, not screen presentation",
                     "tap=Flutter platform-channel arrival for Flutter; native handler for Swift",
                     "samples=\(samples.count); active=\(current != nil); max_refresh=\(UIScreen.main.maximumFramesPerSecond)",
                     "low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled); reduce_motion=\(UIAccessibility.isReduceMotionEnabled)"]
        for sample in samples {
            let intervals = sample.intervals
            let first = sample.first.map { ($0 - sample.start) * 1000 }
            let start = sample.animation.map { ($0 - sample.start) * 1000 }
            let end = sample.end.map { ($0 - sample.start) * 1000 }
            let long = zip(intervals, sample.targets).filter { $0.0 > $0.1 * 1.5 }.count
            func number(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "n/a" }
            let sorted = intervals.sorted()
            let p95: Double? = sorted.count >= 10 ? sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] : nil
            lines.append("id=\(sample.id) interrupted=\(sample.interrupted) start_ms=\(number(start)) first_ms=\(number(first)) end_ms=\(number(end)) frames=\(intervals.count) max_ms=\(number(intervals.max())) p95_ms=\(number(p95)) long=\(long) target_min_ms=\(number(sample.targets.min())) target_max_ms=\(number(sample.targets.max()))")
        }
        return lines.joined(separator: "\n")
    }
}

import SwiftUI

struct MotionProbePanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = MotionProbe.shared.enabled
    @State private var copied = false
    var body: some View {
        NavigationStack {
            Form {
                Toggle("开启采样", isOn: Binding(
                    get: { enabled },
                    set: { enabled = $0; MotionProbe.shared.setEnabled($0) }))
                Text("开启后关闭此面板，反复打开并关闭课程详情；仅记录动画时间，不记录课程或账号。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("复制报告") {
                    UIPasteboard.general.string = MotionProbe.shared.report(engine: "Swift")
                    copied = true
                }
                Button("清空记录", role: .destructive) { MotionProbe.shared.clear() }
                if copied { Text("报告已复制").foregroundStyle(.secondary) }
            }
            .navigationTitle("课程动画测试")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
#endif
