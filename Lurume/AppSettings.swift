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
        static let modelTranslationPrompt = "modelTranslationPrompt"
        static let confirmedTranslationOrigins = "confirmedTranslationOrigins"
    }

    private let defaults: UserDefaults

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
        modelTranslationBaseURL = storedBaseURL
        modelTranslationModel = storedModel
        modelTranslationStreamsResponse = storedStreamsResponse
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
               prompt: storedPrompt
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
            prompt: modelTranslationPrompt
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
            prompt: configuration?.prompt
        )
    }

    func applyModelTranslationConfiguration(
        _ configuration: ValidatedModelTranslationConfiguration,
        engine: TranslationEngine
    ) {
        modelTranslationBaseURL = configuration.configuration.baseURL
        modelTranslationModel = configuration.configuration.model
        modelTranslationStreamsResponse = configuration.configuration.streamsResponse
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
