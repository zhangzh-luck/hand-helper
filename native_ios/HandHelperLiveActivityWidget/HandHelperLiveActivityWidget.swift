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
                    Label(context.state.kind == "course" ? "课程" : "安排",
                          systemImage: symbol(context.state.kind))
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title).font(.headline).lineLimit(2)
                        HStack(spacing: 4) {
                            Text(context.state.start, style: .time)
                            Text("—")
                            Text(context.state.end, style: .time)
                            if let location = context.state.location, !location.isEmpty {
                                Spacer(minLength: 4)
                                Text(location).lineLimit(1)
                            }
                        }
                        .font(.caption)
                        ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false)
                            .labelsHidden()
                    }
                    .accessibilityElement(children: .combine)
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

    /// Debug-only A-F experiment for measuring Dynamic Island outer width.
    /// Release and ordinary Debug builds always retain the production A layout.
    @ViewBuilder
    private func compactTrailingTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        #if DEBUG && LIVE_ACTIVITY_WIDTH_TEST_C
        // C: remove only compact trailing content. This is never compiled into Release.
        EmptyView()
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_B
        // B: keep the system timer but use proportional digits.
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2)
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_D
        // D: constrain only the system timer's proposed width to 40 points.
        widthConstrainedTimer(context, width: 40)
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_E
        // E: same as D, with a 48 point proposed width.
        widthConstrainedTimer(context, width: 48)
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_F
        // F: preserve the timer's natural horizontal intrinsic size.
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2.monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
        #else
        // A: production baseline with fixed-width timer digits.
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2.monospacedDigit())
        #endif
    }

    /// Shared only by Debug D/E. The fixed frame applies to the timer content,
    /// not to the Dynamic Island's system-owned outer capsule.
    private func widthConstrainedTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>,
                                       width: CGFloat) -> some View {
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }
}
