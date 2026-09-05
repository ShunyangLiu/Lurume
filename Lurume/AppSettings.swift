import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let automaticTranslation = "automaticTranslation"
        static let sourceLanguageIdentifier = "sourceLanguageIdentifier"
        static let targetLanguageIdentifier = "targetLanguageIdentifier"
        // Keep the existing key so earlier choices become the startup default.
        static let defaultLibrarySortOption = "librarySortOption"
        static let mainWindowMode = "mainWindowMode"
        static let lastLibrarySource = "lastLibrarySource"
        static let translationEngine = "translationEngine"
        static let modelTranslationBaseURL = "modelTranslationBaseURL"
        static let modelTranslationModel = "modelTranslationModel"
        static let modelTranslationStreamsResponse = "modelTranslationStreamsResponse"
        static let modelTranslationOptimizesForTranslation = "modelTranslationOptimizesForTranslation"
        static let modelTranslationPrompt = "modelTranslationPrompt"
        static let modelTranslationProvider = "modelTranslationProvider"
        static let modelTranslationAPIFormat = "modelTranslationAPIFormat"
        static let modelTranslationProfiles = "modelTranslationProfiles"
        static let confirmedTranslationOrigins = "confirmedTranslationOrigins"
    }

    private let defaults: UserDefaults
    @Published private(set) var modelTranslationProvider: TranslationProvider {
        didSet { defaults.set(modelTranslationProvider.rawValue, forKey: Key.modelTranslationProvider) }
    }
    @Published private(set) var modelTranslationAPIFormat: TranslationAPIFormat {
        didSet { defaults.set(modelTranslationAPIFormat.rawValue, forKey: Key.modelTranslationAPIFormat) }
    }
    private(set) var modelTranslationProfiles: [String: ModelTranslationProfile]

    @Published var automaticTranslation: Bool {
        didSet { defaults.set(automaticTranslation, forKey: Key.automaticTranslation) }
    }

    @Published var targetLanguageIdentifier: String {
        didSet { defaults.set(targetLanguageIdentifier, forKey: Key.targetLanguageIdentifier) }
    }

    @Published var sourceLanguageIdentifier: String {
        didSet { defaults.set(sourceLanguageIdentifier, forKey: Key.sourceLanguageIdentifier) }
    }

    @Published var defaultLibrarySortOption: LibrarySortOption {
        didSet {
            defaults.set(
                defaultLibrarySortOption.rawValue,
                forKey: Key.defaultLibrarySortOption
            )
        }
    }

    /// Current-session sorting. Sidebar changes intentionally do not persist.
    @Published var librarySortOption: LibrarySortOption

    @Published var mainWindowMode: MainWindowMode {
        didSet { defaults.set(mainWindowMode.rawValue, forKey: Key.mainWindowMode) }
    }

    @Published var lastLibrarySource: LibrarySource {
        didSet { defaults.set(lastLibrarySource.id, forKey: Key.lastLibrarySource) }
    }

    @Published private(set) var translationEngine: TranslationEngine {
        didSet { defaults.set(translationEngine.rawValue, forKey: Key.translationEngine) }
    }

    @Published private(set) var modelTranslationBaseURL: String {
        didSet { defaults.set(modelTranslationBaseURL, forKey: Key.modelTranslationBaseURL) }
    }

    @Published private(set) var modelTranslationModel: String {
        didSet { defaults.set(modelTranslationModel, forKey: Key.modelTranslationModel) }
    }

    @Published private(set) var modelTranslationStreamsResponse: Bool {
        didSet {
            defaults.set(
                modelTranslationStreamsResponse,
                forKey: Key.modelTranslationStreamsResponse
            )
        }
    }

    @Published private(set) var modelTranslationOptimizesForTranslation: Bool {
        didSet {
            defaults.set(
                modelTranslationOptimizesForTranslation,
                forKey: Key.modelTranslationOptimizesForTranslation
            )
        }
    }

    @Published private(set) var modelTranslationPrompt: String {
        didSet { defaults.set(modelTranslationPrompt, forKey: Key.modelTranslationPrompt) }
    }

    @Published private(set) var confirmedTranslationOrigins: Set<String> {
        didSet {
            defaults.set(
                confirmedTranslationOrigins.sorted(),
                forKey: Key.confirmedTranslationOrigins
            )
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Older installs are custom configurations, even when their URL matches a preset.
        let storedProvider = defaults.string(forKey: Key.modelTranslationProvider)
            .flatMap(TranslationProvider.init(rawValue:)) ?? .custom
        let storedAPIFormat = defaults.string(forKey: Key.modelTranslationAPIFormat)
            .flatMap(TranslationAPIFormat.init(rawValue:)) ?? .openAI
        modelTranslationProvider = storedProvider
        modelTranslationAPIFormat = storedAPIFormat
        modelTranslationProfiles = defaults.data(forKey: Key.modelTranslationProfiles).flatMap {
            try? JSONDecoder().decode([String: ModelTranslationProfile].self, from: $0)
        } ?? [:]
        if defaults.object(forKey: Key.automaticTranslation) == nil {
            automaticTranslation = true
        } else {
            automaticTranslation = defaults.bool(forKey: Key.automaticTranslation)
        }
        sourceLanguageIdentifier = defaults.string(forKey: Key.sourceLanguageIdentifier)
            ?? TranslationSourceLanguageOption.englishID
        targetLanguageIdentifier = defaults.string(forKey: Key.targetLanguageIdentifier)
            ?? "zh-Hans"
        let startupSortOption = defaults.string(forKey: Key.defaultLibrarySortOption)
            .flatMap(LibrarySortOption.init(rawValue:))
            ?? .dateAdded
        defaultLibrarySortOption = startupSortOption
        librarySortOption = startupSortOption
        mainWindowMode = defaults.string(forKey: Key.mainWindowMode)
            .flatMap(MainWindowMode.init(rawValue:))
            ?? .reading
        lastLibrarySource = defaults.string(forKey: Key.lastLibrarySource)
            .flatMap(LibrarySource.init(persistedValue:))
            ?? .all

        let storedBaseURL = defaults.string(forKey: Key.modelTranslationBaseURL)
            ?? ModelTranslationConfiguration.defaultBaseURL
        let storedModel = defaults.string(forKey: Key.modelTranslationModel) ?? ""
        let storedPrompt = defaults.string(forKey: Key.modelTranslationPrompt)
            ?? ModelTranslationConfiguration.defaultPrompt
        let storedStreamsResponse: Bool
        if defaults.object(forKey: Key.modelTranslationStreamsResponse) == nil {
            storedStreamsResponse = true
        } else {
            storedStreamsResponse = defaults.bool(forKey: Key.modelTranslationStreamsResponse)
        }
        let storedOptimizesForTranslation: Bool
        if defaults.object(forKey: Key.modelTranslationOptimizesForTranslation) == nil {
            storedOptimizesForTranslation = true
        } else {
            storedOptimizesForTranslation = defaults.bool(
                forKey: Key.modelTranslationOptimizesForTranslation
            )
        }
        modelTranslationBaseURL = storedBaseURL
        modelTranslationModel = storedModel
        modelTranslationStreamsResponse = storedStreamsResponse
        modelTranslationOptimizesForTranslation = storedOptimizesForTranslation
        modelTranslationPrompt = storedPrompt

        confirmedTranslationOrigins = Set(
            (defaults.stringArray(forKey: Key.confirmedTranslationOrigins) ?? []).compactMap {
                TranslationOrigin(persistedValue: $0)?.persistedValue
            }
        )

        let requestedEngine = defaults.string(forKey: Key.translationEngine)
            .flatMap(TranslationEngine.init(rawValue:))
            ?? .apple
        if requestedEngine == .customModel,
           (try? ModelTranslationConfigurationValidator.validate(
               baseURL: storedBaseURL,
               model: storedModel,
               streamsResponse: storedStreamsResponse,
               optimizesForTranslation: storedOptimizesForTranslation,
               prompt: storedPrompt,
               provider: storedProvider,
               apiFormat: storedAPIFormat
           )) == nil {
            translationEngine = .apple
            defaults.set(TranslationEngine.apple.rawValue, forKey: Key.translationEngine)
        } else {
            translationEngine = requestedEngine
        }
    }

    /// `nil` 表示使用 Natural Language 自动识别；默认固定英语以适配论文阅读。
    var sourceLanguage: Locale.Language? {
        guard sourceLanguageIdentifier != TranslationSourceLanguageOption.automaticID else {
            return nil
        }
        return Locale.Language(identifier: sourceLanguageIdentifier)
    }

    var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageIdentifier)
    }

    var modelTranslationConfiguration: ValidatedModelTranslationConfiguration? {
        try? ModelTranslationConfigurationValidator.validate(
            baseURL: modelTranslationBaseURL,
            model: modelTranslationModel,
            streamsResponse: modelTranslationStreamsResponse,
            optimizesForTranslation: modelTranslationOptimizesForTranslation,
            prompt: modelTranslationPrompt,
            provider: modelTranslationProvider,
            apiFormat: modelTranslationAPIFormat
        )
    }

    var translationRequestPreferences: TranslationRequestPreferences {
        let configuration = modelTranslationConfiguration
        return TranslationRequestPreferences(
            engine: translationEngine,
            sourceLanguageIdentifier: sourceLanguageIdentifier,
            targetLanguageIdentifier: targetLanguageIdentifier,
            modelConfiguration: configuration,
            modelOriginIsConfirmed: configuration.map {
                isTranslationOriginConfirmed($0.origin)
            } ?? false
        )
    }

    var translationConfigurationIdentity: TranslationConfigurationIdentity {
        let configuration = modelTranslationConfiguration?.configuration
        return TranslationConfigurationIdentity(
            engine: translationEngine,
            sourceLanguageIdentifier: sourceLanguageIdentifier,
            targetLanguageIdentifier: targetLanguageIdentifier,
            baseURL: configuration?.baseURL,
            model: configuration?.model,
            streamsResponse: configuration?.streamsResponse,
            optimizesForTranslation: configuration?.optimizesForTranslation,
            prompt: configuration?.prompt,
            provider: configuration?.provider,
            apiFormat: configuration?.apiFormat
        )
    }

    func applyModelTranslationConfiguration(
        _ configuration: ValidatedModelTranslationConfiguration,
        engine: TranslationEngine
    ) {
        // Save the previous profile as well, so the first switch preserves legacy settings.
        if let previous = modelTranslationConfiguration?.configuration {
            modelTranslationProfiles[previous.provider.rawValue] = ModelTranslationProfile(configuration: previous)
        }
        let next = configuration.configuration
        modelTranslationProfiles[next.provider.rawValue] = ModelTranslationProfile(configuration: next)
        if let data = try? JSONEncoder().encode(modelTranslationProfiles) {
            defaults.set(data, forKey: Key.modelTranslationProfiles)
        }
        modelTranslationProvider = next.provider
        modelTranslationAPIFormat = next.apiFormat
        modelTranslationBaseURL = configuration.configuration.baseURL
        modelTranslationModel = configuration.configuration.model
        modelTranslationStreamsResponse = configuration.configuration.streamsResponse
        modelTranslationOptimizesForTranslation = configuration.configuration.optimizesForTranslation
        modelTranslationPrompt = configuration.configuration.prompt
        translationEngine = engine
    }

    func isTranslationOriginConfirmed(_ origin: TranslationOrigin) -> Bool {
        confirmedTranslationOrigins.contains(origin.persistedValue)
    }

    func confirmTranslationOrigin(_ origin: TranslationOrigin) {
        confirmedTranslationOrigins.insert(origin.persistedValue)
    }
}

struct TranslationSourceLanguageOption: Identifiable, Hashable, Sendable {
    static let englishID = "en"
    static let automaticID = "automatic"

    let id: String
    let name: String

    static let common: [Self] = [
        Self(id: englishID, name: "英语（默认）"),
        Self(id: automaticID, name: "自动识别"),
    ]
}

struct TranslationLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static let common: [Self] = [
        Self(id: "zh-Hans", name: "简体中文"),
        Self(id: "zh-Hant", name: "繁体中文"),
        Self(id: "en", name: "英语"),
        Self(id: "ja", name: "日语"),
        Self(id: "ko", name: "韩语"),
        Self(id: "fr", name: "法语"),
        Self(id: "de", name: "德语"),
        Self(id: "es", name: "西班牙语"),
    ]
}
