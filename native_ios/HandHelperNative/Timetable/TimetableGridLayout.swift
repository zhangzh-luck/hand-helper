import SwiftUI

/// Every grid layer uses these coordinates; only the outer scroll views move them.
struct TimetableGridMetrics {
    let railWidth: CGFloat
    let dayWidth: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let rowCount: Int

    init(viewportWidth: CGFloat, rowCount: Int, dynamicScale: CGFloat = 1) {
        railWidth = 38 * dynamicScale
        dayWidth = max(80 * dynamicScale, (viewportWidth - railWidth) / 7)
        rowHeight = max(76, 76 * dynamicScale)
        headerHeight = max(48, 48 * dynamicScale)
        self.rowCount = rowCount
    }

    var width: CGFloat { railWidth + 7 * dayWidth }
    var bodyHeight: CGFloat { CGFloat(rowCount) * rowHeight }

    func frame(for placement: WeeklyCoursePlacement) -> CGRect {
        let laneWidth = dayWidth / CGFloat(max(placement.laneCount, 1))
        return CGRect(x: railWidth + CGFloat(placement.weekday - 1) * dayWidth +
                          CGFloat(placement.laneIndex) * laneWidth,
                      y: CGFloat(placement.startRow) * rowHeight,
                      width: laneWidth,
                      height: CGFloat(placement.rowSpan) * rowHeight)
    }

    func shouldSummarize(_ placement: WeeklyCoursePlacement) -> Bool {
        dayWidth / CGFloat(max(placement.laneCount, 1)) < 56
    }
}
