import PhotosUI
import SwiftUI
import UIKit

enum WallpaperSelectionError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "所选照片无法读取，请选择其他图片。" }
}

struct WallpaperPhotoSelection: Identifiable {
    let id = UUID()
    let image: UIImage
    let generation: Int
    let aspectRatio: CGFloat
}

@MainActor
final class WallpaperSettingsModel: ObservableObject {
    @Published private(set) var wallpaperData: Data?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private let state: AppState
    private let store: WallpaperStore
    private let kind: WallpaperKind
    private let revision: Int
    private var selectionGeneration = 0

    init(state: AppState, revision: Int, kind: WallpaperKind = .today,
         store: WallpaperStore? = nil) {
        self.state = state
        self.revision = revision
        self.store = store ?? WallpaperStore(session: state.sessionStore,
                                             account: state.verifiedAccount, kind: kind)
        self.kind = self.store.kind
    }

    func load() {
        do {
            _ = try state.requireCurrentAccount(revision: revision)
            wallpaperData = try store.load()
            errorMessage = nil
        } catch {
            wallpaperData = nil
            errorMessage = "本机壁纸无法读取：\(error.localizedDescription)"
        }
    }

    func replace(using loadPhoto: () async throws -> Data?) async {
        guard !isWorking else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        do {
            _ = try state.requireCurrentAccount(revision: revision)
            isWorking = true
            defer { if generation == selectionGeneration { isWorking = false } }
            guard let data = try await loadPhoto() else { throw WallpaperSelectionError.unreadableImage }
            guard generation == selectionGeneration, !Task.isCancelled else { return }
            _ = try state.requireCurrentAccount(revision: revision)
            let storedData: Data
            if kind == .timetable || kind == .analysis {
                storedData = try await TimetableWallpaperImage.prepare(data)
            } else {
                guard UIImage(data: data) != nil else { throw WallpaperSelectionError.unreadableImage }
                storedData = data
            }
            guard generation == selectionGeneration, !Task.isCancelled else { return }
            _ = try state.requireCurrentAccount(revision: revision)
            try store.save(storedData)
            wallpaperData = storedData
            try publishChange()
            errorMessage = nil
        } catch {
            guard generation == selectionGeneration, !Task.isCancelled else { return }
            errorMessage = "壁纸无法保存：\(error.localizedDescription)"
        }
    }

    func selectPhoto(using loadPhoto: () async throws -> Data?, aspectRatio: CGFloat) async -> WallpaperPhotoSelection? {
        guard !isWorking, aspectRatio > 0 else { return nil }
        selectionGeneration += 1
        let generation = selectionGeneration
        do {
            _ = try state.requireCurrentAccount(revision: revision)
            isWorking = true
            defer { if generation == selectionGeneration { isWorking = false } }
            guard let data = try await loadPhoto(), !data.isEmpty,
                  data.count <= TimetableWallpaperImage.maxSourceBytes,
                  generation == selectionGeneration, !Task.isCancelled else {
                return nil
            }
            guard let sourceImage = UIImage(data: data) else { throw WallpaperSelectionError.unreadableImage }
            let image = try WallpaperCropProcessor.normalized(sourceImage)
            guard Double(image.size.width) * Double(image.size.height) <= Double(TimetableWallpaperImage.maxSourcePixels) else {
                throw TimetableWallpaperImageError.oversizedSource
            }
            guard generation == selectionGeneration, !Task.isCancelled else { return nil }
            return WallpaperPhotoSelection(image: image, generation: generation, aspectRatio: aspectRatio)
        } catch {
            guard generation == selectionGeneration, !Task.isCancelled else { return nil }
            errorMessage = "壁纸无法读取：\(error.localizedDescription)"
            return nil
        }
    }

    func saveCropped(_ data: Data, generation: Int) async {
        guard generation == selectionGeneration, !isWorking else { return }
        do {
            _ = try state.requireCurrentAccount(revision: revision)
            isWorking = true
            defer { if generation == selectionGeneration { isWorking = false } }
            let storedData: Data
            if kind == .timetable || kind == .analysis {
                storedData = try await TimetableWallpaperImage.prepare(data)
            } else {
                guard UIImage(data: data) != nil else { throw WallpaperSelectionError.unreadableImage }
                storedData = data
            }
            guard generation == selectionGeneration, !Task.isCancelled else { return }
            _ = try state.requireCurrentAccount(revision: revision)
            try store.save(storedData)
            wallpaperData = storedData
            try publishChange()
            errorMessage = nil
        } catch {
            guard generation == selectionGeneration, !Task.isCancelled else { return }
            errorMessage = "壁纸无法保存：\(error.localizedDescription)"
        }
    }

