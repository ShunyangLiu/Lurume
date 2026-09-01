import AppKit
import SwiftUI

struct ZoteroImportWizardView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var coordinator: ZoteroImportCoordinator
    let undoManager: UndoManager?

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
            case .preparingFiles:
                preparingFilesView
            case .ready:
                readyView
            case .copying:
                copyingView
            case .completed:
                completedView
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
                authorizationControls
                Text("API 返回的文件地址不会自动获得信任；只有位于你明确授权来源根内的普通 PDF 才能进入复制计划。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("返回选择") { coordinator.backToSelection() }
                    Spacer()
                    Button("生成最终迁移计划") { coordinator.prepareCopyPreview() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!coordinator.canPrepareCopyPreview)
                }
            }
        }
    }

    private var authorizationControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(
                    coordinator.sourceDirectoryNames.isEmpty ? "选择 Zotero 数据目录…" : "添加外部附件目录…",
                    action: selectSourceDirectory
                )
                if coordinator.sourceDirectoryNames.isEmpty {
                    Text("尚未授权来源")
                        .foregroundStyle(.secondary)
                } else {
                    Text(coordinator.sourceDirectoryNames.joined(separator: "、"))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("选择 Lurume 目标目录…", action: selectTargetDirectory)
                Text(coordinator.targetDirectoryName ?? "尚未选择目标")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if coordinator.unauthorizedAttachmentCount > 0, !coordinator.sourceDirectoryNames.isEmpty {
                Text("仍有 \(coordinator.unauthorizedAttachmentCount) 个附件不在已授权根内；继续时会跳过，可添加其共同祖先目录。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private func selectSourceDirectory() {
        selectDirectory(
            title: "选择 Zotero 数据目录",
            prompt: "授权来源",
            canCreateDirectories: false
        ) { coordinator.addSourceDirectory($0) }
    }

    private func selectTargetDirectory() {
        selectDirectory(
            title: "选择 Lurume 目标目录",
            prompt: "选择目标",
            canCreateDirectories: true
        ) { coordinator.selectTargetDirectory($0) }
    }

    private func selectDirectory(
        title: String,
        prompt: String,
        canCreateDirectories: Bool,
        completion: @escaping (URL) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = title
            panel.prompt = prompt
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = canCreateDirectories
            panel.resolvesAliases = true

            guard panel.runModal() == .OK, let url = panel.urls.first else { return }
            completion(url)
        }
    }

    private var preparingFilesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(
                value: Double(coordinator.fileProgressCount),
                total: Double(max(1, coordinator.fileProgressTotal))
            )
            Text("正在验证授权边界并计算源 PDF 哈希…")
                .font(.headline)
            Text("\(coordinator.fileProgressCount)/\(coordinator.fileProgressTotal)；尚未创建目标文件或修改文献库。")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("停止", role: .cancel) { coordinator.cancel() }
            }
        }
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = coordinator.copyPreview {
                HStack(spacing: 20) {
                    summary("将处理", preview.includedPaperCount)
                    summary("复制", preview.copiedPaperCount)
                    summary("复用", preview.reusedPaperCount)
                    summary("版本冲突", preview.keptVersionConflictCount)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ByteCountFormatter.string(
                            fromByteCount: preview.copiedByteCount,
                            countStyle: .file
                        ))
                        .font(.headline.monospacedDigit())
                        Text("预计复制")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("导入根文献集位置", selection: Binding<UUID?>(
                    get: { preview.targetParentID },
                    set: { coordinator.setCopyTargetParentID($0) }
                )) {
                    Text("顶层").tag(nil as UUID?)
                    ForEach(libraryStore.sortedCollections) { collection in
                        Text(libraryStore.collectionPath(for: collection.id).map(\.name).joined(separator: " › "))
                            .tag(Optional(collection.id))
                    }
                }
                .frame(maxWidth: 480)
                let mergeRows = preview.collections.filter { !$0.mergeTargetIDs.isEmpty }
                if !mergeRows.isEmpty {
                    GroupBox("同名文献集决定") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(mergeRows) { row in
                                HStack {
                                    Text(String(repeating: "  ", count: row.depth) + row.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Picker("文献集决定", selection: Binding<UUID?>(
                                        get: { selectedMergeTarget(for: row) },
                                        set: { coordinator.setCopyCollectionMergeTarget($0, source: row.source) }
                                    )) {
                                        Text("新建编号名称").tag(nil as UUID?)
                                        ForEach(row.mergeTargetIDs, id: \.self) { id in
                                            if let collection = libraryStore.collections.first(where: { $0.id == id }) {
                                                Text("合并到「\(collection.name)」").tag(Optional(id))
                                            }
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 210)
                                }
                            }
                        }
                    }
                }
                List(preview.papers) { row in
                    HStack(spacing: 9) {
                        if case .keepExistingVersion = row.action {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { row.isIncluded },
                                set: { coordinator.setCopyPaperIncluded($0, source: row.source) }
                            ))
                            .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).lineLimit(1)
                            Text(row.fileName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if !row.blockedManualFields.isEmpty {
                                Text("保留 \(row.blockedManualFields.count) 个手动字段")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        copyActionControl(row)
                    }
                }
                if !preview.authorizationDiagnostics.isEmpty {
                    Text("另有 \(preview.authorizationDiagnostics.count) 个附件因未授权、不可读或变化而跳过。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("确认后将复制到“\(coordinator.targetDirectoryName ?? "目标目录")/\(preview.library.name)”；绝不覆盖已有文件。撤销只移除本批记录和归属，不删除已复制 PDF。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("返回授权") { coordinator.backToAuthorization() }
                    Spacer()
                    Button("确认复制并迁移") {
                        coordinator.confirmCopy(store: libraryStore, undoManager: undoManager)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.includedPaperCount == 0 || libraryStore.persistenceDisabled)
                }
            }
        }
    }

    @ViewBuilder
    private func copyActionControl(_ row: ZoteroCopyPaperPreview) -> some View {
        switch row.action {
        case .create:
            Text("复制新增").foregroundStyle(.secondary)
        case let .reuse(_, reason):
            Text(reason == .contentSHA256 ? "按内容复用" : "复用现有")
                .foregroundStyle(.secondary)
        case .keepExistingVersion:
            Picker("版本决定", selection: Binding(
                get: { false },
                set: { coordinator.setChangedSourceImportedAsNew($0, source: row.source) }
            )) {
                Text("保留现有").tag(false)
                Text("另存新版本").tag(true)
            }
            .labelsHidden()
            .frame(width: 160)
        case .createNewVersion:
            Picker("版本决定", selection: Binding(
                get: { true },
                set: { coordinator.setChangedSourceImportedAsNew($0, source: row.source) }
            )) {
                Text("保留现有").tag(false)
                Text("另存新版本").tag(true)
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private func selectedMergeTarget(for row: FolderCollectionPreview) -> UUID? {
        guard case let .reuse(id, matchedSource)? = row.action, !matchedSource else { return nil }
        return id
    }

    private var copyingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(
                value: Double(coordinator.fileProgressCount),
                total: Double(max(1, coordinator.fileProgressTotal))
            )
            Text("正在暂存、复制并校验 Zotero PDF…")
                .font(.headline)
            Text("\(coordinator.fileProgressCount)/\(coordinator.fileProgressTotal) · 已校验 \(ByteCountFormatter.string(fromByteCount: coordinator.copiedByteCount, countStyle: .file))")
                .foregroundStyle(.secondary)
            Text("完整候选文献库准备好后才会一次发布；取消会清理本事务创建的副本。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { coordinator.cancel() }
            }
        }
    }

    private var completedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Zotero 迁移完成", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let report = coordinator.report {
                ScrollView {
                    Text(report.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let notice = coordinator.failureMessage {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("复制报告") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                    }
                    Spacer()
                    Button("完成") { coordinator.dismiss() }
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
            Text("Zotero 来源和既有目标文件不会被修改；若复制阶段中断，事务日志会在下次启动继续保守清理。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("关闭") { coordinator.dismiss() }
                Spacer()
                Button("重试") { coordinator.begin(store: libraryStore) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var cancelledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已停止 Zotero 迁移预览", systemImage: "stop.circle")
                .font(.headline)
            Text("没有发布部分文献记录；本事务创建的暂存或最终副本会被清理，既有文件不会删除。")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("关闭") { coordinator.dismiss() }
                Spacer()
                Button("重新开始") { coordinator.begin(store: libraryStore) }
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
