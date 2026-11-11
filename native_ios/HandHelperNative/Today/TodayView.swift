import SwiftUI

@MainActor
struct TodayView: View {
    @ObservedObject private var state: AppState
    private let onAvatarPreview: @MainActor (TodayAvatarPreviewRoute) -> Void
    private let deleteConfirmation: DestructiveConfirmationCoordinator
    @StateObject private var model: TodayViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .title) private var avatarDimension: CGFloat = 60
    @State private var editor: ScheduleEditorRoute?
    @State private var pendingDelete: PendingScheduleDelete?
    @State private var localError: String?
    @State private var appliedCourseInvalidationSequence: Int?
    @State private var avatarSourceData: Data?
    @State private var avatarImage: UIImage?

    init(state: AppState, onAvatarPreview: @escaping @MainActor (TodayAvatarPreviewRoute) -> Void,
         deleteConfirmation: DestructiveConfirmationCoordinator) {
        self.state = state
        self.onAvatarPreview = onAvatarPreview
        self.deleteConfirmation = deleteConfirmation
        let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                              account: state.verifiedAccount)
        let wallpaper = WallpaperStore(session: state.sessionStore, account: state.verifiedAccount)
        _model = StateObject(wrappedValue: TodayViewModel(repository: repository, wallpaperStore: wallpaper,
                                                           tabSwitchDiagnostics: state.tabSwitchDiagnostics))
    }

    private var dark: Bool { colorScheme == .dark }
    private var mayShowLocalSchedules: Bool {
        state.canAccessPrivateData
    }
    private var displayName: String { state.currentProfile.resolvedDisplayName }
    private var avatarData: Data? { state.currentProfile.avatarData }
    private var avatarPreviewRoute: TodayAvatarPreviewRoute? {
        guard state.canAccessPrivateData, let avatarImage else { return nil }
        return TodayAvatarPreviewRoute(image: avatarImage, revision: state.authenticationRevision)
    }
    private var entries: [TodayEntry] {
        ((state.canAccessPrivateData ? model.courses : []).map(TodayEntry.course) +
         (state.canAccessPrivateData ? model.schedules : []).map(TodayEntry.schedule))
            .sorted { ($0.sortTime, $0.id) < ($1.sortTime, $1.id) }
    }

    var body: some View {
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
                scheduleHeader.padding(.top, 24)
                if !entries.isEmpty && (state.canAccessPrivateData && (model.active != nil || model.upcoming != nil) || model.schedules.isEmpty) {
                    statusCard
                        .padding(.top, 5).padding(.bottom, 9)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !state.canAccessPrivateData || !model.hasCourseData {
                            HStack(spacing: 12) {
                                Text(courseMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if state.canAccessPrivateData {
                                    Button("重试") { Task { await refreshCourses() } }
                                }
                            }
                            .padding(.top, 12)
                        } else if let error = model.errorMessage {
                            Text(error).font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(entries) { entry in
                            switch entry {
                            case .course(let course):
                                CourseCardView(course: course, active: model.active?.id == course.id,
                                               hasWallpaper: model.wallpaperData != nil)
                            case .schedule(let schedule):
                                scheduleCard(schedule, revision: state.authenticationRevision)
                            }
                        }
                    }
                    .padding(.top, entries.isEmpty ? 0 : 12)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 18)
            .padding(.top, 26)
        }
        .task {
            reloadAvatarImageIfNeeded()
            model.load(allowPrivateCache: state.canAccessPrivateData, allowLocalSchedules: mayShowLocalSchedules)
            if state.canAccessPrivateData && state.selectedTab == .today { await refreshCourses() }
            while !Task.isCancelled {
                let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                let delay = 60 - remainder + 0.05
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                if model.tick(allowLocalSchedules: mayShowLocalSchedules) && state.canAccessPrivateData { await refreshCourses() }
            }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            appliedCourseInvalidationSequence = nil
            editor = nil
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
            state.tabSwitchDiagnostics.record(.todaySelectedTabChangeBegin, for: tab.diagnosticTab)
            if tab == .today && state.canAccessPrivateData && pendingCourseInvalidation == nil {
                let cacheAvailable = model.restoreInMemoryIfAvailable(allowPrivateCache: true,
                                                                        allowLocalSchedules: mayShowLocalSchedules)
                    ?? model.load(allowPrivateCache: true, allowLocalSchedules: mayShowLocalSchedules)
                state.tabSwitchDiagnostics.recordPageReady(for: .today,
                                                           cacheState: cacheAvailable ? .hit : .miss)
            }
            if tab == .today && pendingCourseInvalidation != nil {
                Task { await refreshCourses() }
            }
            state.tabSwitchDiagnostics.record(.todaySelectedTabChangeEnd, for: tab.diagnosticTab)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let changed = model.tick(allowLocalSchedules: mayShowLocalSchedules)
                if state.canAccessPrivateData && (changed || pendingCourseInvalidation != nil) {
                    Task { await refreshCourses() }
                }
            }
        }
        .sheet(item: $editor) { route in
            ScheduleEditorView(schedule: route.schedule, now: model.now) { id, title, date, time, endTime in
                _ = try state.requireCurrentAccount(revision: route.revision)
                try model.saveSchedule(id: id, title: title, date: date, time: time, endTime: endTime)
                try? state.localScheduleDidChange(revision: route.revision)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("操作失败", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("确定", role: .cancel) { localError = nil }
        } message: { Text(localError ?? "") }
    }

    private func scheduleCard(_ schedule: CustomSchedule, revision: Int) -> some View {
        ScheduleCardView(schedule: schedule, hasWallpaper: model.wallpaperData != nil,
                         onEdit: {
                             guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                             editor = ScheduleEditorRoute(schedule: schedule, revision: revision)
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
            Text("今日安排")
                .font(.title3.weight(.semibold))
            if state.canAccessPrivateData && !model.schedules.isEmpty {
                Text("今天有 \(model.schedules.count) 项自定义安排")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            HStack(alignment: .center, spacing: 12) {
                scheduleHeading
                Spacer(minLength: 0)
                if state.canAccessPrivateData { addScheduleButton }
            }
        }
    }

    private var addScheduleButton: some View {
        let button = Button {
            editor = ScheduleEditorRoute(schedule: nil, revision: state.authenticationRevision)
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
        .padding(22)
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
        }
    }

    private var avatarButton: some View {
        Button {
            if let route = avatarPreviewRoute {
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
            .frame(width: min(avatarDimension, 88), height: min(avatarDimension, 88))
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(avatarPreviewRoute == nil)
        .accessibilityLabel(avatarPreviewRoute == nil ? "尚未设置头像" : "查看头像大图")
    }

    private var courseMessage: String {
        switch state.authenticationStatus {
        case .signedOut: return state.credentialRemovalError ?? "登录后查看今日课程"
        case .verifying: return "正在验证登录状态…"
        case .offline: return "网络暂不可用，登录状态尚未验证"
        case .expired: return state.credentialRemovalError ?? "登录状态已失效，请重新登录"
        case .signedIn: return model.errorMessage ?? "今天暂无课程"
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
        return Text(model.status)
            .font(.subheadline.weight(complete ? .medium : .semibold))
            .foregroundStyle(complete ? Color.secondary : Color.accentColor)
            .padding(.vertical, 10)
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

    var sortTime: String {
        switch self {
        case .course(let value):
            guard let start = value.start else { return "99:99" }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: start)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        case .schedule(let value): return value.time
        }
    }
}

private struct ScheduleEditorRoute: Identifiable {
    let schedule: CustomSchedule?
    let revision: Int
    var id: String { "\(revision)-\(schedule?.id ?? 0)" }
}

private struct PendingScheduleDelete {
    let schedule: CustomSchedule
    let revision: Int
}

struct TodayAvatarPreviewRoute: Identifiable {
    let id = UUID()
    let image: UIImage
    let revision: Int

    static func make(avatarData: Data?, canAccessPrivateData: Bool,
                     revision: Int) -> TodayAvatarPreviewRoute? {
        guard canAccessPrivateData, let avatarData,
              let image = UIImage(data: avatarData) else { return nil }
        return TodayAvatarPreviewRoute(image: image, revision: revision)
    }
}
