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
        XCTAssertEqual(recordedCalls, ["readiness", "translate"])
        XCTAssertEqual(controller.translatedText, "译文")
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

    private func makeController() -> TranslationController {
        TranslationController(sourceLanguageRecognizer: FixedSourceLanguageRecognizer())
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

    func translate(_ text: String) async throws -> TranslationOutput {
        calls.append("translate")
        return TranslationOutput(targetText: "译文")
    }
}
