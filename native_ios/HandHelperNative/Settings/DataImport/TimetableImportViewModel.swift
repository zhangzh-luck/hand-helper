import Foundation
import SwiftUI

@MainActor
final class TimetableImportViewModel: ObservableObject {
    @Published private(set) var selectedFileName: String?
    @Published private(set) var isReading = false
    @Published private(set) var isInspecting = false
    @Published private(set) var errorMessage: String?

    private let state: AppState
    private let reader: any ImportFileReading
    private let service: any TimetableImportServicing
    private var selectedFile: MultipartFilePayload?
    private var selectedOwner: String?
    private var selectedRevision: Int?
    private var selectionGeneration = 0
    private var readTask: Task<MultipartFilePayload, Error>?
    private var uploadTask: Task<Void, Never>?

    init(state: AppState, reader: (any ImportFileReading)? = nil,
         service: any TimetableImportServicing) {
        self.state = state
        self.reader = reader ?? ImportFileReader()
        self.service = service
    }

    var canUpload: Bool {
        guard selectedFile != nil, let selectedOwner, let selectedRevision else { return false }
        return !isReading && uploadTask == nil && state.visibleTimetableImport == nil &&
            (try? state.requireCurrentAccount(revision: selectedRevision)) == selectedOwner
    }

    func select(_ url: URL) async {
        let revision = state.authenticationRevision
        let owner: String
        do { owner = try state.requireCurrentAccount(revision: revision) }
        catch { errorMessage = error.localizedDescription; return }
        readTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedFile = nil
        selectedFileName = nil
        selectedOwner = nil
        selectedRevision = nil
        isReading = true
        errorMessage = nil
        defer {
            if generation == selectionGeneration {
                readTask = nil
                isReading = false
            }
        }
        do {
            let fileReader = reader
            let task = Task { try await fileReader.readXLS(from: url) }
            readTask = task
            let file = try await task.value
            guard !Task.isCancelled, generation == selectionGeneration,
                  (try? state.requireCurrentAccount(revision: revision)) == owner else { return }
            selectedFile = file
            selectedFileName = url.lastPathComponent
            selectedOwner = owner
            selectedRevision = revision
        } catch is CancellationError {
            return
        } catch {
            guard generation == selectionGeneration,
                  (try? state.requireCurrentAccount(revision: revision)) == owner else { return }
            errorMessage = error.localizedDescription
        }
    }

    func selectionCancelled() {
        // A cancelled picker never starts a network operation.
    }

    func fileSelectionFailed(_ error: Error) {
        errorMessage = "无法选择文件：\(error.localizedDescription)"
    }

    func authenticationDidChange() {
        cancelFileSelection()
        isInspecting = false
        errorMessage = nil
        // The AppState ticket survives same-account Cookie verification; it is
        // cleared and its URLSession task cancelled only by logout/401.
    }

    func cancelFileSelection() {
        readTask?.cancel()
        readTask = nil
        selectionGeneration += 1
        selectedFile = nil
        selectedFileName = nil
        selectedOwner = nil
        selectedRevision = nil
        isReading = false
    }

    func startUpload() {
        guard canUpload, let file = selectedFile else { return }
        let revision = state.authenticationRevision
        let owner: String
        let id: UUID
        do {
            owner = try state.requireCurrentAccount(revision: revision)
            id = try state.beginTimetableImport(revision: revision)
        } catch { errorMessage = error.localizedDescription; return }
        selectedFile = nil
        selectedFileName = nil
        selectedOwner = nil
        selectedRevision = nil
        errorMessage = nil
        let task = Task {
            await self.performUpload(file, id: id, owner: owner, revision: revision)
        }
        uploadTask = task
        state.setTimetableUploadCancellation({ task.cancel() }, id: id)
    }

    private func performUpload(_ file: MultipartFilePayload, id: UUID,
                               owner: String, revision: Int) async {
        defer { uploadTask = nil }
        do {
            let result = try await service.upload(file)
            guard !Task.isCancelled, state.pendingTimetableImport?.id == id else { return }
            // The accepted response is retained in AppState before any further
            // suspension, even if the root view is about to switch for /auth/me.
            state.acceptTimetableImport(result, id: id)
        } catch {
            guard state.pendingTimetableImport?.id == id else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError,
               state.authenticationRevision == revision {
                state.handleUnauthorized()
            } else if Self.isLocalUploadFailure(error) {
                state.discardTimetableImport(id: id)
                if (try? state.requireCurrentAccount(revision: revision)) == owner {
                    errorMessage = error.localizedDescription
                }
            } else {
                state.markTimetableImportUnconfirmed(
                    "上传结果尚不明确。服务器可能已经处理文件；请先只读核实，不会自动重新上传。\n\(error.localizedDescription)",
                    id: id)
            }
        }
    }

    private static func isLocalUploadFailure(_ error: Error) -> Bool {
        if let apiError = error as? APIError, case .invalidConfiguration = apiError { return true }
        if let fileError = error as? ImportFileError { return fileError == .wrongExtension || fileError == .unreadable }
        if let uploadError = error as? MultipartUploadError {
            switch uploadError {
            case .emptyFile, .fileTooLarge, .invalidTermID: return true
            case .sessionChanged: return false
            }
        }
        // A response from the import endpoint, including 422, can arrive after
        // the server committed the course replacement but failed to rebuild sessions.
        return false
    }

    func cancelUpload() {
        guard let operation = state.visibleTimetableImport,
              case .uploading = operation.phase else { return }
        uploadTask?.cancel()
        state.markTimetableImportUnconfirmed("已停止等待上传结果；服务器是否完成导入仍需核实。", id: operation.id)
    }

    func waitForUploadCompletion() async {
        await uploadTask?.value
    }

    func inspectUnconfirmed() async {
        guard !isInspecting, let operation = state.visibleTimetableImport,
              case .unconfirmed = operation.phase else { return }
        let revision = state.authenticationRevision
        guard (try? state.requireCurrentAccount(revision: revision)) == operation.owner else { return }
        isInspecting = true
        errorMessage = nil
        defer { isInspecting = false }
        do {
            let inspection = try await service.inspect(isCurrent: {
                self.state.visibleTimetableImport?.id == operation.id &&
                (try? self.state.requireCurrentAccount(revision: revision)) == operation.owner
            })
            guard !Task.isCancelled else { return }
            state.noteTimetableInspection(inspection, id: operation.id,
                                          owner: operation.owner, revision: revision)
        } catch {
            guard state.visibleTimetableImport?.id == operation.id else { return }
            errorMessage = "只读核实未完成：\(error.localizedDescription)"
        }
    }

    func discardResult() {
        guard let operation = state.visibleTimetableImport else { return }
        if case .uploading = operation.phase { return }
        state.discardTimetableImport(id: operation.id)
        errorMessage = nil
    }
}
