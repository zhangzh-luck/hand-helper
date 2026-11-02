import SwiftUI

@MainActor
struct GradeDetailView: View {
    let grade: GradeRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(grade.courseName)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 8) {
                        score("总评成绩", grade.score ?? "未公布", emphasized: true)
                        score("期末成绩", grade.finalExamScore ?? "未提供")
                        score("平时成绩", grade.usualScore ?? "未提供")
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                    VStack(spacing: 0) {
                        detail("课程名称", grade.courseName, symbol: "book")
                        detail("学分 / 绩点", "\(grade.credits.map { String($0) } ?? "—") / \(grade.gradePoint.map { String($0) } ?? "—")", symbol: "graduationcap")
                        detail("课程性质", grade.courseType ?? "未提供", symbol: "books.vertical")
                        detail("考试性质", grade.examType ?? "未提供", symbol: "doc.text")
                        detail("补考 / 重修", "\(grade.makeupFlag ? "补考" : "否") / \(grade.retakeFlag ? "重修" : "否")", symbol: "arrow.clockwise")
                    }
                    .padding(.horizontal, 16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("成绩详情")
            .navigationBarTitleDisplayMode(.inline)
        }
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

    private func detail(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
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
