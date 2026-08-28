import SwiftUI

@main
struct LurumeApp: App {
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var appSettings = AppSettings()
    @StateObject private var translationController = TranslationController()
    @StateObject private var highlightStore = HighlightStore()

    var body: some Scene {
        Window("Lurume", id: "main") {
            ContentView()
                .environmentObject(libraryStore)
                .environmentObject(appSettings)
                .environmentObject(translationController)
                .environmentObject(highlightStore)
                .onDisappear {
                    libraryStore.flushPendingSave()
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandMenu("翻译") {
                Button("翻译当前选区") {
                    translationController.requestTranslation(
                        targetLanguage: appSettings.targetLanguage,
                        sourceLanguage: appSettings.sourceLanguage
                    )
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(translationController.selection == nil)
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(appSettings)
        }
    }
}
