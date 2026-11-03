import SwiftUI
import UIKit

@MainActor
struct AnalysisView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: AnalysisViewModel
    @ObservedObject private var gradeDetail: GradeDetailCoordinator
    private let timetableDetail: TimetableCourseDetailCoordinator
    private let deleteConfirmation: DestructiveConfirmationCoordinator
    @State private var reportRoute: AnalysisReportRoute?
    @State private var historyOpen = false
    @State private var deleteTermID: Int?
    @State private var wallpaperImage: UIImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var gradeTitleMinimumHeight: CGFloat = 42
    @ScaledMetric(relativeTo: .body) private var gradeRowMinimumHeight: CGFloat = 90
    @ScaledMetric(relativeTo: .title2) private var gradeScoreColumnWidth: CGFloat = 82

    init(state: AppState, gradeDetail: GradeDetailCoordinator,
         timetableDetail: TimetableCourseDetailCoordinator,
         deleteConfirmation: DestructiveConfirmationCoordinator) {
        self.state = state
        self.gradeDetail = gradeDetail
        self.timetableDetail = timetableDetail
        self.deleteConfirmation = deleteConfirmation
        _model = StateObject(wrappedValue: AnalysisViewModel(state: state))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let wallpaperImage, !reduceTransparency, contrast != .increased {
                    GeometryReader { proxy in
                        Image(uiImage: wallpaperImage).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                    Color(uiColor: colorScheme == .dark ? .black : .systemBackground)
                        .opacity(colorScheme == .dark ? 0.34 : 0.24)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                } else {
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                }
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
            }
            .navigationTitle("成绩分析")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("刷新成绩")
                        .disabled(model.refreshing || !state.canAccessPrivateData)
                }
            }
            .task { loadWallpaper(); model.loadIfNeeded() }
            .onChange(of: state.selectedTab) { _, tab in
                if tab == .analysis { model.loadIfNeeded() }
                else { gradeDetail.clear() }
            }
            .onChange(of: state.authenticationRevision) { _, _ in
                gradeDetail.clear()
                deleteTermID = nil
                wallpaperImage = nil
                model.authenticationDidChange()
                if state.selectedTab == .analysis { loadWallpaper() }
            }
            .onChange(of: state.analysisWallpaperVersion) { _, _ in loadWallpaper() }
            .onChange(of: model.selectedTermID) { _, _ in
                gradeDetail.clear()
                reportRoute = nil
                historyOpen = false
                deleteTermID = nil
                if deleteConfirmation.request?.kind == .grades { deleteConfirmation.clear() }
            }
            .onChange(of: model.snapshot) { _, _ in
                validateGradeDetail()
                if deleteTermID != nil, model.selectedData?.grades.isEmpty != false {
                    self.deleteTermID = nil
                    if deleteConfirmation.request?.kind == .grades { deleteConfirmation.clear() }
                }
            }
            .sheet(item: $reportRoute) { route in
                GradeAIReportView(analysis: route.analysis) {
                    reportRoute = nil
                    model.generateAnalysis(force: true) { showReport($0) }
                }
            }
        }
    }

    private func loadWallpaper() {
        guard state.canAccessPrivateData else { wallpaperImage = nil; return }
        let store = WallpaperStore(session: state.sessionStore, account: state.verifiedAccount,
                                   kind: .analysis)
        wallpaperImage = (try? store.load()).flatMap(UIImage.init(data:))
    }

    private func openGradeDetail(_ grade: GradeRecord) {
        guard state.selectedTab == .analysis, state.canAccessPrivateData,
              reportRoute == nil, deleteTermID == nil,
              !timetableDetail.isPresenting,
              let termID = model.selectedTermID, grade.termID == termID,
              model.selectedData?.grades.first(where: { $0.id == grade.id }) == grade,
              let owner = try? state.requireCurrentAccount(revision: state.authenticationRevision)
        else { return }
        let context = GradeDetailContext(owner: owner,
            authenticationRevision: state.authenticationRevision,
            termID: termID, gradeID: grade.id)
        _ = gradeDetail.open(grade: grade, context: context)
    }

    private func validateGradeDetail() {
        guard let route = gradeDetail.route else { return }
        let owner = try? state.requireCurrentAccount(revision: state.authenticationRevision)
        let grade = model.selectedData?.grades.first(where: { $0.id == route.context.gradeID })
        gradeDetail.invalidate(owner: owner, authenticationRevision: state.authenticationRevision,
                               termID: model.selectedTermID, grade: grade)
    }

    private func showReport(_ analysis: GradeAIAnalysis) {
        guard !gradeDetail.isPresenting, deleteTermID == nil,
              state.selectedTab == .analysis, state.canAccessPrivateData else { return }
        reportRoute = AnalysisReportRoute(analysis: analysis)
    }

    private func confirmGradeDeletion() {
        guard !gradeDetail.isPresenting, reportRoute == nil, !model.deleting,
              let termID = model.selectedTermID,
              let owner = try? state.requireCurrentAccount(revision: state.authenticationRevision)
        else { return }
        let revision = state.authenticationRevision
        deleteTermID = termID
        if !deleteConfirmation.present(.grades, confirm: {
            guard deleteTermID == termID,
                  model.selectedTermID == termID,
                  (try? state.requireCurrentAccount(revision: revision)) == owner else {
                deleteTermID = nil
                return
            }
            deleteTermID = nil
            model.deleteSelectedTerm(termID)
        }, cancel: {
            if deleteTermID == termID { deleteTermID = nil }
        }) {
            deleteTermID = nil
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
                metric("不及格", summary.map { String($0.failedCourses) } ?? "—", symbol: "exclamationmark.circle")
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
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if let result = model.currentAnalysis {
                        showReport(result)
                    } else {
                        model.generateAnalysis { showReport($0) }
                    }
                } label: {
                    HStack {
                        Label(model.currentAnalysis == nil ? "生成 AI 成绩分析" : "查看 AI 成绩分析",
                              systemImage: "sparkles")
                        Spacer()
                        if model.analyzing { ProgressView() }
                        else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(model.analyzing || model.refreshing || model.offline ||
                          model.selectedData?.grades.isEmpty != false)
                Divider()
                Button {
                    withAnimation(.smooth) { historyOpen.toggle() }
                } label: {
                    HStack {
                        Text("历史分析")
                        Spacer()
                        Text("\(model.selectedData?.history.count ?? 0) 条")
                            .foregroundStyle(.secondary)
                        Image(systemName: historyOpen ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                if historyOpen {
                    ForEach(model.selectedData?.history ?? []) { result in
                        Divider()
                        Button {
                            showReport(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.model).font(.body.weight(.medium))
                                Text(result.createdAt.replacingOccurrences(of: "T", with: " "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                    if model.selectedData?.history.isEmpty != false {
                        Text("当前学期还没有历史分析。")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
            Text("仅在你点击生成后，将当前学期课程名称、成绩、学分和绩点发送给已配置的模型服务。")
                .font(.footnote).foregroundStyle(.secondary)
            if let error = model.actionError { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var gradesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课程成绩").font(.title3.weight(.semibold))
            let grades = model.selectedData?.grades ?? []
            if !grades.isEmpty && !model.offline {
                gradeDeleteButton
            }
            if grades.isEmpty {
                ContentUnavailableView("暂无课程成绩", systemImage: "doc.text",
                                       description: Text("导入并确认成绩后，这里会显示课程明细。"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(grades) { grade in
                        Button { openGradeDetail(grade) } label: { gradeRow(grade) }
                            .buttonStyle(.plain)
                        if grade.id != grades.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var gradeDeleteButton: some View {
        let button = Button(role: .destructive) { confirmGradeDeletion() } label: {
            Label(model.deleting ? "正在删除" : "删除本学期成绩", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
        }
        .accessibilityLabel(model.deleting ? "正在删除本学期成绩" : "删除本学期成绩")
        .disabled(model.deleting || model.refreshing || model.analyzing)

        return Group {
            if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
                button.buttonStyle(.glass(.regular.tint(.red)))
                    .foregroundStyle(.red)
            } else if reduceTransparency || contrast == .increased {
                button.buttonStyle(.bordered)
                    .tint(.red)
            } else {
                button.buttonStyle(GradeDeleteMaterialButtonStyle())
            }
        }
    }

    private func gradeRow(_ grade: GradeRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(grade.courseName)
                    .font(.system(size: 17, weight: .semibold, relativeTo: .body))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: gradeTitleMinimumHeight, alignment: .topLeading)
                Text("\(grade.courseType ?? "课程性质未提供") · \(grade.credits.map { String($0) } ?? "—") 学分 · GPA \(grade.gradePoint.map { String($0) } ?? "—")")
                    .font(.system(size: 13, relativeTo: .footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("成绩")
                    .font(.system(size: 12, relativeTo: .caption))
                    .foregroundStyle(.secondary)
                Text(grade.score ?? "未公布")
                    .font(grade.score == nil
                          ? .subheadline.weight(.semibold)
                          : .system(size: 24, weight: .bold, relativeTo: .title2))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: gradeScoreColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(minHeight: gradeRowMinimumHeight)
        .accessibilityElement(children: .combine)
    }
}

private struct GradeDeleteMaterialButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.red)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
