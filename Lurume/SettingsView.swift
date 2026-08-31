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

private struct TranslationSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var modelSettings = ModelTranslationSettingsController()
    @State private var pendingTestDisclosure: TranslationConnectionDisclosure?

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
                TextField("Base URL", text: $modelSettings.draftBaseURL)
                    .textContentType(.URL)
                    .accessibilityHint("填写 API 根地址；Lurume 会追加 chat/completions")
                TextField("模型", text: $modelSettings.draftModel)
                    .accessibilityHint("填写服务支持的模型名称")
                SecureField("API Key（可留空）", text: $modelSettings.draftAPIKey)
                    .accessibilityLabel("API Key 安全输入")
                    .accessibilityValue(apiKeyStatusText)
                    .disabled(modelSettings.isLoadingAPIKey)
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
                    .accessibilityHint("从 macOS 钥匙串删除已保存的 API Key")
                }
                Toggle("流式输出", isOn: $modelSettings.draftStreamsResponse)
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
                        ProgressView()
                            .controlSize(.small)
                        Button("停止测试") {
                            modelSettings.cancelConnectionTest()
                        }
                    }
                }

                Text(testConnectionPrivacyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let normalizationMessage = modelSettings.normalizationMessage {
                    Label(normalizationMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let validationMessage = modelSettings.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("配置错误：\(validationMessage)")
                }
                if let saveStatus = modelSettings.saveStatus {
                    switch saveStatus {
                    case let .success(message):
                        Text(message)
                            .foregroundStyle(.secondary)
                    case let .failure(message):
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityLabel("保存失败：\(message)")
                    }
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
    }

    private var isTesting: Bool {
        if case .testing = modelSettings.connectionState { return true }
        return false
    }

    private var apiKeyStatusText: String {
        if modelSettings.isLoadingAPIKey { return "正在读取钥匙串…" }
        if modelSettings.apiKeyLoadFailed { return "钥匙串读取失败；原有 API Key 未更改" }
        return modelSettings.hasStoredAPIKey ? "钥匙串中已配置 API Key" : "未配置 API Key"
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
