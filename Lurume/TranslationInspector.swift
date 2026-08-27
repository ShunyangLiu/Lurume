import AppKit
import SwiftUI

/// 译文优先的翻译检查器：原文默认完全隐藏，文献与页码在顶部标识来源。
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
                    VStack(alignment: .leading, spacing: 14) {
                        sourceMetadata(for: selection)
                        HStack {
                            statusLabel
                            Spacer()
                            translateAgainButton
                        }
                        translationBody
                    }
                    .padding()
                }

                Divider()
                actionBar(for: selection)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 280, idealWidth: 340)
    }

    private func sourceMetadata(for selection: TranslationSelection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selection.paperName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("第 \(selection.pageIndex + 1) 页")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var translationBody: some View {
        if let translatedText = controller.translatedText {
            Text(translatedText)
                .textSelection(.enabled)
        } else if case let .failed(message) = controller.state {
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var translateAgainButton: some View {
        Group {
            if controller.state != .translating && controller.state != .resourcesNeeded {
                Button("翻译") {
                    controller.requestTranslation(
                        targetLanguage: settings.targetLanguage
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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

    /// 原文不再展示，但复制能力常驻。
    private func actionBar(for selection: TranslationSelection) -> some View {
        HStack {
            Button("复制译文") {
                if let translatedText = controller.translatedText {
                    copy(translatedText)
                }
            }
            .disabled(controller.translatedText == nil)

            Button("复制原文") {
                copy(selection.rawText)
            }

            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "translate")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("划词后，译文会显示在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
