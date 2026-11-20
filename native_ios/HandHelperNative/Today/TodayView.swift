import SwiftUI

enum TodayContentWidth {
    static let standard: CGFloat = 680
    static let wideMaximum: CGFloat = 1_100
    private static let wideSideSpace: CGFloat = 48

    static func maximum(for availableWidth: CGFloat, isIPad: Bool) -> CGFloat {
        guard isIPad, availableWidth.isFinite else { return standard }
        return min(wideMaximum, max(standard, availableWidth - wideSideSpace))
    }
}

enum TodayEntryLayout {
    static let minimumTwoColumnWidth: CGFloat = 700
    static let spacing: CGFloat = 12

    static func columnCount(width: CGFloat, viewport: CGSize, isIPad: Bool, usesLargeText: Bool) -> Int {
        guard isIPad, !usesLargeText, width.isFinite, width >= minimumTwoColumnWidth,
              viewport.width.isFinite, viewport.height.isFinite, viewport.height > 0,
              viewport.width > viewport.height else { return 1 }
        return 2
    }
}

enum TodayCarouselSelection {
    struct Item: Equatable {
        let id: String
        let start: Date?
        let isActiveCourse: Bool
    }

    static func initial(items: [Item], now: Date) -> String? {
        items.first(where: { $0.isActiveCourse })?.id
            ?? items.first(where: { $0.start.map { $0 > now } ?? false })?.id
            ?? items.last(where: { $0.start != nil })?.id
            ?? items.last?.id
    }

    static func reconcile(selected: String?, previous: [String], current: [String], fallback: String?) -> String? {
        guard !current.isEmpty else { return nil }
        if let selected, current.contains(selected) { return selected }
        if let selected, let index = previous.firstIndex(of: selected) {
            return current[min(index, current.count - 1)]
        }
        return fallback.flatMap { current.contains($0) ? $0 : nil } ?? current.first
    }
}

enum TodayTimeStatus: Equatable {
    case ongoing, upcoming, startedWithoutKnownEnd, ended, unknown

    static func evaluate(start: Date?, end: Date?, hasEnd: Bool, now: Date) -> Self {
        guard let start else { return .unknown }
        if hasEnd {
            guard let end, end > start else { return .unknown }
            if now < start { return .upcoming }
            return now < end ? .ongoing : .ended
        }
        return now < start ? .upcoming : .startedWithoutKnownEnd
    }
}

enum TodayCarouselFollowEvent {
    case horizontalUserDrag, returnToCurrent, newDay, programmaticPosition
}

enum TodayCarouselFollow {
    static func update(_ following: Bool, event: TodayCarouselFollowEvent) -> Bool {
        switch event {
        case .horizontalUserDrag: return false
        case .returnToCurrent, .newDay: return true
        case .programmaticPosition: return following
        }
    }
}

struct TodayCarouselItem: Equatable {
    let id: String
    let start: Date?
    let end: Date?
    let hasEnd: Bool

    func status(at now: Date) -> TodayTimeStatus {
        TodayTimeStatus.evaluate(start: start, end: end, hasEnd: hasEnd, now: now)
    }

