import SwiftUI
import WidgetKit

private struct ProbeEntry: TimelineEntry {
    let date: Date
    let result: WidgetProbeStore.Result?
}

private struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: Date(), result: nil) }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: Date(), result: context.isPreview ? nil : WidgetProbeStore.read(from: WidgetProbeStore.container())))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: Date(), result: WidgetProbeStore.read(from: WidgetProbeStore.container()))], policy: .never))
    }
}

struct TodayCourseProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetProbeStore.kind, provider: ProbeProvider()) { entry in
            VStack(alignment: .leading, spacing: 10) {
                Label("今日课程", systemImage: "calendar")
                    .font(.headline)
                Text(message(entry.result)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("共享测试 · 非真实课程").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
            .widgetURL(URL(string: "handhelper://today"))
        }
        .configurationDisplayName("今日课程（共享测试）")
        .description("测试应用与小组件的共享容器，不显示真实课程。")
        .supportedFamilies([.systemSmall])
    }

    private func message(_ result: WidgetProbeStore.Result?) -> String {
        switch result {
        case nil: "预览：尚未读取共享数据"
        case .success: WidgetProbeStore.payload
        case .containerUnavailable: "共享容器不可用，请检查签名权限"
        case .missing: "尚未写入测试数据，请在 App 中运行测试"
        case .invalid: "测试数据无效，请重新写入"
        case .failed: "共享数据读取失败，请检查权限"
        }
    }
}
