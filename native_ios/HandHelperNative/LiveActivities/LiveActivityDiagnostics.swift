import ActivityKit
import Foundation
import OSLog
import SwiftUI

struct LiveActivityDiagnosticSnapshot {
    var systemEnabled = false
    var appEnabled = false
    var verified = false
    var foreground = false
    var candidateCount = 0
    var selected = "无"
    var activities: [String] = []
}

@MainActor
final class LiveActivityDiagnostics: ObservableObject {
    @Published private(set) var snapshot = LiveActivityDiagnosticSnapshot()
    @Published private(set) var lastOutcome = "尚未尝试启动实时活动"
    private let logger = Logger(subsystem: "com.zhangzh.hangassistant.native.dev", category: "LiveActivity")

    func update(_ snapshot: LiveActivityDiagnosticSnapshot) {
        self.snapshot = snapshot
    }

    func record(_ message: String, outcome: Bool = false) {
        if outcome { lastOutcome = message }
        #if DEBUG
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        logger.debug("[LiveActivity] t=\(stamp, privacy: .public) \(message, privacy: .public)")
        #endif
    }

    func recordFailure(_ error: Error, operation: String) {
        let value = error as NSError
        let description = "\(operation) failed type=\(type(of: error)) domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription)"
        lastOutcome = description
        #if DEBUG
        logger.error("[LiveActivity] \(description, privacy: .public)")
        #endif
    }
}
