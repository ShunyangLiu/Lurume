import XCTest
@testable import Lurume

@MainActor
final class TranslationProviderTests: XCTestCase {
    func testEveryPresetHasValidModelsAndExpectedProtocol() throws {
        for provider in TranslationProvider.allCases where provider != .custom {
            let profile = ModelTranslationProfile(provider: provider)
            XCTAssertFalse(profile.model.isEmpty)
            let configuration = try validated(provider: provider)
            XCTAssertEqual(configuration.endpoint.absoluteString, provider.baseURL + provider.apiFormat.endpointSuffix)
            XCTAssertEqual(configuration.configuration.provider, provider)
            XCTAssertFalse(provider.baseURL.contains("coding"))
        }
        XCTAssertEqual(TranslationProvider.anthropic.apiFormat, .anthropic)
        XCTAssertTrue(TranslationProvider.openRouter.models.allSatisfy { $0.contains("/") })
    }

    func testNativeEndpointNormalizationAndCredentialIsolation() throws {
        let native = try validated(provider: .anthropic, url: "https://API.ANTHROPIC.COM/v1/messages/")
        XCTAssertEqual(native.configuration.baseURL, TranslationProvider.anthropic.baseURL)
        XCTAssertTrue(native.strippedChatCompletionsSuffix)
        let custom = try validated(provider: .custom, url: native.configuration.baseURL)
        let path = try validated(provider: .anthropic, url: "https://api.anthropic.com/other")
        XCTAssertNotEqual(native.configuration.credentialScope, custom.configuration.credentialScope)
        XCTAssertNotEqual(native.configuration.credentialScope, path.configuration.credentialScope)
    }

    func testThinkingIsOnlyDisabledForOptedInCompatibleProviders() throws {
        for provider in TranslationProvider.allCases where provider != .custom {
            let config = try validated(provider: provider).configuration
            XCTAssertEqual(config.disablesThinking, [.anthropic, .glm, .volcengine, .deepSeek].contains(provider))
        }
        let config = try ModelTranslationConfigurationValidator.validate(
            baseURL: TranslationProvider.deepSeek.baseURL, model: "fixture", streamsResponse: true,
            optimizesForTranslation: false, prompt: "translate", provider: .deepSeek
        )
        XCTAssertFalse(config.configuration.disablesThinking)
    }

