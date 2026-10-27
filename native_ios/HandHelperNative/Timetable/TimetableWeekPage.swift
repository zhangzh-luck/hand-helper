import SwiftUI

/// A complete horizontal page: its dates stay above its own vertical grid.
struct TimetableWeekPage<Header: View, Grid: View>: View {
    let projection: WeeklyTimetableProjection
    let periodCount: Int
    let dynamicScale: CGFloat
    let bottomPadding: CGFloat
    let header: (WeeklyTimetableProjection, TimetableGridMetrics) -> Header
    let grid: (WeeklyTimetableProjection, TimetableGridMetrics) -> Grid
    let showUnplaced: ([UnplacedCourse]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !projection.unplaced.isEmpty {
                Button { showUnplaced(projection.unplaced) } label: {
                    Label("\(projection.unplaced.count) 门课程未能定位节次，点按查看",
                          systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            if projection.placements.isEmpty && projection.unplaced.isEmpty {
                Label("本周暂无课程", systemImage: "calendar.badge.checkmark")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            GeometryReader { geometry in
                let metrics = TimetableGridMetrics(viewportWidth: geometry.size.width,
                                                   rowCount: periodCount,
                                                   dynamicScale: dynamicScale)
                VStack(spacing: 0) {
                    header(projection, metrics)
                    ScrollView(.vertical) {
                        grid(projection, metrics)
                            .padding(.bottom, bottomPadding)
                    }
                }
                .frame(width: metrics.width)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}