    func restoreDefault() {
        cancelSelection()
        do {
            _ = try state.requireCurrentAccount(revision: revision)
            try store.remove()
            wallpaperData = nil
            try publishChange()
            errorMessage = nil
        } catch {
            errorMessage = "默认背景无法恢复：\(error.localizedDescription)"
        }
    }

    func cancelSelection() {
        selectionGeneration += 1
        isWorking = false
    }

    func clearVisibleWallpaper() {
        cancelSelection()
        wallpaperData = nil
        errorMessage = nil
    }

    func reportLayoutUnavailable() {
        errorMessage = "页面布局尚未准备好，请返回该页面后再试。"
    }

    func clearError() { errorMessage = nil }

    private func publishChange() throws {
        switch kind {
        case .today: try state.wallpaperDidChange(revision: revision)
        case .timetable: try state.timetableWallpaperDidChange(revision: revision)
        case .analysis: try state.analysisWallpaperDidChange(revision: revision)
        }
    }
}

@MainActor
struct WallpaperSettingsView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: WallpaperSettingsModel
    private let kind: WallpaperKind
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectionTask: Task<Void, Never>?
    @State private var cropSelection: WallpaperPhotoSelection?
    @State private var cropPreview: WallpaperCropPreview?
    @State private var pendingCropPreview: WallpaperCropPreview?
    @State private var showResetConfirmation = false

    init(state: AppState, kind: WallpaperKind = .today) {
        self.state = state
        self.kind = kind
        _model = StateObject(wrappedValue: WallpaperSettingsModel(
            state: state, revision: state.authenticationRevision, kind: kind
        ))
    }

    var body: some View {
        Form {
            Section("当前壁纸") {
                if let data = model.wallpaperData, let image = UIImage(data: data) {
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("当前\(title)预览")
                } else {
                    Label("正在使用默认背景", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("更换壁纸", systemImage: "photo.on.rectangle")
                }
                .disabled(model.isWorking)

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("恢复默认背景", systemImage: "rectangle.slash")
                }
                .disabled(model.isWorking || model.wallpaperData == nil)

                if model.isWorking { ProgressView("正在保存壁纸") }
            } header: {
                Text("管理")
            } footer: {
                Text("壁纸只保存在此设备，不会上传服务器。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { model.load() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            guard let aspectRatio = state.wallpaperContainerAspectRatio(for: kind) else {
                model.reportLayoutUnavailable()
                selectedPhoto = nil
                return
            }
            selectionTask = Task {
                cropSelection = await model.selectPhoto(using: { try await item.loadTransferable(type: Data.self) },
                                                        aspectRatio: aspectRatio)
                selectedPhoto = nil
                selectionTask = nil
            }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            selectionTask?.cancel()
            selectedPhoto = nil
            cropSelection = nil
            cropPreview = nil
            pendingCropPreview = nil
            model.clearVisibleWallpaper()
        }
        .onDisappear {
            selectionTask?.cancel()
            if cropSelection == nil && cropPreview == nil && pendingCropPreview == nil {
                model.cancelSelection()
            }
        }
        .fullScreenCover(item: $cropSelection, onDismiss: {
            if let pendingCropPreview {
                cropPreview = pendingCropPreview
                self.pendingCropPreview = nil
            }
        }) { selection in
            WallpaperCropEditorView(image: selection.image, aspectRatio: selection.aspectRatio,
                                    onCancel: {
                                        model.cancelSelection()
                                        pendingCropPreview = nil
                                        cropSelection = nil
                                    }, onComplete: { data in
                                        pendingCropPreview = WallpaperCropPreview(data: data,
                                                                                  generation: selection.generation)
                                        cropSelection = nil
                                    })
        }
        .sheet(item: $cropPreview) { preview in
            WallpaperCropPreviewView(preview: preview, onCancel: {
                model.cancelSelection()
                cropPreview = nil
            }, onUse: {
                cropPreview = nil
                selectionTask = Task {
                    await model.saveCropped(preview.data, generation: preview.generation)
                    selectionTask = nil
                }
            })
            .interactiveDismissDisabled()
        }
        .confirmationDialog("恢复默认背景？", isPresented: $showResetConfirmation) {
            Button("恢复默认背景", role: .destructive) { model.restoreDefault() }
        } message: {
            Text("\(kind == .today ? "今日页" : kind == .timetable ? "课程表" : "分析页")将使用系统背景。")
        }
        .alert("壁纸操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("确定", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var title: String {
        switch kind {
        case .today: "今日页壁纸"
        case .timetable: "课程表壁纸"
        case .analysis: "分析页壁纸"
        }
    }
}
