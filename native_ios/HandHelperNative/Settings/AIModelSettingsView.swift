import Foundation
import SwiftUI

struct AIProviderSettings: Codable, Equatable {
    let configured: Bool
    let provider: String?
    let baseURL: String?
    let model: String?
    let apiKeyHint: String?
    let availableModels: [String]
    let modelsSyncedAt: String?
    let requiresAPIKeyFanMigration: Bool

    enum CodingKeys: String, CodingKey {
        case configured, provider, model
        case baseURL = "base_url"
        case apiKeyHint = "api_key_hint"
        case availableModels = "available_models"
        case modelsSyncedAt = "models_synced_at"
        case requiresAPIKeyFanMigration = "requires_apikey_fan_migration"
    }
}

private struct AISettingsInput: Encodable {
    let provider: String
    let baseURL: String
    let model: String
    let apiKey: String
    enum CodingKeys: String, CodingKey { case provider, model; case baseURL = "base_url"; case apiKey = "api_key" }
}

private struct AIModelLookupInput: Encodable {
    let provider: String
    let baseURL: String
    let apiKey: String
    enum CodingKeys: String, CodingKey { case provider; case baseURL = "base_url"; case apiKey = "api_key" }
}

private struct AIModelSelectionInput: Encodable { let model: String }
private struct AIModelList: Decodable { let models: [String] }
private struct AIConnectionTest: Decodable { let message: String }

@MainActor
private final class AIModelSettingsModel: ObservableObject {
    @Published var provider = "APIKEY.FAN"
    @Published var baseURL = "https://api.apikey.fan/v1"
    @Published var model = ""
    @Published var apiKey = ""
    @Published var settings: AIProviderSettings?
    @Published var models: [String] = []
    @Published var loading = false
    @Published var saving = false
    @Published var message: String?
    @Published var error: String?

    private let state: AppState
    private var owner: String?
    private var revision = 0

    init(state: AppState) { self.state = state }

    var isConfigured: Bool { settings?.configured == true }
    var keyStatus: String { apiKey.isEmpty ? (settings?.apiKeyHint ?? "未配置") : "待保存" }
    var canSave: Bool { !saving && apiKey.count >= 8 && !model.isEmpty && baseURL.hasPrefix("https://") }

