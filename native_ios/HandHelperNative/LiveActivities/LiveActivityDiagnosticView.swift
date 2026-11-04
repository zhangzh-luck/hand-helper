#if DEBUG
import SwiftUI

@MainActor
struct LiveActivityDiagnosticView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var diagnostics: LiveActivityDiagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var testDuration = LiveActivityDiagnosticDuration.tenMinutes

    init(state: AppState) {
        self.state = state
        _diagnostics = ObservedObject(wrappedValue: state.liveActivityCoordinator.diagnostics)
    }

    var body: some View {
        Form {
            Section("启动条件") {
                row("系统允许实时活动", diagnostics.snapshot.systemEnabled ? "是" : "否")
                row("应用内开关", diagnostics.snapshot.appEnabled ? "开启" : "关闭")
                row("账号已验证", diagnostics.snapshot.verified ? "是" : "否")
                row("前台", diagnostics.snapshot.foreground ? "是" : "否")
            }
            Section("当前事项") {
                row("候选数量", "\(diagnostics.snapshot.candidateCount)")
                Text(diagnostics.snapshot.selected)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            Section("ActivityKit") {
                row("活动数量", "\(diagnostics.snapshot.activities.count)")
                ForEach(diagnostics.snapshot.activities, id: \.self) { activity in
                    Text(activity).font(.footnote).textSelection(.enabled)
                }
                Text("最近结果：\(diagnostics.lastOutcome)")
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            Section {
                Picker("测试时长", selection: $testDuration) {
                    ForEach(LiveActivityDiagnosticDuration.allCases) { duration in
                        Text(duration.label).tag(duration)
                    }
                }
                Button("启动\(testDuration.label)测试活动") {
                    state.liveActivityCoordinator.startDiagnosticTest(state: state,
                        foreground: scenePhase == .active, duration: testDuration)
                }
                .disabled(!canStart)
                Button("结束测试活动") {
                    state.liveActivityCoordinator.endDiagnosticTest(state: state,
                        foreground: scenePhase == .active)
                }
                Button("重新检查") {
                    state.liveActivityCoordinator.synchronize(state: state,
                        foreground: scenePhase == .active, reason: "diagnostic_refresh")
                }
            } footer: {
                Text("仅 Debug 构建可见。5、15、65 分钟用于覆盖计时格式边界。测试活动也要求应用开关开启、系统授权、账号已验证且 App 正在前台。Xcode Console 可用 [LiveActivity] 过滤完整事件。")
            }
        }
        .navigationTitle("实时活动诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            state.liveActivityCoordinator.synchronize(state: state,
                foreground: scenePhase == .active, reason: "diagnostic_open")
        }
    }

    private var canStart: Bool {
        diagnostics.snapshot.systemEnabled && state.liveActivitiesEnabled &&
        state.canAccessPrivateData && scenePhase == .active
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

enum LiveActivityDiagnosticDuration: TimeInterval, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case sixtyFiveMinutes = 3900

    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .fiveMinutes: "5 分钟"
        case .tenMinutes: "10 分钟"
        case .fifteenMinutes: "15 分钟"
        case .sixtyFiveMinutes: "65 分钟"
        }
    }
}
#endif
