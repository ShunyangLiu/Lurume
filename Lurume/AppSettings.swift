import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let automaticTranslation = "automaticTranslation"
        static let sourceLanguageIdentifier = "sourceLanguageIdentifier"
        static let targetLanguageIdentifier = "targetLanguageIdentifier"
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
