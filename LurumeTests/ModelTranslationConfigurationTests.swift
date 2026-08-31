import Foundation
import XCTest
@testable import Lurume

@MainActor
final class ModelTranslationConfigurationTests: XCTestCase {
    func testFreshSettingsRemainOnAppleTranslation() {
        withSettings { settings, _ in
            XCTAssertEqual(settings.translationEngine, .apple)
            XCTAssertEqual(settings.modelTranslationBaseURL, "https://api.openai.com/v1")
            XCTAssertEqual(settings.modelTranslationModel, "")
            XCTAssertTrue(settings.modelTranslationStreamsResponse)
        }
    }

    func testUnknownOrInvalidStoredEngineFallsBackToApple() {
        withSettings(initialValues: [
            "translationEngine": TranslationEngine.customModel.rawValue,
            "modelTranslationBaseURL": "http://example.com/v1",
            "modelTranslationModel": "fixture-model",
            "modelTranslationPrompt": ModelTranslationConfiguration.defaultPrompt,
        ]) { settings, defaults in
            XCTAssertEqual(settings.translationEngine, .apple)
            XCTAssertEqual(defaults.string(forKey: "translationEngine"), "apple")
        }
    }

    func testValidCustomConfigurationPersists() throws {
        try withSettings { settings, defaults in
            let validated = try ModelTranslationConfigurationValidator.validate(
                baseURL: "https://example.com/v1/",
                model: "fixture-model",
                streamsResponse: false,
                prompt: ModelTranslationConfiguration.defaultPrompt
            )
            settings.applyModelTranslationConfiguration(validated, engine: .customModel)
            let restored = AppSettings(defaults: defaults)

            XCTAssertEqual(restored.translationEngine, .customModel)
            XCTAssertEqual(restored.modelTranslationBaseURL, "https://example.com/v1")
            XCTAssertEqual(restored.modelTranslationModel, "fixture-model")
            XCTAssertFalse(restored.modelTranslationStreamsResponse)
        }
    }

