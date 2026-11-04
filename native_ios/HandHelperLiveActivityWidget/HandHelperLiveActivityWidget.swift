import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HandHelperLiveActivityBundle: WidgetBundle {
    var body: some Widget { HandHelperLiveActivityWidget() }
}

struct HandHelperLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HandHelperActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(context.state.kind == "course" ? "正在上课" : "正在进行安排",
                      systemImage: symbol(context.state.kind))
                    .font(.caption.weight(.semibold))
                Text(context.state.title).font(.headline).lineLimit(2)
                HStack {
                    Text(context.state.start, style: .time)
                    Text("—")
                    Text(context.state.end, style: .time)
                    Spacer(minLength: 8)
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .monospacedDigit()
                }
                .font(.subheadline)
                ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false)
                    .labelsHidden()
                if let location = context.state.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption).lineLimit(1)
                }
            }
            .padding()
            .accessibilityElement(children: .combine)
            .widgetURL(URL(string: "handhelper://today"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeadingContent(context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottomContent(context)
                }
            } compactLeading: {
                Image(systemName: symbol(context.state.kind))
                    .accessibilityLabel(context.state.kind == "course" ? "课程" : "安排")
            } compactTrailing: {
                compactTrailingTimer(context)
            } minimal: {
                Image(systemName: symbol(context.state.kind))
                    .accessibilityLabel(context.state.kind == "course" ? "课程" : "安排")
            }
            .widgetURL(URL(string: "handhelper://today"))
        }
    }

    private func symbol(_ kind: String) -> String {
        kind == "course" ? "book.closed.fill" : "checklist"
    }

    @ViewBuilder
    private func compactTrailingTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        if #available(iOS 18.0, *) {
            compactDurationOffsetTimer(context)
        } else {
            baselineCompactTimer(context)
        }
    }

    private func baselineCompactTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        // iOS 17 compatibility fallback keeps the established system timer.
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2.monospacedDigit())
    }

    @available(iOS 18.0, *)
    private func compactDurationOffsetTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        Text(
            .durationOffset(to: context.state.end),
            format: .time(pattern: .hourMinute(padHourToLength: 1, roundSeconds: .up))
        )
        .font(.caption2.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .frame(width: 40, alignment: .trailing)
    }

    @ViewBuilder
    private func expandedBottomContent(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        // Keep the system's default Dynamic Island margins and give a long
        // location a full-width row rather than competing with the time.
        VStack(alignment: .leading, spacing: 5) {
            Text(context.state.title)
                .font(.headline)
                .lineLimit(2)
                .layoutPriority(1)
            HStack(spacing: 4) {
                Text(context.state.start, style: .time)
                Text("—")
                Text(context.state.end, style: .time)
            }
            .font(.caption)
            if let location = context.state.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .lineLimit(2)
            }
            ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false)
                .labelsHidden()
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func expandedLeadingContent(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        // Reserve the icon's own layout space without overriding Dynamic Island
        // margins, avoiding glyph compression near the leading corner.
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: symbol(context.state.kind))
                .font(.caption.weight(.semibold))
                .frame(width: 16, height: 16)
                .fixedSize()
                .layoutPriority(1)
            Text(context.state.kind == "course" ? "课程" : "安排")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }
}
