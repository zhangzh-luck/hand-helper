import Foundation

enum TimetableAddCourseDiagnostics {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func record(_ event: String, operationID: UUID?, startedAt: TimeInterval? = nil) {
        #if DEBUG
        let uptime = now
        let elapsed = startedAt.map { String(format: "%.3f", uptime - $0) } ?? "-"
        let identifier = operationID.map { String($0.uuidString.prefix(8)) } ?? "-"
        print("[TimetableAdd] op=\(identifier) uptime=\(String(format: "%.3f", uptime)) elapsed=\(elapsed) event=\(event)")
        #endif
    }
}