    func testValidatorBuildsMinimalEndpointAndEffectiveOrigin() throws {
        let result = try ModelTranslationConfigurationValidator.validate(
            baseURL: " HTTPS://Example.COM/v1/ ",
            model: "  fixture-model  ",
            streamsResponse: true,
            prompt: "  translate  "
        )

        XCTAssertEqual(result.configuration.baseURL, "https://example.com/v1")
        XCTAssertEqual(result.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(result.configuration.model, "fixture-model")
        XCTAssertEqual(result.configuration.prompt, "translate")
        XCTAssertEqual(result.origin.persistedValue, "https://example.com:443")
        XCTAssertFalse(result.strippedChatCompletionsSuffix)
    }

    func testValidatorStripsCopiedChatCompletionsEndpoint() throws {
        let result = try ModelTranslationConfigurationValidator.validate(
            baseURL: "https://example.com/v1/chat/completions/",
            model: "fixture-model",
            streamsResponse: true,
            prompt: "translate"
        )

        XCTAssertEqual(result.configuration.baseURL, "https://example.com/v1")
        XCTAssertEqual(result.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertTrue(result.strippedChatCompletionsSuffix)
    }

    func testValidatorAllowsOnlyLoopbackHTTP() throws {
        for baseURL in [
            "http://localhost:1234/v1",
            "http://127.0.0.1:1234/v1",
            "http://[::1]:1234/v1",
        ] {
            let result = try ModelTranslationConfigurationValidator.validate(
                baseURL: baseURL,
                model: "fixture-model",
                streamsResponse: true,
                prompt: "translate"
            )
            XCTAssertTrue(result.origin.isLoopback)
        }

        XCTAssertThrowsError(try validated(baseURL: "http://example.com/v1")) {
            XCTAssertEqual($0 as? ModelTranslationConfigurationError, .insecureRemoteHTTP)
        }
    }

    func testValidatorRejectsCredentialsQueryFragmentAndSchemes() {
        let cases: [(String, ModelTranslationConfigurationError)] = [
            ("https://user:pass@example.com/v1", .credentialsNotAllowed),
            ("https://example.com/v1?token=value", .queryNotAllowed),
            ("https://example.com/v1#fragment", .fragmentNotAllowed),
            ("file:///tmp/service", .malformedBaseURL),
            ("ftp://example.com/v1", .unsupportedScheme),
        ]
        for (baseURL, expected) in cases {
            XCTAssertThrowsError(try validated(baseURL: baseURL)) {
                XCTAssertEqual($0 as? ModelTranslationConfigurationError, expected)
            }
        }
    }

    func testPromptValidationAndLanguageReplacement() throws {
        XCTAssertThrowsError(
            try validated(baseURL: "https://example.com/v1", prompt: " \n ")
        ) {
            XCTAssertEqual($0 as? ModelTranslationConfigurationError, .emptyPrompt)
        }
        XCTAssertThrowsError(
            try validated(
                baseURL: "https://example.com/v1",
                prompt: String(repeating: "a", count: 4_001)
            )
        ) {
            XCTAssertEqual($0 as? ModelTranslationConfigurationError, .promptTooLong)
        }

        let configuration = try validated(
            baseURL: "https://example.com/v1",
            prompt: "from {source_language} to {target_language}"
        )
        XCTAssertEqual(
            configuration.renderedPrompt(
                sourceLanguage: "自动识别原文语言",
                targetLanguage: "简体中文"
            ),
            "from 自动识别原文语言 to 简体中文"
        )
    }

    func testOriginConfirmationIsNormalizedAndPersisted() throws {
        try withSettings { settings, defaults in
            let origin = try validated(baseURL: "https://EXAMPLE.com/v1").origin
            XCTAssertFalse(settings.isTranslationOriginConfirmed(origin))

            settings.confirmTranslationOrigin(origin)
            let restored = AppSettings(defaults: defaults)

            XCTAssertTrue(restored.isTranslationOriginConfirmed(origin))
            XCTAssertEqual(restored.confirmedTranslationOrigins, ["https://example.com:443"])
        }
    }

    func testLoopbackAndRemoteDisclosuresUseDifferentFeeLanguage() throws {
        let local = TranslationConnectionDisclosure(
            origin: try validated(baseURL: "http://127.0.0.1:1234/v1").origin
        )
        let remote = TranslationConnectionDisclosure(
            origin: try validated(baseURL: "https://example.com/v1").origin
        )
        let localConsent = TranslationOriginConsentNotice(
            origin: try validated(baseURL: "http://localhost:1234/v1").origin
        )
        let remoteConsent = TranslationOriginConsentNotice(
            origin: try validated(baseURL: "https://example.com/v1").origin
        )

        XCTAssertTrue(local.message.contains("本机"))
        XCTAssertFalse(local.message.contains("费用"))
        XCTAssertTrue(remote.message.contains("费用"))
        XCTAssertFalse(localConsent.message.contains("费用"))
        XCTAssertTrue(remoteConsent.message.contains("费用"))
        XCTAssertTrue(remoteConsent.message.contains("手动翻译和自动翻译"))
    }

    func testSuccessfulSavePublishesConfigurationAndStoresKey() async throws {
        let store = FakeTranslationAPIKeyStore()
        let sender = RecordingTranslationRequestSender()
        let controller = ModelTranslationSettingsController(keyStore: store, requestSender: sender)
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await controller.load(from: settings)
        controller.draftEngine = .customModel
        controller.draftBaseURL = "https://example.com/v1/chat/completions"
        controller.draftModel = "fixture-model"
        controller.draftAPIKey = "fixture-api-value"

        await controller.save(to: settings)

        XCTAssertEqual(settings.translationEngine, .customModel)
        XCTAssertEqual(settings.modelTranslationBaseURL, "https://example.com/v1")
        let storedValue = await store.currentValue()
        XCTAssertEqual(storedValue, "fixture-api-value")
        XCTAssertTrue(controller.hasStoredAPIKey)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            (value as? String) == "fixture-api-value"
        })
    }

