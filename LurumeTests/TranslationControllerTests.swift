import Foundation
import XCTest
@testable import Lurume

@MainActor
final class TranslationControllerTests: XCTestCase {
    func testClearingPDFSelectionRetainsLastInspectorSelection() {
        let controller = makeController()
        let paperID = UUID()
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 2),
            paperID: paperID,
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: Locale.Language(identifier: "zh-Hans")
        )

        controller.receiveSelection(
            nil,
            paperID: paperID,
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: Locale.Language(identifier: "zh-Hans")
        )

        XCTAssertEqual(controller.selection?.rawText, "Original")
        XCTAssertEqual(controller.state, .waiting)
    }

    func testManualModeWaitsWithoutCreatingTranslationConfiguration() {
        let controller = makeController()
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: Locale.Language(identifier: "zh-Hans")
        )

        XCTAssertNil(controller.configuration)
        XCTAssertEqual(controller.state, .waiting)
    }

    func testLateOldResultCannotReplaceNewSelection() async {
        let controller = makeController()
        let target = Locale.Language(identifier: "zh-Hans")

        controller.receiveSelection(
            PDFSelectionEvent(rawText: "First", pageIndex: 0),
            paperID: UUID(),
            paperName: "First Paper",
            automaticTranslation: false,
            targetLanguage: target
        )
        controller.requestTranslation(targetLanguage: target)
        let firstRun = Task {
            await controller.perform(
                using: FakeTranslationPerformer(output: "旧译文", delay: .milliseconds(80))
            )
        }
        await Task.yield()

        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Second", pageIndex: 3),
            paperID: UUID(),
            paperName: "Second Paper",
            automaticTranslation: false,
            targetLanguage: target
        )
        controller.requestTranslation(targetLanguage: target)
        await controller.perform(
            using: FakeTranslationPerformer(output: "新译文", delay: .zero)
        )
        await firstRun.value

        XCTAssertEqual(controller.selection?.rawText, "Second")
        XCTAssertEqual(controller.translatedText, "新译文")
        XCTAssertEqual(controller.state, .success)
    }

    func testManualRetryDuringFlightDoesNotLetStaleResultOverwrite() async {
        let controller = makeController()
        let target = Locale.Language(identifier: "zh-Hans")

        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )
        controller.requestTranslation(targetLanguage: target)
        let firstAttempt = Task {
            await controller.perform(
                using: FakeTranslationPerformer(output: "旧译文", delay: .milliseconds(80))
            )
        }
        try? await Task.sleep(for: .milliseconds(10))

        controller.requestTranslation(targetLanguage: target)
        await controller.perform(
            using: FakeTranslationPerformer(output: "新译文", delay: .zero)
        )
        await firstAttempt.value

        XCTAssertEqual(controller.translatedText, "新译文")
        XCTAssertEqual(controller.state, .success)
    }

    func testDownloadableLanguageTranslatesWithSampleText() async {
        let controller = makeController()
        let target = Locale.Language(identifier: "zh-Hans")
        let performer = RecordingTranslationPerformer()
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )
        controller.requestTranslation(targetLanguage: target)

        await controller.perform(using: performer)

        let recordedCalls = await performer.calls
        XCTAssertEqual(recordedCalls, ["readiness", "prepare", "translate"])
        XCTAssertEqual(controller.translatedText, "译文")
    }

    func testRepeatedAppleTranslationInvalidatesSameLanguageConfiguration() {
        let controller = makeController()
        let target = Locale.Language(identifier: "zh-Hans")
        let preferences = TranslationRequestPreferences.apple(
            targetLanguage: target,
            sourceLanguage: Locale.Language(identifier: "en")
        )

        controller.receiveSelection(
            PDFSelectionEvent(rawText: "First", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            preferences: preferences
        )
        controller.requestTranslation(preferences: preferences)
        let firstVersion = controller.configuration?.version

        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Second", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            preferences: preferences
        )
        controller.requestTranslation(preferences: preferences)

        XCTAssertNotNil(firstVersion)
        XCTAssertEqual(controller.configuration?.source?.minimalIdentifier, "en")
        XCTAssertEqual(controller.configuration?.target?.minimalIdentifier, "zh")
        XCTAssertGreaterThan(controller.configuration?.version ?? 0, firstVersion ?? 0)
    }

    func testAppleTranslationTimeoutCancelsSessionAndAllowsRetry() async {
        let performer = HangingTranslationPerformer()
        let controller = TranslationController(
            sourceLanguageRecognizer: FixedSourceLanguageRecognizer(),
            systemTimeoutPolicy: SystemTranslationTimeoutPolicy(
                readiness: .seconds(1),
                translation: .milliseconds(20),
                resourcePreparation: .seconds(1)
            )
        )
        let target = Locale.Language(identifier: "zh-Hans")
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )
        controller.requestTranslation(targetLanguage: target)

        await controller.perform(using: performer)

        XCTAssertEqual(controller.state, .failed("系统翻译响应超时，请重试。"))
        XCTAssertNil(controller.configuration)
        XCTAssertEqual(performer.cancelCount, 1)
    }

    func testAppleTranslationSessionActivationCannotWaitForever() async {
        let controller = TranslationController(
            sourceLanguageRecognizer: FixedSourceLanguageRecognizer(),
            systemTimeoutPolicy: SystemTranslationTimeoutPolicy(
                readiness: .milliseconds(20),
                translation: .seconds(1),
                resourcePreparation: .seconds(1)
            )
        )
        let target = Locale.Language(identifier: "zh-Hans")
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )

        controller.requestTranslation(targetLanguage: target)
        XCTAssertTrue(controller.isTranslationActive)
        try? await waitUntil {
            controller.state == .failed("系统翻译会话启动超时，请重试。")
        }

        XCTAssertEqual(controller.state, .failed("系统翻译会话启动超时，请重试。"))
        XCTAssertNil(controller.configuration)
        XCTAssertFalse(controller.isTranslationActive)
    }

    func testTurningOffAutomaticTranslationCancelsPendingDebounce() async {
        let controller = makeController()
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: true,
            targetLanguage: Locale.Language(identifier: "zh-Hans")
        )

        controller.cancelPendingAutomaticTranslation()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(controller.configuration)
        XCTAssertEqual(controller.state, .waiting)
    }

    func testAutomaticTranslationDoesNotReopenHiddenInspector() async {
        let controller = makeController()
        controller.isInspectorPresented = false
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: true,
            targetLanguage: Locale.Language(identifier: "zh-Hans")
        )

        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(controller.isInspectorPresented)
        XCTAssertNotNil(controller.configuration)
    }

    func testManualTranslationReopensHiddenInspector() {
        let controller = makeController()
        let target = Locale.Language(identifier: "zh-Hans")
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Original", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )
        controller.isInspectorPresented = false

        controller.requestTranslation(targetLanguage: target)

        XCTAssertTrue(controller.isInspectorPresented)
    }

    func testShortTermUsesPageContextForSourceLanguage() {
        let controller = TranslationController(
            sourceLanguageRecognizer: ContextAwareSourceLanguageRecognizer()
        )
        let target = Locale.Language(identifier: "zh-Hans")
        controller.receiveSelection(
            PDFSelectionEvent(
                rawText: "interaction",
                pageIndex: 0,
                languageSample: "This paper studies interaction prototypes across multiple regions."
            ),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )

        controller.requestTranslation(targetLanguage: target)

        XCTAssertEqual(controller.configuration?.source?.minimalIdentifier, "en")
        XCTAssertEqual(controller.configuration?.target?.minimalIdentifier, "zh")
    }

    func testExplicitEnglishSourceBypassesIncorrectAutomaticRecognition() {
        let controller = TranslationController(
            sourceLanguageRecognizer: NorwegianSourceLanguageRecognizer()
        )
        let target = Locale.Language(identifier: "zh-Hans")
        controller.receiveSelection(
            PDFSelectionEvent(
                rawText: "decay normalization",
                pageIndex: 9,
                languageSample: "Interleaved two-column PDF text"
            ),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            targetLanguage: target
        )

        controller.requestTranslation(
            targetLanguage: target,
            sourceLanguage: Locale.Language(identifier: "en")
        )

        XCTAssertEqual(controller.configuration?.source?.minimalIdentifier, "en")
        XCTAssertEqual(controller.configuration?.target?.minimalIdentifier, "zh")
    }

    func testSettingsDefaultToEnglishSourceAndSimplifiedChineseTarget() {
        let suiteName = "TranslationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.sourceLanguageIdentifier, "en")
        XCTAssertEqual(settings.sourceLanguage?.minimalIdentifier, "en")
        XCTAssertEqual(settings.targetLanguage.minimalIdentifier, "zh")
    }

    func testSettingsCanPersistAutomaticSourceRecognition() {
        let suiteName = "TranslationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.sourceLanguageIdentifier = TranslationSourceLanguageOption.automaticID
        let restored = AppSettings(defaults: defaults)

        XCTAssertNil(restored.sourceLanguage)
        XCTAssertEqual(
            restored.sourceLanguageIdentifier,
            TranslationSourceLanguageOption.automaticID
        )
    }

    func testModelTranslationWaitsForOriginConsentAndSendsOnlyNormalizedSelection() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender, apiKey: "  secret-key  ")
        let preferences = try modelPreferences(originConfirmed: false)
        receiveModelSelection("  fixture   selection\nonly  ", controller: controller, preferences: preferences)

        controller.requestTranslation(preferences: preferences)

        XCTAssertEqual(sender.requestCount, 0)
        XCTAssertNotNil(controller.pendingOriginConsent)
        XCTAssertEqual(controller.state, .waiting)

        controller.confirmPendingOrigin()
        let request = try await waitForModelRequest(sender)

        XCTAssertEqual(request.endpoint, "http://127.0.0.1:8765/v1/chat/completions")
        XCTAssertEqual(request.model, "fixture-model")
        XCTAssertEqual(request.selectedText, "fixture selection only")
        XCTAssertEqual(request.apiKey, "secret-key")
        XCTAssertTrue(request.systemPrompt.contains("英语"))
        XCTAssertTrue(request.systemPrompt.contains("简体中文"))
        XCTAssertFalse(request.systemPrompt.contains("Paper"))
        XCTAssertEqual(request.maximumOutputTokens, 1_024)
        XCTAssertEqual(request.temperature, 0)
    }

    func testDecliningOriginConsentNeverStartsModelRequest() throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: false)
        receiveModelSelection("Private selection", controller: controller, preferences: preferences)

        controller.requestTranslation(preferences: preferences)
        controller.declinePendingOrigin()

        XCTAssertEqual(sender.requestCount, 0)
        XCTAssertNil(controller.pendingOriginConsent)
        XCTAssertEqual(controller.state, .failed("未授权向该服务发送选中文字。"))
    }

    func testModelTranslationOmitsOptimizationFieldsWhenDisabled() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = TranslationRequestPreferences(
            engine: .customModel,
            sourceLanguageIdentifier: "en",
            targetLanguageIdentifier: "zh-Hans",
            modelConfiguration: try validatedConfiguration(optimizesForTranslation: false),
            modelOriginIsConfirmed: true
        )
        receiveModelSelection("Selection", controller: controller, preferences: preferences)

        controller.requestTranslation(preferences: preferences)
        let request = try await waitForModelRequest(sender)

        XCTAssertNil(request.maximumOutputTokens)
        XCTAssertNil(request.temperature)
    }

    func testOversizedSelectionFailsBeforeKeychainOrXPC() async throws {
        let sender = RecordingModelRequestSender()
        let keyStore = RecordingTranslationAPIKeyStore(key: "unused")
        let controller = TranslationController(
            sourceLanguageRecognizer: FixedSourceLanguageRecognizer(),
            availabilityChecker: FixedTranslationAvailabilityChecker(readiness: .installed),
            keyStore: keyStore,
            modelRequestSender: sender
        )
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection(
            String(repeating: "x", count: ModelTranslationConfiguration.maximumSelectionCharacters + 1),
            controller: controller,
            preferences: preferences
        )

        controller.requestTranslation(preferences: preferences)
        await Task.yield()

        XCTAssertEqual(sender.requestCount, 0)
        let keychainReadCount = await keyStore.readCount
        XCTAssertEqual(keychainReadCount, 0)
        XCTAssertEqual(controller.state, .failed("选中文字超过 12,000 个字符，未发送翻译请求。"))
    }

    func testStreamingFailureKeepsPartialTextAndCompletedRetryIsCached() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection("Selection", controller: controller, preferences: preferences)

        controller.requestTranslation(preferences: preferences)
        let first = try await waitForModelRequest(sender)
        sender.emit(.init(requestID: first.requestID, kind: "delta", text: "部分译文"))
        sender.emit(.init(requestID: first.requestID, kind: "failed", message: "连接中断"))
        try await waitUntil { controller.state == .interrupted("连接中断") }

        XCTAssertEqual(controller.translatedText, "部分译文")
        XCTAssertNil(controller.configuration)
        XCTAssertEqual(sender.requestCount, 1)

        controller.requestTranslation(preferences: preferences)
        let second = try await waitForModelRequest(sender, count: 2)
        sender.emit(.init(requestID: second.requestID, kind: "delta", text: "完整"))
        sender.emit(.init(requestID: second.requestID, kind: "delta", text: "译文"))
        sender.emit(.init(requestID: second.requestID, kind: "completed"))
        try await waitUntil { controller.state == .success }

        XCTAssertEqual(controller.translatedText, "完整译文")

        controller.requestTranslation(preferences: preferences)

        XCTAssertEqual(controller.state, .success)
        XCTAssertEqual(controller.translatedText, "完整译文")
        XCTAssertEqual(sender.requestCount, 2)
    }

    func testStopKeepsPartialTextCancelsRequestAndIgnoresLateEvents() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection("Selection", controller: controller, preferences: preferences)
        controller.requestTranslation(preferences: preferences)
        let request = try await waitForModelRequest(sender)
        sender.emit(.init(requestID: request.requestID, kind: "delta", text: "已生成"))
        try await waitUntil { controller.state == .streaming }

        controller.stopTranslation()

        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(controller.translatedText, "已生成")
        XCTAssertEqual(sender.cancelledRequestIDs, [request.requestID])

        sender.emit(.init(requestID: request.requestID, kind: "delta", text: "迟到内容"))
        sender.emit(.init(requestID: request.requestID, kind: "completed"))
        await Task.yield()

        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(controller.translatedText, "已生成")
    }

    func testStopBeforeFirstDeltaIsAFailureWithoutPartialResult() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection("Selection", controller: controller, preferences: preferences)
        controller.requestTranslation(preferences: preferences)
        let request = try await waitForModelRequest(sender)

        controller.stopTranslation()

        XCTAssertEqual(controller.state, .failed("已停止翻译，尚未收到译文。"))
        XCTAssertNil(controller.translatedText)
        XCTAssertEqual(sender.cancelledRequestIDs, [request.requestID])
    }

    func testFailureDoesNotRetryOrFallbackUntilUserRequestsSystemTranslation() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection("Selection", controller: controller, preferences: preferences)
        controller.requestTranslation(preferences: preferences)
        let request = try await waitForModelRequest(sender)

        sender.emit(.init(requestID: request.requestID, kind: "failed", message: "服务不可用"))
        try await waitUntil { controller.state == .failed("服务不可用") }
        try await waitUntil { controller.systemFallbackAvailability == .available }

        XCTAssertEqual(sender.requestCount, 1)
        XCTAssertNil(controller.configuration)
        XCTAssertEqual(controller.resultSource, .customModel(model: "fixture-model"))

        controller.requestSystemTranslation(preferences: preferences)
        XCTAssertNotNil(controller.configuration)
        XCTAssertEqual(controller.resultSource, .apple)
        await controller.perform(using: FakeTranslationPerformer(output: "系统译文", delay: .zero))

        XCTAssertEqual(controller.state, .success)
        XCTAssertEqual(controller.translatedText, "系统译文")
        XCTAssertEqual(sender.requestCount, 1)
    }

    func testConfigurationChangeCancelsModelRequestAndRejectsItsLateResult() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection("Selection", controller: controller, preferences: preferences)
        controller.requestTranslation(preferences: preferences)
        let request = try await waitForModelRequest(sender)

        controller.translationPreferencesDidChange()
        sender.emit(.init(requestID: request.requestID, kind: "delta", text: "stale"))
        sender.emit(.init(requestID: request.requestID, kind: "completed"))
        await Task.yield()

        XCTAssertEqual(sender.cancelledRequestIDs, [request.requestID])
        XCTAssertEqual(controller.state, .waiting)
        XCTAssertNil(controller.translatedText)
        XCTAssertNil(controller.resultSource)
    }

    func testSwitchingPaperCancelsModelRequestAndClearsOldSelection() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        let firstPaperID = UUID()
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Selection", pageIndex: 0),
            paperID: firstPaperID,
            paperName: "First Paper",
            automaticTranslation: false,
            preferences: preferences
        )
        controller.requestTranslation(preferences: preferences)
        let request = try await waitForModelRequest(sender)

        controller.activePaperDidChange(to: UUID())
        sender.emit(.init(requestID: request.requestID, kind: "delta", text: "stale"))
        await Task.yield()

        XCTAssertEqual(sender.cancelledRequestIDs, [request.requestID])
        XCTAssertNil(controller.selection)
        XCTAssertNil(controller.translatedText)
        XCTAssertEqual(controller.state, .idle)
    }

    func testCustomModelCacheKeyExcludesStreamingButIncludesPromptAndEndpoint() throws {
        let streaming = try validatedConfiguration(streamsResponse: true)
        let nonStreaming = try validatedConfiguration(streamsResponse: false)
        let differentPrompt = try validatedConfiguration(
            streamsResponse: true,
            prompt: "Different {source_language} to {target_language} prompt"
        )
        let differentEndpoint = try ModelTranslationConfigurationValidator.validate(
            baseURL: "http://127.0.0.1:8766/v1",
            model: "fixture-model",
            streamsResponse: true,
            prompt: ModelTranslationConfiguration.defaultPrompt
        )
        let key = TranslationCacheKey.customModel(
            text: "Selection",
            sourceIdentifier: "en",
            targetIdentifier: "zh-Hans",
            configuration: streaming
        )

        XCTAssertEqual(
            key,
            .customModel(
                text: "Selection",
                sourceIdentifier: "en",
                targetIdentifier: "zh-Hans",
                configuration: nonStreaming
            )
        )
        XCTAssertNotEqual(
            key,
            .customModel(
                text: "Selection",
                sourceIdentifier: "en",
                targetIdentifier: "zh-Hans",
                configuration: differentPrompt
            )
        )
        XCTAssertNotEqual(
            key,
            .customModel(
                text: "Selection",
                sourceIdentifier: "en",
                targetIdentifier: "zh-Hans",
                configuration: differentEndpoint
            )
        )
    }

    func testKeychainReadFailureNeverStartsXPCRequest() async throws {
        let sender = RecordingModelRequestSender()
        let controller = TranslationController(
            sourceLanguageRecognizer: FixedSourceLanguageRecognizer(),
            availabilityChecker: FixedTranslationAvailabilityChecker(readiness: .installed),
            keyStore: FailingTranslationAPIKeyStore(),
            modelRequestSender: sender
        )
        let preferences = try modelPreferences(originConfirmed: true)
        receiveModelSelection("Selection", controller: controller, preferences: preferences)

        controller.requestTranslation(preferences: preferences)
        try await waitUntil { controller.state == .failed("无法读取 API Key。") }

        XCTAssertEqual(sender.requestCount, 0)
        XCTAssertNil(controller.translatedText)
    }

    func testMissingModelConfigurationUsesGenericSourceAndNoRequest() {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = TranslationRequestPreferences(
            engine: .customModel,
            sourceLanguageIdentifier: "en",
            targetLanguageIdentifier: "zh-Hans",
            modelConfiguration: nil,
            modelOriginIsConfirmed: false
        )
        receiveModelSelection("Selection", controller: controller, preferences: preferences)

        controller.requestTranslation(preferences: preferences)

        XCTAssertEqual(controller.resultSource, .customModel(model: nil))
        XCTAssertEqual(controller.resultSource?.label, "自定义大模型")
        XCTAssertEqual(controller.state, .failed("自定义大模型配置不完整，请先在设置中保存有效配置。"))
        XCTAssertEqual(sender.requestCount, 0)
    }

    func testAutomaticModelTranslationUsesCapturedPreferences() async throws {
        let sender = RecordingModelRequestSender()
        let controller = makeModelController(sender: sender)
        let preferences = try modelPreferences(originConfirmed: true)
        controller.isInspectorPresented = false

        controller.receiveSelection(
            PDFSelectionEvent(rawText: "Automatic selection", pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: true,
            preferences: preferences
        )

        let request = try await waitForModelRequest(sender)
        XCTAssertEqual(request.selectedText, "Automatic selection")
        XCTAssertEqual(request.model, "fixture-model")
        XCTAssertFalse(controller.isInspectorPresented)
    }

    private func makeController() -> TranslationController {
        TranslationController(sourceLanguageRecognizer: FixedSourceLanguageRecognizer())
    }

    private func makeModelController(
        sender: RecordingModelRequestSender,
        apiKey: String? = nil
    ) -> TranslationController {
        TranslationController(
            sourceLanguageRecognizer: FixedSourceLanguageRecognizer(),
            availabilityChecker: FixedTranslationAvailabilityChecker(readiness: .installed),
            keyStore: RecordingTranslationAPIKeyStore(key: apiKey),
            modelRequestSender: sender
        )
    }

    private func modelPreferences(originConfirmed: Bool) throws -> TranslationRequestPreferences {
        TranslationRequestPreferences(
            engine: .customModel,
            sourceLanguageIdentifier: "en",
            targetLanguageIdentifier: "zh-Hans",
            modelConfiguration: try validatedConfiguration(),
            modelOriginIsConfirmed: originConfirmed
        )
    }

    private func validatedConfiguration(
        streamsResponse: Bool = true,
        optimizesForTranslation: Bool = true,
        prompt: String = ModelTranslationConfiguration.defaultPrompt
    ) throws -> ValidatedModelTranslationConfiguration {
        try ModelTranslationConfigurationValidator.validate(
            baseURL: "http://127.0.0.1:8765/v1",
            model: "fixture-model",
            streamsResponse: streamsResponse,
            optimizesForTranslation: optimizesForTranslation,
            prompt: prompt
        )
    }

    private func receiveModelSelection(
        _ text: String,
        controller: TranslationController,
        preferences: TranslationRequestPreferences
    ) {
        controller.receiveSelection(
            PDFSelectionEvent(rawText: text, pageIndex: 0),
            paperID: UUID(),
            paperName: "Paper",
            automaticTranslation: false,
            preferences: preferences
        )
    }

    private func waitForModelRequest(
        _ sender: RecordingModelRequestSender,
        count: Int = 1
    ) async throws -> TranslationXPCRequest {
        try await waitUntil { sender.requestCount >= count }
        return try XCTUnwrap(sender.requests.last)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for asynchronous translation state")
    }
}

