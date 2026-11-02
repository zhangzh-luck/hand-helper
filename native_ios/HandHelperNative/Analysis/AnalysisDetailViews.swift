import SwiftUI

@MainActor
struct GradeDetailView: View {
    let grade: GradeRecord
    let focusTitle: Bool
    let onClose: () -> Void
    var glassHeader = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 26)
                    .accessibilityHidden(true)
                Text(grade.courseName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: 0)
                GlassCloseButton(accessibilityLabel: "关闭成绩详情", diameter: 44,
                                 onDarkBackground: false, action: onClose)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) { scores }
                    } else {
                        HStack(alignment: .top, spacing: 8) { scores }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 12) {
                    detail("学分 / 绩点", "\(grade.credits.map { String($0) } ?? "—") / \(grade.gradePoint.map { String($0) } ?? "—")", symbol: "graduationcap")
                    detail("课程性质", grade.courseType ?? "未提供", symbol: "books.vertical")
                    detail("考试性质", grade.examType ?? "未提供", symbol: "doc.text")
                    detail("补考 / 重修", "\(grade.makeupFlag ? "补考" : "否") / \(grade.retakeFlag ? "重修" : "否")", symbol: "arrow.clockwise")
                    if !grade.courseCode.isEmpty {
                        detail("课程代码", grade.courseCode, symbol: "number", secondary: true)
                    }
                    if let weighted = grade.weightedGradePoint {
                        detail("加权绩点", String(weighted), symbol: "chart.bar", secondary: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, glassHeader ? 14 : 0)
            .padding(.bottom, 20)
            .background {
                if glassHeader {
                    Color(uiColor: .systemGroupedBackground).opacity(0.94)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onChange(of: focusTitle) { _, value in titleFocused = value }
    }

    @ViewBuilder
    private var scores: some View {
        score("总评成绩", grade.score ?? "未公布", emphasized: true)
        score("期末成绩", grade.finalExamScore ?? "未提供")
        score("平时成绩", grade.usualScore ?? "未提供")
    }

    private func score(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(emphasized ? .title3.weight(.bold) : .body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ label: String, _ value: String, symbol: String,
                        secondary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).foregroundStyle(secondary ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct AnalysisReportRoute: Identifiable {
    let id = UUID()
    let analysis: GradeAIAnalysis
}

@MainActor
struct GradeAIReportView: View {
    let analysis: GradeAIAnalysis
    let onRegenerate: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("分析模型", value: analysis.model)
                    LabeledContent("服务提供方", value: analysis.provider)
                    LabeledContent("结果来源", value: analysis.cached == true ? "当前成绩快照的缓存" : "实时生成或历史记录")
                    LabeledContent("生成时间", value: analysis.createdAt.replacingOccurrences(of: "T", with: " "))
                    Button("重新生成") { onRegenerate() }
                    Divider()
                    ForEach(Array(analysis.content.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { entry in
                        let line = String(entry.element).trimmingCharacters(in: .whitespaces)
                        if line.hasPrefix("## ") {
                            Text(String(line.dropFirst(3))).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                            Label(String(line.dropFirst(2)), systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon).font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(line).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("分析结果")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
