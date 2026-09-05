import AppKit
import SwiftUI

enum ReaderInspectorMode: String, CaseIterable, Identifiable {
    case translation
    case highlights

    var id: Self { self }

    var label: String {
        switch self {
        case .translation: "翻译"
        case .highlights: "高亮"
        }
    }
}

/// 译文优先的翻译检查器：原文默认完全隐藏，文献与页码在顶部标识来源。
struct TranslationInspector: View {
    @ObservedObject var controller: TranslationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var highlightStore: HighlightStore
    @ObservedObject var pdfController: PDFReaderController
    @Binding var mode: ReaderInspectorMode
    let paper: PaperRecord?
    let navigateToHighlight: (HighlightRecord) -> Void
    let deleteHighlight: (UUID) -> Void

    private var paperHighlights: [HighlightRecord] {
        guard let paper else { return [] }
        return highlightStore.highlights(for: paper.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("检查器内容", selection: $mode) {
                    ForEach(ReaderInspectorMode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("检查器内容")

                Menu {
                    switch mode {
                    case .translation:
                        Button {
                            controller.clear()
                        } label: {
                            Label("清空翻译", systemImage: "xmark.circle")
                        }
                            .disabled(controller.selection == nil)
                    case .highlights:
                        Button(role: .destructive) {
                            guard let id = pdfController.currentHighlightID else { return }
                            deleteHighlight(id)
                        } label: {
                            Label("删除所选高亮", systemImage: "trash")
                        }
                        .disabled(
                            pdfController.currentHighlightID == nil
                                || highlightStore.persistenceDisabled
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(mode == .translation ? "更多翻译操作" : "更多高亮操作")
                .accessibilityLabel(mode == .translation ? "更多翻译操作" : "更多高亮操作")
            }
            .padding()

            Divider()

            switch mode {
            case .translation:
                translationContent
            case .highlights:
                highlightsContent
            }
        }
        .frame(minWidth: 280, idealWidth: 340)
    }

    @ViewBuilder
    private var translationContent: some View {
        Group {
            if let selection = controller.selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sourceMetadata(for: selection)
                        HStack {
                            statusLabel
                            Spacer()
                            primaryTranslationAction
                        }
                        if let source = controller.resultSource {
                            Text(source.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("译文来源：\(source.label)")
                        }
                        translationBody
                        recoveryActions
                    }
                    .padding()
                }

                Divider()
                actionBar(for: selection)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var highlightsContent: some View {
        if highlightStore.persistenceDisabled || pdfController.skippedHighlightFragmentCount > 0 {
            VStack(spacing: 0) {
                if highlightStore.persistenceDisabled {
                    Label(
                        "高亮处于只读状态",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                if pdfController.skippedHighlightFragmentCount > 0 {
                    Label(
                        "当前 PDF 中有 \(pdfController.skippedHighlightFragmentCount) 个高亮片段无法安全显示。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                Divider()
                highlightListOrEmpty
            }
        } else {
            highlightListOrEmpty
        }
    }

    @ViewBuilder
    private var highlightListOrEmpty: some View {
        if paper == nil {
            highlightEmptyState(
                title: "尚未选择论文",
                description: "选择一篇论文后，这里会显示它的高亮。"
            )
        } else if paperHighlights.isEmpty {
            highlightEmptyState(
                title: "这篇论文还没有高亮",
                description: "选择 PDF 文字后按 ⌃⌘H 添加黄色高亮。"
            )
        } else {
            List(selection: $pdfController.currentHighlightID) {
                ForEach(paperHighlights) { highlight in
                    HighlightRow(highlight: highlight)
                        .tag(highlight.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            pdfController.currentHighlightID = highlight.id
                            navigateToHighlight(highlight)
                        }
                        .contextMenu {
                            Button("删除高亮", role: .destructive) {
                                deleteHighlight(highlight.id)
                            }
                            .disabled(highlightStore.persistenceDisabled)
                        }
                }
            }
            .onDeleteCommand {
                guard let id = pdfController.currentHighlightID else { return }
                deleteHighlight(id)
            }
        }
    }

    private func highlightEmptyState(title: String, description: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "highlighter")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(translatedText)
                    .textSelection(.enabled)
                switch controller.state {
                case .stopped:
                    Label("生成已停止，内容可能不完整。", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                case let .interrupted(message):
                    Label("响应中断，内容可能不完整。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                default:
                    EmptyView()
                }
            }
        } else if case let .failed(message) = controller.state {
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var primaryTranslationAction: some View {
        if controller.isTranslationActive {
            Button("停止") {
                controller.stopTranslation()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("停止当前翻译请求；大模型翻译会保留已经生成的部分译文")
        } else if !controller.canRetryModelTranslation {
            if controller.state != .translating
                && controller.state != .streaming
                && controller.state != .resourcesNeeded {
                Button("翻译") {
                    controller.requestTranslation(
                        preferences: settings.translationRequestPreferences
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if controller.canRetryModelTranslation {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("重试") {
                        controller.requestTranslation(
                            preferences: settings.translationRequestPreferences
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button("使用系统翻译") {
                        controller.requestSystemTranslation(
                            preferences: settings.translationRequestPreferences
                        )
                    }
                    .disabled(controller.systemFallbackAvailability != .available)
                }
                .controlSize(.small)

                switch controller.systemFallbackAvailability {
                case .checking:
                    Text("正在检查系统语言支持…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case let .unavailable(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 7) {
            if controller.state == .connecting
                || controller.state == .translating
                || controller.state == .streaming
                || controller.state == .resourcesNeeded {
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

private struct HighlightRow: View {
    let highlight: HighlightRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(highlight.pageLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if highlight.hasNote {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(highlight.previewText)
                .font(.body)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(highlight.pageLabel)，\(highlight.previewText)\(highlight.hasNote ? "，包含笔记" : "")"
        )
    }
}
