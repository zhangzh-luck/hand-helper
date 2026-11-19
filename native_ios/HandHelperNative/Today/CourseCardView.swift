import SwiftUI

struct CourseCardView: View {
    let course: CourseSession
    let active: Bool
    let hasWallpaper: Bool

    var body: some View {
        TodayEntryFace(
            kind: "课程", title: course.name,
            time: "\(format(course.start))—\(format(course.end))",
            detail: "\(course.room ?? "教室待定") · \(course.teacher ?? "教师待定")",
            active: active, custom: false, hasWallpaper: hasWallpaper
        )
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

struct TodayEntryFace: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    let kind: String
    let title: String
    let time: String
    let detail: String
    let active: Bool
    let custom: Bool
    let hasWallpaper: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(kind)
                if active { Label("进行中", systemImage: "clock.fill") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(active || custom ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(time)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if hasWallpaper && !reduceTransparency && contrast != .increased {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(TodayStyle.color(colorScheme == .dark ? 0x0A84FF : 0x60A5FA, alpha: 0.7), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
struct ScheduleCardView: View {
    let schedule: CustomSchedule
    let hasWallpaper: Bool
    var active: Bool = false
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TodayEntryFace(kind: "自定义安排", title: schedule.title,
                       time: schedule.endTime.map { "\(schedule.time)—\($0)" } ?? schedule.time,
                       detail: "", active: active, custom: true,
                       hasWallpaper: hasWallpaper)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