private struct FixedSourceLanguageRecognizer: SourceLanguageRecognizing {
    func language(for text: String) -> Locale.Language? {
        Locale.Language(identifier: "en")
    }
}

private struct ContextAwareSourceLanguageRecognizer: SourceLanguageRecognizing {
    func language(for text: String) -> Locale.Language? {
        guard text.count >= 20 else { return nil }
        return Locale.Language(identifier: "en")
    }
}

private struct NorwegianSourceLanguageRecognizer: SourceLanguageRecognizing {
    func language(for text: String) -> Locale.Language? {
        Locale.Language(identifier: "nb")
    }
}

private final class FakeTranslationPerformer: TranslationPerforming, @unchecked Sendable {
    let output: String
    let delay: Duration

    init(output: String, delay: Duration) {
        self.output = output
        self.delay = delay
    }

    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        .installed
    }

    func translate(_ text: String) async throws -> TranslationOutput {
        await Task.detached { [delay] in
            try? await Task.sleep(for: delay)
        }.value
        return TranslationOutput(targetText: output)
    }
}

private actor RecordingTranslationPerformer: TranslationPerforming {
    private(set) var calls: [String] = []

    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        calls.append("readiness")
        return .downloadable
    }

    func prepare() async throws {
        calls.append("prepare")
    }

    func translate(_ text: String) async throws -> TranslationOutput {
        calls.append("translate")
        return TranslationOutput(targetText: "译文")
    }
}