    func load() {
        guard let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { clear(); return }
        if owner != currentOwner || revision != state.authenticationRevision { clear(); owner = currentOwner; revision = state.authenticationRevision }
        guard !loading else { return }
        loading = true
        let token = revision
        Task {
            defer { if self.revision == token { self.loading = false } }
            do {
                let value: AIProviderSettings = try await state.api.request("GET", path: "/api/v1/ai/settings", body: nil, preserveSessionOnPasswordError: false)
                guard self.isCurrent(currentOwner, token) else { return }
                apply(value, clearKey: true)
            } catch {
                guard self.isCurrent(currentOwner, token) else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func fetchModels() { performModelsLookup(savedConfiguration: isConfigured && apiKey.isEmpty && provider == settings?.provider && baseURL == settings?.baseURL) }

    func save() {
        guard canSave, let owner else { error = "请填写 HTTPS 服务地址、至少 8 位 API Key，并选择模型。"; return }
        saving = true; error = nil
        let token = revision
        let body = try? JSONEncoder().encode(AISettingsInput(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey))
        Task {
            defer { if self.isCurrent(owner, token) { self.saving = false } }
            do {
                guard let body else { throw APIError.invalidConfiguration }
                let value: AIProviderSettings = try await state.api.request("PUT", path: "/api/v1/ai/settings", body: body, preserveSessionOnPasswordError: false)
                guard self.isCurrent(owner, token) else { return }
                apply(value, clearKey: true); message = "模型配置已保存。"
            } catch { guard self.isCurrent(owner, token) else { return }; self.error = error.localizedDescription }
        }
    }

    func selectSavedModel(_ selected: String) {
        guard isConfigured, apiKey.isEmpty, let owner else { model = selected; return }
        let token = revision
        Task {
            do {
                let body = try JSONEncoder().encode(AIModelSelectionInput(model: selected))
                let value: AIProviderSettings = try await state.api.request("PATCH", path: "/api/v1/ai/settings/model", body: body, preserveSessionOnPasswordError: false)
                guard self.isCurrent(owner, token) else { return }
                apply(value, clearKey: true); message = "模型已切换。"
            } catch { guard self.isCurrent(owner, token) else { return }; self.error = error.localizedDescription }
        }
    }

    func test() {
        guard apiKey.count >= 8, !model.isEmpty, let owner else { error = "请填写 API Key 并选择模型。"; return }
        let token = revision
        Task {
            do {
                let body = try JSONEncoder().encode(AISettingsInput(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey))
                let result: AIConnectionTest = try await state.api.request("POST", path: "/api/v1/ai/settings/test", body: body, preserveSessionOnPasswordError: false)
                guard self.isCurrent(owner, token) else { return }; message = result.message
            } catch { guard self.isCurrent(owner, token) else { return }; self.error = error.localizedDescription }
        }
    }

    func clearSavedSettings() {
        guard let owner else { return }; let token = revision
        Task {
            do {
                let _: DeleteResponse = try await state.api.request("DELETE", path: "/api/v1/ai/settings", body: nil, preserveSessionOnPasswordError: false)
                guard self.isCurrent(owner, token) else { return }; clear(); self.message = "模型服务配置已清除。"
            } catch { guard self.isCurrent(owner, token) else { return }; self.error = error.localizedDescription }
        }
    }

    private func performModelsLookup(savedConfiguration: Bool) {
        guard let owner else { return }; let token = revision; error = nil
        Task {
            do {
                if savedConfiguration {
                    let value: AIProviderSettings = try await state.api.request("POST", path: "/api/v1/ai/settings/models/refresh", body: nil, preserveSessionOnPasswordError: false)
                    guard self.isCurrent(owner, token) else { return }; apply(value, clearKey: false)
                } else {
                    guard apiKey.count >= 8 else { throw APIError.server(status: 422, message: "请先填写至少 8 位 API Key。") }
                    let body = try JSONEncoder().encode(AIModelLookupInput(provider: provider, baseURL: baseURL, apiKey: apiKey))
                    let result: AIModelList = try await state.api.request("POST", path: "/api/v1/ai/settings/models", body: body, preserveSessionOnPasswordError: false)
                    guard self.isCurrent(owner, token) else { return }; models = result.models; if !models.contains(model) { model = models.first ?? "" }
                }
                message = "已读取 \(models.count) 个可用模型。"
            } catch { guard self.isCurrent(owner, token) else { return }; self.error = error.localizedDescription }
        }
    }

    private func apply(_ value: AIProviderSettings, clearKey: Bool) {
        settings = value; provider = value.provider ?? "APIKEY.FAN"; baseURL = value.baseURL ?? "https://api.apikey.fan/v1"; model = value.model ?? ""; models = value.availableModels
        if clearKey { apiKey = "" }
    }
    private func isCurrent(_ candidate: String, _ token: Int) -> Bool { owner == candidate && revision == token && (try? state.requireCurrentAccount(revision: token)) == candidate }
    private func clear() { owner = nil; settings = nil; models = []; apiKey = ""; model = ""; provider = "APIKEY.FAN"; baseURL = "https://api.apikey.fan/v1"; error = nil }
}

private struct DeleteResponse: Decodable { let deleted: Bool }

struct AIModelSettingsView: View {
    @ObservedObject var state: AppState
    @StateObject private var model: AIModelSettingsModel
    @State private var showKey = false
    @State private var confirmClear = false

    init(state: AppState) { self.state = state; _model = StateObject(wrappedValue: AIModelSettingsModel(state: state)) }
    var body: some View {
        Form {
            Section("模型服务") {
                Picker("服务预设", selection: $model.provider) { Text("APIKEY.FAN").tag("APIKEY.FAN"); Text("自定义服务").tag("自定义") }
                    .onChange(of: model.provider) { _, value in if value == "APIKEY.FAN" { model.baseURL = "https://api.apikey.fan/v1"; model.models = [] } }
                TextField("服务名称", text: $model.provider).textInputAutocapitalization(.characters)
                TextField("HTTPS 服务地址", text: $model.baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                HStack { Group { if showKey { TextField("API Key", text: $model.apiKey) } else { SecureField("API Key", text: $model.apiKey) } }.textInputAutocapitalization(.never).autocorrectionDisabled(); Button(showKey ? "隐藏" : "显示") { showKey.toggle() } }
                LabeledContent("已保存 API Key", value: model.keyStatus)
            }
            Section("模型") {
                Picker("当前模型", selection: $model.model) { Text(model.model.isEmpty ? "请选择" : model.model).tag(model.model); ForEach(model.models, id: \.self) { Text($0).tag($0) } }
                    .onChange(of: model.model) { _, value in if !value.isEmpty { model.selectSavedModel(value) } }
                Button("获取模型列表", systemImage: "arrow.clockwise") { model.fetchModels() }
                Button("测试当前配置", systemImage: "checkmark.circle") { model.test() }.disabled(model.apiKey.count < 8 || model.model.isEmpty)
            }
            Section { Button(model.saving ? "正在保存…" : "保存配置") { model.save() }.frame(maxWidth: .infinity).disabled(!model.canSave) }
            if model.isConfigured { Section("危险操作") { Button("清除模型服务配置", systemImage: "trash", role: .destructive) { confirmClear = true } } }
            Section { Text("API Key 仅在保存、读取模型或测试连接时提交给后端；客户端不会持久化或回显明文。 ").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("AI 模型配置").navigationBarTitleDisplayMode(.inline)
        .overlay { if model.loading { ProgressView("正在读取配置") } }
        .alert("清除模型服务配置？", isPresented: $confirmClear) { Button("取消", role: .cancel) {}; Button("清除", role: .destructive) { model.clearSavedSettings() } } message: { Text("地址、模型和 API Key 将从后端移除；成绩与分析历史不受影响。") }
        .alert("提示", isPresented: Binding(get: { model.error != nil || model.message != nil }, set: { if !$0 { model.error = nil; model.message = nil } })) { Button("好", role: .cancel) {} } message: { Text(model.error ?? model.message ?? "") }
        .onAppear { model.load() }.onChange(of: state.authenticationRevision) { _, _ in model.load() }
    }
}
