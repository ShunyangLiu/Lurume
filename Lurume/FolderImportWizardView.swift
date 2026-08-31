import AppKit
import SwiftUI

struct FolderImportWizardView: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var coordinator: FolderImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            switch coordinator.phase {
            case .idle:
                EmptyView()
            case .scanning:
                scanningView
            case .preview:
                previewView
            case .executing:
                executingView
            case .completed:
                completedView
            case .failed:
                failedView
            case .cancelled:
                cancelledView
            }
        }
        .padding(20)
        .frame(width: 780, height: 680)
        .interactiveDismissDisabled(coordinator.isBusy)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("导入文件夹")
                    .font(.title2.weight(.semibold))
                Text("原位引用 PDF；不会复制、移动、重命名或修改原文件。")
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

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(
                value: Double(coordinator.scanProgress.processedPDFCount),
                total: Double(max(1, coordinator.scanProgress.discoveredPDFCount))
            )
            Text(
                "已发现 \(coordinator.scanProgress.discoveredPDFCount) 个 PDF；"
                    + "已检查 \(coordinator.scanProgress.processedPDFCount) 个，"
                    + "其中 \(coordinator.scanProgress.validPDFCount) 个有效。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("取消扫描", role: .cancel) { coordinator.cancel() }
            }
        }
    }

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = coordinator.preview {
                summary(preview)
                targetParentPicker(preview)
                Text("原位引用不会制作历史副本；Finder 中的原文件以后若被外部程序覆盖，Lurume 也会读到新内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TabView {
                    collectionPreview(preview)
                        .tabItem { Label("文献集", systemImage: "folder") }
                    paperPreview(preview)
                        .tabItem { Label("PDF", systemImage: "doc.richtext") }
                    diagnosticsPreview(preview)
                        .tabItem { Label("诊断", systemImage: "exclamationmark.triangle") }
                }
                HStack {
                    Button("取消", role: .cancel) { coordinator.dismiss() }
                    Spacer()
                    Button("重新扫描") { coordinator.rescan(store: libraryStore) }
                    Button("确认导入") {
                        coordinator.confirm(store: libraryStore, undoManager: undoManager)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.includedPaperCount == 0 || libraryStore.persistenceDisabled)
                }
            }
        }
    }

    private func summary(_ preview: FolderImportPreview) -> some View {
        HStack(spacing: 18) {
            summaryValue("将处理", value: preview.includedPaperCount)
            summaryValue("新增", value: preview.newPaperCount)
            summaryValue("复用", value: preview.reusedPaperCount)
            summaryValue("版本冲突", value: preview.versionConflictCount)
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteCountFormatter.string(
                    fromByteCount: preview.includedByteCount,
                    countStyle: .file
                ))
                    .font(.headline.monospacedDigit())
                Text("原位引用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if preview.versionConflictCount > 0 {
                Menu("批量决定") {
                    Button("全部保留现有版本") {
                        coordinator.setAllChangedSourcesImportedAsNew(false)
                    }
                    Button("全部另存为新文献") {
                        coordinator.setAllChangedSourcesImportedAsNew(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryValue(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func targetParentPicker(_ preview: FolderImportPreview) -> some View {
        Picker("导入根文献集位置", selection: Binding<UUID?>(
            get: { preview.targetParentID },
            set: { coordinator.setTargetParentID($0) }
        )) {
            Text("顶层").tag(nil as UUID?)
            ForEach(libraryStore.sortedCollections) { collection in
                Text(collectionPath(collection.id)).tag(Optional(collection.id))
            }
        }
        .frame(maxWidth: 460)
    }

    private func collectionPreview(_ preview: FolderImportPreview) -> some View {
        List(preview.collections) { row in
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { coordinator.directoryIsIncluded(row.source) },
                    set: { coordinator.setDirectoryIncluded($0, source: row.source) }
                ))
                .labelsHidden()
                .accessibilityLabel("包含目录 \(row.name)")
                .disabled(row.action == nil)
                HStack(spacing: 5) {
                    ForEach(0..<row.depth, id: \.self) { _ in
                        Color.clear.frame(width: 12, height: 1)
                    }
                    Image(systemName: "folder")
                    Text(row.name)
                }
                Spacer()
                collectionDecision(row)
            }
        }
        .overlay {
            if preview.collections.isEmpty {
                ContentUnavailableView("没有可创建的文献集", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private func collectionDecision(_ row: FolderCollectionPreview) -> some View {
        switch row.action {
        case let .reuse(id, matchedSource) where matchedSource:
            Text("按来源复用“\(collectionPath(id))”")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .reuse(id, _) where !row.mergeTargetIDs.isEmpty:
            collectionMergePicker(row, selectedID: id)
        case .create where !row.mergeTargetIDs.isEmpty:
            collectionMergePicker(row, selectedID: nil)
        case .create:
            Text("新建")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .reuse:
            Text("复用")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            Text("已排除")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func collectionMergePicker(
        _ row: FolderCollectionPreview,
        selectedID: UUID?
    ) -> some View {
        Picker("同名文献集决定", selection: Binding<UUID?>(
            get: { selectedID },
            set: { coordinator.setCollectionMergeTarget($0, source: row.source) }
        )) {
            Text("新建“\(row.name)”").tag(nil as UUID?)
            ForEach(row.mergeTargetIDs, id: \.self) { id in
                Text("合并到“\(collectionPath(id))”").tag(Optional(id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 280)
    }

    private func paperPreview(_ preview: FolderImportPreview) -> some View {
        List(preview.papers) { row in
            HStack(spacing: 10) {
                if case .keepExistingVersion = row.action {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("版本冲突")
                } else if case .createNewVersion = row.action {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("版本冲突，另存为新文献")
                } else {
                    Toggle("", isOn: Binding(
                        get: { row.isIncluded },
                        set: { coordinator.setPaperIncluded($0, source: row.source) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("包含 \(row.relativePath)")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .lineLimit(1)
                    Text(row.relativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !row.changedMetadataFields.isEmpty || !row.blockedManualFields.isEmpty {
                        Text(metadataDecisionSummary(row))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if case .keepExistingVersion = row.action {
                    versionConflictPicker(row, importAsNew: false)
                } else if case .createNewVersion = row.action {
                    versionConflictPicker(row, importAsNew: true)
                } else {
                    Text(paperActionTitle(row.action))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func versionConflictPicker(
        _ row: FolderPaperPreview,
        importAsNew: Bool
    ) -> some View {
        Picker("版本冲突决定", selection: Binding(
            get: { importAsNew },
            set: { coordinator.setChangedSourceImportedAsNew($0, source: row.source) }
        )) {
            Text("保留现有").tag(false)
            Text("另存为新文献").tag(true)
        }
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private func paperActionTitle(_ action: FolderPaperImportAction) -> String {
        switch action {
        case .create: "新增"
        case let .reuse(_, reason):
            switch reason {
            case .source: "按来源复用"
            case .fileIdentity: "按文件复用"
            case .contentSHA256: "按内容复用"
            }
        case .keepExistingVersion: "保留现有"
        case .createNewVersion: "另存为新文献"
        }
    }

    private func metadataDecisionSummary(_ row: FolderPaperPreview) -> String {
        var segments: [String] = []
        if !row.changedMetadataFields.isEmpty {
            segments.append("将更新 \(row.changedMetadataFields.count) 个元数据字段")
        }
        if !row.blockedManualFields.isEmpty {
            segments.append("保留 \(row.blockedManualFields.count) 个手动字段")
        }
        return segments.joined(separator: "；")
    }

    private func diagnosticsPreview(_ preview: FolderImportPreview) -> some View {
        List {
            if preview.unsupportedFileCount > 0 {
                LabeledContent("未探测的非 PDF 文件") {
                    Text(preview.unsupportedFileCount, format: .number)
                }
            }
            ForEach(preview.diagnostics) { diagnostic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.relativePath)
                        .font(.callout.monospaced())
                    Text(diagnostic.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if preview.diagnostics.isEmpty && preview.unsupportedFileCount == 0 {
                ContentUnavailableView("没有扫描诊断", systemImage: "checkmark.circle")
            }
        }
    }

    private var executingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(
                value: Double(coordinator.executionCompletedCount),
                total: Double(max(1, coordinator.executionTotalCount))
            )
            Text(
                "正在确认文件未变化并创建逐文件只读书签："
                    + "\(coordinator.executionCompletedCount)/\(coordinator.executionTotalCount)"
            )
            .foregroundStyle(.secondary)
            Text("此阶段仍不会复制或修改 PDF；全部候选准备完成后才一次保存文献库。")
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
            Label("文件夹导入完成", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let report = coordinator.report {
                ScrollView {
                    Text(report.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("复制报告") { copyReport(report.text) }
                    Spacer()
                    Button("完成") { coordinator.dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("文件夹导入失败", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(coordinator.failureMessage ?? "发生未知错误。")
                .textSelection(.enabled)
            Text("文献库和原 PDF 均未被修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("关闭") { coordinator.dismiss() }
                Spacer()
                Button("重新扫描") { coordinator.rescan(store: libraryStore) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var cancelledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已取消文件夹导入", systemImage: "stop.circle")
                .font(.headline)
            Text("未发布候选文献集或文献记录，原 PDF 未被修改。")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("关闭") { coordinator.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func collectionPath(_ id: UUID) -> String {
        let path = libraryStore.collectionPath(for: id).map(\.name).joined(separator: " › ")
        return path.isEmpty ? "未知文献集" : path
    }

    private func copyReport(_ report: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
