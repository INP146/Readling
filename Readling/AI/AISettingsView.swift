import SwiftUI

/// Settings › AI 服务: the user's LLM endpoints. Each feature (translation, …)
/// picks which one it uses in its own settings.
struct AISettingsView: View {
    @State private var editing: AIEndpointEditorView.Mode?
    private let store = AIEndpointStore.shared
    private let translation = TranslationService.shared

    var body: some View {
        SettingsList {
            Section {
                ForEach(store.endpoints) { endpoint in
                    Button { editing = .existing(endpoint) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: endpoint.displayName).foregroundStyle(Color.primary)
                                Text(verbatim: endpoint.subtitle).font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) { store.remove(endpoint.id) }
                    }
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editing = .existing(endpoint) }
                        Button("删除", systemImage: "trash", role: .destructive) { store.remove(endpoint.id) }
                    }
                }
                Button { editing = .new } label: {
                    Label("添加服务…", systemImage: "plus")
                }
                .accessibilityIdentifier("add-ai-endpoint")
            } footer: {
                Text("添加大模型服务：官方 API、中转站，或局域网里的 Ollama、LM Studio 等。翻译等功能在各自的设置里选择用哪个服务。使用时，选中的文字和所在的句子会发给该服务，书的其余内容和生词本不会上传。")
            }
            Section {
                NavigationLink {
                    TranslationPromptsView()
                } label: {
                    LabeledContent("翻译", value: translation.prompts.resolved == .default ? String(localized: "默认") : String(localized: "已自定义"))
                }
            } header: { Text("提示词") } footer: {
                Text("每个功能有自己的提示词，所有 AI 服务通用。")
            }
        }
        .navigationTitle("AI 服务")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { mode in
            NavigationStack { AIEndpointEditorView(mode: mode) }
        }
    }
}

/// Creates or edits an AI endpoint: API format, base URL, optional API key,
/// model name, and a live test.
struct AIEndpointEditorView: View {
    enum Mode: Identifiable {
        case new
        case existing(AIEndpoint)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let endpoint): endpoint.id.uuidString
            }
        }
    }

    private struct Preset {
        var name: String
        var format: AIFormat
        var address: String
    }

    private static let presets: [Preset] = [
        .init(name: "OpenAI", format: .openAI, address: "https://api.openai.com/v1"),
        .init(name: "DeepSeek", format: .openAI, address: "https://api.deepseek.com/v1"),
        .init(name: "OpenRouter", format: .openAI, address: "https://openrouter.ai/api/v1"),
        .init(name: "通义千问", format: .openAI, address: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(name: "Kimi", format: .openAI, address: "https://api.moonshot.cn/v1"),
        .init(name: "Ollama（局域网）", format: .openAI, address: "http://192.168.1.2:11434/v1"),
        .init(name: "Claude", format: .claude, address: "https://api.anthropic.com/v1"),
        .init(name: "Gemini", format: .gemini, address: "https://generativelanguage.googleapis.com/v1beta"),
    ]

    let mode: Mode
    /// Called with the endpoint after it is saved, e.g. to start using a new one.
    var onSave: (AIEndpoint) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: AIEndpoint
    @State private var key: KeyDraft
    @State private var saveError: String?
    private let store = AIEndpointStore.shared

    init(mode: Mode, onSave: @escaping (AIEndpoint) -> Void = { _ in }) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .new:
            _endpoint = State(initialValue: AIEndpoint(name: "", format: .openAI, baseURL: AIFormat.openAI.defaultBaseURL, model: ""))
            _key = State(initialValue: KeyDraft())
        case .existing(let endpoint):
            _endpoint = State(initialValue: endpoint)
            _key = State(initialValue: KeyDraft(saved: AIEndpointStore.shared.key(for: endpoint.id)))
        }
    }

    private struct Draft: Equatable { var endpoint: AIEndpoint; var key: String? }

    private var isEditingExisting: Bool { if case .existing = mode { true } else { false } }
    private var client: (any AIClient)? { endpoint.format.client(for: endpoint, key: key.effective) }
    private var canFetchModels: Bool { endpoint.format.previewURL(address: endpoint.baseURL) != nil }

    var body: some View {
        SettingsList {
            Section {
                TextField("名称（可选，如 DeepSeek、本机 Ollama）", text: $endpoint.name)
                Picker("接口格式", selection: $endpoint.format) {
                    ForEach(AIFormat.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Menu("填入常用预设") {
                    ForEach(Self.presets, id: \.name) { preset in
                        Button("\(preset.name)（\(preset.format.title)）") { apply(preset) }
                    }
                }
            } footer: {
                Text("许多第三方中转站和本地推理服务（Ollama、LM Studio、vLLM、OneAPI）使用 OpenAI 兼容、Claude 或 Gemini 接口格式，按服务商文档选择即可。")
            }
            Section {
                TextField("https://…", text: $endpoint.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: { Text("服务地址") } footer: {
                if let preview = endpoint.format.previewURL(address: endpoint.baseURL, model: endpoint.model) {
                    Text(verbatim: "请求地址：\(preview.absoluteString)")
                } else {
                    Text("地址要以 https:// 或 http:// 开头。")
                }
            }
            APIKeySection(draft: $key, placeholder: "API Key（本地无鉴权服务可留空）") {
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                } else {
                    Text("Key 只存在本机钥匙串里，不随 iCloud 同步，也不进备份。建议单独创建一个设置了额度上限的 Key；局域网里的无鉴权服务可留空。")
                }
            }
            Section {
                TextField("模型名", text: $endpoint.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                NavigationLink("从服务获取模型列表") {
                    AIModelList(format: endpoint.format, address: endpoint.baseURL, key: key.effective, selection: $endpoint.model)
                }
                .disabled(!canFetchModels)
            } header: { Text("模型") } footer: {
                Text("从服务拉取可用模型列表，或直接填写模型 ID。")
            }
            ServiceTestSection(draft: Draft(endpoint: endpoint, key: key.effective),
                               request: client.map { client in { client.complete(.connectionTest) } },
                               footer: "发送一句短英文请模型翻译，验证当前填写的地址、接口格式、模型和 Key 可用。")
            if isEditingExisting {
                Section {
                    Button("删除服务", role: .destructive) {
                        store.remove(endpoint.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isEditingExisting ? "编辑 AI 服务" : "添加 AI 服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(client == nil)
            }
        }
        .onChange(of: endpoint.format) { oldFormat, newFormat in
            let trimmed = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == oldFormat.defaultBaseURL {
                endpoint.baseURL = newFormat.defaultBaseURL
            }
        }
    }

    private func apply(_ preset: Preset) {
        let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || Self.presets.contains(where: { $0.name == trimmedName }) {
            endpoint.name = preset.name
        }
        endpoint.format = preset.format
        endpoint.baseURL = preset.address
    }

    private func save() {
        do {
            try store.save(endpoint, keyChange: key.change)
            onSave(endpoint)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// The models an endpoint lists, searchable; picking one fills in the model name.
private struct AIModelList: View {
    var format: AIFormat
    var address: String
    var key: String?
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String]?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        SettingsList {
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if let models {
                let shown = query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
                ForEach(shown, id: \.self) { model in
                    Button { selection = model; dismiss() } label: {
                        HStack {
                            Text(verbatim: model).foregroundStyle(Color.primary)
                            Spacer()
                            if model == selection { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .task {
            do {
                let fetched = try await format.models(address: address, key: key)
                models = fetched
                if fetched.isEmpty { error = String(localized: "服务没有列出模型，请直接填写模型名。") }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
