import SwiftUI
import UIKit

@MainActor
struct TabSwitchDiagnosticsView: View {
    @ObservedObject private var diagnostics: TabSwitchDiagnostics
    @State private var copied = false

    init(diagnostics: TabSwitchDiagnostics) {
        _diagnostics = ObservedObject(wrappedValue: diagnostics)
    }

    var body: some View {
        List {
            Section {
                Toggle("记录 Tab 切换性能", isOn: Binding(
                    get: { diagnostics.isEnabled },
                    set: { diagnostics.setEnabled($0) }
                ))
                if diagnostics.isSampling {
                    Label("正在采样本次切换", systemImage: "waveform.path.ecg")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("默认关闭。开启后仅在你切换底部 Tab 时采样约 0.7 秒；不会记录账号、课程、成绩、网络地址或登录凭据。")
            }

            Section("最近记录") {
                if diagnostics.reports.isEmpty {
                    Text(diagnostics.isEnabled ? "切换任意底部 Tab 后将在这里显示结果。" : "开启后切换任意底部 Tab 即可采样。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics.reports) { report in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(report.source.title) → \(report.destination.title)")
                                .font(.headline)
                            Text(report.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("\(report.frameCount) 帧 · P95 \(report.p95FrameIntervalMilliseconds.map { "\($0)ms" } ?? "—") · 超过 20ms：\(report.intervalsOverTwentyMilliseconds)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !diagnostics.reports.isEmpty {
                Section {
                    Button(copied ? "已复制诊断结果" : "复制诊断结果") {
                        UIPasteboard.general.string = diagnostics.exportText
                        copied = true
                    }
                    Button("清除诊断结果", role: .destructive) {
                        diagnostics.clearReports()
                        copied = false
                    }
                }
            }
        }
        .navigationTitle("Tab 切换性能诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: diagnostics.reports.count) { _, _ in
            copied = false
        }
    }
}
