import Foundation

/// Pure countdown math shared by the H–L Widget diagnostics and XCTest.
/// The output is deliberately ASCII `H:MM`: it has no localized unit labels
/// and rounds any positive fraction of a minute upward.
enum CompactMinuteCountdown {
    static func display(at date: Date, endingAt end: Date) -> String {
        display(remaining: end.timeIntervalSince(date))
    }

    static func display(remaining: TimeInterval) -> String {
        let totalMinutes = Int(ceil(max(0, remaining) / 60))
        let minutes = totalMinutes % 60
        return "\(totalMinutes / 60):\(minutes < 10 ? "0" : "")\(minutes)"
    }

    /// The next strictly later input at which the ceiling-minute display changes.
    static func nextChange(after input: Date, endingAt end: Date) -> Date? {
        guard input < end else { return nil }
        let remaining = end.timeIntervalSince(input)
        let displayedMinutes = max(1, Int(ceil(remaining / 60)))
        return end.addingTimeInterval(-Double(displayedMinutes - 1) * 60)
    }

    /// The preceding strictly earlier input at which the display changed.
    static func previousChange(before input: Date, endingAt end: Date) -> Date? {
        guard input <= end else { return end }
        let remaining = max(0, end.timeIntervalSince(input))
        let displayedMinutes = Int(ceil(remaining / 60))
        let boundary = end.addingTimeInterval(-Double(displayedMinutes) * 60)
        return boundary < input ? boundary : boundary.addingTimeInterval(-60)
    }
}
