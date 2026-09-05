import AppKit
import SwiftUI
import XCTest
@testable import Lurume

@MainActor
final class TranslationSettingsViewTests: XCTestCase {
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
