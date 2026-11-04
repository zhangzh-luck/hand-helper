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

    /// Debug-only A-N experiment for measuring Dynamic Island outer width.
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
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_G
        // G: iOS 18+ minute-granularity timer in the same 40 point proposal as D.
        // iOS 17 retains the production A timer as an availability fallback.
        if #available(iOS 18.0, *) {
            compactMinuteTimer(context)
        } else {
            baselineCompactTimer(context)
        }
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_H
        // H: keep D's 40 point proposal, but use a pure-numeric, ceil-to-minute
        // discrete style. SwiftUI owns its minute-boundary refresh schedule.
        // iOS 17 retains the production A timer as an availability fallback.
        if #available(iOS 18.0, *) {
            compactNumericMinuteTimer(context, width: 40)
        } else {
            baselineCompactTimer(context)
        }
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_I
        // I: same custom dynamic source as H, widened only to test truncation.
        if #available(iOS 18.0, *) {
            compactNumericMinuteTimer(context, width: 48)
        } else {
            baselineCompactTimer(context)
        }
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_J
        // J: same custom dynamic source with no proposed width.
        if #available(iOS 18.0, *) {
            compactNumericMinuteTimer(context, width: nil)
        } else {
            baselineCompactTimer(context)
        }
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_K
        // K: ActivityKit's established timer renderer, retained only as a
        // control for custom-format compatibility. It intentionally has seconds.
        widthConstrainedTimer(context, width: 40)
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_L
        // L: fixed pure-numeric text. It diagnoses compact Text rendering only;
        // it is not a production countdown and never updates automatically.
        Text("1:05")
            .font(.caption2.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 40, alignment: .trailing)
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_M
        // M: test the system Duration offset source and hour-minute formatter.
        // It intentionally remains diagnostic because the system owns both its
        // sign convention and its Dynamic Island refresh behavior.
        if #available(iOS 18.0, *) {
            compactDurationOffsetTimer(context)
        } else {
            baselineCompactTimer(context)
        }
        #elseif DEBUG && LIVE_ACTIVITY_WIDTH_TEST_N
        // N: test the system date-range duration source independently from M.
        // Its localized field selection is an observed diagnostic result, not a
        // production formatting commitment.
        if #available(iOS 18.0, *) {
            compactDateRangeTimer(context)
        } else {
            baselineCompactTimer(context)
        }
        #else
        baselineCompactTimer(context)
        #endif
    }

    private func baselineCompactTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        // A: production baseline with fixed-width timer digits.
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2.monospacedDigit())
    }

    @available(iOS 18.0, *)
    private func compactMinuteTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        Text(.currentDate, format: .timer(
            countingDownIn: context.state.start..<context.state.end,
            showsHours: true,
            maxFieldCount: 2,
            maxPrecision: .seconds(60)
        ))
        .font(.caption2.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .frame(width: 40, alignment: .trailing)
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

    @available(iOS 18.0, *)
    private func compactDateRangeTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        Text(.dateRange(endingAt: context.state.end), format: .timeDuration)
            .font(.caption2.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 40, alignment: .trailing)
    }

    #if DEBUG
    @available(iOS 18.0, *)
    private func compactNumericMinuteTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>,
                                           width: CGFloat?) -> some View {
        Text(.currentDate, format: CompactMinuteCountdownFormat(end: context.state.end))
            .font(.caption2.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }
    #endif

    /// Shared only by Debug D/E. The fixed frame applies to the timer content,
    /// not to the Dynamic Island's system-owned outer capsule.
    private func widthConstrainedTimer(_ context: ActivityViewContext<HandHelperActivityAttributes>,
                                       width: CGFloat) -> some View {
        Text(timerInterval: context.state.start...context.state.end, countsDown: true)
            .font(.caption2.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder
    private func expandedBottomContent(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        #if DEBUG && (LIVE_ACTIVITY_WIDTH_TEST_G || LIVE_ACTIVITY_WIDTH_TEST_H || LIVE_ACTIVITY_WIDTH_TEST_M || LIVE_ACTIVITY_WIDTH_TEST_N)
        // G keeps the system's default Dynamic Island margins and only gives a
        // long location a full-width row rather than competing with the time.
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
        #else
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
        #endif
    }

    @ViewBuilder
    private func expandedLeadingContent(_ context: ActivityViewContext<HandHelperActivityAttributes>) -> some View {
        #if DEBUG && (LIVE_ACTIVITY_WIDTH_TEST_H || LIVE_ACTIVITY_WIDTH_TEST_M || LIVE_ACTIVITY_WIDTH_TEST_N)
        // H deliberately changes only the icon's own layout reservation. It does
        // not override Dynamic Island margins, so a remaining corner clip points
        // to the system region rather than an HStack compression of the glyph.
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
        #else
        Label(context.state.kind == "course" ? "课程" : "安排",
              systemImage: symbol(context.state.kind))
            .font(.caption.weight(.semibold))
        #endif
    }
}

/// H-only diagnostic format. `Text(.currentDate, format:)` recognizes
/// `DiscreteFormatStyle` boundaries and schedules refreshes without an app-side
/// timer or ActivityKit update. This intentionally uses ASCII H:MM output so it
/// remains compact regardless of the user's language.
#if DEBUG
@available(iOS 18.0, *)
private struct CompactMinuteCountdownFormat: DiscreteFormatStyle {
    let end: Date

    func format(_ value: Date) -> String {
        CompactMinuteCountdown.display(at: value, endingAt: end)
    }

    func discreteInput(before input: Date) -> Date? {
        CompactMinuteCountdown.previousChange(before: input, endingAt: end)
    }

    func discreteInput(after input: Date) -> Date? {
        CompactMinuteCountdown.nextChange(after: input, endingAt: end)
    }
}
#endif
