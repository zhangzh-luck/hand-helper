import PhotosUI
import SwiftUI
import UIKit

enum WallpaperSelectionError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "所选照片无法读取，请选择其他图片。" }
}

@MainActor
final class WallpaperSettingsModel: ObservableObject {
    @Published private(set) var wallpaperData: Data?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private let state: AppState
    private let store: WallpaperStore
    private let revision: Int
    private var selectionGeneration = 0

    init(state: AppState, revision: Int, store: WallpaperStore? = nil) {
        self.state = state
        self.revision = revision
        self.store = store ?? WallpaperStore(session: state.sessionStore, account: state.verifiedAccount)
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
            guard UIImage(data: data) != nil else { throw WallpaperSelectionError.unreadableImage }
            try store.save(data)
            wallpaperData = data
            try state.wallpaperDidChange(revision: revision)
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
            try state.wallpaperDidChange(revision: revision)
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

    func clearError() { errorMessage = nil }
}

@MainActor
struct WallpaperSettingsView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: WallpaperSettingsModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectionTask: Task<Void, Never>?
    @State private var showResetConfirmation = false

    init(state: AppState) {
        self.state = state
        _model = StateObject(wrappedValue: WallpaperSettingsModel(
            state: state, revision: state.authenticationRevision
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
                    .accessibilityLabel("当前今日页壁纸预览")
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
        .navigationTitle("今日页壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.load() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectionTask = Task {
                await model.replace { try await item.loadTransferable(type: Data.self) }
                selectedPhoto = nil
                selectionTask = nil
            }
        }
        .onChange(of: state.authenticationRevision) { _, _ in
            selectionTask?.cancel()
            selectedPhoto = nil
            model.clearVisibleWallpaper()
        }
        .onDisappear {
            selectionTask?.cancel()
            model.cancelSelection()
        }
        .confirmationDialog("恢复默认背景？", isPresented: $showResetConfirmation) {
            Button("恢复默认背景", role: .destructive) { model.restoreDefault() }
        } message: {
            Text("今日页将使用系统背景。")
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
}
