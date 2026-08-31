import Foundation
import NaturalLanguage
import Translation

enum TranslationReadiness: Equatable, Sendable {
    case installed
    case downloadable
    case unsupported
}

struct TranslationOutput: Equatable, Sendable {
    let targetText: String
}

protocol TranslationPerforming: AnyObject, Sendable {
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness
    func translate(_ text: String) async throws -> TranslationOutput
}

protocol TranslationAvailabilityChecking: Sendable {
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness
}

protocol SourceLanguageRecognizing: Sendable {
    func language(for text: String) -> Locale.Language?
}

struct NaturalLanguageSourceRecognizer: SourceLanguageRecognizing {
    func language(for text: String) -> Locale.Language? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else {
            return nil
        }
        return Locale.Language(identifier: language.rawValue)
    }
}

struct SystemTranslationAvailabilityChecker: TranslationAvailabilityChecking {
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            .installed
        case .supported:
            .downloadable
        case .unsupported:
            .unsupported
        @unknown default:
            .unsupported
        }
    }
}

final class SystemTranslationPerformer: TranslationPerforming, @unchecked Sendable {
    private let session: TranslationSession
    private let availability = LanguageAvailability()

    init(session: TranslationSession) {
        self.session = session
    }

    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        switch await availability.status(from: source, to: target) {
        case .installed:
            .installed
        case .supported:
            .downloadable
        case .unsupported:
            .unsupported
        @unknown default:
            .unsupported
        }
    }

    func translate(_ text: String) async throws -> TranslationOutput {
        let response = try await session.translate(text)
        return TranslationOutput(targetText: response.targetText)
    }
}

struct TranslationSelection: Equatable, Sendable {
    let rawText: String
    let normalizedText: String
    let languageSample: String
    let paperID: UUID
    let paperName: String
    let pageIndex: Int
}

struct TranslationRequestPreferences: Equatable, Sendable {
    let engine: TranslationEngine
    let sourceLanguageIdentifier: String
    let targetLanguageIdentifier: String
    let modelConfiguration: ValidatedModelTranslationConfiguration?
    let modelOriginIsConfirmed: Bool

    var sourceLanguage: Locale.Language? {
        guard sourceLanguageIdentifier != TranslationSourceLanguageOption.automaticID else {
            return nil
        }
        return Locale.Language(identifier: sourceLanguageIdentifier)
    }

    var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageIdentifier)
    }

    static func apple(
        targetLanguage: Locale.Language,
        sourceLanguage: Locale.Language?
    ) -> Self {
        Self(
            engine: .apple,
            sourceLanguageIdentifier: sourceLanguage?.minimalIdentifier
                ?? TranslationSourceLanguageOption.automaticID,
            targetLanguageIdentifier: targetLanguage.minimalIdentifier,
            modelConfiguration: nil,
            modelOriginIsConfirmed: false
        )
    }

    func usingAppleEngine() -> Self {
        Self(
            engine: .apple,
            sourceLanguageIdentifier: sourceLanguageIdentifier,
            targetLanguageIdentifier: targetLanguageIdentifier,
            modelConfiguration: nil,
            modelOriginIsConfirmed: false
        )
    }
}

struct TranslationConfigurationIdentity: Equatable, Sendable {
    let engine: TranslationEngine
    let sourceLanguageIdentifier: String
    let targetLanguageIdentifier: String
    let baseURL: String?
    let model: String?
    let streamsResponse: Bool?
    let prompt: String?
}

enum TranslationResultSource: Equatable, Sendable {
    case apple
    case customModel(model: String)

    var label: String {
        switch self {
        case .apple: "系统翻译"
        case let .customModel(model): "自定义大模型 · \(model)"
        }
    }
}

enum TranslationState: Equatable, Sendable {
    case idle
    case waiting
    case connecting
    case translating
    case streaming
    case resourcesNeeded
    case success
    case stopped
    case interrupted(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "尚无翻译"
        case .waiting: "等待翻译"
        case .connecting: "正在连接"
        case .translating: "正在翻译"
        case .streaming: "正在翻译"
        case .resourcesNeeded: "正在准备语言资源"
        case .success: "翻译完成"
        case .stopped: "生成已停止，内容可能不完整"
        case .interrupted: "响应中断，内容可能不完整"
        case .failed: "翻译失败"
        }
    }

    var detailMessage: String? {
        switch self {
        case let .interrupted(message), let .failed(message): message
        default: nil
        }
    }
}

enum SystemFallbackAvailability: Equatable, Sendable {
    case checking
    case available
    case unavailable(String)
}

