import AppKit
import SwiftUI
import XCTest
import Translation
@testable import Lurume

@MainActor
final class TranslationSettingsViewTests: XCTestCase {
    func testSwitchingTranslationModesRecreatesSystemSession() async throws {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        let parent = TranslationController()
        let controller = try XCTUnwrap(parent.comparisonController)
        let preferences = TranslationRequestPreferences.apple(targetLanguage: target, sourceLanguage: source)
        func content(for activeController: TranslationController) -> some View {
            Text("System translation session fixture")
                .frame(width: 500, height: 300)
                .modifier(ReaderSystemTranslationModifier(
                    controller: activeController,
                    makePerformer: { _ in SessionActivationFixturePerformer() }
                ))
        }
        let view = NSHostingView(rootView: content(for: parent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer {
            parent.clear()
            window.orderOut(nil)
            window.contentView = nil
        }
        view.layoutSubtreeIfNeeded()
        parent.receiveSelection(PDFSelectionEvent(rawText: "First selection", pageIndex: 0),
                                paperID: UUID(), paperName: "System session fixture",
                                automaticTranslation: false, preferences: preferences)
        parent.requestTranslation(preferences: preferences)
        for _ in 0..<200 {
            if parent.state == .success { break }
            if case .failed = parent.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(parent.state, .success)
        parent.translationPreferencesDidChange()
        controller.receiveSelection(PDFSelectionEvent(rawText: "Comparison selection", pageIndex: 0),
                                    paperID: UUID(), paperName: "System session fixture",
                                    automaticTranslation: false, preferences: preferences)
        view.rootView = content(for: controller)
        view.layoutSubtreeIfNeeded()
        controller.requestTranslation(preferences: preferences)
        for _ in 0..<400 {
            if controller.state == .success { break }
            if case .failed = controller.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(controller.state, .success)
        XCTAssertFalse(controller.translatedText?.isEmpty ?? true)
        let bothPreferences = TranslationRequestPreferences(
            engine: .both, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
            modelConfiguration: nil, modelOriginIsConfirmed: false)
        for index in 0..<3 {
            parent.receiveSelection(PDFSelectionEvent(rawText: "Consecutive selection \(index)", pageIndex: 0),
                                    paperID: UUID(), paperName: "System session fixture",
                                    automaticTranslation: false, preferences: bothPreferences)
            parent.requestTranslation(preferences: bothPreferences)
            for _ in 0..<200 {
                if controller.state == .success { break }
                if case .failed = controller.state { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(controller.state, .success, "Consecutive selection \(index)")
            if controller.state != .success { break }
        }
        parent.translationPreferencesDidChange()
        parent.receiveSelection(PDFSelectionEvent(rawText: "Return to system translation", pageIndex: 0),
                                paperID: UUID(), paperName: "System session fixture",
                                automaticTranslation: false, preferences: preferences)
        view.rootView = content(for: parent)
        view.layoutSubtreeIfNeeded()
        parent.requestTranslation(preferences: preferences)
        for _ in 0..<200 {
            if parent.state == .success { break }
            if case .failed = parent.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(parent.state, .success)
    }

    func testReaderControlsRemainVisibleAtNarrowWidths() async throws {
        let controller = PDFReaderController()
        for width in [180.0, 410.0] {
            let view = NSHostingView(rootView: PDFToolbar(controller: controller).frame(width: width))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = view
            defer { window.contentView = nil }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let size = view.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1)
            if width == 180 {
                XCTAssertGreaterThan(size.height, 60, "Narrow readers should use two rows")
            } else {
                XCTAssertLessThan(size.height, 50, "Normal readers should use one row")
            }
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Reader controls at \(Int(width)) points"
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lurume-reader-controls-\(Int(width)).png")
            try data.write(to: url)
            print("UI_FIXTURE_SNAPSHOT: \(url.path)")
        }
    }

    func testSettingsFormRendersWithAnIsolatedProviderFixture() async throws {
        let suite = "TranslationSettingsViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = ModelTranslationSettingsController(keyStore: EmptySettingsViewKeyStore())
        await controller.load(from: settings)
        controller.draftEngine = .customModel
        controller.selectProvider(.anthropic)
        await controller.waitForAPIKeyLoad()
        let view = NSHostingView(rootView: TranslationSettingsView(modelSettings: controller).environmentObject(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = view
        defer { window.contentView = nil }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 680)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(imageData.count, 10_000)
        let attachment = XCTAttachment(data: imageData, uniformTypeIdentifier: "public.png")
        attachment.name = "Translation settings — isolated Claude fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lurume-translation-settings-fixture.png")
        try imageData.write(to: url)
        print("UI_FIXTURE_SNAPSHOT: \(url.path)")
    }
}

private struct EmptySettingsViewKeyStore: TranslationAPIKeyStoring {
    func read() async throws -> String? { nil }
    func save(_ apiKey: String) async throws {}
    func delete() async throws {}
}

/// The real SwiftUI translationTask must activate first; only the subsequent
/// translation is stubbed so this test neither downloads languages nor uses a network service.
private final class SessionActivationFixturePerformer: TranslationPerforming, Sendable {
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        .installed
    }
    func translate(_ text: String) async throws -> TranslationOutput {
        TranslationOutput(targetText: "会话已启动")
    }
}
