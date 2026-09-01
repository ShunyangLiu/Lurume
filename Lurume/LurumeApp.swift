import SwiftUI

@main
struct LurumeApp: App {
    @StateObject private var updaterController = UpdaterController()
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
                .environmentObject(updaterController)
                .onDisappear {
                    libraryStore.flushPendingSave()
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入 PDF…") {
                    NotificationCenter.default.post(name: .lurumeImportPDF, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("导入文件夹…") {
                    NotificationCenter.default.post(name: .lurumeImportFolder, object: nil)
                }
                Button("从 Zotero 迁移…") {
                    NotificationCenter.default.post(name: .lurumeImportZotero, object: nil)
                }
                Divider()
            }

            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updaterController.checkForUpdates()
                }
                .disabled(!updaterController.canCheckForUpdates)
            }

            CommandMenu("翻译") {
                Button("翻译当前选区") {
                    translationController.requestTranslation(
                        preferences: appSettings.translationRequestPreferences
                    )
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(translationController.selection == nil)
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(appSettings)
                .environmentObject(updaterController)
        }
    }
}