struct TranslationOriginConsentRequest: Equatable, Identifiable, Sendable {
    let origin: TranslationOrigin
    let title: String
    let message: String

    var id: String { origin.persistedValue }

    init(origin: TranslationOrigin) {
        self.origin = origin
        let notice = TranslationOriginConsentNotice(origin: origin)
        title = notice.title
        message = notice.message
    }
}

struct TranslationCacheKey: Hashable, Sendable {
    let text: String
    let sourceIdentifier: String
    let targetIdentifier: String
    let engine: TranslationEngine
    let baseURL: String?
    let model: String?
    let prompt: String?

    static func apple(
        text: String,
        sourceIdentifier: String,
        targetIdentifier: String
    ) -> Self {
        Self(
            text: text,
            sourceIdentifier: sourceIdentifier,
            targetIdentifier: targetIdentifier,
            engine: .apple,
            baseURL: nil,
            model: nil,
            prompt: nil
        )
    }

    static func customModel(
        text: String,
        sourceIdentifier: String,
        targetIdentifier: String,
        configuration: ValidatedModelTranslationConfiguration
    ) -> Self {
        Self(
            text: text,
            sourceIdentifier: sourceIdentifier,
            targetIdentifier: targetIdentifier,
            engine: .customModel,
            baseURL: configuration.configuration.baseURL,
            model: configuration.configuration.model,
            prompt: configuration.configuration.prompt
        )
    }
}

@MainActor
final class TranslationController: ObservableObject {
    @Published private(set) var selection: TranslationSelection?
    @Published private(set) var translatedText: String?
    @Published private(set) var state: TranslationState = .idle
    @Published private(set) var resultSource: TranslationResultSource?
    @Published private(set) var pendingOriginConsent: TranslationOriginConsentRequest?
    @Published private(set) var systemFallbackAvailability: SystemFallbackAvailability?
    @Published private(set) var configuration: TranslationSession.Configuration?
    /// P1：主窗口打开时检查器默认可见，首次选区只更新内容、不再改变布局。
    @Published var isInspectorPresented = true

    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var activeTranslationTask: Task<TranslationOutput, Error>?
    private var pendingAppleRequest: AppleRequestContext?
    private var pendingModelConsent: ModelRequestContext?
    private var activeModelRequest: ModelRequestContext?
    private var activeModelPreparationTask: Task<Void, Never>?
    private var pendingModelDelta = ""
    private var deltaFlushTask: Task<Void, Never>?
    private var fallbackAvailabilityTask: Task<Void, Never>?
    private var cache: [TranslationCacheKey: String] = [:]
    private var lastPreferences: TranslationRequestPreferences?

    private let sourceLanguageRecognizer: any SourceLanguageRecognizing
    private let availabilityChecker: any TranslationAvailabilityChecking
    private let keyStore: any TranslationAPIKeyStoring
    private let modelRequestSender: any TranslationRequestSending

    init(
        sourceLanguageRecognizer: any SourceLanguageRecognizing = NaturalLanguageSourceRecognizer(),
        availabilityChecker: any TranslationAvailabilityChecking = SystemTranslationAvailabilityChecker(),
        keyStore: any TranslationAPIKeyStoring = KeychainTranslationAPIKeyStore(),
        modelRequestSender: any TranslationRequestSending = TranslationXPCClient()
    ) {
        self.sourceLanguageRecognizer = sourceLanguageRecognizer
        self.availabilityChecker = availabilityChecker
        self.keyStore = keyStore
        self.modelRequestSender = modelRequestSender
    }

    deinit {
        debounceTask?.cancel()
        activeTranslationTask?.cancel()
        activeModelPreparationTask?.cancel()
        deltaFlushTask?.cancel()
        fallbackAvailabilityTask?.cancel()
        if let requestID = activeModelRequest?.requestID {
            modelRequestSender.cancel(requestID: requestID)
        }
    }

    var isModelTranslationActive: Bool {
        guard case .customModel = resultSource else { return false }
        return state == .connecting || state == .streaming
    }

    var canRetryModelTranslation: Bool {
        guard case .customModel = resultSource else { return false }
        return switch state {
        case .stopped, .interrupted, .failed:
            true
        default:
            false
        }
    }

