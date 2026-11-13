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

enum AccountSettingsConfirmation: Equatable {
    case removeAvatar, discardChanges

    var title: String {
        switch self {
        case .removeAvatar: "移除头像？"
        case .discardChanges: "放弃未保存的修改？"
        }
    }
}

enum AccountSettingsAlert: Equatable {
    case logout(hasUnsavedChanges: Bool)
    case profileError(String)

    var title: String {
        switch self {
        case .logout: "退出当前账号？"
        case .profileError: "个人资料操作失败"
        }
    }

    var message: String {
        switch self {
        case .logout(let hasUnsavedChanges):
            return hasUnsavedChanges
                ? "未保存的头像或显示名称修改将被放弃。本机已保存的个人资料会保留。"
                : "本机已保存的个人资料会保留，重新验证同一账号后可继续使用。"
        case .profileError(let message):
            return message
        }
    }
}

@MainActor
struct ProfileView: View {
    @ObservedObject var state: AppState
    let revision: Int
    let presentation: ProfilePresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.settingsNavigator) private var settingsNavigator
    @State private var original: LocalProfile
    @State private var name: String
    @State private var avatar: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showPreview = false
    @State private var showCrop = false
    @State private var confirmation: AccountSettingsConfirmation?
    @State private var activeAlert: AccountSettingsAlert?
    @State private var cropSource: Data?
    @State private var isBusy = false
    @State private var logoutRequested = false
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
                    requestConfirmation(.discardChanges)
                }
            }
        }
        .interactiveDismissDisabled(presentation == .sheet && (dirty || isBusy) && !mayDismiss)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in selectPhoto(item) }
        .onChange(of: state.authenticationRevision) { _, newRevision in
            if newRevision != revision {
                selectionGeneration += 1
                confirmation = nil
                activeAlert = nil
                logoutRequested = false
                dismissProfileEditor()
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
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            switch confirmation {
            case .removeAvatar:
                Button("移除头像", role: .destructive) { avatar = nil }
            case .discardChanges:
                Button("放弃修改", role: .destructive) {
                    selectionGeneration += 1
                    mayDismiss = true
                    dismissProfileEditor()
                }
            case nil:
                EmptyView()
            }
        }
        .alert(activeAlert?.title ?? "", isPresented: Binding(
            get: { activeAlert != nil },
            set: { if !$0 { activeAlert = nil } }
        )) {
            switch activeAlert {
            case .logout:
                Button("取消", role: .cancel) { }
                Button("退出登录", role: .destructive) {
                    guard !logoutRequested else { return }
                    logoutRequested = true
                    Task {
                        guard (try? state.requireCurrentAccount(revision: revision)) != nil else {
                            logoutRequested = false
                            return
                        }
                        selectionGeneration += 1
                        await state.logout()
                    }
                }
            case .profileError:
                Button("确定", role: .cancel) { }
            case nil:
                EmptyView()
            }
        } message: {
            if let activeAlert { Text(activeAlert.message) }
        }
    }

    private var editor: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Button { showPreview = true } label: {
                        avatarFace.frame(width: 112, height: 112)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看头像大图")
                    avatarActions
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            } header: { Text("头像") }

            Section("显示名称") {
                nameInput
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                if let profileError = state.profileError {
                    Text(profileError).foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                logoutButton
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("账户设置")
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

    @ViewBuilder
    private var avatarActions: some View {
        let actions = HStack(spacing: 12) {
            Button("从相册选择") { showPhotoPicker = true }
            if avatar != nil {
                Button("移除头像", role: .destructive) { requestConfirmation(.removeAvatar) }
            }
        }
        if #available(iOS 26.0, *), !reduceTransparency {
            actions.buttonStyle(.glass)
        } else {
            actions.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var nameInput: some View {
        let field = TextField("显示名称", text: $name)
            .textContentType(.nickname)
            .autocorrectionDisabled()
            .accessibilityLabel("显示名称")
            .padding(12)
        if #available(iOS 26.0, *), !reduceTransparency {
            field.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            field.background(Color(uiColor: .secondarySystemGroupedBackground),
                             in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var logoutButton: some View {
        let button = Button(role: .destructive) { requestLogoutAlert() } label: {
            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .tint(.red)
        .disabled(isBusy || logoutRequested || showPhotoPicker || showPreview || showCrop)
        if #available(iOS 26.0, *), !reduceTransparency {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
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
        guard !isBusy, !logoutRequested else { return }
        if dirty { requestConfirmation(.discardChanges) }
        else {
            selectionGeneration += 1
            mayDismiss = true
            dismissProfileEditor()
        }
    }

    private func requestConfirmation(_ choice: AccountSettingsConfirmation) {
        guard confirmation == nil, activeAlert == nil, !logoutRequested,
              !isBusy, !showPhotoPicker, !showPreview, !showCrop else { return }
        confirmation = choice
    }

    private func dismissProfileEditor() {
        if presentation == .navigation, settingsNavigator != nil {
            settingsNavigator?.pop()
        } else {
            dismiss()
        }
    }

    private func requestLogoutAlert() {
        guard confirmation == nil, activeAlert == nil, !logoutRequested,
              !isBusy, !showPhotoPicker, !showPreview, !showCrop,
              (try? state.requireCurrentAccount(revision: revision)) != nil else { return }
        activeAlert = .logout(hasUnsavedChanges: dirty)
    }

    private func save() {
        guard !isBusy else { return }
        guard validName else {
            activeAlert = .profileError(LocalProfileError.invalidName.localizedDescription)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let candidate = ProfileDraftState.candidate(original: original, name: name, avatar: avatar)
            try state.saveLocalProfile(candidate, revision: revision)
            selectionGeneration += 1
            mayDismiss = true
            dismissProfileEditor()
        } catch { activeAlert = .profileError(error.localizedDescription) }
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
                activeAlert = .profileError(error.localizedDescription)
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
