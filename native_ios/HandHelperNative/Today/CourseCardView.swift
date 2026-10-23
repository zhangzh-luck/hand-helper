import SwiftUI

struct CourseCardView: View {
    let course: CourseSession
    let active: Bool
    let hasWallpaper: Bool
    let dark: Bool

    var body: some View {
        TodayEntryFace(
            kind: "课程", title: course.name,
            time: "\(format(course.start))—\(format(course.end))",
            detail: "\(course.room ?? "教室待定") · \(course.teacher ?? "教师待定")",
            active: active, custom: false, hasWallpaper: hasWallpaper, dark: dark
        )
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

struct TodayEntryFace: View {
    let kind: String
    let title: String
    let time: String
    let detail: String
    let active: Bool
    let custom: Bool
    let hasWallpaper: Bool
    let dark: Bool

    private var colors: [Color] {
        if dark {
            let value = TodayStyle.color(0x141416, alpha: hasWallpaper ? 194.0 / 255 : 1)
            return [value, value]
        }
        if hasWallpaper {
            return custom
                ? [TodayStyle.color(0xf8fbff, alpha: 199.0 / 255), TodayStyle.color(0xe8f2ff, alpha: 179.0 / 255)]
                : [TodayStyle.color(0xffffff, alpha: 204.0 / 255), TodayStyle.color(0xf7faff, alpha: 179.0 / 255)]
        }
        if custom { return [TodayStyle.color(0xf8fbff), TodayStyle.color(0xeef5ff)] }
        if active { return [TodayStyle.color(0xf4f8ff), .white] }
        return [.white, TodayStyle.color(0xfbfdff)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TodayStyle.color(dark ? 0x69adff : (custom ? 0x3567b7 : 0x007aff)))
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 17, weight: .heavy))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(time)
                .font(.system(size: 15))
                .foregroundStyle(TodayStyle.color(dark ? 0xd1d1d6 : 0x334155))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(TodayStyle.color(dark ? 0xa1a1a6 : 0x64748b))
                    .lineLimit(1)
                    .padding(.top, 5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(height: 144)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
            active ? TodayStyle.color(dark ? 0x0a84ff : 0x60a5fa)
                   : TodayStyle.color(dark ? 0xffffff : (custom ? 0xdbeafe : 0xe3eaf3), alpha: dark ? 24.0 / 255 : 1),
            lineWidth: active ? 2 : 1))
        .shadow(color: TodayStyle.shadow, radius: 5, x: 0, y: 2)
    }
}

@MainActor
struct ScheduleCardView: View {
    let schedule: CustomSchedule
    let hasWallpaper: Bool
    let dark: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TodayEntryFace(kind: "自定义安排", title: schedule.title, time: schedule.time,
                       detail: "", active: false, custom: true,
                       hasWallpaper: hasWallpaper, dark: dark)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                ForEach(ScheduleCardAction.allCases) { action in
                    Button(role: action.role) {
                        action.perform(onEdit: onEdit, onDelete: onDelete)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }
    }
}

enum ScheduleCardAction: CaseIterable, Identifiable, Hashable {
    case edit, delete

    var id: Self { self }
    var title: String { self == .edit ? "编辑" : "删除" }
    var symbol: String { self == .edit ? "pencil" : "trash" }
    var role: ButtonRole? { self == .delete ? .destructive : nil }

    func perform(onEdit: () -> Void, onDelete: () -> Void) {
        switch self {
        case .edit: onEdit()
        case .delete: onDelete()
        }
    }
}
