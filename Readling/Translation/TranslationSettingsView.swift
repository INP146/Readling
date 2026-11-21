import SwiftUI
@preconcurrency import Translation

/// Settings › 翻译: which service translates (Apple, DeepL, or one of the AI
/// endpoints), Apple's language pack, and whether to translate automatically.
struct TranslationSettingsView: View {
    @AppStorage(TranslationService.automaticKey) private var automatic = true
    @State private var status: LanguageAvailability.Status?
    @State private var download: TranslationSession.Configuration?
    @State private var editingDeepL = false
    @State private var editingEndpoint: AIEndpointEditorView.Mode?
    private let service = TranslationService.shared

    var body: some View {
        SettingsList {
            Section {
                row(.apple, subtitle: String(localized: "本机离线"))
                row(.deepL, subtitle: service.isDeepLConfigured ? String(localized: "只翻译，不解释生词") : String(localized: "未配置"),
                    select: service.isDeepLConfigured ? nil : { editingDeepL = true },
                    edit: { editingDeepL = true })
            } header: { Text("翻译服务") } footer: {
                Text("所选服务请求失败或没有网络时，自动改用 Apple 本机翻译。")
            }
            Section {
                ForEach(service.endpoints.endpoints) { endpoint in
                    row(.ai(endpoint.id), subtitle: endpoint.subtitle, edit: { editingEndpoint = .existing(endpoint) })
                }
                Button { editingEndpoint = .new } label: {
                    Label("添加 AI 服务…", systemImage: "plus")
                }
                .accessibilityIdentifier("add-ai-endpoint")
            } header: { Text("AI 服务") } footer: {
                Text("大模型除了翻译句子，还能结合句子解释词典里没有的词。这里的服务与“设置 › AI 服务”里的是同一批。使用联网服务时，选中的文字和所在的句子会发给该服务，书的其余内容和生词本不会上传。")
            }
            Section {
                LabeledContent("英语 → 简体中文") {
                    switch status {
                    case nil: ProgressView()
                    case .installed: Text("已下载")
                    case .supported:
                        Button("下载语言包") { download = .init(source: TranslationService.source, target: TranslationService.target) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    default: Text("不支持")
                    }
                }
            } header: { Text("Apple 本机翻译") } footer: {
                Text("在本机翻译，不联网。语言包由系统管理，其他 app 也能使用。")
            }
            Section {
                Toggle("查不到时自动翻译", isOn: $automatic)
            } footer: {
                Text("词典里没有的词和选中的句子，在单词卡里直接显示译文。关闭后点“显示译文”才翻译。")
            }
        }
        .navigationTitle("翻译")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingDeepL) {
            NavigationStack {
                DeepLSettingsView { if service.isDeepLConfigured { service.selection = .deepL } }
            }
        }
        .sheet(item: $editingEndpoint) { mode in
            NavigationStack {
                AIEndpointEditorView(mode: mode) { endpoint in
                    if case .new = mode { service.selection = .ai(endpoint.id) }
                }
            }
        }
        .task(id: download == nil) { status = await AppleTranslationEngine.status() }
        .translationTask(download) { session in
            try? await session.prepareTranslation()
            status = await AppleTranslationEngine.status()
            download = nil
        }
    }

    /// A service the user can pick; `select` replaces picking (e.g. to configure it first).
    private func row(_ provider: TranslationProviderID, subtitle: String,
                     select: (() -> Void)? = nil, edit: (() -> Void)? = nil) -> some View {
        let title = service.title(of: provider)
        return HStack(spacing: 12) {
            Button { if let select { select() } else { service.selection = provider } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).foregroundStyle(Color.primary)
                        Text(verbatim: subtitle).font(.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    if service.effectiveSelection == provider {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let edit {
                Button(action: edit) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑 \(title)")
            }
        }
    }
}

/// Settings › AI 服务 › 提示词 › 翻译: the instructions AI endpoints get for translating
/// and for explaining a word in its sentence. Saved as the user types.
struct TranslationPromptsView: View {
    @Bindable private var service = TranslationService.shared

    var body: some View {
        SettingsList {
            section(String(localized: "翻译句子"), text: $service.prompts.translate, fallback: TranslationPrompts.defaultTranslate,
                    footer: String(localized: "用于翻译选中的句子和词典里没有的词组。"))
            section(String(localized: "解释生词"), text: $service.prompts.explain, fallback: TranslationPrompts.defaultExplain,
                    footer: String(localized: "用于结合所在句子解释词典里没有的词，结果显示在单词卡里，建议保持简短。"))
            Section {
                Button("全部恢复默认") { service.prompts = .default }
                    .disabled(service.prompts.resolved == .default)
            } footer: {
                Text("选中的文字和句子由 app 放在标签里附在提示词之后，并提醒模型只把它们当作数据。留空等于使用默认提示词。")
            }
        }
        .navigationTitle("翻译提示词")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, text: Binding<String>, fallback: String, footer: String) -> some View {
        Section {
            TextEditor(text: text)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(title)
            Button("恢复默认") { text.wrappedValue = fallback }
                .disabled(text.wrappedValue == fallback)
        } header: { Text(verbatim: title) } footer: { Text(verbatim: footer) }
    }
}

/// The DeepL service: official DeepL Free / Pro, or a self-hosted DeepLX address.
struct DeepLSettingsView: View {
    var onSave: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var key: KeyDraft
    @State private var saveError: String?
    private let service = TranslationService.shared

    init(onSave: @escaping () -> Void = {}) {
        self.onSave = onSave
        _address = State(initialValue: TranslationService.shared.deepLAddress)
        _key = State(initialValue: KeyDraft(saved: TranslationService.shared.deepLKey))
    }

    private struct Draft: Equatable { var address: String; var key: String? }

    private var configuration: DeepLEngine.Configuration? { DeepLEngine.configuration(address: address, key: key.effective) }

    var body: some View {
        SettingsList {
            Section {
                TextField("https://…", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("恢复官方地址") { address = DeepLEngine.defaultBaseURL }
                    .disabled(address == DeepLEngine.defaultBaseURL)
            } header: { Text("服务地址") } footer: {
                if let preview = DeepLEngine.endpointURL(address, key: key.effective) {
                    Text(verbatim: "请求地址：\(preview.absoluteString)")
                } else {
                    Text("地址要以 https:// 或 http:// 开头。")
                }
            }
            APIKeySection(draft: $key, placeholder: "API Key（自建 DeepLX 可留空）") {
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                } else {
                    Text("Key 只存在本机钥匙串里，不同步也不进备份。官方免费版（以 :fx 结尾）和付费版 Key 会自动选用对应的官方地址；自建 DeepLX 可填自己的地址。")
                }
            }
            ServiceTestSection(draft: Draft(address: address, key: key.effective),
                               request: configuration.map { configuration in
                                   { DeepLEngine(configuration: configuration).run(.translate("The quick brown fox jumps over the lazy dog.")) }
                               },
                               footer: "发送一句短英文，验证当前填写的地址和 Key 可用。")
        }
        .navigationTitle("DeepL")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
            }
        }
    }

    private func save() {
        do {
            try service.saveDeepL(address: address, keyChange: key.change)
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
