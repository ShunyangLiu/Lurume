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
        .frame(width: 460, height: 240)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
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
