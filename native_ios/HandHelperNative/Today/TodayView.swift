import PhotosUI
import SwiftUI

@MainActor
struct TodayView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: TodayViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: ScheduleEditorRoute?
    @State private var pendingDelete: PendingScheduleDelete?
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showAvatar = false
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
    private var visibleProfile: TodayProfile {
        state.canAccessPrivateData ? model.profile : TodayProfile(displayName: "航的助手", avatarDataURL: nil, homeWallpaperDataURL: nil)
    }
    private var avatarData: Data? { WallpaperStore.decodeDataURL(visibleProfile.avatarDataURL) }
    private var entries: [TodayEntry] {
        ((state.canAccessPrivateData ? model.courses : []).map(TodayEntry.course) +
         (state.canAccessPrivateData ? model.schedules : []).map(TodayEntry.schedule))
            .sorted { ($0.sortTime, $0.id) < ($1.sortTime, $1.id) }
    }

    var body: some View {
        ZStack {
            TodayStyle.background(dark).ignoresSafeArea()
            if state.canAccessPrivateData, let data = model.wallpaperData, let image = UIImage(data: data) {
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
                HStack(spacing: 8) {
                    Text("今日安排")
                        .font(.system(size: 19, weight: .heavy))
                    if state.canAccessPrivateData && !model.schedules.isEmpty {
                        Text("今天有 \(model.schedules.count) 项自定义安排")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TodayStyle.color(dark ? 0x9bc3ff : 0x1d4ed8))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(TodayStyle.color(dark ? 0x17263c : 0xdbeafe), in: Capsule())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if state.canAccessPrivateData {
                        Button { editor = ScheduleEditorRoute(schedule: nil, revision: state.authenticationRevision) } label: {
                            Label("添加安排", systemImage: "plus").font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(TodayStyle.color(dark ? 0x9bc3ff : 0x2563eb))
                        .padding(.horizontal, 8).padding(.vertical, 8)
                        .background(TodayStyle.color(dark ? 0x17263c : 0xe8f1ff), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!model.canEditSchedules)
                    }
                }
                .padding(.top, 25)
                if !entries.isEmpty && (state.canAccessPrivateData && (model.active != nil || model.upcoming != nil) || model.schedules.isEmpty) {
                    statusCard
                        .padding(.top, 5).padding(.bottom, 9)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !state.canAccessPrivateData || !model.hasCourseData {
                            HStack(spacing: 12) {
                                Text(courseMessage)
                                    .font(.system(size: 14))
                                    .foregroundStyle(TodayStyle.secondary(dark))
                                Spacer()
                                if state.credentialRemovalError != nil {
                                    Button("重试清理") { state.retryCredentialRemoval() }
                                } else if state.canAccessPrivateData {
                                    Button("重试") { Task { await refreshCourses() } }
                                } else if state.authenticationStatus != .verifying {
                                    Button("登录") { state.isLoginPresented = true }
                                }
                            }
                            .padding(.top, 12)
                        } else if let error = model.errorMessage {
                            Text(error).font(.system(size: 13))
                                .foregroundStyle(TodayStyle.secondary(dark))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(entries) { entry in
                            switch entry {
                            case .course(let course):
                                CourseCardView(course: course, active: model.active?.id == course.id,
                                               hasWallpaper: model.wallpaperData != nil, dark: dark)
                            case .schedule(let schedule):
                                ScheduleCardView(schedule: schedule, hasWallpaper: model.wallpaperData != nil,
                                                 dark: dark, model: model,
                                                 onEdit: {
                                                     guard state.canAccessPrivateData else { return }
                                                     editor = ScheduleEditorRoute(schedule: schedule,
                                                                                  revision: state.authenticationRevision)
                                                 },
                                                 onDelete: {
                                                     guard state.canAccessPrivateData else { return }
                                                     pendingDelete = PendingScheduleDelete(schedule: schedule,
                                                                                           revision: state.authenticationRevision)
                                                 })
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
            showAvatar = false
            model.authenticationDidChange(allowPrivateCache: state.canAccessPrivateData,
                                          allowLocalSchedules: mayShowLocalSchedules)
            if state.canAccessPrivateData { Task { await refreshCourses() } }
        }
        .onChange(of: state.selectedTab) { _, tab in if tab != .today { model.closeActions() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let changed = model.tick(allowLocalSchedules: mayShowLocalSchedules)
                if changed && state.canAccessPrivateData { Task { await refreshCourses() } }
                if state.authenticationStatus == .offline { Task { await state.retrySessionVerification() } }
            }
        }
        .onDisappear { model.closeActions() }
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
        .sheet(isPresented: $showAvatar) {
            if let avatarData, let image = UIImage(data: avatarData) {
                Image(uiImage: image).resizable().scaledToFit()
                    .padding(20)
                    .background(TodayStyle.background(dark))
            }
        }
        .sheet(isPresented: $state.isLoginPresented) { LoginView(state: state) }
    }

    private var hero: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                badge("今日 · \(greeting)")
                Text(visibleProfile.displayName)
                    .font(.system(size: 31, weight: .heavy))
                    .foregroundStyle(TodayStyle.color(dark ? 0xffffff : 0x172033))
                    .lineLimit(1)
                badge(dateLabel)
            }
            Spacer(minLength: 0)
            Button { if avatarData != nil { showAvatar = true } } label: {
                Group {
                    if let avatarData, let image = UIImage(data: avatarData) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Text(visibleProfile.displayName == "航的助手" ? "航" : String(visibleProfile.displayName.suffix(1)))
                            .font(.system(size: 28, weight: .bold))
                    }
                }
                .frame(width: 74, height: 74)
                .background(dark ? Color.black : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .padding(3)
                .background(dark ? Color.black : Color.white, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: TodayStyle.color(0x0f172a, alpha: 38.0 / 255), radius: 8, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(avatarData == nil)
        }
        .padding(.horizontal, 22).padding(.vertical, 26)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .leading)
        .background(LinearGradient(colors: dark
            ? [TodayStyle.color(0x202228), TodayStyle.color(0x121418)]
            : [TodayStyle.color(0xfbfcfe), TodayStyle.color(0xeaf2f9)],
            startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(
            TodayStyle.color(dark ? 0xffffff : 0x0f172a, alpha: 16.0 / 255)))
        .shadow(color: TodayStyle.color(0x0f172a, alpha: 18.0 / 255), radius: 11, x: 0, y: 8)
        .contextMenu {
            if state.canAccessPrivateData {
                Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await state.logout() }
                }
            } else {
                Button("登录", systemImage: "person.crop.circle") { state.isLoginPresented = true }
            }
            Button("更换今日壁纸", systemImage: "photo") { showPhotoPicker = true }
                .disabled(!state.canAccessPrivateData)
            Button("使用默认背景", systemImage: "rectangle.slash") {
                do { try model.removeWallpaper() } catch { localError = error.localizedDescription }
            }
            .disabled(!state.canAccessPrivateData || model.wallpaperData == nil)
        }
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
        if state.isAuthenticated && state.sessionStore.cookie != nil && !state.canAccessPrivateData {
            await state.reverifyRotatedSession()
            return
        }
        if unauthorized && state.isAuthenticated && !state.isLoginSubmitting {
            state.handleUnauthorized()
        }
    }

    private func badge(_ value: String) -> some View {
        Text(value).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TodayStyle.color(dark ? 0xe0e5ec : 0x475b74))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(TodayStyle.color(dark ? 0x000000 : 0xffffff, alpha: dark ? 56.0 / 255 : 120.0 / 255),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                TodayStyle.color(0xffffff, alpha: dark ? 32.0 / 255 : 153.0 / 255)))
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
            .font(.system(size: complete ? 13 : 14, weight: .bold))
            .foregroundStyle(TodayStyle.color(dark ? 0xbfdbfe : 0x1d4ed8))
            .frame(maxWidth: complete ? nil : .infinity, minHeight: complete ? nil : 62, alignment: .leading)
            .padding(.horizontal, complete ? 11 : 15).padding(.vertical, complete ? 7 : 13)
            .background(TodayStyle.color(dark ? 0x102642 : 0xe8f1ff),
                        in: RoundedRectangle(cornerRadius: complete ? 11 : 14))
            .overlay(RoundedRectangle(cornerRadius: complete ? 11 : 14).strokeBorder(
                TodayStyle.color(dark ? 0x234671 : 0xdbeafe)))
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
