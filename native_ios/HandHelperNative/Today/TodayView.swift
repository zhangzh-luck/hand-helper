import PhotosUI
import SwiftUI

@MainActor
struct TodayView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: TodayViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .title) private var avatarDimension: CGFloat = 60
    @State private var editor: ScheduleEditorRoute?
    @State private var pendingDelete: PendingScheduleDelete?
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showProfile = false
    @State private var localError: String?

    init(state: AppState) {
        self.state = state
        let repository = DiskCourseRepository(api: state.api, session: state.sessionStore,
                                              account: state.verifiedAccount)
        let wallpaper = WallpaperStore(session: state.sessionStore)
        _model = StateObject(wrappedValue: TodayViewModel(repository: repository, wallpaperStore: wallpaper))
    }

    private var dark: Bool { colorScheme == .dark }
    private var mayShowLocalSchedules: Bool {
        state.canAccessPrivateData
    }
    private var displayName: String { state.currentProfile.resolvedDisplayName }
    private var avatarData: Data? { state.currentProfile.avatarData }
    private var entries: [TodayEntry] {
        ((state.canAccessPrivateData ? model.courses : []).map(TodayEntry.course) +
         (state.canAccessPrivateData ? model.schedules : []).map(TodayEntry.schedule))
            .sorted { ($0.sortTime, $0.id) < ($1.sortTime, $1.id) }
    }

    var body: some View {
        ZStack {
            TodayStyle.background.ignoresSafeArea()
            if !reduceTransparency, state.canAccessPrivateData,
               let data = model.wallpaperData, let image = UIImage(data: data) {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(y: -geometry.size.height * 0.05)
                        .clipped()
                        .opacity(dark ? 0.52 : 0.38)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0.16),
                            .init(color: .black, location: 0.39),
                            .init(color: .black, location: 1)
                        ], startPoint: .top, endPoint: .bottom))
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
            model.load(allowPrivateCache: state.canAccessPrivateData, allowLocalSchedules: mayShowLocalSchedules)
            if state.canAccessPrivateData { await refreshCourses() }
            while !Task.isCancelled {
                let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                let delay = 60 - remainder + 0.05
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                if model.tick(allowLocalSchedules: mayShowLocalSchedules) && state.canAccessPrivateData { await refreshCourses() }
            }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            editor = nil
            pendingDelete = nil
            selectedPhoto = nil
            showProfile = false
            model.authenticationDidChange(allowPrivateCache: state.canAccessPrivateData,
                                          allowLocalSchedules: mayShowLocalSchedules)
            if state.canAccessPrivateData { Task { await refreshCourses() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let changed = model.tick(allowLocalSchedules: mayShowLocalSchedules)
                if changed && state.canAccessPrivateData { Task { await refreshCourses() } }
            }
        }
        .sheet(item: $editor) { route in
            ScheduleEditorView(schedule: route.schedule, now: model.now) { id, title, date, time in
                _ = try state.requireCurrentAccount(revision: route.revision)
                try model.saveSchedule(id: id, title: title, date: date, time: time)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("删除“\(pendingDelete?.schedule.title ?? "")”？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除安排", role: .destructive) {
                if let pendingDelete {
                    do {
                        _ = try state.requireCurrentAccount(revision: pendingDelete.revision)
                        try model.deleteSchedule(id: pendingDelete.schedule.id)
                    }
                    catch { localError = error.localizedDescription }
                }
                pendingDelete = nil
            }
        } message: { Text("删除后无法恢复这项自定义安排。") }
        .alert("操作失败", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("确定", role: .cancel) { localError = nil }
        } message: { Text(localError ?? "") }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            let revision = state.authenticationRevision
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                do {
                    _ = try state.requireCurrentAccount(revision: revision)
                    try model.setWallpaper(data)
                }
                catch { localError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView(state: state, revision: state.authenticationRevision)
        }
    }

    private func scheduleCard(_ schedule: CustomSchedule, revision: Int) -> some View {
        ScheduleCardView(schedule: schedule, hasWallpaper: model.wallpaperData != nil,
                         onEdit: {
                             guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                             editor = ScheduleEditorRoute(schedule: schedule, revision: revision)
                         },
                         onDelete: {
                             guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                             pendingDelete = PendingScheduleDelete(schedule: schedule, revision: revision)
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
        .contextMenu {
            if state.canAccessPrivateData {
                Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await state.logout() }
                }
            }
            Button("更换今日壁纸", systemImage: "photo") { showPhotoPicker = true }
                .disabled(!state.canAccessPrivateData)
            Button("使用默认背景", systemImage: "rectangle.slash") {
                do { try model.removeWallpaper() } catch { localError = error.localizedDescription }
            }
            .disabled(!state.canAccessPrivateData || model.wallpaperData == nil)
        }
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
        Button { showProfile = true } label: {
            Group {
                if let avatarData, let image = UIImage(data: avatarData) {
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
        .accessibilityLabel("打开个人资料")
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

    private func refreshCourses() async {
        let revision = state.authenticationRevision
        let unauthorized = await model.refresh()
        guard revision == state.authenticationRevision else { return }
        if unauthorized && state.isAuthenticated && !state.isLoginSubmitting {
            state.handleUnauthorized()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: model.now)
        return hour < 10 ? "早上好" : hour < 14 ? "中午好" : hour < 18 ? "下午好" : "晚上好"
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