    static func ordered(_ items: [Self]) -> [Self] {
        items.sorted { lhs, rhs in
            switch (lhs.start, rhs.start) {
            case let (a?, b?): return a == b ? lhs.id < rhs.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }

    static func target(_ items: [Self], now: Date) -> String? {
        let valid = items.filter { $0.status(at: now) != .unknown }
        return valid.first(where: { $0.status(at: now) == .ongoing })?.id
            ?? valid.first(where: { $0.status(at: now) == .upcoming })?.id
            ?? valid.last?.id ?? items.first?.id
    }
}

// Measures every card at its natural height and proposes the maximum to each.
struct TodayEqualHeightRow: Layout {
    let width: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: CGFloat(subviews.count) * width + CGFloat(max(0, subviews.count - 1)) * spacing,
                      height: max(106, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

@MainActor
struct TodayView: View {
    @ObservedObject private var state: AppState
    private let onAvatarPreview: @MainActor (TodayAvatarPreviewRoute) -> Void
    @ObservedObject private var avatarPreviewCoordinator: AvatarPreviewCoordinator
    @ObservedObject private var scheduleEditor: ScheduleEditorCoordinator
    private let deleteConfirmation: DestructiveConfirmationCoordinator
    @StateObject private var model: TodayViewModel
    @StateObject private var lifeModel: LifeDashboardModel
    @StateObject private var ledgerModel: LedgerViewModel
    @StateObject private var weatherModel = WeatherViewModel()
    @State private var ledgerOpen = false
    @State private var quickEntryOpen = false
    @State private var weatherCityOpen = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorContrast
    @ScaledMetric(relativeTo: .title) private var avatarDimension: CGFloat = 60
    @State private var pendingDelete: PendingScheduleDelete?
    @State private var localError: String?
    @State private var appliedCourseInvalidationSequence: Int?
    @State private var avatarSourceData: Data?
    @State private var avatarImage: UIImage?
    @State private var contentMaxWidth = TodayContentWidth.standard
    @State private var entryContentWidth: CGFloat = 0
    @State private var contentViewport: CGSize = .zero
    @State private var selectedEntryID: String?
    @State private var previousEntryIDs: [String] = []
    @State private var selectionDay: String?
    @State private var followsCurrent = true

    init(state: AppState, onAvatarPreview: @escaping @MainActor (TodayAvatarPreviewRoute) -> Void,
         avatarPreviewCoordinator: AvatarPreviewCoordinator,
         scheduleEditor: ScheduleEditorCoordinator,
         deleteConfirmation: DestructiveConfirmationCoordinator) {
        self.state = state
        self.onAvatarPreview = onAvatarPreview
        self.avatarPreviewCoordinator = avatarPreviewCoordinator
        self.scheduleEditor = scheduleEditor
        self.deleteConfirmation = deleteConfirmation
        let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                              account: state.verifiedAccount)
        let wallpaper = WallpaperStore(session: state.sessionStore, account: state.verifiedAccount)
        _model = StateObject(wrappedValue: TodayViewModel(repository: repository, wallpaperStore: wallpaper))
        _lifeModel = StateObject(wrappedValue: LifeDashboardModel(state: state))
        _ledgerModel = StateObject(wrappedValue: LedgerViewModel(state: state))
    }

    private var dark: Bool { colorScheme == .dark }
    private var mayShowLocalSchedules: Bool {
        state.canAccessPrivateData
    }
    private var displayName: String { state.currentProfile.resolvedDisplayName }
    private var avatarData: Data? { state.currentProfile.avatarData }
    private var canPreviewAvatar: Bool {
        state.canAccessPrivateData && avatarImage != nil
    }

    private func avatarPreviewRoute(sourceFrameInGlobal: CGRect) -> TodayAvatarPreviewRoute? {
        guard state.canAccessPrivateData, let avatarImage,
              sourceFrameInGlobal.width > 0, sourceFrameInGlobal.height > 0 else { return nil }
        return TodayAvatarPreviewRoute(image: avatarImage, revision: state.authenticationRevision,
                                       sourceFrameInGlobal: sourceFrameInGlobal)
    }
    private var entries: [TodayEntry] {
        let values = (state.canAccessPrivateData ? model.courses : []).map(TodayEntry.course) +
            (state.canAccessPrivateData ? model.schedules : []).map(TodayEntry.schedule)
        let ordered = TodayCarouselItem.ordered(values.map { $0.carouselItem })
        let byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { byID[$0.id] }
    }

    private var suggestedEntryID: String? {
        TodayCarouselItem.target(entries.map(\.carouselItem), now: model.now)
    }

    private var entryColumnCount: Int {
        UIDevice.current.userInterfaceIdiom == .pad && entryContentWidth >= 700 && dynamicTypeSize < .xxxLarge ? 2 : 1
    }

    var body: some View {
        NavigationStack {
            page
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $ledgerOpen) {
                    TabBarHiddenNavigationDestination(state: state, tab: .today) {
                        LedgerView(state: state, model: ledgerModel, didChange: refreshLifeDashboard)
                    }
                }
        }
        .sheet(isPresented: $quickEntryOpen) {
            LedgerEditorSheet(model: ledgerModel, transaction: nil, didChange: refreshLifeDashboard)
        }
    }

    private var page: some View {
        ZStack {
            TodayStyle.background.ignoresSafeArea()
            if !reduceTransparency, state.canAccessPrivateData,
               let image = model.wallpaperImage {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(TodayStyle.background.opacity(dark ? 0.48 : 0.62))
                }.ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                hero
                ScrollView {
                    LazyVStack(spacing: 12) {
                        VStack(spacing: 0) {
                            scheduleHeader.padding(.top, 18)
                            if state.canAccessPrivateData && model.hasCourseData && !model.courses.isEmpty {
                                statusCard
                                    .padding(.top, 5).padding(.bottom, 9)
                            }
                        }
                        if !state.canAccessPrivateData || !model.hasCourseData {
                            HStack(spacing: 12) {
                                Text(state.canAccessPrivateData && model.isLoading && model.errorMessage == nil
                                     ? "正在读取今日课程…" : courseMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if state.canAccessPrivateData {
                                    Button("重试") { Task { await refreshCourses() } }
                                }
                            }
                            .padding(.top, 12)
                        } else if let error = model.errorMessage {
                            HStack(alignment: .top, spacing: 12) {
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button("重试") { Task { await refreshCourses() } }
                            }
                        }
                        if !entries.isEmpty { scheduleCarousel }
                        else if TodayEmptyState.isConfirmed(identityValid: state.canAccessPrivateData,
                                    course: model.courseReadState, local: model.localReadState,
                                    day: CourseScheduleCalculator.dateKey(model.now), entryCount: entries.count) {
                            emptyScheduleCard
                        } else if state.canAccessPrivateData && model.errorMessage == nil && !model.isLoading && model.hasCourseData {
                            HStack {
                                Text(model.localReadState == .notRead ? "本机安排尚未读取" : "课程数据需要更新")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button("重试") { Task { await refreshCourses() } }
                            }
                        }
                        if state.canAccessPrivateData {
                            LifeDashboardView(model: lifeModel, onAdd: { quickEntryOpen = true },
                                              onLedger: { ledgerOpen = true },
                                              hasWallpaper: model.wallpaperImage != nil && !reduceTransparency)
                                .padding(.top, 12)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    entryContentWidth = width
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, 18)
            .padding(.top, 26)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            UIDevice.current.userInterfaceIdiom == .pad ? proxy.size : .zero
        } action: { size in
            contentViewport = size
            contentMaxWidth = TodayContentWidth.maximum(for: size.width,
                isIPad: UIDevice.current.userInterfaceIdiom == .pad)
        }
        .task {
            weatherModel.loadIfNeeded()
            reloadAvatarImageIfNeeded()
            model.load(allowPrivateCache: state.canAccessPrivateData, allowLocalSchedules: mayShowLocalSchedules)
            if state.canAccessPrivateData && state.selectedTab == .today { Task { await lifeModel.load() } }
            if state.canAccessPrivateData && state.selectedTab == .today { await refreshCourses() }
            while !Task.isCancelled {
                let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                let delay = 60 - remainder + 0.05
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                if scenePhase == .active && state.selectedTab == .today { weatherModel.loadIfNeeded() }
                let changed = model.tick(allowLocalSchedules: mayShowLocalSchedules)
                if changed && state.canAccessPrivateData {
                    if state.selectedTab == .today { Task { await lifeModel.load() } }
                    await refreshCourses()
                }
            }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            selectedEntryID = nil
            previousEntryIDs = []
            selectionDay = nil
            followsCurrent = TodayCarouselFollow.update(followsCurrent, event: .newDay)
            ledgerModel.clear()
            ledgerOpen = false
            quickEntryOpen = false
            lifeModel.clear()
            if state.canAccessPrivateData && state.selectedTab == .today { Task { await lifeModel.load() } }
            appliedCourseInvalidationSequence = nil
            pendingDelete = nil
            model.authenticationDidChange(allowPrivateCache: state.canAccessPrivateData,
                                          allowLocalSchedules: mayShowLocalSchedules)
            if state.canAccessPrivateData { Task { await refreshCourses() } }
        }
        .onChange(of: avatarData) { _, _ in
            reloadAvatarImageIfNeeded()
        }
        .onChange(of: state.wallpaperVersion) { _, _ in
            guard state.canAccessPrivateData else { return }
            do { try model.reloadWallpaper() }
            catch { localError = "本机壁纸无法读取：\(error.localizedDescription)" }
        }
        .onChange(of: state.courseDataInvalidation) { _, _ in
            if state.selectedTab == .today && pendingCourseInvalidation != nil {
                Task { await refreshCourses() }
            }
        }
        .onChange(of: state.localManualCourseChange) { _, change in
            guard let change,
                  (try? state.requireCurrentAccount(revision: change.authenticationRevision)) == change.owner else { return }
            model.load(allowPrivateCache: true, allowLocalSchedules: mayShowLocalSchedules, forceDiskRead: true)
        }
        .onChange(of: state.completedCourseRefresh) { _, marker in
            if state.selectedTab == .today && marker == pendingCourseInvalidation {
                Task { await refreshCourses() }
            }
        }
        .onChange(of: state.selectedTab) { _, tab in
            if tab == .today { weatherModel.loadIfNeeded() }
            if tab == .today && state.canAccessPrivateData { Task { await lifeModel.load() } }
            if tab == .today && state.canAccessPrivateData && pendingCourseInvalidation == nil {
                _ = model.restoreInMemoryIfAvailable(allowPrivateCache: true,
                                                      allowLocalSchedules: mayShowLocalSchedules)
                    ?? model.load(allowPrivateCache: true, allowLocalSchedules: mayShowLocalSchedules)
            }
            if tab == .today && pendingCourseInvalidation != nil {
                Task { await refreshCourses() }
            }
        }
        .onChange(of: entries.map(\.carouselItem), initial: true) { _, items in
            updateCarouselSelection(ids: items.map(\.id))
        }
        .onChange(of: CourseScheduleCalculator.dateKey(model.now)) { _, _ in
            selectedEntryID = nil
            previousEntryIDs = []
            selectionDay = nil
            followsCurrent = TodayCarouselFollow.update(followsCurrent, event: .newDay)
            updateCarouselSelection(ids: entries.map(\.id))
        }
        .onChange(of: model.now) { _, _ in
            if followsCurrent && state.selectedTab == .today {
                selectedEntryID = suggestedEntryID
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if state.selectedTab == .today { weatherModel.loadIfNeeded() }
                if state.selectedTab == .today && state.canAccessPrivateData { Task { await lifeModel.load() } }
                let changed = model.tick(allowLocalSchedules: mayShowLocalSchedules)
                if state.canAccessPrivateData && (changed || pendingCourseInvalidation != nil) {
                    Task { await refreshCourses() }
                }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("确定", role: .cancel) { localError = nil }
        } message: { Text(localError ?? "") }
    }

    private func updateCarouselSelection(ids: [String]) {
        let day = CourseScheduleCalculator.dateKey(model.now)
        if selectionDay != day {
            selectedEntryID = nil
            previousEntryIDs = []
            selectionDay = day
            followsCurrent = TodayCarouselFollow.update(followsCurrent, event: .newDay)
        }
        selectedEntryID = TodayCarouselSelection.reconcile(
            selected: selectedEntryID, previous: previousEntryIDs, current: ids,
            fallback: suggestedEntryID)
        if followsCurrent { selectedEntryID = suggestedEntryID }
        previousEntryIDs = ids
    }

    private var scheduleCarousel: some View {
        let width = max(1, entryContentWidth)
        let count = entryColumnCount
        let spacing = TodayEntryLayout.spacing
        let cardWidth = entries.count == 1 ? width :
            (count == 2 ? (width - spacing) / 2 : width * 0.9)
        return ScrollView(.horizontal) {
            TodayEqualHeightRow(width: cardWidth, spacing: spacing) {
                ForEach(entries) { entry in
                    entryCard(entry)
                        .frame(width: cardWidth)
                        .id(entry.id)
                }
            }
            .scrollTargetLayout()
            .padding(.trailing, entries.count > 1 ? max(0, width - cardWidth) : 0)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedEntryID)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
            if abs(value.translation.width) > abs(value.translation.height) {
                followsCurrent = TodayCarouselFollow.update(followsCurrent, event: .horizontalUserDrag)
            }
        })
    }

    private func refreshLifeDashboard() {
        Task { await lifeModel.load(force: true) }
    }

    @ViewBuilder
    private func entryCard(_ entry: TodayEntry) -> some View {
        switch entry {
        case .course(let course):
            CourseCardView(course: course, active: entry.carouselItem.status(at: model.now) == .ongoing,
                           hasWallpaper: model.wallpaperData != nil)
        case .schedule(let schedule):
            scheduleCard(schedule, revision: state.authenticationRevision)
        }
    }

    private func scheduleCard(_ schedule: CustomSchedule, revision: Int) -> some View {
        ScheduleCardView(schedule: schedule, hasWallpaper: model.wallpaperData != nil,
                         active: TodayEntry.schedule(schedule).carouselItem.status(at: model.now) == .ongoing,
                         onEdit: {
                             guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                             presentScheduleEditor(schedule: schedule, revision: revision)
                         },
                         onDelete: {
                             guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                             let pending = PendingScheduleDelete(schedule: schedule, revision: revision)
                             pendingDelete = pending
                             if !deleteConfirmation.present(.schedule, confirm: {
                                 guard state.selectedTab == .today,
                                       pendingDelete?.schedule.id == pending.schedule.id,
                                       pendingDelete?.revision == pending.revision else { return }
                                 pendingDelete = nil
                                 do {
                                     _ = try state.requireCurrentAccount(revision: pending.revision)
                                     try model.deleteSchedule(id: pending.schedule.id)
                                      try? state.localScheduleDidChange(revision: pending.revision)
                                 } catch { localError = error.localizedDescription }
                             }, cancel: {
                                 if pendingDelete?.schedule.id == pending.schedule.id {
                                     pendingDelete = nil
                                 }
                             }) {
                                 pendingDelete = nil
                             }
                         })
    }

    private var scheduleHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("今日安排")
                    .font(.title3.weight(.semibold))
                if entries.count > 1, let id = selectedEntryID,
                   let index = entries.firstIndex(where: { $0.id == id }) {
                    Text("\(index + 1) / \(entries.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("当前起始安排第 \(index + 1) 项，共 \(entries.count) 项")
                }
                if !followsCurrent, let target = suggestedEntryID, target != selectedEntryID {
                    Button("回到当前") {
                        followsCurrent = TodayCarouselFollow.update(followsCurrent, event: .returnToCurrent)
                        selectedEntryID = target
                    }
                    .font(.caption.weight(.medium))
                    .accessibilityHint("恢复自动跟随当前安排")
                }
            }
        }
        .padding(.horizontal, model.wallpaperImage != nil && !reduceTransparency ? 8 : 0)
        .padding(.vertical, model.wallpaperImage != nil && !reduceTransparency ? 4 : 0)
        .background {
            if model.wallpaperImage != nil && !reduceTransparency {
                if colorContrast == .increased {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
                }
            }
        }
    }

    @ViewBuilder
    private var scheduleHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                scheduleHeading
                if state.canAccessPrivateData { addScheduleButton }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    scheduleHeading.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    if state.canAccessPrivateData { addScheduleButton.fixedSize(horizontal: true, vertical: false) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    scheduleHeading
                    if state.canAccessPrivateData { addScheduleButton }
                }
            }
        }
    }

    private var emptyScheduleCard: some View {
        VStack(spacing: 6) {
            Text("今天暂无安排").font(.subheadline.weight(.semibold))
            Text("享受属于自己的空闲时间").font(.footnote).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 106)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if model.wallpaperImage != nil && !reduceTransparency && colorContrast != .increased {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var addScheduleButton: some View {
        let button = Button {
            presentScheduleEditor(schedule: nil, revision: state.authenticationRevision)
        } label: {
            Label("添加安排", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
        }
        .buttonBorderShape(.capsule)
        .disabled(!model.canEditSchedules)

        return Group {
            if #available(iOS 26.0, *) {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
    }

    private func presentScheduleEditor(schedule: CustomSchedule?, revision: Int) {
        guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
        scheduleEditor.present(schedule: schedule, now: model.now, revision: revision) { id, title, date, time, endTime in
            _ = try state.requireCurrentAccount(revision: revision)
            try model.saveSchedule(id: id, title: title, date: date, time: time, endTime: endTime)
            try? state.localScheduleDidChange(revision: revision)
        }
    }

    private var hero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    heroInformation
                    avatarButton
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    heroInformation
                        .frame(maxWidth: .infinity, alignment: .leading)
                    avatarButton
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TodayHeroSurface())
    }

    private var heroInformation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日 · \(greeting)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(dateLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            weatherLine
        }
    }

    private var weatherLine: some View {
        Button { weatherCityOpen = true } label: {
            if let weather = weatherModel.cache {
                let appearance = WeatherDescription.appearance(code: weather.reading.code, isDay: weather.reading.isDay == 1)
                Label("\(appearance.text) · \(Int(weather.reading.temperature.rounded()))°C · \(weather.city.name)",
                      systemImage: appearance.symbol)
                    .accessibilityLabel("\(appearance.text)，\(Int(weather.reading.temperature.rounded()))度，体感\(Int(weather.reading.apparentTemperature.rounded()))度，\(weather.city.name)，选择城市")
            } else {
                Label(weatherModel.loading ? "正在读取天气" : "选择城市查看天气", systemImage: "cloud")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .buttonStyle(.plain)
        .accessibilityHint("打开城市选择")
        .sheet(isPresented: $weatherCityOpen) { WeatherCityPickerView(model: weatherModel) }
    }

    private var avatarButton: some View {
        GeometryReader { geometry in
            Button {
                if let route = avatarPreviewRoute(sourceFrameInGlobal: geometry.frame(in: .global)) {
                    AppHaptics.trigger(.detailOpened)
                    onAvatarPreview(route)
                }
            } label: {
                Group {
                    if let image = avatarImage {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Text(displayName == "航的助手" ? "航" : String(displayName.suffix(1)))
                            .font(.title.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            // Preserve the button's layout and global GeometryReader frame while the
            // overlay owns the visible hero image.
            .opacity(avatarPreviewCoordinator.isSourceAvatarHidden ? 0 : 1)
            .disabled(!canPreviewAvatar)
            .accessibilityLabel(canPreviewAvatar ? "查看头像大图" : "尚未设置头像")
        }
        .frame(width: min(avatarDimension, 88), height: min(avatarDimension, 88))
    }

    private var courseMessage: String {
        switch state.authenticationStatus {
        case .signedOut: return state.credentialRemovalError ?? "登录后查看今日课程"
        case .verifying: return "正在验证登录状态…"
        case .offline: return "网络暂不可用，登录状态尚未验证"
        case .expired: return state.credentialRemovalError ?? "登录状态已失效，请重新登录"
        case .signedIn: return model.errorMessage ?? "课程数据尚未就绪"
        }
    }

    private var pendingCourseInvalidation: CourseDataInvalidation? {
        state.pendingCourseInvalidation(after: appliedCourseInvalidationSequence)
    }

    private func refreshCourses() async {
        let revision = state.authenticationRevision
        if let marker = pendingCourseInvalidation {
            if state.completedCourseRefresh == marker {
                model.load(allowPrivateCache: state.canAccessPrivateData,
                           allowLocalSchedules: mayShowLocalSchedules,
                           forceDiskRead: true)
                if model.snapshot != nil { appliedCourseInvalidationSequence = marker.sequence }
                return
            }
            let result = await model.refreshStrict(isCurrent: {
                state.canAccessPrivateData &&
                state.selectedTab == .today &&
                state.authenticationRevision == marker.authenticationRevision &&
                state.courseDataInvalidation == marker &&
                (try? state.requireCurrentAccount(revision: marker.authenticationRevision)) == marker.owner
            })
            guard revision == state.authenticationRevision else { return }
            if result.completed && state.courseDataInvalidation == marker {
                appliedCourseInvalidationSequence = marker.sequence
                state.acknowledgeCourseRefresh(marker)
                try? state.courseSnapshotDidChange(revision: revision)
            }
            if result.unauthorized && state.isAuthenticated && !state.isLoginSubmitting {
                state.handleUnauthorized()
            }
        } else {
            let unauthorized = await model.refresh(isCurrent: {
                state.selectedTab == .today && state.authenticationRevision == revision && state.canAccessPrivateData
            })
            guard revision == state.authenticationRevision else { return }
            if !unauthorized { try? state.courseSnapshotDidChange(revision: revision) }
            if unauthorized && state.isAuthenticated && !state.isLoginSubmitting {
                state.handleUnauthorized()
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: model.now)
        return hour < 10 ? "早上好" : hour < 14 ? "中午好" : hour < 18 ? "下午好" : "晚上好"
    }

    private func reloadAvatarImageIfNeeded() {
        let data = avatarData
        guard avatarSourceData != data else { return }
        avatarSourceData = data
        // Avatar bytes are decoded only when the profile changes, never during
        // repeated SwiftUI body evaluations while the tab bar is animating.
        avatarImage = data.flatMap(UIImage.init(data:))
    }

    private var dateLabel: String {
        let parts = Calendar.current.dateComponents([.month, .day, .weekday], from: model.now)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日星期\(weekdays[(parts.weekday ?? 1) - 1])"
    }

    private var statusCard: some View {
        let complete = model.active == nil && model.upcoming == nil
        let ended = complete && !model.courses.isEmpty && model.courses.allSatisfy {
            guard let end = $0.end else { return false }
            return end <= model.now
        }
        return Text(ended ? "今天的课程已经结束" : model.status)
            .font(.subheadline.weight(complete ? .medium : .semibold))
            .foregroundStyle(complete ? Color.secondary : Color.accentColor)
            .padding(.horizontal, model.wallpaperImage != nil && !reduceTransparency ? 8 : 0)
            .padding(.vertical, 8)
            .background {
                if model.wallpaperImage != nil && !reduceTransparency {
                    if colorContrast == .increased {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum TodayEntry: Identifiable {
    case course(CourseSession)
    case schedule(CustomSchedule)

    var id: String {
        switch self {
        case .course(let value): "course-\(value.id)"
        case .schedule(let value): "schedule-\(value.id)"
        }
    }

    var carouselItem: TodayCarouselItem {
        switch self {
        case .course(let value):
            let start = value.start.flatMap { CourseScheduleCalculator.dateKey($0) == value.date ? $0 : nil }
            return TodayCarouselItem(id: id, start: start, end: value.end, hasEnd: true)
        case .schedule(let value):
            let start = ScheduleTimeRange.date(value.date, time: value.time)
            let end = value.endTime.flatMap { ScheduleTimeRange.date(value.date, time: $0) }
            return TodayCarouselItem(id: id, start: start, end: end, hasEnd: value.endTime != nil)
        }
    }

    var sortTime: String {
        switch self {
        case .course(let value):
            guard let start = value.start else { return "99:99" }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: start)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        case .schedule(let value): return value.time
        }
    }

    func start(on day: Date) -> Date? {
        switch self {
        case .course(let value): return value.start
        case .schedule(let value): return CourseScheduleCalculator.dateTime(day: day, clock: value.time)
        }
    }

    func isActiveCourse(_ activeID: Int?) -> Bool {
        guard let activeID, case .course(let value) = self else { return false }
        return value.id == activeID
    }
}


private struct PendingScheduleDelete {
    let schedule: CustomSchedule
    let revision: Int
}

struct TodayAvatarPreviewRoute: Identifiable {
    let id = UUID()
    let image: UIImage
    let revision: Int
    let sourceFrameInGlobal: CGRect

    static func make(avatarData: Data?, canAccessPrivateData: Bool,
                     revision: Int, sourceFrameInGlobal: CGRect = .zero) -> TodayAvatarPreviewRoute? {
        guard canAccessPrivateData, let avatarData,
              let image = UIImage(data: avatarData) else { return nil }
        return TodayAvatarPreviewRoute(image: image, revision: revision,
                                       sourceFrameInGlobal: sourceFrameInGlobal)
    }
}
