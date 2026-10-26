import SwiftUI

@MainActor
struct TimetableView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: TimetableViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var gridScale: CGFloat = 1
    @State private var selectedCourse: CourseSession?
    @State private var showingUnplaced = false
    @State private var conflictCourses: [CourseSession] = []
    @State private var showingConflicts = false

    init(state: AppState) {
        self.state = state
        let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                              account: state.verifiedAccount)
        _model = StateObject(wrappedValue: TimetableViewModel(state: state, repository: repository))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                if let projection = model.projection {
                    if !projection.unplaced.isEmpty { unplacedButton(projection) }
                    if projection.placements.isEmpty && projection.unplaced.isEmpty {
                        Label("本周暂无课程", systemImage: "calendar.badge.checkmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    if model.periods.isEmpty {
                        ContentUnavailableView("节次尚未设置", systemImage: "clock.badge.questionmark",
                                               description: Text("请在时间设置中配置课程节次。"))
                    } else {
                        GeometryReader { geometry in
                            let metrics = TimetableGridMetrics(viewportWidth: geometry.size.width,
                                                               rowCount: model.periods.count,
                                                               dynamicScale: gridScale)
                            ScrollView(.horizontal) {
                                VStack(spacing: 0) {
                                    dateHeader(projection, metrics: metrics)
                                    ScrollView(.vertical) {
                                        courseGrid(projection, metrics: metrics)
                                    }
                                }
                                .frame(width: metrics.width)
                            }
                        }
                    }
                } else if model.isLoading && model.snapshot == nil {
                    ProgressView("正在加载课程表")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(model.terms.isEmpty ? "暂无学期" : "暂无可显示的课程表",
                                           systemImage: "calendar",
                                           description: Text(model.errorMessage ?? "请选择学期，或检查学期第一周日期。"))
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("课程表")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshManually() }
                    } label: { Label("刷新课程", systemImage: "arrow.clockwise") }
                    .disabled(model.isLoading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.errorMessage, model.projection != nil {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(8)
                        .background(.regularMaterial)
                }
            }
            .sheet(item: $selectedCourse) { course in
                NavigationStack { TimetableCourseDetailView(course: course) }
            }
            .sheet(isPresented: $showingUnplaced) { unplacedList }
            .sheet(isPresented: $showingConflicts) { conflictList }
            .task { await model.updateIfNeeded() }
            .onChange(of: state.selectedTab) { _, tab in
                if tab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.courseDataInvalidation) { _, _ in
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.completedCourseRefresh) { _, _ in
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.authenticationRevision) { _, _ in
                selectedCourse = nil
                showingUnplaced = false
                showingConflicts = false
                model.clear()
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    ForEach(model.terms, id: \.id) { term in
                        Button(term.displayName) { model.selectTerm(term.id) }
                    }
                } label: {
                    Label(model.terms.first(where: { $0.id == model.selectedTermID })?.displayName ?? "选择学期",
                          systemImage: "chevron.down")
                        .lineLimit(1)
                }
                .disabled(model.terms.isEmpty)
                Spacer(minLength: 8)
                Text("第 \(model.selectedWeek) 周").font(.headline).monospacedDigit()
            }
            HStack(spacing: 18) {
                Button { changeWeek(-1) } label: { Label("上一周", systemImage: "chevron.left") }
                    .disabled(model.selectedWeek <= 1 || model.selectedTermID == nil)
                Spacer()
                Button("返回本周") { changeWeek(nil) }
                    .disabled(model.isCurrentWeek || model.selectedTermID == nil)
                Spacer()
                Button { changeWeek(1) } label: { Label("下一周", systemImage: "chevron.right") }
                    .disabled(model.selectedTermID == nil || model.selectedWeek >= 999)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func changeWeek(_ delta: Int?) {
        if reduceMotion {
            if let delta { model.moveWeek(delta) } else { model.jumpToCurrentWeek() }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                if let delta { model.moveWeek(delta) } else { model.jumpToCurrentWeek() }
            }
        }
    }

    private func dateHeader(_ projection: WeeklyTimetableProjection,
                            metrics: TimetableGridMetrics) -> some View {
        HStack(spacing: 0) {
            Text("节").frame(width: metrics.railWidth)
            ForEach(0..<7, id: \.self) { index in
                let date = projection.dates[index]
                VStack(spacing: 2) {
                    Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][index])
                        .font(.caption.weight(.medium))
                    Text(String(date.dropFirst(5))).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(date == CourseScheduleCalculator.dateKey(Date()) ? Color.accentColor : Color.primary)
                .frame(width: metrics.dayWidth, height: metrics.headerHeight)
                .background(date == CourseScheduleCalculator.dateKey(Date()) ?
                            Color.accentColor.opacity(0.12) : Color.clear)
            }
        }
        .frame(height: metrics.headerHeight)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func courseGrid(_ projection: WeeklyTimetableProjection,
                            metrics: TimetableGridMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<model.periods.count, id: \.self) { row in
                HStack(spacing: 0) {
                    Text("\(model.periods[row].periodNumber)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: metrics.railWidth)
                    ForEach(0..<7, id: \.self) { _ in
                        Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground))
                            .overlay(alignment: .bottom) { Divider() }
                            .overlay(alignment: .trailing) { Divider() }
                            .frame(width: metrics.dayWidth, height: metrics.rowHeight)
                    }
                }
                .offset(y: CGFloat(row) * metrics.rowHeight)
            }
            ForEach(projection.placements.indices, id: \.self) { index in
                let placement = projection.placements[index]
                if !metrics.shouldSummarize(placement) {
                    courseButton(placement.course, width: metrics.frame(for: placement).width - 4,
                                 height: metrics.frame(for: placement).height - 4)
                        .offset(x: metrics.frame(for: placement).minX + 2,
                                y: metrics.frame(for: placement).minY + 2)
                }
            }
            ForEach(compactGroups(projection, metrics: metrics), id: \.group) { group in
                Button {
                    conflictCourses = group.courses
                    showingConflicts = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(group.courses.count) 门冲突课程").font(.caption.bold())
                        Text("点按查看全部").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(5)
                    .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .frame(width: metrics.dayWidth - 4, height: group.height - 4)
                .offset(x: metrics.railWidth + CGFloat(group.weekday - 1) * metrics.dayWidth + 2,
                        y: CGFloat(group.startRow) * metrics.rowHeight + 2)
            }
        }
        .frame(width: metrics.width, height: metrics.bodyHeight, alignment: .topLeading)
    }

    private func courseButton(_ course: CourseSession, width: CGFloat, height: CGFloat) -> some View {
        Button { selectedCourse = course } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(course.name).font(.caption.weight(.semibold)).lineLimit(3)
                if let room = course.room, !room.isEmpty {
                    Text(room).font(.caption2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(5)
            .background(courseColor(course.name).opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .accessibilityLabel("\(course.name)，\(course.date)，\(course.room ?? "教室未提供")")
    }

    private func courseColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .purple, .green]
        let hash = name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private struct CompactGroup {
        let group: Int
        let weekday: Int
        let startRow: Int
        let height: CGFloat
        let courses: [CourseSession]
    }

    private func compactGroups(_ projection: WeeklyTimetableProjection,
                               metrics: TimetableGridMetrics) -> [CompactGroup] {
        let grouped = Dictionary(grouping: projection.placements.filter(metrics.shouldSummarize),
                                 by: \.conflictGroup)
        return grouped.keys.sorted().compactMap { key in
            guard let items = grouped[key], let first = items.first,
                  let end = items.map({ $0.startRow + $0.rowSpan }).max() else { return nil }
            return CompactGroup(group: key, weekday: first.weekday,
                                startRow: items.map(\.startRow).min() ?? first.startRow,
                                height: CGFloat(end - (items.map(\.startRow).min() ?? first.startRow)) * metrics.rowHeight,
                                courses: items.map(\.course))
        }
    }

    private func unplacedButton(_ projection: WeeklyTimetableProjection) -> some View {
        Button { showingUnplaced = true } label: {
            Label("\(projection.unplaced.count) 门课程未能定位节次，点按查看", systemImage: "exclamationmark.circle")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal).padding(.bottom, 8)
    }

    private var unplacedList: some View {
        NavigationStack {
            let items = model.projection?.unplaced ?? []
            List {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    NavigationLink {
                        TimetableCourseDetailView(course: item.course)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.course.name)
                            Text("\(item.course.date) · \(reason(item.reason))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("未定位课程")
            .toolbar { Button("完成") { showingUnplaced = false } }
        }
    }

    private var conflictList: some View {
        NavigationStack {
            List(conflictCourses) { course in
                NavigationLink {
                    TimetableCourseDetailView(course: course)
                } label: {
                    VStack(alignment: .leading) {
                        Text(course.name)
                        Text("\(course.date) · \(course.room ?? "教室未提供")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("同时段课程")
            .toolbar { Button("完成") { showingConflicts = false } }
        }
    }

    private func reason(_ reason: UnplacedCourseReason) -> String {
        switch reason {
        case .invalidSessionDate: "日期无效"
        case .invalidTimeRange: "时间范围无效"
        case .invalidExplicitPeriod: "节次无效"
        case .unmatchedStartTime: "开始时间未匹配节次"
        case .unmatchedEndTime: "结束时间未匹配节次"
        }
    }
}
