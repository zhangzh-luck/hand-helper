import SwiftUI

/// The header, rail, grid, and cards share a seven-day coordinate system.
struct TimetableGridMetrics {
    let viewportWidth: CGFloat
    let railWidth: CGFloat
    let dayWidth: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let rowCount: Int

    init(viewportWidth: CGFloat, rowCount: Int, dynamicScale: CGFloat = 1) {
        self.viewportWidth = max(0, viewportWidth)
        railWidth = min(self.viewportWidth, min(44, max(36, viewportWidth * 0.11)))
        dayWidth = max(0, (self.viewportWidth - railWidth) / 7)
        rowHeight = max(76, 76 * dynamicScale)
        headerHeight = max(48, 48 * dynamicScale)
        self.rowCount = rowCount
    }

    var width: CGFloat { viewportWidth }
    var bodyHeight: CGFloat { CGFloat(rowCount) * rowHeight }

    func rowOrigin(_ row: Int) -> CGFloat { CGFloat(row) * rowHeight }

    func dayOrigin(_ weekday: Int) -> CGFloat {
        railWidth + CGFloat(weekday - 1) * dayWidth
    }

    func dayWidth(_ weekday: Int) -> CGFloat {
        weekday == 7 ? max(0, viewportWidth - dayOrigin(weekday)) : dayWidth
    }

    func cellFrame(weekday: Int, row: Int) -> CGRect {
        CGRect(x: dayOrigin(weekday), y: rowOrigin(row),
               width: dayWidth(weekday), height: rowHeight)
    }

    var verticalBoundaries: [CGFloat] {
        [0, railWidth] + (1...7).map { dayOrigin($0) + dayWidth($0) }
    }

    var horizontalBoundaries: [CGFloat] {
        (0...rowCount).map(rowOrigin)
    }

    func frame(for placement: WeeklyCoursePlacement) -> CGRect {
        let laneWidth = dayWidth(placement.weekday) / CGFloat(max(placement.laneCount, 1))
        return CGRect(x: dayOrigin(placement.weekday) +
                          CGFloat(placement.laneIndex) * laneWidth,
                      y: rowOrigin(placement.startRow),
                      width: laneWidth,
                      height: CGFloat(placement.rowSpan) * rowHeight)
    }

    func shouldSummarize(_ placement: WeeklyCoursePlacement) -> Bool {
        placement.laneCount > 1 &&
            dayWidth(placement.weekday) / CGFloat(placement.laneCount) < 56
    }
}

enum TimetablePeriodLabel {
    static func safeTime(_ value: String) -> String {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return "—" }
        return value
    }
}

enum TimetableDateLabel {
    static func month(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]) else { return "节" }
        return "\(month)月"
    }

    static func day(_ key: String, previous: String?) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return "—" }
        if let previous, previous.prefix(7) != key.prefix(7) { return "\(month)/\(day)" }
        return "\(day)"
    }
}

struct TimetableCardContentPolicy {
    let titleLines: Int
    let roomLines: Int
    let showsRoom: Bool
    let showsTeacher: Bool

    init(rowSpan: Int) {
        let expanded = rowSpan > 1
        titleLines = expanded ? 6 : 3
        roomLines = expanded ? 2 : 1
        showsRoom = true
        showsTeacher = expanded
    }
}
