import SwiftUI
import UIKit

enum TimetableWallpaperStyle {
    static func showsPhoto(hasImage: Bool, reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        hasImage && !reduceTransparency && !increasedContrast
    }

    static func scrimOpacity(dark: Bool) -> Double { dark ? 0.34 : 0.18 }
    static func cellOpacity(hasPhoto: Bool) -> Double { hasPhoto ? 0.12 : 1 }
    static func cardOpacity(hasPhoto: Bool) -> Double { hasPhoto ? 0.78 : 1 }
}

@MainActor
struct TimetableView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: TimetableViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var gridScale: CGFloat = 1
    @State private var selectedCourse: CourseSession?
    @State private var showingUnplaced = false
    @State private var unplacedCourses: [UnplacedCourse] = []
    @State private var conflictCourses: [CourseSession] = []
    @State private var showingConflicts = false
    @State private var wallpaperImage: UIImage?
    @State private var wallpaperTask: Task<Void, Never>?
    @State private var wallpaperGeneration = 0
    @State private var wallpaperError: String?

    init(state: AppState) {
        self.state = state
        let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                              account: state.verifiedAccount)
        _model = StateObject(wrappedValue: TimetableViewModel(state: state, repository: repository))
    }

    private var showsWallpaper: Bool {
        TimetableWallpaperStyle.showsPhoto(hasImage: wallpaperImage != nil,
                                           reduceTransparency: reduceTransparency,
                                           increasedContrast: contrast == .increased)
    }

    private func reloadWallpaper() {
        wallpaperTask?.cancel()
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        guard state.canAccessPrivateData else {
            wallpaperImage = nil
            wallpaperError = nil
            return
        }
        do {
            let revision = state.authenticationRevision
            let data = try WallpaperStore(session: state.sessionStore,
                                          account: state.verifiedAccount,
                                          kind: .timetable).load()
            wallpaperError = nil
            guard let data else {
                wallpaperImage = nil
                return
            }
            wallpaperTask = Task {
                do {
                    let decoded = try await TimetableWallpaperImage.displayImage(data)
                    guard !Task.isCancelled, generation == wallpaperGeneration,
                          (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                    wallpaperImage = UIImage(cgImage: decoded)
                } catch {
                    guard !Task.isCancelled, generation == wallpaperGeneration else { return }
                    wallpaperImage = nil
                    wallpaperError = "课表壁纸无法读取：\(error.localizedDescription)"
                }
            }
        } catch {
            wallpaperImage = nil
            wallpaperError = "课表壁纸无法读取：\(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var pageBackground: some View {
        ZStack {
            if showsWallpaper, let wallpaperImage {
                GeometryReader { geometry in
                    Image(uiImage: wallpaperImage)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(colorScheme == .dark
                                 ? Color.black.opacity(TimetableWallpaperStyle.scrimOpacity(dark: true))
                                 : Color.white.opacity(TimetableWallpaperStyle.scrimOpacity(dark: false)))
                }
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(false)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                VStack(spacing: 0) {
                    controls
                    if let error = model.errorMessage ?? wallpaperError, model.projection != nil {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.regularMaterial)
                    }
                    if model.projection != nil {
                        if model.periods.isEmpty {
                            ContentUnavailableView("节次尚未设置", systemImage: "clock.badge.questionmark",
                                                   description: Text("请在时间设置中配置课程节次。"))
                        } else {
                            TimetableWeekPager(model: model,
                                               authenticationRevision: state.authenticationRevision,
                                               renderRevision: state.timetableWallpaperVersion,
                                               wallpaperVisible: showsWallpaper,
                                               layoutScale: gridScale,
                                               reduceMotion: reduceMotion) { projection in
                                TimetableWeekPage(projection: projection,
                                                  periodCount: model.periods.count,
                                                  dynamicScale: gridScale,
                                                  bottomPadding: viewport.safeAreaInsets.bottom + 12,
                                                  header: { dateHeader($0, metrics: $1) },
                                                  grid: { courseGrid($0, metrics: $1) },
                                                  showUnplaced: { courses in
                                                      unplacedCourses = courses
                                                      showingUnplaced = true
                                                  })
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
                .background { pageBackground }
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedCourse) { course in
                NavigationStack { TimetableCourseDetailView(course: course) }
            }
            .sheet(isPresented: $showingUnplaced) { unplacedList }
            .sheet(isPresented: $showingConflicts) { conflictList }
            .task {
                reloadWallpaper()
                await model.updateIfNeeded()
            }
            .onChange(of: state.selectedTab) { _, tab in
                if tab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.courseDataInvalidation) { _, _ in
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.completedCourseRefresh) { _, _ in
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.timetableWallpaperVersion) { _, _ in reloadWallpaper() }
            .onChange(of: state.authenticationRevision) { _, _ in
                selectedCourse = nil
                showingUnplaced = false
                unplacedCourses = []
                showingConflicts = false
                model.clear()
                wallpaperTask?.cancel()
                wallpaperGeneration += 1
                wallpaperImage = nil
                wallpaperError = nil
                reloadWallpaper()
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(model.terms, id: \.id) { term in
                    Button(term.displayName) { model.selectTerm(term.id) }
                }
                Divider()
                Button {
                    Task { await model.refreshManually() }
                } label: {
                    Label("刷新课程", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 2) {
                        Text("第 \(model.selectedWeek) 周").font(.headline).monospacedDigit()
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    Text(model.terms.first(where: { $0.id == model.selectedTermID })?.displayName ?? "选择学期")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { changeWeek(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("上一周")
                .disabled(model.selectedWeek <= 1 || model.selectedTermID == nil)
            Button("今天") { changeWeek(nil) }
                .font(.subheadline.weight(.medium)).lineLimit(1)
                .disabled(model.isCurrentWeek || model.selectedTermID == nil)
            Button { changeWeek(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("下一周")
                .disabled(model.selectedTermID == nil || model.selectedWeek >= 999)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(showsWallpaper ? 0.82 : 1))
    }

    private func changeWeek(_ delta: Int?) {
        if let delta { model.moveWeek(delta) } else { model.jumpToCurrentWeek() }
    }

    @ViewBuilder
    private func dateHeader(_ projection: WeeklyTimetableProjection,
                            metrics: TimetableGridMetrics) -> some View {
        let header = HStack(spacing: 0) {
            Text(TimetableDateLabel.month(projection.dates.first ?? ""))
                .font(.caption2.weight(.semibold))
                .frame(width: metrics.railWidth)
            ForEach(0..<7, id: \.self) { index in
                let date = projection.dates[index]
                VStack(spacing: 2) {
                    Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][index])
                        .font(.caption2.weight(.medium))
                    Text(TimetableDateLabel.day(date, previous: index == 0 ? nil : projection.dates[index - 1]))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 2).padding(.vertical, 3)
                        .background(date == CourseScheduleCalculator.dateKey(Date()) ?
                                    Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(date == CourseScheduleCalculator.dateKey(Date()) ? Color.white : Color.primary)
                }
                .frame(width: metrics.dayWidth(index + 1), height: metrics.headerHeight)
                .clipped()
                .accessibilityLabel("\(["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"][index])，\(date)")
            }
        }
        .frame(width: metrics.width, height: metrics.headerHeight)

        if reduceTransparency || contrast == .increased {
            header.background(Color(uiColor: .secondarySystemGroupedBackground))
        } else if #available(iOS 26.0, *) {
            header.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            header.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func courseGrid(_ projection: WeeklyTimetableProjection,
                            metrics: TimetableGridMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<model.periods.count, id: \.self) { row in
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(showsWallpaper ? 0.82 : 1))
                    .frame(width: metrics.railWidth, height: metrics.rowHeight)
                    .offset(y: metrics.rowOrigin(row))
                periodLabel(model.periods[row])
                    .frame(width: metrics.railWidth, height: metrics.rowHeight)
                    .offset(y: metrics.rowOrigin(row))
                ForEach(1...7, id: \.self) { day in
                    let cell = metrics.cellFrame(weekday: day, row: row)
                    Rectangle()
                        .fill(Color(uiColor: .secondarySystemGroupedBackground)
                            .opacity(TimetableWallpaperStyle.cellOpacity(hasPhoto: showsWallpaper)))
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: cell.minX, y: cell.minY)
                }
            }
            gridLines(metrics: metrics)
            ForEach(projection.placements.indices, id: \.self) { index in
                let placement = projection.placements[index]
                if !metrics.shouldSummarize(placement) {
                    courseButton(placement.course, rowSpan: placement.rowSpan,
                                 width: metrics.frame(for: placement).width - 4,
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
                    .background(Color.orange.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.7), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .frame(width: metrics.dayWidth(group.weekday) - 4, height: group.height - 4)
                .offset(x: metrics.dayOrigin(group.weekday) + 2,
                        y: metrics.rowOrigin(group.startRow) + 2)
            }
        }
        .frame(width: metrics.width, height: metrics.bodyHeight, alignment: .topLeading)
    }

    private func periodLabel(_ period: PeriodInfo) -> some View {
        VStack(spacing: 1) {
            Text("\(period.periodNumber)").font(.caption.weight(.bold))
            Text(TimetablePeriodLabel.safeTime(period.startTime)).font(.caption2).lineLimit(1)
            Text(TimetablePeriodLabel.safeTime(period.endTime)).font(.caption2).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("第 \(period.periodNumber) 节，\(TimetablePeriodLabel.safeTime(period.startTime)) 至 \(TimetablePeriodLabel.safeTime(period.endTime))")
    }

    private func gridLines(metrics: TimetableGridMetrics) -> some View {
        Path { path in
            for x in metrics.verticalBoundaries {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: metrics.bodyHeight))
            }
            for y in metrics.horizontalBoundaries {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: metrics.width, y: y))
            }
        }
        .stroke(Color.primary.opacity(showsWallpaper ? 0.28 : 0.15), lineWidth: 0.5)
        .frame(width: metrics.width, height: metrics.bodyHeight)
        .allowsHitTesting(false)
    }

    private func courseButton(_ course: CourseSession, rowSpan: Int,
                              width: CGFloat, height: CGFloat) -> some View {
        let policy = TimetableCardContentPolicy(rowSpan: rowSpan)
        return Button { selectedCourse = course } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name).font(.caption2.weight(.bold))
                    .lineLimit(policy.titleLines).truncationMode(.tail)
                if policy.showsRoom, let room = course.room, !room.isEmpty {
                    Text(room).font(.caption2).lineLimit(2).truncationMode(.tail)
                }
                if policy.showsTeacher, let teacher = course.teacher, !teacher.isEmpty {
                    Spacer(minLength: 0)
                    Text(teacher).font(.caption2).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(3)
            .background(courseColor(course.name).opacity(showsWallpaper ? 0.36 : 0.28), in: RoundedRectangle(cornerRadius: 8))
            .background(Color(uiColor: .secondarySystemGroupedBackground)
                            .opacity(TimetableWallpaperStyle.cardOpacity(hasPhoto: showsWallpaper)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(courseColor(course.name).opacity(showsWallpaper ? 0.7 : 0.55), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(course.name)，\(course.date)，\(course.room ?? "教室未提供")，\(course.teacher ?? "教师未提供")")
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

    private var unplacedList: some View {
        NavigationStack {
            let items = unplacedCourses
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