    func testKeychainFailureDoesNotPublishDraft() async {
        let store = FakeTranslationAPIKeyStore(failsOnSave: true)
        let controller = ModelTranslationSettingsController(
            keyStore: store,
            requestSender: RecordingTranslationRequestSender()
        )
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await controller.load(from: settings)
        controller.draftEngine = .customModel
        controller.draftBaseURL = "https://example.com/v1"
        controller.draftModel = "fixture-model"
        controller.draftAPIKey = "fixture-api-value"

        await controller.save(to: settings)

        XCTAssertEqual(settings.translationEngine, .apple)
        XCTAssertEqual(settings.modelTranslationModel, "")
        XCTAssertTrue(controller.saveMessage?.contains("钥匙串") == true)
    }

    func testEmptyKeySaveDeletesPreviousKey() async {
        let store = FakeTranslationAPIKeyStore(initialValue: "old-value")
        let controller = ModelTranslationSettingsController(
            keyStore: store,
            requestSender: RecordingTranslationRequestSender()
        )
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await controller.load(from: settings)
        controller.draftBaseURL = "https://example.com/v1"
        controller.draftModel = "fixture-model"
        controller.draftAPIKey = ""

        await controller.save(to: settings)

        let storedValue = await store.currentValue()
        XCTAssertNil(storedValue)
        XCTAssertFalse(controller.hasStoredAPIKey)
    }

    func testConnectionTestRequestUsesOnlyBuiltInTextAndCurrentDraft() throws {
        let sender = RecordingTranslationRequestSender()
        let controller = ModelTranslationSettingsController(
            keyStore: FakeTranslationAPIKeyStore(),
            requestSender: sender
        )
        controller.draftBaseURL = "https://example.com/v1"
        controller.draftModel = "fixture-model"
        controller.draftAPIKey = "fixture-api-value"
        controller.draftStreamsResponse = false
        controller.startConnectionTest(
            sourceLanguageIdentifier: TranslationSourceLanguageOption.automaticID,
            targetLanguageIdentifier: "zh-Hans"
        )

        let request = try XCTUnwrap(sender.lastRequest)
        XCTAssertEqual(request.endpoint, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.model, "fixture-model")
        XCTAssertEqual(request.selectedText, ModelTranslationConfiguration.connectionTestText)
        XCTAssertTrue(request.systemPrompt.contains("自动识别原文语言"))
        XCTAssertTrue(request.systemPrompt.contains("简体中文"))
        XCTAssertEqual(request.apiKey, "fixture-api-value")
        XCTAssertFalse(request.streamsResponse)
    }

    private func validated(
        baseURL: String,
        prompt: String = ModelTranslationConfiguration.defaultPrompt
    ) throws -> ValidatedModelTranslationConfiguration {
        try ModelTranslationConfigurationValidator.validate(
            baseURL: baseURL,
            model: "fixture-model",
            streamsResponse: true,
            prompt: prompt
        )
    }

    private func withSettings(
        initialValues: [String: Any] = [:],
        _ body: (AppSettings, UserDefaults) throws -> Void
    ) rethrows {
        let (settings, defaults, suiteName) = makeSettings(initialValues: initialValues)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(settings, defaults)
    }

    private func makeSettings(
        initialValues: [String: Any] = [:]
    ) -> (AppSettings, UserDefaults, String) {
        let suiteName = "ModelTranslationConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        for (key, value) in initialValues {
            defaults.set(value, forKey: key)
        }
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }
}

private actor FakeTranslationAPIKeyStore: TranslationAPIKeyStoring {
    private var value: String?
    private let failsOnSave: Bool

    init(initialValue: String? = nil, failsOnSave: Bool = false) {
        value = initialValue
        self.failsOnSave = failsOnSave
    }

    func read() async throws -> String? { value }

    func save(_ apiKey: String) async throws {
        if failsOnSave {
            throw TranslationAPIKeyStoreError.keychain(-1)
        }
        value = apiKey
    }

    func delete() async throws {
        value = nil
    }

    func currentValue() -> String? { value }
}

private final class RecordingTranslationRequestSender: TranslationRequestSending, @unchecked Sendable {
    private let lock = NSLock()
    private var request: TranslationXPCRequest?

    var lastRequest: TranslationXPCRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func start(
        _ request: TranslationXPCRequest,
        eventHandler: @escaping @Sendable (TranslationXPCEvent) -> Void
    ) throws {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func cancel(requestID: String) {}
}
