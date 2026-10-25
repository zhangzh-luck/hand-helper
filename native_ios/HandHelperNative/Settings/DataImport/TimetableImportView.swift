import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TimetableImportPickerTypes {
    // File providers may advertise legacy .xls files under unrelated types.
    // The picker permits items; ImportFileReader validates the extension and size.
    static let allowed: [UTType] = [.item]
}

enum TimetableDocumentPickerError: LocalizedError {
    case noFileURL

    var errorDescription: String? { "文件选择器没有返回可读取的文件。" }
}

enum TimetableDocumentPickerOutcome {
    case selected(URL)
    case cancelled
    case failed(Error)
}

@MainActor
struct TimetableDocumentPicker: UIViewControllerRepresentable {
    let onResult: (TimetableDocumentPickerOutcome) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // A copied URL remains readable after this picker is dismissed.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: TimetableImportPickerTypes.allowed, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onResult: (TimetableDocumentPickerOutcome) -> Void
        private var completed = false

        init(onResult: @escaping (TimetableDocumentPickerOutcome) -> Void) {
            self.onResult = onResult
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
#if DEBUG
            print("[TimetableImport] UIKit picker didPickDocumentsAt: \(urls.count) URL(s)")
#endif
            if let url = urls.first, url.isFileURL {
                onResult(.selected(url))
            } else {
                onResult(.failed(TimetableDocumentPickerError.noFileURL))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
#if DEBUG
            print("[TimetableImport] UIKit picker cancelled")
#endif
            onResult(.cancelled)
        }
    }
}

@MainActor
struct TimetableImportView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: TimetableImportViewModel
    @State private var showingImporter = false
    @State private var pickerOutcome: TimetableDocumentPickerOutcome?
    @State private var pickerRevision: Int?
    @State private var confirmingReplacement = false

    init(state: AppState) {
        self.state = state
        _model = StateObject(wrappedValue: TimetableImportViewModel(
            state: state, service: TimetableImportService(api: state.api)))
    }

    var body: some View {
        List {
            Section {
                Button {
#if DEBUG
                    print("[TimetableImport] presenting file picker")
#endif
                    pickerOutcome = nil
                    pickerRevision = state.authenticationRevision
                    showingImporter = true
                } label: {
                    Label("选择 XLS 课表文件", systemImage: "doc.badge.plus")
                }
                .disabled(!state.canAccessPrivateData || model.isReading || state.visibleTimetableImport != nil)

                if model.isReading { ProgressView("正在读取并校验文件") }
                if let name = model.selectedFileName {
                    LabeledContent("已选择", value: name)
                    Button("继续导入") { confirmingReplacement = true }
                        .disabled(!model.canUpload)
                }
            } footer: {
                Text("仅支持 .xls，文件最大 2,000,000 字节。选择后才会读取文件；确认替换前不会上传。")
            }

            if let operation = state.visibleTimetableImport {
                operationSection(operation)
            }

            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("导入课表")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImporter, onDismiss: finishFileSelection) {
            TimetableDocumentPicker { outcome in
                pickerOutcome = outcome
                showingImporter = false
            }
        }
        .confirmationDialog("替换文件所属学期的课程？", isPresented: $confirmingReplacement) {
            Button("确认导入", role: .destructive) { model.startUpload() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("导入后将替换文件所属学期已有的导入课程。手动添加的课程不属于本次替换范围。")
        }
        .onChange(of: state.authenticationRevision) { _, _ in
#if DEBUG
            print("[TimetableImport] authentication changed; dismissing file picker")
#endif
            model.authenticationDidChange()
            confirmingReplacement = false
            pickerOutcome = nil
            pickerRevision = nil
            showingImporter = false
        }
        .onChange(of: showingImporter) { _, isPresented in
#if DEBUG
            print(isPresented
                  ? "[TimetableImport] file picker presented"
                  : "[TimetableImport] file picker dismissed")
#endif
        }
        .onDisappear {
#if DEBUG
            print("[TimetableImport] import page disappeared")
#endif
            // Presenting the UIKit picker must not cancel the pending selection.
            if !showingImporter { model.cancelFileSelection() }
            confirmingReplacement = false
        }
    }

    private func finishFileSelection() {
        defer {
            pickerOutcome = nil
            pickerRevision = nil
        }
        guard pickerRevision == state.authenticationRevision,
              state.canAccessPrivateData else {
            model.selectionCancelled()
            return
        }
        switch pickerOutcome {
        case .selected(let url):
#if DEBUG
            print("[TimetableImport] UIKit picker returned a URL; starting validation")
#endif
            Task {
                await model.select(url)
#if DEBUG
                print(model.selectedFileName == nil
                      ? "[TimetableImport] file validation did not complete"
                      : "[TimetableImport] file validation completed")
#endif
            }
        case .failed(let error):
            model.fileSelectionFailed(error)
        case .cancelled, .none:
            model.selectionCancelled()
        }
    }

    @ViewBuilder
    private func operationSection(_ operation: PendingTimetableImport) -> some View {
        Section("导入状态") {
            switch operation.phase {
            case .uploading:
                ProgressView("正在上传课表")
                Button("停止等待上传", role: .destructive) { model.cancelUpload() }
            case .accepted(let result):
                resultRows(result)
                Text("服务端已接受；正在等待当前账号重新验证，然后刷新今日课程。")
                    .foregroundStyle(.secondary)
            case .refreshPending(let result, _):
                resultRows(result)
                Text("服务端导入已成功。今日课程正在刷新或等待重新进入今日页；刷新失败时会保留待刷新标记。")
                    .foregroundStyle(.secondary)
            case .refreshCompleted(let result):
                resultRows(result)
                Text("今日课程已完成严格刷新并保存本地快照。")
                    .foregroundStyle(.secondary)
                Button("导入另一份文件") { model.discardResult() }
            case .unconfirmed(let message):
                Text(message).foregroundStyle(.secondary)
                if let inspection = operation.inspection {
                    Text("当前服务端有 \(inspection.termCount) 个学期、\(inspection.sessionCount) 条课程日程。现有接口无法证明本次上传是否完成。")
                        .foregroundStyle(.secondary)
                }
                Button("只读核实服务端状态") { Task { await model.inspectUnconfirmed() } }
                    .disabled(model.isInspecting)
                if model.isInspecting { ProgressView("正在读取服务端状态") }
                Button("重新选择文件") { model.discardResult() }
            }
        }
    }

    @ViewBuilder
    private func resultRows(_ result: TimetableImportResult) -> some View {
        LabeledContent("所属学期", value: result.termID)
        LabeledContent("导入课程", value: "\(result.coursesImported)")
        LabeledContent("生成日程", value: "\(result.sessionsGenerated)")
        if result.ignoredNotes {
            Text("文件中的备注未导入。")
                .foregroundStyle(.secondary)
        }
        if result.sessionsGenerated == 0 {
            Text("没有生成日程不一定表示导入失败；该学期可能尚未设置第一周周一。")
                .foregroundStyle(.secondary)
        }
    }
}
