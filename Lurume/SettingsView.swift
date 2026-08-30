import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            TranslationSettingsView()
                .tabItem {
                    Label("翻译", systemImage: "translate")
                }
        }
        .frame(width: 460, height: 300)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updaterController: UpdaterController

    var body: some View {
        Form {
            Section("软件更新") {
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { updaterController.automaticallyChecksForUpdates },
                        set: { updaterController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .accessibilityValue(
                    updaterController.automaticallyChecksForUpdates ? "已开启" : "已关闭"
                )

                Text("开启后每 24 小时检查一次。发现新版本时会询问，不会自动下载或安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文献库") {
                Picker("启动时排序", selection: $settings.defaultLibrarySortOption) {
                    ForEach(LibrarySortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Text("下次启动 Lurume 时使用。侧栏排序只影响当前运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranslationSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("翻译") {
                Toggle("自动翻译选中文字", isOn: $settings.automaticTranslation)
                Picker("原文语言", selection: $settings.sourceLanguageIdentifier) {
                    ForEach(TranslationSourceLanguageOption.common) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                Picker("目标语言", selection: $settings.targetLanguageIdentifier) {
                    ForEach(TranslationLanguageOption.common) { language in
                        Text(language.name).tag(language.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