private final class HangingTranslationPerformer: TranslationPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCancelCount = 0

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        .installed
    }

    func translate(_ text: String) async throws -> TranslationOutput {
        try await Task.sleep(for: .seconds(60))
        return TranslationOutput(targetText: "late")
    }

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
    }
}

private struct FixedTranslationAvailabilityChecker: TranslationAvailabilityChecking {
    let readiness: TranslationReadiness

    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        readiness
    }
}

private actor RecordingTranslationAPIKeyStore: TranslationAPIKeyStoring {
    let key: String?
    private(set) var readCount = 0

    init(key: String?) {
        self.key = key
    }

    func read() async throws -> String? {
        readCount += 1
        return key
    }

    func save(_ apiKey: String) async throws {}
    func delete() async throws {}
}

private struct FailingTranslationAPIKeyStore: TranslationAPIKeyStoring {
    func read() async throws -> String? {
        throw FailingTranslationAPIKeyStoreError.unavailable
    }

    func save(_ apiKey: String) async throws {}
    func delete() async throws {}
}

private enum FailingTranslationAPIKeyStoreError: LocalizedError {
    case unavailable

    var errorDescription: String? { "无法读取 API Key。" }
}

private final class RecordingModelRequestSender: TranslationRequestSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [TranslationXPCRequest] = []
    private var handlers: [String: @Sendable (TranslationXPCEvent) -> Void] = [:]
    private var storedCancelledRequestIDs: [String] = []

    var requests: [TranslationXPCRequest] {
        lock.withLock { storedRequests }
    }

    var requestCount: Int {
        lock.withLock { storedRequests.count }
    }

    var cancelledRequestIDs: [String] {
        lock.withLock { storedCancelledRequestIDs }
    }

    func start(
        _ request: TranslationXPCRequest,
        eventHandler: @escaping @Sendable (TranslationXPCEvent) -> Void
    ) throws {
        lock.withLock {
            storedRequests.append(request)
            handlers[request.requestID] = eventHandler
        }
    }

    func cancel(requestID: String) {
        lock.withLock {
            storedCancelledRequestIDs.append(requestID)
        }
    }

    func emit(_ event: TranslationXPCEvent) {
        let handler = lock.withLock { handlers[event.requestID] }
        handler?(event)
    }
}