    func testLegacyConfigurationSurvivesProviderSaveAndRestart() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try validated(provider: .custom, url: "https://example.test/api/coding/v3")
        settings.applyModelTranslationConfiguration(legacy, engine: .customModel)
        // Simulate an actual pre-profile installation.
        defaults.removeObject(forKey: "modelTranslationProvider")
        defaults.removeObject(forKey: "modelTranslationProfiles")
        let restoredLegacy = AppSettings(defaults: defaults)
        XCTAssertEqual(restoredLegacy.modelTranslationProvider, .custom)
        let store = CountingFixtureKeyStore()
        let controller = ModelTranslationSettingsController(keyStore: store, legacyKeyStore: store)
        await controller.load(from: restoredLegacy)
        controller.selectProvider(.anthropic)
        await controller.waitForAPIKeyLoad()
        controller.draftModel = "manual-model-id"
        await controller.save(to: restoredLegacy)
        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.modelTranslationProvider, .anthropic)
        XCTAssertEqual(reopened.modelTranslationAPIFormat, .anthropic)
        XCTAssertEqual(reopened.modelTranslationModel, "manual-model-id")
        XCTAssertEqual(reopened.modelTranslationProfiles["custom"]?.baseURL, legacy.configuration.baseURL)
        let nextController = ModelTranslationSettingsController(keyStore: store)
        await nextController.load(from: reopened)
        nextController.selectProvider(.custom)
        await nextController.waitForAPIKeyLoad()
        XCTAssertEqual(nextController.draftBaseURL, legacy.configuration.baseURL)
        nextController.selectProvider(.anthropic)
        await nextController.waitForAPIKeyLoad()
        XCTAssertEqual(nextController.draftModel, "manual-model-id")
    }

    func testSwitchingProviderAndAddressNeverCarriesPreviousKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials/keys.json")
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyStore = CountingFixtureKeyStore(key: "legacy-fixture")
        let controller = ModelTranslationSettingsController(
            legacyKeyStore: legacyStore,
            keyStoreFactory: { LocalTranslationAPIKeyStore(scope: $0, fileURL: file) }
        )
        await controller.load(from: settings)
        controller.selectProvider(.openAI)
        await controller.waitForAPIKeyLoad()
        controller.draftAPIKey = "openai-fixture"
        await controller.save(to: settings)
        controller.selectProvider(.deepSeek)
        XCTAssertEqual(controller.draftAPIKey, "")
        await controller.waitForAPIKeyLoad()
        XCTAssertEqual(controller.draftAPIKey, "")
        controller.draftAPIKey = "deepseek-fixture"
        await controller.save(to: settings)
        controller.selectProvider(.openAI)
        await controller.waitForAPIKeyLoad()
        XCTAssertEqual(controller.draftAPIKey, "openai-fixture")
        controller.draftBaseURL = "https://another.example.test/v1"
        XCTAssertEqual(controller.draftAPIKey, "")
        await controller.waitForAPIKeyLoad()
        XCTAssertFalse(controller.hasStoredAPIKey)
        controller.draftAPIKey = "unsaved-fixture"
        controller.draftAPIFormat = .anthropic
        XCTAssertEqual(controller.draftAPIKey, "")
        await controller.waitForAPIKeyLoad()
        let reads = await legacyStore.readCount
        XCTAssertEqual(reads, 0)
        let storedProfiles = try XCTUnwrap(defaults.data(forKey: "modelTranslationProfiles"))
        XCTAssertFalse(String(decoding: storedProfiles, as: UTF8.self).contains("fixture"))
    }

    func testStaleCredentialReadCannotReplaceNewProviderKey() async throws {
        let oldStore = SuspendedFixtureKeyStore()
        let nextStore = CountingFixtureKeyStore(key: "new-provider-fixture")
        let controller = ModelTranslationSettingsController(keyStoreFactory: { scope in
            if scope.hasPrefix("openAI|") { return oldStore }
            return nextStore
        })
        controller.selectProvider(.openAI)
        await oldStore.waitUntilStarted()
        controller.selectProvider(.deepSeek)
        await controller.waitForAPIKeyLoad()
        XCTAssertEqual(controller.draftAPIKey, "new-provider-fixture")
        await oldStore.complete()
        await Task.yield()
        XCTAssertEqual(controller.draftAPIKey, "new-provider-fixture")
        XCTAssertFalse(controller.isLoadingAPIKey)
    }

    func testLegacyKeyReadRequiresExplicitActionAndNeverDeletesOldItem() async throws {
        let local = CountingFixtureKeyStore()
        let legacy = CountingFixtureKeyStore(key: "legacy-fixture")
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ModelTranslationSettingsController(keyStore: local, legacyKeyStore: legacy)
        await controller.load(from: settings)
        var reads = await legacy.readCount
        XCTAssertEqual(reads, 0)
        await controller.readLegacyAPIKey()
        XCTAssertEqual(controller.draftAPIKey, "legacy-fixture")
        var localKey = await local.key
        XCTAssertNil(localKey)
        controller.draftModel = "fixture-model"
        await controller.save(to: settings)
        localKey = await local.key
        XCTAssertEqual(localKey, "legacy-fixture")
        reads = await legacy.readCount
        let deletes = await legacy.deleteCount
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(deletes, 0)
    }

    func testLegacyMigrationNeverOverwritesAnExistingDraftKey() async throws {
        let legacy = CountingFixtureKeyStore(key: "legacy-fixture")
        let controller = ModelTranslationSettingsController(keyStore: CountingFixtureKeyStore(), legacyKeyStore: legacy)
        controller.selectProvider(.openAI)
        await controller.waitForAPIKeyLoad()
        controller.draftAPIKey = "manual-fixture"
        await controller.readLegacyAPIKey()
        let reads = await legacy.readCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(controller.draftAPIKey, "manual-fixture")
    }

    private func validated(provider: TranslationProvider, url: String? = nil) throws -> ValidatedModelTranslationConfiguration {
        try ModelTranslationConfigurationValidator.validate(
            baseURL: url ?? provider.baseURL, model: "fixture", streamsResponse: true,
            prompt: "translate", provider: provider, apiFormat: provider.apiFormat
        )
    }

    private func makeSettings() -> (AppSettings, UserDefaults, String) {
        let suite = "TranslationProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TranslationKeysTests-\(UUID().uuidString)")
    }
}

private actor CountingFixtureKeyStore: TranslationAPIKeyStoring {
    var key: String?
    var readCount = 0
    var deleteCount = 0
    init(key: String? = nil) { self.key = key }
    func read() -> String? { readCount += 1; return key }
    func save(_ apiKey: String) { key = apiKey }
    func delete() { deleteCount += 1; key = nil }
}

private actor SuspendedFixtureKeyStore: TranslationAPIKeyStoring {
    private var continuation: CheckedContinuation<String?, Never>?
    func read() async -> String? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func complete() { continuation?.resume(returning: "old-provider-fixture"); continuation = nil }
    func save(_ apiKey: String) {}
    func delete() {}
}