    func receiveSelection(
        _ event: PDFSelectionEvent?,
        paperID: UUID,
        paperName: String,
        automaticTranslation: Bool,
        preferences: TranslationRequestPreferences
    ) {
        guard let event else { return }
        let normalizedText = TextNormalizer.translationInput(from: event.rawText)
        guard !normalizedText.isEmpty else { return }

        let newSelection = TranslationSelection(
            rawText: event.rawText,
            normalizedText: normalizedText,
            languageSample: event.languageSample,
            paperID: paperID,
            paperName: paperName,
            pageIndex: event.pageIndex
        )
        guard newSelection != selection else { return }

        cancelWorkForNewGeneration()
        selection = newSelection
        translatedText = nil
        resultSource = nil
        systemFallbackAvailability = nil
        state = .waiting
        lastPreferences = preferences

        guard automaticTranslation else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.requestTranslation(preferences: preferences, revealInspector: false)
        }
    }

    func receiveSelection(
        _ event: PDFSelectionEvent?,
        paperID: UUID,
        paperName: String,
        automaticTranslation: Bool,
        targetLanguage: Locale.Language,
        sourceLanguage: Locale.Language? = nil
    ) {
        receiveSelection(
            event,
            paperID: paperID,
            paperName: paperName,
            automaticTranslation: automaticTranslation,
            preferences: .apple(targetLanguage: targetLanguage, sourceLanguage: sourceLanguage)
        )
    }

    func requestTranslation(
        preferences: TranslationRequestPreferences,
        revealInspector: Bool = true
    ) {
        if revealInspector { isInspectorPresented = true }
        cancelWorkForNewGeneration()
        guard let selection else { return }
        lastPreferences = preferences
        translatedText = nil
        systemFallbackAvailability = nil

        switch preferences.engine {
        case .apple:
            prepareAppleTranslation(selection: selection, preferences: preferences)
        case .customModel:
            prepareModelTranslation(selection: selection, preferences: preferences)
        }
    }

    func requestTranslation(
        targetLanguage: Locale.Language,
        sourceLanguage: Locale.Language? = nil,
        revealInspector: Bool = true
    ) {
        requestTranslation(
            preferences: .apple(targetLanguage: targetLanguage, sourceLanguage: sourceLanguage),
            revealInspector: revealInspector
        )
    }

    func requestSystemTranslation(preferences: TranslationRequestPreferences) {
        requestTranslation(preferences: preferences.usingAppleEngine())
    }

    func confirmPendingOrigin() {
        guard let request = pendingModelConsent,
              request.generation == generation else { return }
        pendingModelConsent = nil
        pendingOriginConsent = nil
        startModelTranslation(request)
    }

    func declinePendingOrigin() {
        guard pendingModelConsent?.generation == generation else { return }
        pendingModelConsent = nil
        pendingOriginConsent = nil
        state = .failed("未授权向该服务发送选中文字。")
        refreshSystemFallbackAvailability()
    }

    func stopTranslation() {
        guard activeModelRequest != nil || activeModelPreparationTask != nil else { return }
        let hadPartialText = translatedText?.isEmpty == false || !pendingModelDelta.isEmpty
        flushPendingModelDelta()
        generation += 1
        if let requestID = activeModelRequest?.requestID {
            modelRequestSender.cancel(requestID: requestID)
        }
        activeModelRequest = nil
        activeModelPreparationTask?.cancel()
        activeModelPreparationTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingModelDelta = ""
        configuration = nil
        state = hadPartialText ? .stopped : .failed("已停止翻译，尚未收到译文。")
        refreshSystemFallbackAvailability()
    }

    func perform(using performer: any TranslationPerforming) async {
        guard let request = pendingAppleRequest,
              request.generation == generation else { return }
        pendingAppleRequest = nil

        let task = Task { @MainActor in
            let readiness = await performer.readiness(
                from: request.sourceLanguage,
                to: request.targetLanguage
            )
            switch readiness {
            case .installed:
                state = .translating
            case .downloadable:
                state = .resourcesNeeded
            case .unsupported:
                throw TranslationControllerError.unsupportedLanguagePair
            }
            return try await performer.translate(request.selection.normalizedText)
        }
        activeTranslationTask = task

        do {
            let output = try await task.value
            guard request.generation == generation else { return }
            cache[request.cacheKey] = output.targetText
            translatedText = output.targetText
            resultSource = .apple
            state = .success
        } catch is CancellationError {
            guard request.generation == generation else { return }
            state = .failed("系统翻译已停止。")
        } catch {
            guard request.generation == generation else { return }
            state = .failed(error.localizedDescription)
        }

        if request.generation == generation {
            activeTranslationTask = nil
        }
    }

    func translationPreferencesDidChange() {
        guard selection != nil else { return }
        cancelWorkForNewGeneration()
        translatedText = nil
        resultSource = nil
        systemFallbackAvailability = nil
        state = .waiting
    }

    func clear() {
        cancelWorkForNewGeneration()
        selection = nil
        translatedText = nil
        resultSource = nil
        systemFallbackAvailability = nil
        state = .idle
    }

    func paperRemoved(_ paperID: UUID) {
        guard selection?.paperID == paperID else { return }
        clear()
    }

    func activePaperDidChange(to paperID: UUID?) {
        guard let selection, selection.paperID != paperID else { return }
        clear()
    }

    func cancelPendingAutomaticTranslation() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func prepareAppleTranslation(
        selection: TranslationSelection,
        preferences: TranslationRequestPreferences
    ) {
        guard let sourceLanguage = resolvedAppleSourceLanguage(
            selection: selection,
            preferences: preferences
        ) else {
            resultSource = .apple
            state = .failed("无法识别原文语言。请尝试选择更长的文本。")
            return
        }
        let targetLanguage = preferences.targetLanguage
        let cacheKey = TranslationCacheKey.apple(
            text: selection.normalizedText,
            sourceIdentifier: sourceLanguage.minimalIdentifier,
            targetIdentifier: targetLanguage.minimalIdentifier
        )
        resultSource = .apple
        if let cached = cache[cacheKey] {
            translatedText = cached
            state = .success
            return
        }

        let request = AppleRequestContext(
            generation: generation,
            selection: selection,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            cacheKey: cacheKey
        )
        pendingAppleRequest = request
        state = .waiting
        if var currentConfiguration = configuration,
           currentConfiguration.source == sourceLanguage,
           currentConfiguration.target == targetLanguage {
            currentConfiguration.invalidate()
            configuration = currentConfiguration
        } else {
            configuration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage
            )
        }
    }

    private func prepareModelTranslation(
        selection: TranslationSelection,
        preferences: TranslationRequestPreferences
    ) {
        configuration = nil
        guard let configuration = preferences.modelConfiguration else {
            resultSource = .customModel(model: "未配置")
            state = .failed("自定义大模型配置不完整，请先在设置中保存有效配置。")
            refreshSystemFallbackAvailability()
            return
        }
        resultSource = .customModel(model: configuration.configuration.model)
        guard selection.normalizedText.count <= ModelTranslationConfiguration.maximumSelectionCharacters else {
            state = .failed("选中文字超过 12,000 个字符，未发送翻译请求。")
            refreshSystemFallbackAvailability()
            return
        }

        let cacheKey = TranslationCacheKey.customModel(
            text: selection.normalizedText,
            sourceIdentifier: preferences.sourceLanguageIdentifier,
            targetIdentifier: preferences.targetLanguageIdentifier,
            configuration: configuration
        )
        if let cached = cache[cacheKey] {
            translatedText = cached
            state = .success
            return
        }

        let request = ModelRequestContext(
            generation: generation,
            requestID: UUID().uuidString,
            selection: selection,
            preferences: preferences,
            configuration: configuration,
            cacheKey: cacheKey
        )
        if preferences.modelOriginIsConfirmed {
            startModelTranslation(request)
        } else {
            pendingModelConsent = request
            pendingOriginConsent = TranslationOriginConsentRequest(origin: configuration.origin)
            state = .waiting
        }
    }

    private func startModelTranslation(_ request: ModelRequestContext) {
        guard request.generation == generation else { return }
        activeModelRequest = request
        state = .connecting
        let keyStore = self.keyStore
        activeModelPreparationTask = Task { [weak self] in
            do {
                let apiKey = try await keyStore.read()
                guard !Task.isCancelled else { return }
                self?.launchModelRequest(request, apiKey: apiKey)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishModelRequest(request, errorMessage: error.localizedDescription)
            }
        }
    }

    private func launchModelRequest(_ context: ModelRequestContext, apiKey: String?) {
        guard context.generation == generation,
              activeModelRequest?.requestID == context.requestID else { return }
        activeModelPreparationTask = nil
        let request = TranslationXPCRequest(
            requestID: context.requestID,
            endpoint: context.configuration.endpoint.absoluteString,
            model: context.configuration.configuration.model,
            systemPrompt: context.configuration.renderedPrompt(
                sourceLanguage: TranslationLanguageNames.source(
                    identifier: context.preferences.sourceLanguageIdentifier
                ),
                targetLanguage: TranslationLanguageNames.target(
                    identifier: context.preferences.targetLanguageIdentifier
                )
            ),
            selectedText: context.selection.normalizedText,
            apiKey: apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            streamsResponse: context.configuration.configuration.streamsResponse
        )
        do {
            try modelRequestSender.start(request) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.receiveModelEvent(event, context: context)
                }
            }
        } catch {
            finishModelRequest(context, errorMessage: error.localizedDescription)
        }
    }

    private func receiveModelEvent(
        _ event: TranslationXPCEvent,
        context: ModelRequestContext
    ) {
        guard event.requestID == context.requestID,
              context.generation == generation,
              activeModelRequest?.requestID == context.requestID else { return }
        switch event.kind {
        case "delta":
            guard let delta = event.text, !delta.isEmpty else { return }
            if translatedText == nil, pendingModelDelta.isEmpty {
                translatedText = delta
                state = .streaming
            } else {
                pendingModelDelta += delta
                scheduleDeltaFlush()
            }
        case "completed":
            flushPendingModelDelta()
            guard let text = translatedText, !text.isEmpty else {
                finishModelRequest(context, errorMessage: "服务没有返回文本译文。")
                return
            }
            cache[context.cacheKey] = text
            state = .success
            completeModelRequest(context)
        case "failed":
            finishModelRequest(context, errorMessage: event.message ?? "翻译服务请求失败。")
        case "cancelled":
            finishModelRequest(context, errorMessage: "翻译请求已取消。")
        default:
            break
        }
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.flushPendingModelDelta()
        }
    }

    private func flushPendingModelDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingModelDelta.isEmpty else { return }
        translatedText = (translatedText ?? "") + pendingModelDelta
        pendingModelDelta = ""
        state = .streaming
    }

    private func finishModelRequest(
        _ context: ModelRequestContext,
        errorMessage: String
    ) {
        guard context.generation == generation,
              activeModelRequest?.requestID == context.requestID else { return }
        flushPendingModelDelta()
        if translatedText?.isEmpty == false {
            state = .interrupted(errorMessage)
        } else {
            translatedText = nil
            state = .failed(errorMessage)
        }
        completeModelRequest(context)
        refreshSystemFallbackAvailability()
    }

    private func completeModelRequest(_ context: ModelRequestContext) {
        guard activeModelRequest?.requestID == context.requestID else { return }
        activeModelRequest = nil
        activeModelPreparationTask?.cancel()
        activeModelPreparationTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingModelDelta = ""
    }

    private func refreshSystemFallbackAvailability() {
        guard let preferences = lastPreferences,
              preferences.engine == .customModel,
              let selection,
              let sourceLanguage = resolvedAppleSourceLanguage(
                  selection: selection,
                  preferences: preferences
              )
        else {
            systemFallbackAvailability = .unavailable("系统翻译无法识别当前原文语言。")
            return
        }
        fallbackAvailabilityTask?.cancel()
        systemFallbackAvailability = .checking
        let targetLanguage = preferences.targetLanguage
        let checker = availabilityChecker
        let expectedGeneration = generation
        fallbackAvailabilityTask = Task { [weak self] in
            let readiness = await checker.readiness(from: sourceLanguage, to: targetLanguage)
            guard !Task.isCancelled, self?.generation == expectedGeneration else { return }
            switch readiness {
            case .installed, .downloadable:
                self?.systemFallbackAvailability = .available
            case .unsupported:
                self?.systemFallbackAvailability = .unavailable("系统不支持这个原文语言与目标语言组合。")
            }
        }
    }

    private func resolvedAppleSourceLanguage(
        selection: TranslationSelection,
        preferences: TranslationRequestPreferences
    ) -> Locale.Language? {
        preferences.sourceLanguage ?? sourceLanguageRecognizer.language(for: selection.languageSample)
    }

    private func cancelWorkForNewGeneration() {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        pendingAppleRequest = nil
        pendingModelConsent = nil
        pendingOriginConsent = nil
        if let requestID = activeModelRequest?.requestID {
            modelRequestSender.cancel(requestID: requestID)
        }
        activeModelRequest = nil
        activeModelPreparationTask?.cancel()
        activeModelPreparationTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingModelDelta = ""
        fallbackAvailabilityTask?.cancel()
        fallbackAvailabilityTask = nil
        configuration = nil
    }

    private struct AppleRequestContext {
        let generation: Int
        let selection: TranslationSelection
        let sourceLanguage: Locale.Language
        let targetLanguage: Locale.Language
        let cacheKey: TranslationCacheKey
    }

    private struct ModelRequestContext: Sendable {
        let generation: Int
        let requestID: String
        let selection: TranslationSelection
        let preferences: TranslationRequestPreferences
        let configuration: ValidatedModelTranslationConfiguration
        let cacheKey: TranslationCacheKey
    }
}

private enum TranslationControllerError: LocalizedError {
    case unsupportedLanguagePair

    var errorDescription: String? {
        "系统不支持这个原文语言与目标语言组合。"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
