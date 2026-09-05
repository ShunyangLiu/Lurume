import Foundation

@MainActor
final class ModelTranslationSettingsController: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case testing(response: String)
        case succeeded(model: String, response: String)
        case failed(String)
    }

    enum SaveStatus: Equatable {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case let .success(message), let .failure(message): message
            }
        }
    }

    @Published var draftEngine: TranslationEngine = .apple {
        didSet { draftDidChange() }
    }
    @Published var draftBaseURL = ModelTranslationConfiguration.defaultBaseURL {
        didSet { draftDidChange(); credentialDraftDidChange() }
    }
    @Published private(set) var draftProvider: TranslationProvider = .custom
    @Published var draftAPIFormat: TranslationAPIFormat = .openAI {
        didSet { draftDidChange(); credentialDraftDidChange() }
    }
    @Published var draftModel = "" {
        didSet { draftDidChange() }
    }
    @Published var draftAPIKey = "" {
        didSet { draftDidChange() }
    }
    @Published var draftStreamsResponse = true {
        didSet { draftDidChange() }
    }
    @Published var draftOptimizesForTranslation = true {
        didSet { draftDidChange() }
    }
    @Published var draftPrompt = ModelTranslationConfiguration.defaultPrompt {
        didSet { draftDidChange() }
    }
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var apiKeyLoadFailed = false
    @Published private(set) var isLoadingAPIKey = false
    @Published private(set) var isSaving = false
    @Published private(set) var saveStatus: SaveStatus?
    @Published private(set) var validationMessage: String?
    @Published private(set) var normalizationMessage: String?
    @Published private(set) var connectionState: ConnectionState = .idle

    private let keyStore: (any TranslationAPIKeyStoring)?
    private let legacyKeyStore: any TranslationAPIKeyStoring
    private let keyStoreFactory: @Sendable (String) -> any TranslationAPIKeyStoring
    private var profiles: [String: ModelTranslationProfile] = [:]
    private var credentialScope: String?
    private var credentialGeneration = UUID()
    private var keyLoadTask: Task<Void, Never>?
    private let requestSender: any TranslationRequestSending
    private var didLoad = false
    private var isSynchronizingDraft = false
    private var activeTestRequestID: String?

    init(
        keyStore: (any TranslationAPIKeyStoring)? = nil,
        legacyKeyStore: any TranslationAPIKeyStoring = KeychainTranslationAPIKeyStore(),
        keyStoreFactory: @escaping @Sendable (String) -> any TranslationAPIKeyStoring = {
            LocalTranslationAPIKeyStore(scope: $0)
        },
        requestSender: any TranslationRequestSending = TranslationXPCClient()
    ) {
        self.keyStore = keyStore
        self.legacyKeyStore = legacyKeyStore
        self.keyStoreFactory = keyStoreFactory
        self.requestSender = requestSender
    }

    func load(from settings: AppSettings) async {
        guard !didLoad else { return }
        didLoad = true
        isSynchronizingDraft = true
        profiles = settings.modelTranslationProfiles
        draftProvider = settings.modelTranslationProvider
        draftAPIFormat = settings.modelTranslationAPIFormat
        draftEngine = settings.translationEngine
        draftBaseURL = settings.modelTranslationBaseURL
        draftModel = settings.modelTranslationModel
        draftStreamsResponse = settings.modelTranslationStreamsResponse
        draftOptimizesForTranslation = settings.modelTranslationOptimizesForTranslation
        draftPrompt = settings.modelTranslationPrompt
        isSynchronizingDraft = false
        credentialDraftDidChange(force: true)
        await waitForAPIKeyLoad()
    }

    func selectProvider(_ provider: TranslationProvider) {
        guard provider != draftProvider, !isSaving else { return }
        profiles[draftProvider.rawValue] = currentProfile
        let profile = profiles[provider.rawValue] ?? ModelTranslationProfile(provider: provider)
        isSynchronizingDraft = true
        draftProvider = provider
        draftBaseURL = profile.baseURL
        draftModel = profile.model
        draftAPIFormat = profile.apiFormat
        draftStreamsResponse = profile.streamsResponse
        draftOptimizesForTranslation = profile.optimizesForTranslation
        draftPrompt = profile.prompt
        isSynchronizingDraft = false
        draftDidChange()
        credentialDraftDidChange(force: true)
    }

    func waitForAPIKeyLoad() async {
        await keyLoadTask?.value
    }

    private var currentProfile: ModelTranslationProfile {
        var profile = ModelTranslationProfile(provider: draftProvider)
        profile.baseURL = draftBaseURL
        profile.model = draftModel
        profile.apiFormat = draftAPIFormat
        profile.streamsResponse = draftStreamsResponse
        profile.optimizesForTranslation = draftOptimizesForTranslation
        profile.prompt = draftPrompt
        return profile
    }

    private func store(for scope: String) -> any TranslationAPIKeyStoring {
        keyStore ?? keyStoreFactory(scope)
    }

    private func credentialDraftDidChange(force: Bool = false) {
        guard !isSynchronizingDraft else { return }
        // Key identity does not depend on whether the model or prompt is currently valid.
        let scope = (try? ModelTranslationConfigurationValidator.validate(
            baseURL: draftBaseURL, model: "credential-scope", streamsResponse: true,
            prompt: "credential-scope", provider: draftProvider, apiFormat: draftAPIFormat
        ))?.configuration.credentialScope
        guard force || scope != credentialScope else { return }
        credentialGeneration = UUID()
        let generation = credentialGeneration
        credentialScope = scope
        keyLoadTask?.cancel()
        draftAPIKey = ""
        hasStoredAPIKey = false
        apiKeyLoadFailed = false
        isLoadingAPIKey = false
        guard let scope else { return }
        isLoadingAPIKey = true
        let keyStore = store(for: scope)
        keyLoadTask = Task { [weak self] in
            do {
                let apiKey = try await keyStore.read()
                guard let self, self.credentialGeneration == generation, !Task.isCancelled else { return }
                self.isSynchronizingDraft = true
                self.draftAPIKey = apiKey ?? ""
                self.isSynchronizingDraft = false
                self.hasStoredAPIKey = apiKey != nil
                self.isLoadingAPIKey = false
            } catch {
                guard let self, self.credentialGeneration == generation, !Task.isCancelled else { return }
                self.apiKeyLoadFailed = true
                self.isLoadingAPIKey = false
                self.saveStatus = .failure("无法读取本地 API Key；原有 Key 未更改。\(error.localizedDescription)")
            }
        }
    }

    /// Explicit user action only. Keep the old item until the user manages it themselves.
    func readLegacyAPIKey() async {
        guard !isLoadingAPIKey, !isSaving, draftAPIKey.isEmpty, credentialScope != nil else { return }
        isSaving = true
        let generation = credentialGeneration
        defer { isSaving = false }
        do {
            let key = try await legacyKeyStore.read()
            guard generation == credentialGeneration else { return }
            guard let key, !key.isEmpty else {
                saveStatus = .failure("未找到旧版 API Key。请手动填写。")
                return
            }
            draftAPIKey = key
            saveStatus = .success("已读取旧 Key，请确认当前服务地址后保存配置。旧钥匙串条目未删除。")
        } catch {
            saveStatus = .failure("无法读取旧版 Key，请手动填写。旧钥匙串条目未更改。")
        }
    }

    @discardableResult
    func validateDraft() -> ValidatedModelTranslationConfiguration? {
        do {
            let configuration = try validatedDraft()
            validationMessage = nil
            normalizationMessage = configuration.strippedChatCompletionsSuffix
                ? "已识别完整端点；保存时会移除 \(draftAPIFormat.endpointSuffix)，避免重复拼接。"
                : nil
            return configuration
        } catch {
            validationMessage = error.localizedDescription
            normalizationMessage = nil
            return nil
        }
    }

    func save(to settings: AppSettings) async {
        guard !isLoadingAPIKey, !isSaving, let configuration = validateDraft() else { return }
        let apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(apiKeyLoadFailed && apiKey.isEmpty) else {
            saveStatus = .failure("无法确认本地 API Key，因此未保存配置，也未删除原有 Key。请重新打开设置后再试。")
            return
        }
        isSaving = true
        let keyStore = store(for: configuration.configuration.credentialScope)
        let engine = draftEngine
        let generation = credentialGeneration
        saveStatus = nil
        cancelConnectionTest()
        do {
            if apiKey.isEmpty {
                try await keyStore.delete()
                guard generation == credentialGeneration else { isSaving = false; return }
                hasStoredAPIKey = false
                draftAPIKey = ""
            } else {
                try await keyStore.save(apiKey)
                guard generation == credentialGeneration else { isSaving = false; return }
                hasStoredAPIKey = true
                apiKeyLoadFailed = false
                draftAPIKey = apiKey
            }
            settings.applyModelTranslationConfiguration(configuration, engine: engine)
            profiles[draftProvider.rawValue] = ModelTranslationProfile(configuration: configuration.configuration)
            isSynchronizingDraft = true
            draftBaseURL = configuration.configuration.baseURL
            draftModel = configuration.configuration.model
            draftPrompt = configuration.configuration.prompt
            isSynchronizingDraft = false
            normalizationMessage = configuration.strippedChatCompletionsSuffix
                ? "已移除重复端点后缀；请求端点为 \(configuration.configuration.apiFormat.endpointSuffix)。"
                : nil
            saveStatus = .success("配置已保存。")
        } catch {
            saveStatus = .failure(error.localizedDescription)
        }
        isSaving = false
    }

    func deleteAPIKey() async {
        guard !isLoadingAPIKey, !isSaving, let scope = credentialScope else { return }
        guard !apiKeyLoadFailed else {
            saveStatus = .failure("本地文件读取失败，未删除原有 API Key。请重新打开设置后再试。")
            return
        }
        isSaving = true
        let generation = credentialGeneration
        saveStatus = nil
        do {
            try await store(for: scope).delete()
            guard generation == credentialGeneration else { isSaving = false; return }
            draftAPIKey = ""
            hasStoredAPIKey = false
            saveStatus = .success("当前配置的 API Key 已从本地文件删除。")
        } catch {
            saveStatus = .failure(error.localizedDescription)
        }
        isSaving = false
    }

    func restoreDefaultPrompt() {
        draftPrompt = ModelTranslationConfiguration.defaultPrompt
    }

    func draftDidChange() {
        guard !isSynchronizingDraft else { return }
        cancelConnectionTest()
        validationMessage = nil
        normalizationMessage = nil
        saveStatus = nil
        connectionState = .idle
    }

    func connectionDisclosure() -> TranslationConnectionDisclosure? {
        guard let configuration = validateDraft() else { return nil }
        return TranslationConnectionDisclosure(origin: configuration.origin)
    }

    func startConnectionTest(sourceLanguageIdentifier: String, targetLanguageIdentifier: String) {
        guard !isLoadingAPIKey, !isSaving, let configuration = validateDraft() else { return }
        cancelConnectionTest()
        connectionState = .testing(response: "")
        let requestID = UUID().uuidString
        activeTestRequestID = requestID
        let request = TranslationXPCRequest(
            requestID: requestID,
            endpoint: configuration.endpoint.absoluteString,
            model: configuration.configuration.model,
            systemPrompt: configuration.renderedPrompt(
                sourceLanguage: TranslationLanguageNames.source(identifier: sourceLanguageIdentifier),
                targetLanguage: TranslationLanguageNames.target(identifier: targetLanguageIdentifier)
            ),
            selectedText: ModelTranslationConfiguration.connectionTestText,
            apiKey: draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            streamsResponse: configuration.configuration.streamsResponse,
            maximumOutputTokens: configuration.configuration.optimizesForTranslation
                ? ModelTranslationGenerationOptions.outputTokenLimit(
                    for: ModelTranslationConfiguration.connectionTestText
                )
                : nil,
            temperature: configuration.configuration.optimizesForTranslation
                ? ModelTranslationGenerationOptions.temperature
                : nil,
            apiFormat: configuration.configuration.apiFormat,
            disablesThinking: configuration.configuration.disablesThinking
        )

        do {
            try requestSender.start(request) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.receiveTestEvent(event, model: configuration.configuration.model)
                }
            }
        } catch {
            activeTestRequestID = nil
            connectionState = .failed(error.localizedDescription)
        }
    }

    func cancelConnectionTest() {
        guard let requestID = activeTestRequestID else { return }
        activeTestRequestID = nil
        requestSender.cancel(requestID: requestID)
        if case .testing = connectionState {
            connectionState = .idle
        }
    }

    private func validatedDraft() throws -> ValidatedModelTranslationConfiguration {
        try ModelTranslationConfigurationValidator.validate(
            baseURL: draftBaseURL,
            model: draftModel,
            streamsResponse: draftStreamsResponse,
            optimizesForTranslation: draftOptimizesForTranslation,
            prompt: draftPrompt,
            provider: draftProvider,
            apiFormat: draftAPIFormat
        )
    }

    private func receiveTestEvent(_ event: TranslationXPCEvent, model: String) {
        guard event.requestID == activeTestRequestID else { return }
        switch event.kind {
        case "delta":
            guard let delta = event.text else { return }
            let current: String
            if case let .testing(response) = connectionState {
                current = response
            } else {
                current = ""
            }
            connectionState = .testing(response: String((current + delta).prefix(4_000)))
        case "completed":
            let response: String
            if case let .testing(current) = connectionState, !current.isEmpty {
                response = current
            } else {
                response = "服务已完成请求。"
            }
            activeTestRequestID = nil
            connectionState = .succeeded(model: model, response: response)
        case "failed", "cancelled":
            activeTestRequestID = nil
            connectionState = .failed(event.message ?? "测试连接失败。")
        default:
            break
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
