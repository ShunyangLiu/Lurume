import Foundation

@MainActor
final class ModelTranslationSettingsController: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case testing(response: String)
        case succeeded(model: String, response: String)
        case failed(String)
    }

    @Published var draftEngine: TranslationEngine = .apple {
        didSet { draftDidChange() }
    }
    @Published var draftBaseURL = ModelTranslationConfiguration.defaultBaseURL {
        didSet { draftDidChange() }
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
    @Published var draftPrompt = ModelTranslationConfiguration.defaultPrompt {
        didSet { draftDidChange() }
    }
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var isLoadingAPIKey = false
    @Published private(set) var isSaving = false
    @Published private(set) var saveMessage: String?
    @Published private(set) var validationMessage: String?
    @Published private(set) var normalizationMessage: String?
    @Published private(set) var connectionState: ConnectionState = .idle

    private let keyStore: any TranslationAPIKeyStoring
    private let requestSender: any TranslationRequestSending
    private var didLoad = false
    private var isSynchronizingDraft = false
    private var activeTestRequestID: String?

    init(
        keyStore: any TranslationAPIKeyStoring = KeychainTranslationAPIKeyStore(),
        requestSender: any TranslationRequestSending = TranslationXPCClient()
    ) {
        self.keyStore = keyStore
        self.requestSender = requestSender
    }

    func load(from settings: AppSettings) async {
        guard !didLoad else { return }
        didLoad = true
        isSynchronizingDraft = true
        draftEngine = settings.translationEngine
        draftBaseURL = settings.modelTranslationBaseURL
        draftModel = settings.modelTranslationModel
        draftStreamsResponse = settings.modelTranslationStreamsResponse
        draftPrompt = settings.modelTranslationPrompt
        isSynchronizingDraft = false
        isLoadingAPIKey = true
        defer { isLoadingAPIKey = false }
        do {
            if let apiKey = try await keyStore.read() {
                isSynchronizingDraft = true
                draftAPIKey = apiKey
                isSynchronizingDraft = false
                hasStoredAPIKey = true
            }
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    @discardableResult
    func validateDraft() -> ValidatedModelTranslationConfiguration? {
        do {
            let configuration = try validatedDraft()
            validationMessage = nil
            normalizationMessage = configuration.strippedChatCompletionsSuffix
                ? "已识别完整端点；保存时会移除 /chat/completions，避免重复拼接。"
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
        isSaving = true
        saveMessage = nil
        cancelConnectionTest()
        let apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if apiKey.isEmpty {
                try await keyStore.delete()
                hasStoredAPIKey = false
                draftAPIKey = ""
            } else {
                try await keyStore.save(apiKey)
                hasStoredAPIKey = true
                draftAPIKey = apiKey
            }
            settings.applyModelTranslationConfiguration(configuration, engine: draftEngine)
            isSynchronizingDraft = true
            draftBaseURL = configuration.configuration.baseURL
            draftModel = configuration.configuration.model
            draftPrompt = configuration.configuration.prompt
            isSynchronizingDraft = false
            normalizationMessage = configuration.strippedChatCompletionsSuffix
                ? "已移除 /chat/completions；请求端点保持为单一 /chat/completions。"
                : nil
            saveMessage = "配置已保存。"
        } catch {
            saveMessage = error.localizedDescription
        }
        isSaving = false
    }

    func deleteAPIKey() async {
        guard !isLoadingAPIKey, !isSaving else { return }
        isSaving = true
        saveMessage = nil
        do {
            try await keyStore.delete()
            draftAPIKey = ""
            hasStoredAPIKey = false
            saveMessage = "API Key 已从钥匙串删除。"
        } catch {
            saveMessage = error.localizedDescription
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
        saveMessage = nil
        connectionState = .idle
    }

    func connectionDisclosure() -> TranslationConnectionDisclosure? {
        guard let configuration = validateDraft() else { return nil }
        return TranslationConnectionDisclosure(origin: configuration.origin)
    }

    func startConnectionTest(sourceLanguageIdentifier: String, targetLanguageIdentifier: String) {
        guard !isLoadingAPIKey, let configuration = validateDraft() else { return }
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
            streamsResponse: configuration.configuration.streamsResponse
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
            prompt: draftPrompt
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
