import PhotosUI
import SwiftUI
import UIKit

enum ProfileDraftState {
    static func candidate(original: LocalProfile, name: String, avatar: Data?) -> LocalProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = trimmed == original.resolvedDisplayName ? original.displayName : trimmed
        return LocalProfile(displayName: savedName, avatarData: avatar)
    }

    static func isDirty(original: LocalProfile, name: String, avatar: Data?) -> Bool {
        candidate(original: original, name: name, avatar: avatar) != original
    }
}

enum ProfilePresentation: Equatable {
    case sheet, navigation
}

@MainActor
struct ProfileView: View {
    @ObservedObject var state: AppState
    let revision: Int
    let presentation: ProfilePresentation
    @Environment(\.dismiss) private var dismiss
    @State private var original: LocalProfile
    @State private var name: String
    @State private var avatar: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showPreview = false
    @State private var showCrop = false
    @State private var showDiscard = false
    @State private var showRemove = false
    @State private var cropSource: Data?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var mayDismiss = false
    @State private var selectionGeneration = 0

    init(state: AppState, revision: Int, presentation: ProfilePresentation = .sheet) {
        self.state = state
        self.revision = revision
        self.presentation = presentation
        _original = State(initialValue: state.currentProfile)
        _name = State(initialValue: state.currentProfile.resolvedDisplayName)
        _avatar = State(initialValue: state.currentProfile.avatarData)
    }

    private var dirty: Bool { ProfileDraftState.isDirty(original: original, name: name, avatar: avatar) }
    private var validName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= 64
    }

    var body: some View {
        Group {
            if presentation == .sheet {
                NavigationStack { editor }
            } else {
                editor
            }
        }
        .background {
            if presentation == .sheet {
                ProfileDismissGuard(shouldConfirm: dirty && !mayDismiss) {
                    showDiscard = true
                }
            }
        }
        .interactiveDismissDisabled(presentation == .sheet && (dirty || isBusy) && !mayDismiss)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in selectPhoto(item) }
        .onChange(of: state.authenticationRevision) { _, newRevision in
            if newRevision != revision {
                selectionGeneration += 1
                dismiss()
            }
        }
        .sheet(isPresented: $showPreview) {
            AvatarPreviewView(data: avatar)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showCrop) {
            if let cropSource {
                AvatarCropView(source: cropSource) { cropped in
                    guard (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
                    avatar = cropped
                    showCrop = false
                }
            }
        }
        .confirmationDialog("移除头像？", isPresented: $showRemove) {
            Button("移除头像", role: .destructive) { avatar = nil }
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $showDiscard) {
            Button("放弃修改", role: .destructive) {
                selectionGeneration += 1
                mayDismiss = true
                dismiss()
            }
        }
        .alert("个人资料操作失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var editor: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Button { showPreview = true } label: {
                        avatarFace.frame(width: 112, height: 112)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看头像大图")
                    HStack(spacing: 12) {
                        Button("从相册选择") { showPhotoPicker = true }
                        if avatar != nil {
                            Button("移除头像", role: .destructive) { showRemove = true }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } header: { Text("头像") }

            Section("显示名称") {
                TextField("显示名称", text: $name)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()
                    .accessibilityLabel("显示名称")
                Text("仅用于本机显示，不会修改登录用户名或教务姓名。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("头像和显示名称仅保存在此设备，不会上传服务器，也不会在其他设备同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let profileError = state.profileError {
                    Text(profileError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("个人资料")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(presentation == .navigation && (dirty || isBusy))
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { close() }
                }
            } else if dirty || isBusy {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: { Label("返回", systemImage: "chevron.left") }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!dirty || !validName || isBusy)
            }
        }
    }

    private var avatarFace: some View {
        Group {
            if let avatar, let image = UIImage(data: avatar) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(name == "航的助手" || name.isEmpty ? "航" : String(name.suffix(1)))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Circle())
    }

    private func close() {
        if dirty { showDiscard = true }
        else {
            selectionGeneration += 1
            mayDismiss = true
            dismiss()
        }
    }

    private func save() {
        guard !isBusy else { return }
        guard validName else { errorMessage = LocalProfileError.invalidName.localizedDescription; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let candidate = ProfileDraftState.candidate(original: original, name: name, avatar: avatar)
            try state.saveLocalProfile(candidate, revision: revision)
            selectionGeneration += 1
            mayDismiss = true
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func selectPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let selectedRevision = revision
        selectionGeneration += 1
        let generation = selectionGeneration
        isBusy = true
        Task {
            defer {
                if generation == selectionGeneration { isBusy = false; selectedPhoto = nil }
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let prepared = try await AvatarImageProcessor.prepare(data)
                guard generation == selectionGeneration else { return }
                _ = try state.requireCurrentAccount(revision: selectedRevision)
                cropSource = prepared
                showCrop = true
            } catch {
                guard generation == selectionGeneration else { return }
                guard (try? state.requireCurrentAccount(revision: selectedRevision)) != nil else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ProfileDismissGuard: UIViewControllerRepresentable {
    let shouldConfirm: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.shouldConfirm = shouldConfirm
        context.coordinator.onAttempt = onAttempt
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            (controller.parent?.presentationController ?? controller.presentationController)?.delegate = coordinator
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var shouldConfirm = false
        var onAttempt: (() -> Void)?

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !shouldConfirm
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt?()
        }
    }
}
