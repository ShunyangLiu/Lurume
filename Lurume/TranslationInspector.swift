import AppKit
import SwiftUI

struct TranslationInspector: View {
    @ObservedObject var controller: TranslationController
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("翻译")
                    .font(.headline)
                Spacer()
                Menu {
                    Toggle("自动翻译选中文字", isOn: $settings.automaticTranslation)
                    Button("清空", action: controller.clear)
                        .disabled(controller.selection == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding()

            Divider()

            if let selection = controller.selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        metadata(for: selection)
                        textSection(
                            title: "原文",
                            text: selection.rawText,
                            copyLabel: "复制原文"
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                statusLabel
                                Spacer()
                                if controller.state != .translating
                                    && controller.state != .resourcesNeeded {
                                    Button("翻译") {
                                        controller.requestTranslation(
                                            targetLanguage: settings.targetLanguage
                                        )
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }

                            if let translatedText = controller.translatedText {
                                Text(translatedText)
                                    .textSelection(.enabled)
                                Button("复制译文") {
                                    copy(translatedText)
                                }
                            } else if case let .failed(message) = controller.state {
                                Text(message)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "尚无翻译",
                    systemImage: "translate",
                    description: Text("在 PDF 中选择文字后，译文会显示在这里。")
                )
            }
        }
        .frame(minWidth: 280, idealWidth: 340)
    }

    private func metadata(for selection: TranslationSelection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(selection.paperName)
                .font(.subheadline.weight(.medium))
            Text("第 \(selection.pageIndex + 1) 页")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func textSection(title: String, text: String, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
            Button(copyLabel) {
                copy(text)
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 7) {
            if controller.state == .translating || controller.state == .resourcesNeeded {
                ProgressView()
                    .controlSize(.small)
            }
            Text(controller.state.label)
                .font(.subheadline.weight(.medium))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct TranslationSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("翻译") {
                Toggle("自动翻译选中文字", isOn: $settings.automaticTranslation)
                Picker("目标语言", selection: $settings.targetLanguageIdentifier) {
                    ForEach(TranslationLanguageOption.common) { language in
                        Text(language.name).tag(language.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
        .navigationTitle("翻译")
    }
}
