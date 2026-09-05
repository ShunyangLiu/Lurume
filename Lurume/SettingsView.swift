import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            TranslationSettingsView()
                .tabItem {
                    Label("翻译", systemImage: "translate")
                }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560, idealHeight: 680)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updaterController: UpdaterController

    var body: some View {
        Form {
            Section("软件更新") {
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { updaterController.automaticallyChecksForUpdates },
                        set: { updaterController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .accessibilityValue(
                    updaterController.automaticallyChecksForUpdates ? "已开启" : "已关闭"
                )

                Text("开启后每 24 小时检查一次。发现新版本时会询问，不会自动下载或安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文献库") {
                Picker("启动时排序", selection: $settings.defaultLibrarySortOption) {
                    ForEach(LibrarySortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Text("下次启动 Lurume 时使用。侧栏排序只影响当前运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TranslationSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var modelSettings: ModelTranslationSettingsController
    @State private var pendingTestDisclosure: TranslationConnectionDisclosure?
    @State private var showsAPIKey = false
    @State private var confirmsLegacyKeyRead = false

    init(modelSettings: ModelTranslationSettingsController = ModelTranslationSettingsController()) {
        _modelSettings = StateObject(wrappedValue: modelSettings)
    }

    var body: some View {
        Form {
            Section("翻译") {
                Picker("翻译引擎", selection: $modelSettings.draftEngine) {
                    ForEach(TranslationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Toggle("自动翻译选中文字", isOn: $settings.automaticTranslation)
                if modelSettings.draftEngine == .customModel, settings.automaticTranslation {
                    Text("开启后，选区稳定时会向配置的服务发送选中文字；远端服务可能计费。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("原文语言", selection: $settings.sourceLanguageIdentifier) {
                    ForEach(TranslationSourceLanguageOption.common) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                Picker("目标语言", selection: $settings.targetLanguageIdentifier) {
                    ForEach(TranslationLanguageOption.common) { language in
                        Text(language.name).tag(language.id)
                    }
                }
            }

            Section("自定义大模型") {
                Picker("服务商", selection: Binding(
                    get: { modelSettings.draftProvider },
                    set: { modelSettings.selectProvider($0) }
                )) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Text(modelSettings.draftProvider.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("API 协议", selection: $modelSettings.draftAPIFormat) {
                    ForEach(TranslationAPIFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                TextField("Base URL", text: $modelSettings.draftBaseURL)
                    .textContentType(.URL)
                    .accessibilityHint("填写 API 根地址；Lurume 会追加 \(modelSettings.draftAPIFormat.endpointSuffix)")
                HStack {
                    TextField("模型", text: $modelSettings.draftModel)
                        .accessibilityHint("可手动填写模型 ID，或从右侧选择预设")
                    if !modelSettings.draftProvider.models.isEmpty {
                        Menu("选择模型") {
                            ForEach(modelSettings.draftProvider.models, id: \.self) { model in
                                Button(model) { modelSettings.draftModel = model }
                            }
                        }
                        .fixedSize()
                    }
                }
                HStack {
                    Group {
                        if showsAPIKey {
                            TextField("API Key（可留空）", text: $modelSettings.draftAPIKey)
                        } else {
                            SecureField("API Key（可留空）", text: $modelSettings.draftAPIKey)
                        }
                    }
                    .accessibilityLabel("API Key")
                    .disabled(modelSettings.isLoadingAPIKey)
                    Button {
                        showsAPIKey.toggle()
                    } label: {
                        Image(systemName: showsAPIKey ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showsAPIKey ? "隐藏 API Key" : "显示 API Key")
                }
                HStack {
                    Text(apiKeyStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("删除 API Key") {
                        Task { await modelSettings.deleteAPIKey() }
                    }
                    .disabled(
                        !modelSettings.hasStoredAPIKey
                            || modelSettings.isLoadingAPIKey
                            || modelSettings.isSaving
                    )
                    .accessibilityHint("仅删除当前服务商和地址的本地 API Key")
                }
                Text("Key 明文保存在本机应用数据目录，仅当前系统用户可读写，不使用钥匙串。备份可能包含 Key，请勿分享该文件。更换服务商、协议或地址会清空未保存的 Key，并加载对应配置的 Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("从旧版钥匙串读取 Key…") {
                    confirmsLegacyKeyRead = true
                }
                .disabled(modelSettings.isLoadingAPIKey || !modelSettings.draftAPIKey.isEmpty)
                Toggle("流式输出", isOn: $modelSettings.draftStreamsResponse)
                Toggle("低延迟翻译参数", isOn: $modelSettings.draftOptimizesForTranslation)
                Text("开启后使用 temperature=0，按选区长度限制输出，并对支持的服务关闭深度思考；短文本预算为 1,024 token。若服务不支持这些参数，可关闭。Claude 协议仍需保留最大输出限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("学术翻译提示词") {
                TextEditor(text: $modelSettings.draftPrompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .accessibilityLabel("学术翻译提示词")
                HStack {
                    Text("\(modelSettings.draftPrompt.count) / \(ModelTranslationConfiguration.maximumPromptCharacters)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            modelSettings.draftPrompt.count
                                > ModelTranslationConfiguration.maximumPromptCharacters ? .red : .secondary
                        )
                    Spacer()
                    Button("恢复默认提示词") {
                        modelSettings.restoreDefaultPrompt()
                    }
                }
            }

            Section {
                Text(testConnectionPrivacyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let normalizationMessage = modelSettings.normalizationMessage {
                    Label(normalizationMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                connectionResult
            }

            Section {
                Text("远端服务的数据保留、训练与计费规则由你选择的服务提供方决定。Lurume 只在测试连接时发送内置测试文本；论文选区会在后续明确确认 origin 后才允许发送。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                configurationActions
                if let message = modelSettings.validationMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if let status = modelSettings.saveStatus {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle({
                            if case .failure = status { return Color.red }
                            return Color.secondary
                        }())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(.bar)
        }
        .disabled(modelSettings.isSaving)
        .onChange(of: modelSettings.draftProvider) { showsAPIKey = false }
        .onChange(of: modelSettings.draftBaseURL) { showsAPIKey = false }
        .onChange(of: modelSettings.draftAPIFormat) { showsAPIKey = false }
        .task {
            await modelSettings.load(from: settings)
        }
        .onDisappear {
            modelSettings.cancelConnectionTest()
        }
        .onChange(of: settings.sourceLanguageIdentifier) { modelSettings.draftDidChange() }
        .onChange(of: settings.targetLanguageIdentifier) { modelSettings.draftDidChange() }
        .alert(item: $pendingTestDisclosure) { disclosure in
            Alert(
                title: Text(disclosure.title),
                message: Text(disclosure.message),
                primaryButton: .default(Text("开始测试")) {
                    modelSettings.startConnectionTest(
                        sourceLanguageIdentifier: settings.sourceLanguageIdentifier,
                        targetLanguageIdentifier: settings.targetLanguageIdentifier
                    )
                },
                secondaryButton: .cancel()
            )
        }
        .confirmationDialog("读取旧版 Key？", isPresented: $confirmsLegacyKeyRead) {
            Button("读取旧版 Key") {
                Task { await modelSettings.readLegacyAPIKey() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作可能触发一次 macOS 钥匙串授权。读取后请确认 Key 属于当前地址：\(modelSettings.draftBaseURL)，再保存为本地配置。不会自动删除旧钥匙串条目。")
        }
    }

    private var isTesting: Bool {
        if case .testing = modelSettings.connectionState { return true }
        return false
    }

    private var configurationActions: some View {
        HStack {
            Button("保存配置") {
                Task { await modelSettings.save(to: settings) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(modelSettings.isLoadingAPIKey || modelSettings.isSaving)
            Button("测试连接") {
                pendingTestDisclosure = modelSettings.connectionDisclosure()
            }
            .disabled(modelSettings.isLoadingAPIKey || modelSettings.isSaving || isTesting)
            if isTesting {
                ProgressView().controlSize(.small)
                Button("停止测试") { modelSettings.cancelConnectionTest() }
            }
            Spacer()
        }
    }

    private var apiKeyStatusText: String {
        if modelSettings.isLoadingAPIKey { return "正在读取本地 Key…" }
        if modelSettings.apiKeyLoadFailed { return "本地文件读取失败；原有 API Key 未更改" }
        return modelSettings.hasStoredAPIKey ? "当前配置已保存本地 API Key" : "当前配置未保存 API Key"
    }

    private var testConnectionPrivacyText: String {
        guard let configuration = try? ModelTranslationConfigurationValidator.validate(
            baseURL: modelSettings.draftBaseURL,
            model: modelSettings.draftModel,
            streamsResponse: modelSettings.draftStreamsResponse,
            prompt: modelSettings.draftPrompt
        ) else {
            return "测试连接只发送内置测试文本，不发送 PDF 选区或论文信息。"
        }
        if configuration.origin.isLoopback {
            return "测试连接只会联系本机服务，并发送内置测试文本。"
        }
        return "测试连接会联系远端服务并发送内置测试文本，可能产生少量费用。"
    }

    @ViewBuilder
    private var connectionResult: some View {
        switch modelSettings.connectionState {
        case .idle:
            EmptyView()
        case let .testing(response):
            VStack(alignment: .leading, spacing: 4) {
                Text("正在测试连接…")
                if !response.isEmpty {
                    Text(response)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .accessibilityElement(children: .combine)
        case let .succeeded(model, response):
            VStack(alignment: .leading, spacing: 4) {
                Label("连接成功 · \(model)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(response)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            .accessibilityElement(children: .combine)
        case let .failed(message):
            Label("连接失败：\(message)", systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .accessibilityLabel("连接失败：\(message)")
        }
    }
}
