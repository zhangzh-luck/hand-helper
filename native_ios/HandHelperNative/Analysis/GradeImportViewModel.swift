import Foundation
import SwiftUI

@MainActor
final class GradeImportViewModel: ObservableObject {
    @Published var termID = ""
    @Published private(set) var selectedFileName: String?
    @Published private(set) var isReading = false
    @Published private(set) var errorMessage: String?

    private let state: AppState
    private let reader: any GradeFileReading
    private let service: any GradeImportServicing
    private var selectedFile: MultipartFilePayload?
    private var selectedOwner: String?
    private var selectedRevision: Int?
    private var selectionGeneration = 0
    private var readTask: Task<MultipartFilePayload, Error>?
    private var uploadTask: Task<Void, Never>?

    init(state: AppState, reader: (any GradeFileReading)? = nil,
         service: any GradeImportServicing) {
        self.state = state
        self.reader = reader ?? GradeFileReader()
        self.service = service
    }

    var normalizedTermID: String? {
        let value = termID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var isTermIDValid: Bool {
        guard let value = normalizedTermID else { return true }
        return value.range(of: #"^20\d{2}-20\d{2}-[12]$"#, options: .regularExpression) != nil
    }

    var canUpload: Bool {
        guard selectedFile != nil, let selectedOwner, let selectedRevision else { return false }
        return !isReading && uploadTask == nil && state.visibleGradeImport == nil && isTermIDValid &&
            (try? state.requireCurrentAccount(revision: selectedRevision)) == selectedOwner
    }

    func select(_ url: URL) async {
        let revision = state.authenticationRevision
        let owner: String
        do { owner = try state.requireCurrentAccount(revision: revision) }
        catch { errorMessage = error.localizedDescription; return }
        cancelFileSelection()
        let generation = selectionGeneration
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
            let task = Task { try await fileReader.read(from: url) }
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
        // No upload is started by a dismissed document picker.
    }

    func fileSelectionFailed(_ error: Error) {
        errorMessage = "无法选择文件：\(error.localizedDescription)"
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

    func authenticationDidChange() {
        cancelFileSelection()
        errorMessage = nil
        // AppState retains an already-started preview request across same-owner
        // Cookie verification; the result is hidden until identity is verified.
    }

    func startUpload() {
        guard canUpload, let file = selectedFile else { return }
        let revision = state.authenticationRevision
        let id: UUID
        do { id = try state.beginGradeImport(revision: revision) }
        catch { errorMessage = error.localizedDescription; return }
        let term = normalizedTermID
        let requestCookie = state.sessionStore.cookie
        cancelFileSelection()
        errorMessage = nil
        let task = Task {
            await self.performUpload(file, termID: term, id: id,
                                     revision: revision, requestCookie: requestCookie)
        }
        uploadTask = task
        state.setGradeUploadCancellation({ task.cancel() }, id: id)
    }

    private func performUpload(_ file: MultipartFilePayload, termID: String?, id: UUID,
                               revision: Int, requestCookie: String?) async {
        defer { uploadTask = nil }
        do {
            let preview = try await service.preview(file: file, termID: termID)
            guard !Task.isCancelled else { return }
            state.acceptGradePreview(preview, id: id)
        } catch is CancellationError {
            state.discardGradeImport(id: id)
        } catch {
            guard state.pendingGradeImport?.id == id else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError,
               state.authenticationRevision == revision,
               (state.sessionStore.cookie == requestCookie || state.sessionStore.cookie == nil) {
                state.handleUnauthorized()
            } else {
                state.failGradeImport(error.localizedDescription, id: id)
            }
        }
    }

    func cancelUpload() {
        guard let operation = state.visibleGradeImport,
              case .uploading = operation.phase else { return }
        state.discardGradeImport(id: operation.id)
    }

    func discardResult() {
        guard let operation = state.visibleGradeImport else { return }
        state.discardGradeImport(id: operation.id)
        errorMessage = nil
    }

    func waitForUploadCompletion() async {
        await uploadTask?.value
    }
}
