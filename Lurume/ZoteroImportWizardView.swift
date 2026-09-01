import SwiftUI

struct ZoteroImportWizardView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var coordinator: ZoteroImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            switch coordinator.phase {
            case .idle:
                EmptyView()
            case .connecting:
                progressView(title: "正在连接 Zotero…", detail: "只读取本机 Local API 的书目与附件索引。")
            case .selecting:
                selectionView
            case .scanning:
                progressView(
                    title: "正在读取迁移预览…",
                    detail: "已读取 \(coordinator.scannedItemCount) 条 Zotero 项目；尚未打开或复制 PDF。"
                )
            case .preview:
                previewView
            case .failed:
                failedView
            case .cancelled:
                cancelledView
            }
        }
        .padding(20)
        .frame(width: 800, height: 680)
        .interactiveDismissDisabled(coordinator.isBusy)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("从 Zotero 迁移")
                    .font(.title2.weight(.semibold))
                Text("通过本机只读 Local API 建立预览；Zotero 文库不会被修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !coordinator.isBusy {
                Button("关闭") { coordinator.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func progressView(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("停止", role: .cancel) { coordinator.cancel() }
            }
        }
    }

    private var selectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Zotero 文库", selection: Binding(
                get: { coordinator.selectedLibraryID ?? "" },
                set: { coordinator.selectLibrary(stableID: $0) }
            )) {
                ForEach(coordinator.libraries) { library in
                    Text(library.name).tag(library.stableID)
                }
            }
            .frame(maxWidth: 480)

            Toggle("迁移整个文库", isOn: Binding(
                get: { coordinator.importsWholeLibrary },
                set: { coordinator.setImportsWholeLibrary($0) }
            ))

            Text(
                coordinator.importsWholeLibrary
                    ? "将检查这个文库中的全部项目和 PDF 附件。"
                    : "选择一个或多个文献集；选择父级会包含其全部子文献集。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            List(orderedCollections, id: \.collection.key) { row in
                HStack(spacing: 8) {
                    Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                    Toggle(row.collection.name, isOn: Binding(
                        get: { coordinator.selectedCollectionKeys.contains(row.collection.key) },
                        set: { coordinator.setCollectionSelected($0, key: row.collection.key) }
                    ))
                    .disabled(coordinator.importsWholeLibrary)
                }
            }
            .overlay {
                if coordinator.collections.isEmpty {
                    ContentUnavailableView("没有 Zotero 文献集", systemImage: "folder")
                }
            }

            Text("本步骤不请求磁盘目录权限，也不会读取 PDF 字节。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("取消", role: .cancel) { coordinator.dismiss() }
                Spacer()
                Button("生成预览") { coordinator.scanSelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canScanSelection)
            }
        }
    }

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = coordinator.preview {
                HStack(spacing: 22) {
                    summary("可迁移 PDF", preview.pdfAttachmentCount)
                    summary("文献集", preview.plannedCollectionCount)
                    summary("无 PDF 条目", preview.parentItemsWithoutPDFCount)
                    summary("附件不可用", preview.unavailableAttachmentCount)
                    summary("不支持附件", preview.unsupportedAttachmentCount)
                }
                Text("来源：\(preview.library.name) · 共读取 \(preview.scannedItemCount) 条 Zotero 项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preview.nonPDFAttachmentCount > 0
                    || preview.unsupportedItemCount > 0
                    || preview.ignoredTagCount > 0
                    || preview.ignoredRelationCount > 0 {
                    Text(
                        "未迁移：非 PDF 附件 \(preview.nonPDFAttachmentCount)，"
                            + "便笺/批注 \(preview.unsupportedItemCount)，"
                            + "标签 \(preview.ignoredTagCount)，关系 \(preview.ignoredRelationCount)。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                List(preview.rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .lineLimit(1)
                            Text(row.fileName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !row.collectionNames.isEmpty {
                                Text(row.collectionNames.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(dispositionTitle(row.disposition))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if preview.rows.isEmpty {
                        ContentUnavailableView("没有可迁移的 PDF", systemImage: "doc.badge.ellipsis")
                    }
                }
                Text("这是只读预览。正式迁移将在下一阶段明确请求 Zotero 来源目录和 Lurume 目标目录权限，然后执行复制；此处不会写入文献库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("返回选择") { coordinator.backToSelection() }
                    Spacer()
                    Button("完成预览") { coordinator.dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func summary(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("无法建立 Zotero 迁移预览", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(coordinator.failureMessage ?? "发生未知错误。")
                .textSelection(.enabled)
            Text("Zotero 文库、PDF 和 Lurume 文献库均未被修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("关闭") { coordinator.dismiss() }
                Spacer()
                Button("重试") { coordinator.begin(existingPapers: libraryStore.papers) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var cancelledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已停止 Zotero 迁移预览", systemImage: "stop.circle")
                .font(.headline)
            Text("没有发布记录，也没有读取或复制 PDF。")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("关闭") { coordinator.dismiss() }
                Spacer()
                Button("重新开始") { coordinator.begin(existingPapers: libraryStore.papers) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var orderedCollections: [(collection: ZoteroServiceCollection, depth: Int)] {
        let children = Dictionary(grouping: coordinator.collections, by: \.parentCollection)
        var result: [(ZoteroServiceCollection, Int)] = []
        func append(parent: String?, depth: Int) {
            for collection in (children[parent] ?? []).sorted(by: {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }) {
                result.append((collection, depth))
                append(parent: collection.key, depth: depth + 1)
            }
        }
        append(parent: nil, depth: 0)
        return result
    }

    private func dispositionTitle(_ disposition: ImportDisposition) -> String {
        switch disposition {
        case .create: "新增"
        case .reuse(_, .source): "按来源复用"
        case .reuse(_, .fileIdentity): "按文件复用"
        case .reuse(_, .contentSHA256): "按内容复用"
        case .sourceContentChanged: "来源内容变化"
        }
    }
}
