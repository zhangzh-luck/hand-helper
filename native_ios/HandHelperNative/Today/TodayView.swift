import PhotosUI
import SwiftUI

@MainActor
struct TodayView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: TodayViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: ScheduleEditorRoute?
    @State private var pendingDelete: CustomSchedule?
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showAvatar = false
    @State private var localError: String?

    init(state: AppState) {
        self.state = state
        let repository = DiskCourseRepository(api: state.api, session: state.sessionStore)
        let wallpaper = WallpaperStore(session: state.sessionStore)
        _model = StateObject(wrappedValue: TodayViewModel(repository: repository, wallpaperStore: wallpaper))
    }

    private var dark: Bool { colorScheme == .dark }
    private var avatarData: Data? { WallpaperStore.decodeDataURL(model.profile.avatarDataURL) }
    private var entries: [TodayEntry] {
        (model.courses.map(TodayEntry.course) + model.schedules.map(TodayEntry.schedule))
            .sorted { ($0.sortTime, $0.id) < ($1.sortTime, $1.id) }
    }

    var body: some View {
        ZStack {
            TodayStyle.background(dark).ignoresSafeArea()
            if let data = model.wallpaperData, let image = UIImage(data: data) {
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
                    if !model.schedules.isEmpty {
                        Text("今天有 \(model.schedules.count) 项自定义安排")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TodayStyle.color(dark ? 0x9bc3ff : 0x1d4ed8))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(TodayStyle.color(dark ? 0x17263c : 0xdbeafe), in: Capsule())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { editor = .new } label: {
                        Label("添加安排", systemImage: "plus").font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TodayStyle.color(dark ? 0x9bc3ff : 0x2563eb))
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .background(TodayStyle.color(dark ? 0x17263c : 0xe8f1ff), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!model.canEditSchedules)
                }
                .padding(.top, 25)
                if !entries.isEmpty && (model.active != nil || model.upcoming != nil || model.schedules.isEmpty) {
                    statusCard
                        .padding(.top, 5).padding(.bottom, 9)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !model.hasCourseData {
                            HStack {
                                Text(model.errorMessage ?? "课程数据暂不可用")
                                    .font(.system(size: 14))
                                    .foregroundStyle(TodayStyle.secondary(dark))
                                Spacer()
                                Button("重试") { Task { await model.refresh() } }
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
                                                 onEdit: { editor = .existing(schedule) },
                                                 onDelete: { pendingDelete = schedule })
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
            model.load()
            await model.refresh()
            while !Task.isCancelled {
                let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                let delay = 60 - remainder + 0.05
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                if model.tick() { await model.refresh() }
            }
        }
        .onChange(of: state.selectedTab) { _, tab in if tab != .today { model.closeActions() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let changed = model.tick()
                if changed { Task { await model.refresh() } }
            }
        }
        .onDisappear { model.closeActions() }
        .sheet(item: $editor) { route in
            ScheduleEditorView(schedule: route.schedule, now: model.now) { id, title, date, time in
                try model.saveSchedule(id: id, title: title, date: date, time: time)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("删除“\(pendingDelete?.title ?? "")”？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除安排", role: .destructive) {
                if let id = pendingDelete?.id {
                    do { try model.deleteSchedule(id: id) }
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
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                do { try model.setWallpaper(data) }
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
    }

    private var hero: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                badge("今日 · \(greeting)")
                Text(model.profile.displayName)
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
                        Text(model.profile.displayName == "航的助手" ? "航" : String(model.profile.displayName.suffix(1)))
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
            Button("更换今日壁纸", systemImage: "photo") { showPhotoPicker = true }
                .disabled(!model.canEditSchedules)
            Button("使用默认背景", systemImage: "rectangle.slash") {
                do { try model.removeWallpaper() } catch { localError = error.localizedDescription }
            }
            .disabled(!model.canEditSchedules || model.wallpaperData == nil)
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

private enum ScheduleEditorRoute: Identifiable {
    case new, existing(CustomSchedule)
    var id: String {
        switch self { case .new: "new"; case .existing(let value): "edit-\(value.id)" }
    }
    var schedule: CustomSchedule? {
        if case .existing(let value) = self { return value }
        return nil
    }
}
