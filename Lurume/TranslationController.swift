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

enum TranslationState: Equatable, Sendable {
    case idle
    case waiting
    case translating
    case resourcesNeeded
    case success
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .idle: "尚无翻译"
        case .waiting: "等待翻译"
        case .translating: "正在翻译"
        case .resourcesNeeded: "正在准备语言资源"
        case .success: "翻译完成"
        case .failed: "翻译失败"
        case .cancelled: "任务已取消"
        }
    }
}

@MainActor
final class TranslationController: ObservableObject {
    @Published private(set) var selection: TranslationSelection?
    @Published private(set) var translatedText: String?
    @Published private(set) var state: TranslationState = .idle
    @Published private(set) var configuration: TranslationSession.Configuration?
    /// P1：主窗口打开时检查器默认可见，首次选区只更新内容、不再改变布局。
    @Published var isInspectorPresented = true

    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var activeTranslationTask: Task<TranslationOutput, Error>?
    private var pendingRequest: RequestContext?
    private var cache: [CacheKey: String] = [:]
    private let sourceLanguageRecognizer: any SourceLanguageRecognizing

    init(
        sourceLanguageRecognizer: any SourceLanguageRecognizing = NaturalLanguageSourceRecognizer()
    ) {
        self.sourceLanguageRecognizer = sourceLanguageRecognizer
    }

    deinit {
        debounceTask?.cancel()
        activeTranslationTask?.cancel()
    }

    func receiveSelection(
        _ event: PDFSelectionEvent?,
        paperID: UUID,
        paperName: String,
        automaticTranslation: Bool,
        targetLanguage: Locale.Language
    ) {
        guard let event else {
            return
        }
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
        state = .waiting

        guard automaticTranslation else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.requestTranslation(
                targetLanguage: targetLanguage,
                revealInspector: false
            )
        }
    }

    func requestTranslation(
        targetLanguage: Locale.Language,
        revealInspector: Bool = true
    ) {
        if revealInspector {
            isInspectorPresented = true
        }
        cancelWorkForNewGeneration()
        guard let selection else { return }
        guard let sourceLanguage = sourceLanguageRecognizer.language(
            for: selection.languageSample
        ) else {
            state = .failed("无法识别原文语言。请尝试选择更长的文本。")
            return
        }

        let cacheKey = CacheKey(
            text: selection.normalizedText,
            sourceIdentifier: sourceLanguage.minimalIdentifier,
            targetIdentifier: targetLanguage.minimalIdentifier
        )
        if let cached = cache[cacheKey] {
            translatedText = cached
            state = .success
            return
        }

        let request = RequestContext(
            generation: generation,
            selection: selection,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            cacheKey: cacheKey
        )
        pendingRequest = request
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

    func perform(using performer: any TranslationPerforming) async {
        guard let request = pendingRequest,
              request.generation == generation else { return }
        pendingRequest = nil

        let task = Task { @MainActor in
            let readiness = await performer.readiness(
                from: request.sourceLanguage,
                to: request.targetLanguage
            )
            switch readiness {
            case .installed:
                state = .translating
            case .downloadable:
                // translate(_:) supplies sample text for source-language detection and
                // lets the system present its language-download confirmation UI.
                // prepareTranslation() cannot do that when the session source is nil.
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
            state = .success
        } catch is CancellationError {
            guard request.generation == generation else { return }
            state = .cancelled
        } catch {
            guard request.generation == generation else { return }
            state = .failed(error.localizedDescription)
        }

        if request.generation == generation {
            activeTranslationTask = nil
        }
    }

    func clear() {
        cancelWorkForNewGeneration()
        selection = nil
        translatedText = nil
        state = .idle
    }

    func paperRemoved(_ paperID: UUID) {
        guard selection?.paperID == paperID else { return }
        clear()
    }

    func cancelPendingAutomaticTranslation() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func cancelWorkForNewGeneration() {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        pendingRequest = nil
    }

    private struct RequestContext {
        let generation: Int
        let selection: TranslationSelection
        let sourceLanguage: Locale.Language
        let targetLanguage: Locale.Language
        let cacheKey: CacheKey
    }

    private struct CacheKey: Hashable {
        let text: String
        let sourceIdentifier: String
        let targetIdentifier: String
    }
}

private enum TranslationControllerError: LocalizedError {
    case unsupportedLanguagePair

    var errorDescription: String? {
        "系统不支持这个原文语言与目标语言组合。"
    }
}
