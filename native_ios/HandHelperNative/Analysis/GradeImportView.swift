import SwiftUI

@MainActor
struct GradeImportView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: GradeImportViewModel
    @State private var showingPicker = false
    @State private var pickerRevision: Int?
    @State private var pickerOwner: String?
    @State private var readingPickedFile = false

    init(state: AppState) {
        self.state = state
        _model = StateObject(wrappedValue: GradeImportViewModel(
            state: state, service: GradeImportService(api: state.api)))
    }

    var body: some View {
        List {
            Section("文件与学期") {
                TextField("学期（可留空自动识别）", text: $model.termID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model.termID) { _, value in
                        if value.count > 11 { model.termID = String(value.prefix(11)) }
                    }
                    .disabled(state.visibleGradeImport != nil)
                if !model.isTermIDValid {
                    Text("学期格式应为 2025-2026-2。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    let revision = state.authenticationRevision
                    guard let owner = try? state.requireCurrentAccount(revision: revision) else { return }
                    pickerRevision = revision
                    pickerOwner = owner
                    showingPicker = true
                } label: {
                    Label("选择成绩文件", systemImage: "doc.badge.plus")
                }
                .disabled(!state.canAccessPrivateData || model.isReading || state.visibleGradeImport != nil)

                if model.isReading { ProgressView("正在读取并校验文件") }
                if let name = model.selectedFileName {
                    LabeledContent("已选择", value: name)
                    Button("上传并预览") { model.startUpload() }
                        .disabled(!model.canUpload)
                }
            } footer: {
                Text("支持 .xls、.html、.htm，最大 2,000,000 字节。学期留空时由文件内容识别。上传仅生成预览，不保存成绩。")
            }

            if let operation = state.visibleGradeImport {
                switch operation.phase {
                case .uploading:
                    Section("解析状态") {
                        ProgressView("正在上传并解析成绩")
                        Button("取消等待", role: .destructive) { model.cancelUpload() }
                    }
                case .ready(let preview):
                    previewSections(preview)
                case .failed(let message):
                    Section("预览未完成") {
                        Text(message).foregroundStyle(.red)
                        Button("重新选择文件") { model.discardResult() }
                    }
                }
            }

            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("导入成绩文件")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            // The established timetable picker uses .item for legacy XLS file
            // providers. GradeFileReader enforces the three allowed extensions.
            TimetableDocumentPicker { outcome in handlePickerOutcome(outcome) }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            model.authenticationDidChange()
            pickerRevision = nil
            pickerOwner = nil
            readingPickedFile = false
            showingPicker = false
        }
        .onDisappear {
            // Picker presentation/dismissal must not discard a selected URL
            // before the bounded read completes.
            if !showingPicker && !readingPickedFile { model.cancelFileSelection() }
        }
    }

    @ViewBuilder
    private func previewSections(_ preview: GradeImportPreview) -> some View {
        Section("预览结果") {
            LabeledContent("所属学期", value: preview.sourceTermID)
            LabeledContent("识别课程", value: "\(preview.grades.count) 门")
            Text("以下内容仅供核对，尚未导入成绩数据库。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("关闭预览") { model.discardResult() }
        }
        Section("课程成绩") {
            ForEach(preview.grades.indices, id: \.self) { index in
                let grade = preview.grades[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(grade.courseName).font(.headline)
                    HStack(spacing: 16) {
                        Text("成绩：\(grade.score ?? "未提供")")
                        Text("学分：\(grade.credits.map { String($0) } ?? "未提供")")
                    }
                    .font(.subheadline)
                    Text("绩点：\(grade.gradePoint.map { String($0) } ?? "未提供")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }
        }
    }

    private func handlePickerOutcome(_ outcome: TimetableDocumentPickerOutcome) {
        let revision = pickerRevision
        let owner = pickerOwner
        pickerRevision = nil
        pickerOwner = nil
        switch outcome {
        case .selected(let url):
            guard let revision, let owner,
                  (try? state.requireCurrentAccount(revision: revision)) == owner else {
                showingPicker = false
                model.fileSelectionFailed(TimetableDocumentPickerError.sessionChanged)
                return
            }
            readingPickedFile = true
            showingPicker = false
            Task {
                guard (try? state.requireCurrentAccount(revision: revision)) == owner else {
                    readingPickedFile = false
                    model.fileSelectionFailed(TimetableDocumentPickerError.sessionChanged)
                    return
                }
                await model.select(url)
                readingPickedFile = false
            }
        case .failed(let error):
            showingPicker = false
            model.fileSelectionFailed(error)
        case .cancelled:
            showingPicker = false
            model.selectionCancelled()
        }
    }
}
