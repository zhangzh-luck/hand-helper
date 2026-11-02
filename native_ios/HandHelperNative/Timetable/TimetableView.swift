import SwiftUI
import UIKit

enum TimetableWallpaperStyle {
    static func showsPhoto(hasImage: Bool, reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        hasImage && !reduceTransparency && !increasedContrast
    }

    static func scrimOpacity(dark: Bool) -> Double { dark ? 0.34 : 0.18 }
    static func cellOpacity(hasPhoto: Bool) -> Double { hasPhoto ? 0.12 : 1 }
    static func cardOpacity(hasPhoto: Bool) -> Double { hasPhoto ? 0.78 : 1 }
    static func railOpacity(hasPhoto: Bool, dark: Bool) -> Double {
        guard hasPhoto else { return 1 }
        return dark ? 0.30 : 0.26
    }
}

@MainActor
struct TimetableView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var detail: TimetableCourseDetailCoordinator
    private let deleteConfirmation: DestructiveConfirmationCoordinator
    @StateObject private var model: TimetableViewModel
    @StateObject private var emptyCellSelection = TimetableEmptyCellSelectionCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var gridScale: CGFloat = 1
    @State private var showingUnplaced = false
    @State private var unplacedCourses: [UnplacedCourse] = []
    @State private var conflictCourses: [CourseSession] = []
    @State private var showingConflicts = false
    @State private var editingManualCourse: ManualCourseOperationRoute?
    @State private var deletingManualCourse: ManualCourseOperationRoute?
    @State private var pendingListManualAction: TimetableManualCourseActionRequest?
    @State private var manualCourseError: String?
    @State private var wallpaperImage: UIImage?
    @State private var wallpaperTask: Task<Void, Never>?
    @State private var wallpaperGeneration = 0
    @State private var wallpaperError: String?

    init(state: AppState, detail: TimetableCourseDetailCoordinator? = nil,
         deleteConfirmation: DestructiveConfirmationCoordinator? = nil) {
        self.state = state
        self.detail = detail ?? TimetableCourseDetailCoordinator()
        self.deleteConfirmation = deleteConfirmation ?? DestructiveConfirmationCoordinator()
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
                                               reduceMotion: reduceMotion,
                                                onTransitionStateChange: { busy in
                                                    TimetableAddCourseDiagnostics.record(
                                                        busy ? "pager_busy" : "pager_idle",
                                                        operationID: emptyCellSelection.selectionOperationID)
                                                    detail.setPagerBusy(busy)
                                                }) { projection in
                                TimetableWeekPage(emptyCellSelection: emptyCellSelection,
                                                  projection: projection,
                                                  periodCount: model.periods.count,
                                                  dynamicScale: gridScale,
                                                  bottomPadding: viewport.safeAreaInsets.bottom + 12,
                                                  header: { dateHeader($0, metrics: $1) },
                                                   grid: { courseGrid($0, metrics: $1, selectedCell: $2) },
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
            .sheet(isPresented: $showingUnplaced, onDismiss: presentPendingListManualAction) { unplacedList }
            .sheet(isPresented: $showingConflicts, onDismiss: presentPendingListManualAction) { conflictList }
            .sheet(item: Binding(get: { emptyCellSelection.route },
                                 set: { if $0 == nil { emptyCellSelection.dismissRoute(reason: "sheet_closed") } }),
                   onDismiss: { emptyCellSelection.sheetDidDismiss() }) { route in
                let _ = TimetableAddCourseDiagnostics.record("T3_sheet_content_created",
                    operationID: route.operationID, startedAt: route.tappedAt)
                ManualCourseEditorView(cell: route.cell, periods: model.periods) { draft in
                    try model.addManualCourse(draft, from: route.cell)
                }
                .onAppear {
                    TimetableAddCourseDiagnostics.record("T4_sheet_onAppear",
                        operationID: route.operationID, startedAt: route.tappedAt)
                }
                .onDisappear {
                    TimetableAddCourseDiagnostics.record("sheet_onDisappear",
                        operationID: route.operationID, startedAt: route.tappedAt)
                }
            }
            .sheet(item: $editingManualCourse) { route in
                ManualCourseEditorView(rule: route.rule, periods: model.periods) { draft in
                    try model.updateManualCourse(draft, for: route.request)
                }
            }
            .alert("无法操作课程", isPresented: Binding(get: { manualCourseError != nil },
                                                set: { if !$0 { manualCourseError = nil } })) {
                Button("好", role: .cancel) { manualCourseError = nil }
            } message: {
                Text(manualCourseError ?? "请重试。")
            }
            .task {
                reloadWallpaper()
                await model.updateIfNeeded()
            }
            .onChange(of: state.selectedTab) { _, tab in
                if tab != .timetable {
                    emptyCellSelection.clear(reason: "tab_changed")
                    emptyCellSelection.dismissRoute(reason: "tab_changed")
                    editingManualCourse = nil
                    deletingManualCourse = nil
                    pendingListManualAction = nil
                    clearManualConfirmation()
                }
                if tab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.localManualCourseChange) { _, change in
                guard let change,
                      (try? state.requireCurrentAccount(revision: change.authenticationRevision)) == change.owner else { return }
                model.loadCached()
            }
            .onChange(of: state.courseDataInvalidation) { _, _ in
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.completedCourseRefresh) { _, _ in
                if state.selectedTab == .timetable { Task { await model.updateIfNeeded() } }
            }
            .onChange(of: state.timetableWallpaperVersion) { _, _ in reloadWallpaper() }
            .onChange(of: state.authenticationRevision) { _, _ in
                emptyCellSelection.clear(reason: "authentication_changed")
                emptyCellSelection.dismissRoute(reason: "authentication_changed")
                editingManualCourse = nil
                deletingManualCourse = nil
                pendingListManualAction = nil
                clearManualConfirmation()
                manualCourseError = nil
                detail.clear()
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
            .onChange(of: model.selectedTermID) { _, _ in
                emptyCellSelection.clear(reason: "term_changed")
                emptyCellSelection.dismissRoute(reason: "term_changed")
                editingManualCourse = nil
                deletingManualCourse = nil
                pendingListManualAction = nil
                clearManualConfirmation()
                detail.invalidate(termID: model.selectedTermID,
                                 snapshotRevision: model.snapshotRevision,
                                 authenticationRevision: state.authenticationRevision)
            }
            .onChange(of: model.snapshotRevision) { _, _ in
                emptyCellSelection.clear(reason: "snapshot_changed")
                emptyCellSelection.dismissRoute(reason: "snapshot_changed")
                editingManualCourse = nil
                deletingManualCourse = nil
                pendingListManualAction = nil
                clearManualConfirmation()
                detail.invalidate(termID: model.selectedTermID,
                                 snapshotRevision: model.snapshotRevision,
                                 authenticationRevision: state.authenticationRevision)
            }
            .onChange(of: model.selectedWeek) { _, _ in
                emptyCellSelection.clear(reason: "week_changed")
                emptyCellSelection.dismissRoute(reason: "week_changed")
                editingManualCourse = nil
                deletingManualCourse = nil
                pendingListManualAction = nil
                clearManualConfirmation()
            }
            .onChange(of: detail.readyAction?.id) { _, actionID in
                guard actionID != nil, let request = detail.takeReadyAction() else { return }
                if request.action == .delete {
                    do {
                        try model.deleteManualCourse(for: request)
                        detail.clear()
                    } catch {
                        detail.reportDeletionError(error.localizedDescription)
                    }
                } else {
                    presentManualAction(request)
                }
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
                            metrics: TimetableGridMetrics,
                            selectedCell: TimetableEmptyCellSelection?) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<model.periods.count, id: \.self) { row in
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemGroupedBackground)
                        .opacity(TimetableWallpaperStyle.railOpacity(hasPhoto: showsWallpaper,
                                                                     dark: colorScheme == .dark)))
                    .frame(width: metrics.railWidth, height: metrics.rowHeight)
                    .offset(y: metrics.rowOrigin(row))
                periodLabel(model.periods[row])
                    .frame(width: metrics.railWidth, height: metrics.rowHeight)
                    .offset(y: metrics.rowOrigin(row))
                ForEach(1...7, id: \.self) { day in
                    let cell = metrics.cellFrame(weekday: day, row: row)
                    let periodNumber = model.periods[row].periodNumber
                    let occupied = projection.placements.contains {
                        $0.weekday == day && row >= $0.startRow && row < $0.startRow + $0.rowSpan
                    }
                    let isSelected = selectedCell?.termID == projection.term.id &&
                        selectedCell?.week == projection.week && selectedCell?.weekday == day &&
                        selectedCell?.periodNumber == periodNumber &&
                        selectedCell?.snapshotRevision == model.snapshotRevision &&
                        selectedCell?.authenticationRevision == state.authenticationRevision
                    Button {
                        let operationID = UUID()
                        TimetableAddCourseDiagnostics.record("empty_cell_tapped",
                            operationID: operationID)
                        selectEmptyCell(projection: projection, weekday: day,
                                        periodNumber: periodNumber, operationID: operationID)
                    } label: {
                        Rectangle()
                            .fill(Color(uiColor: .secondarySystemGroupedBackground)
                                .opacity(TimetableWallpaperStyle.cellOpacity(hasPhoto: showsWallpaper)))
                            .overlay {
                                if isSelected { Color.accentColor.opacity(0.17) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(occupied)
                    .accessibilityLabel("\(projection.dates[day - 1])，第 \(periodNumber) 节，选择空白格")
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
                    if isSelected, let selectedCell {
                        let hitSide = min(44, min(cell.width - 2, cell.height - 2))
                        Button {
                            let tappedAt = TimetableAddCourseDiagnostics.now
                            TimetableAddCourseDiagnostics.record("T0_plus_button_tapped",
                                operationID: emptyCellSelection.selectionOperationID, startedAt: tappedAt)
                            openManualEditor(for: selectedCell, tappedAt: tappedAt)
                        } label: {
                            addCourseSymbol
                                .frame(width: hitSide, height: hitSide)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添加课程，\(projection.dates[day - 1])，第 \(periodNumber) 节")
                        .frame(width: hitSide, height: hitSide)
                        .offset(x: cell.midX - hitSide / 2, y: cell.midY - hitSide / 2)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
            }
            gridLines(metrics: metrics)
            ForEach(projection.placements.indices, id: \.self) { index in
                let placement = projection.placements[index]
                if !metrics.shouldSummarize(placement) {
                    let context = TimetableDetailContext(authenticationRevision: state.authenticationRevision,
                                                      termID: projection.term.id, week: projection.week,
                                                      snapshotRevision: model.snapshotRevision,
                                                      courseID: placement.course.id, placementIndex: index)
                    courseButton(placement.course, rowSpan: placement.rowSpan,
                                 width: metrics.frame(for: placement).width - 4,
                                   height: metrics.frame(for: placement).height - 4, context: context)
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

    @ViewBuilder
    private var addCourseSymbol: some View {
        let symbol = Image(systemName: "plus")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 30, height: 30)
        if reduceTransparency || contrast == .increased {
            symbol.background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
        } else if #available(iOS 26.0, *) {
            symbol.glassEffect(.regular.interactive(), in: Circle())
        } else {
            symbol.background(.regularMaterial, in: Circle())
        }
    }

    private func selectEmptyCell(projection: WeeklyTimetableProjection,
                                 weekday: Int, periodNumber: Int, operationID: UUID) {
        guard state.selectedTab == .timetable, state.canAccessPrivateData,
              !detail.isPresenting, !detail.pagerBusy, emptyCellSelection.route == nil,
              model.selectedWeek == projection.week, model.selectedTermID == projection.term.id,
              (1...20).contains(projection.week),
              let owner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else {
            TimetableAddCourseDiagnostics.record("cell_selection_rejected", operationID: operationID)
            return
        }
        let cell = TimetableEmptyCellSelection(owner: owner,
            authenticationRevision: state.authenticationRevision, termID: projection.term.id,
            week: projection.week, snapshotRevision: model.snapshotRevision,
            weekday: weekday, periodNumber: periodNumber)
        withAnimation(.easeOut(duration: 0.16)) {
            emptyCellSelection.select(cell, operationID: operationID)
        }
    }

    private func openManualEditor(for cell: TimetableEmptyCellSelection, tappedAt: TimeInterval) {
        TimetableAddCourseDiagnostics.record("openManualEditor_entered",
            operationID: emptyCellSelection.selectionOperationID, startedAt: tappedAt)
        let context = TimetableEmptyCellSelectionCoordinator.OpeningContext(
            tabActive: state.selectedTab == .timetable,
            detailPresenting: detail.isPresenting,
            pagerBusy: detail.pagerBusy,
            termID: model.selectedTermID,
            week: model.selectedWeek,
            snapshotRevision: model.snapshotRevision,
            verifiedOwner: try? state.requireCurrentAccount(revision: cell.authenticationRevision))
        _ = emptyCellSelection.open(cell, context: context, tappedAt: tappedAt)
    }

    private func periodLabel(_ period: PeriodInfo) -> some View {
        VStack(spacing: 1) {
            Text("\(period.periodNumber)").font(.caption.weight(.bold))
            Text(TimetablePeriodLabel.safeTime(period.startTime)).font(.caption2).lineLimit(1)
            Text(TimetablePeriodLabel.safeTime(period.endTime)).font(.caption2).lineLimit(1)
        }
        .foregroundStyle(showsWallpaper ? Color.primary : Color.secondary)
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
                              width: CGFloat, height: CGFloat,
                              context: TimetableDetailContext) -> some View {
        let policy = TimetableCardContentPolicy(rowSpan: rowSpan)
        return Button {
            guard state.selectedTab == .timetable, state.canAccessPrivateData,
                   model.selectedWeek == context.week, model.selectedTermID == context.termID,
                   model.snapshotRevision == context.snapshotRevision,
                   (try? state.requireCurrentAccount(revision: context.authenticationRevision)) != nil else { return }
            if detail.open(course: course, context: context, color: courseColor(course.name),
                           editableManualCourse: model.editableManualCourse(for: course, context: context)) {
                emptyCellSelection.clear(reason: "course_detail_opened")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name).font(.caption.weight(.semibold))
                    .lineLimit(policy.titleLines)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if policy.showsRoom, let room = course.room, !room.isEmpty {
                    Text(room).font(.caption2)
                        .foregroundStyle(contrast == .increased ? Color.primary : Color.primary.opacity(0.82))
                        .lineLimit(policy.roomLines)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                        .layoutPriority(0.5)
                }
                if policy.showsTeacher, let teacher = course.teacher, !teacher.isEmpty {
                    Text(teacher).font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                        listCourseDetail(item.course)
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
                    listCourseDetail(course)
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

    private func listCourseDetail(_ course: CourseSession) -> TimetableCourseDetailView {
        let context = TimetableDetailContext(authenticationRevision: state.authenticationRevision,
            termID: model.selectedTermID ?? -1, week: model.selectedWeek,
            snapshotRevision: model.snapshotRevision, courseID: course.id, placementIndex: -1)
        let canManage = model.editableManualCourse(for: course, context: context) != nil
        return TimetableCourseDetailView(course: course,
            onEdit: canManage ? { queueListManualAction(.edit, course: course, context: context) } : nil,
            onDelete: canManage ? { queueListManualAction(.delete, course: course, context: context) } : nil)
    }

    private func queueListManualAction(_ action: TimetableManualCourseAction,
                                       course: CourseSession, context: TimetableDetailContext) {
        guard let identity = model.editableManualCourse(for: course, context: context) else {
            manualCourseError = "课程表或账号已变化，请重新打开课程详情。"
            return
        }
        pendingListManualAction = TimetableManualCourseActionRequest(action: action,
            identity: identity, context: context)
        showingConflicts = false
        showingUnplaced = false
    }

    private func presentPendingListManualAction() {
        guard let request = pendingListManualAction else { return }
        pendingListManualAction = nil
        presentManualAction(request)
    }

    private func presentManualAction(_ request: TimetableManualCourseActionRequest) {
        guard let rule = model.manualRule(for: request) else {
            manualCourseError = "课程表或账号已变化，请重新打开课程详情。"
            return
        }
        let route = ManualCourseOperationRoute(rule: rule, request: request)
        switch request.action {
        case .edit: editingManualCourse = route
        case .delete:
            deletingManualCourse = route
            if !deleteConfirmation.present(.manualCourse, confirm: {
                guard deletingManualCourse?.id == route.id else { return }
                deletingManualCourse = nil
                do { try model.deleteManualCourse(for: route.request) }
                catch { manualCourseError = error.localizedDescription }
            }, cancel: {
                if deletingManualCourse?.id == route.id { deletingManualCourse = nil }
            }) {
                deletingManualCourse = nil
            }
        }
    }

    private func clearManualConfirmation() {
        if deleteConfirmation.request?.kind == .manualCourse { deleteConfirmation.clear() }
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
