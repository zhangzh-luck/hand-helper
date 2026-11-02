import SwiftUI

@MainActor
struct AnalysisView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: AnalysisViewModel

    init(state: AppState) {
        self.state = state
        _model = StateObject(wrappedValue: AnalysisViewModel(state: state))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    termPicker
                    if model.offline, model.snapshot != nil {
                        Label("当前离线，显示本机缓存的成绩", systemImage: "wifi.slash")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = model.errorMessage, model.snapshot != nil {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.selectedTerm != nil {
                        overview
                        aiSection
                        gradesSection
                    } else if model.loading {
                        ProgressView("正在读取成绩")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ContentUnavailableView(model.snapshot == nil ? "成绩暂不可用" : "暂无学期",
                                               systemImage: "chart.bar",
                                               description: Text(model.errorMessage ?? "请检查网络后重试。"))
                        Button("重试") { model.refresh() }.frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("成绩分析")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("刷新成绩")
                        .disabled(model.refreshing || !state.canAccessPrivateData)
                }
            }
            .task { model.loadIfNeeded() }
            .onChange(of: state.selectedTab) { _, tab in
                if tab == .analysis { model.loadIfNeeded() }
            }
            .onChange(of: state.authenticationRevision) { _, _ in model.authenticationDidChange() }
        }
    }

    private var termPicker: some View {
        Menu {
            ForEach(model.snapshot?.terms ?? [], id: \.id) { term in
                Button {
                    model.selectTerm(term.id)
                } label: {
                    if term.id == model.selectedTermID { Label(term.displayName, systemImage: "checkmark") }
                    else { Text(term.displayName) }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前学期").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.selectedTerm?.displayName ?? "选择学期")
                        .font(.headline).foregroundStyle(.primary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(model.snapshot?.terms.isEmpty ?? true)
        .accessibilityLabel("选择学期，当前\(model.selectedTerm?.displayName ?? "无")")
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("成绩概览").font(.title3.weight(.semibold))
            let summary = model.selectedData?.summary
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                metric("已获学分", summary?.earnedCredits.map { String($0) } ?? "—", symbol: "graduationcap")
                metric("平均成绩", summary?.averageScore.map { String(format: "%.1f", $0) } ?? "—", symbol: "number")
                metric("绩点", summary?.gpa.map { String(format: "%.2f", $0) } ?? "—", symbol: "chart.bar")
                metric("不及格", summary?.failedCourses.map { String($0) } ?? "—", symbol: "exclamationmark.circle")
            }
            if let note = summary?.gpaNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 成绩分析").font(.title3.weight(.semibold))
            Text("分析操作将在下一阶段接入。").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var gradesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课程成绩").font(.title3.weight(.semibold))
            let grades = model.selectedData?.grades ?? []
            if grades.isEmpty {
                ContentUnavailableView("暂无课程成绩", systemImage: "doc.text",
                                       description: Text("导入并确认成绩后，这里会显示课程明细。"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(grades) { grade in
                        gradeRow(grade)
                        if grade.id != grades.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func gradeRow(_ grade: GradeRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(grade.courseName).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(grade.courseType ?? "课程性质未提供") · \(grade.credits.map { String($0) } ?? "—") 学分 · GPA \(grade.gradePoint.map { String($0) } ?? "—")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(grade.score ?? "未公布").font(.headline).multilineTextAlignment(.trailing)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}
