import SwiftUI
import Translation
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    private enum FileImporterPurpose {
        case importPDFs
        case relinkPaper
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var translationController: TranslationController
    @EnvironmentObject private var highlightStore: HighlightStore
    @StateObject private var pdfController = PDFReaderController()
    @State private var isImporterPresented = false
    @State private var importerPurpose: FileImporterPurpose?
    @State private var relinkingPaperID: UUID?
    @State private var activeAccess: SecurityScopedAccess?
    @State private var activeAccessPaperID: UUID?
    @State private var documentError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorMode: ReaderInspectorMode = .translation
    @State private var pendingPaperRemoval: UUID?

    @State private var searchText = ""
    @State private var sidebarMode: ReaderSidebarMode = .library
    @State private var statusFilter: ReadingStatusFilter = .all
    @State private var statusInteractionLocked = false
    @FocusState private var searchFieldFocused: Bool
    @State private var isPDFSearchPresented = false
    @FocusState private var pdfSearchFieldFocused: Bool
    @State private var metadataEditorTarget: UUID?
    @State private var inlineTitleEditID: UUID?
    @State private var inlineTitleDraft = ""
    @FocusState private var inlineTitleFieldFocused: Bool

    private var selection: Binding<UUID?> {
        Binding(
            get: { libraryStore.selectedPaperID },
            set: { newValue in
                if newValue == nil,
                   let current = libraryStore.selectedPaperID,
                   !filteredPapers.contains(where: { $0.id == current }) {
                    return
                }
                libraryStore.selectPaper(id: newValue)
            }
        )
    }

    private var filteredPapers: [PaperRecord] {
        libraryStore.papers(
            matching: searchText,
            status: statusFilter,
            sortedBy: appSettings.librarySortOption
        )
    }

    private var presentedError: String? {
        highlightStore.presentedError ?? libraryStore.presentedError
    }

    /// Return 改名快捷键只在没有文本输入进行时生效。
    private var returnShortcutDisabled: Bool {
        libraryStore.persistenceDisabled
            || sidebarMode != .library
            || inlineTitleEditID != nil
            || metadataEditorTarget != nil
            || searchFieldFocused
            || libraryStore.selectedPaperID == nil
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
            } detail: {
                detail
            }
            .frame(minWidth: 900, minHeight: 600)
            .toolbar {
                if libraryStore.selectedPaper != nil {
                    ToolbarItemGroup {
                        PDFToolbar(controller: pdfController)
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf],
                // Keep the panel configuration stable while its dismissal animation runs.
                // Relinking still consumes only the first selected URL.
                allowsMultipleSelection: true,
                onCompletion: handleFileImporter
            )
            .overlay {
                FileDropReceiver { urls in
                    guard !libraryStore.persistenceDisabled else { return }
                    let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                    guard !pdfURLs.isEmpty else { return }
                    libraryStore.importPDFs(at: pdfURLs)
                }
                .allowsHitTesting(false)
            }
            .sheet(isPresented: Binding(
                get: { metadataEditorTarget != nil },
                set: { if !$0 { metadataEditorTarget = nil } }
            )) {
                if let target = metadataEditorTarget,
                   let paper = libraryStore.papers.first(where: { $0.id == target }) {
                    MetadataFormView(paper: paper) {
                        metadataEditorTarget = nil
                    }
                }
            }
            .alert(
                "Lurume",
                isPresented: Binding(
                    get: { presentedError != nil },
                    set: { if !$0 { clearPresentedErrors() } }
                )
            ) {
                Button("好", role: .cancel) {
                    clearPresentedErrors()
                }
            } message: {
                Text(presentedError ?? "发生未知错误。")
            }
            .confirmationDialog(
                "移除文献？",
                isPresented: Binding(
                    get: { pendingPaperRemoval != nil },
                    set: { if !$0 { pendingPaperRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("移除文献和高亮", role: .destructive) {
                    guard let id = pendingPaperRemoval else { return }
                    pendingPaperRemoval = nil
                    removePaper(id)
                }
                Button("取消", role: .cancel) {
                    pendingPaperRemoval = nil
                }
            } message: {
                if let id = pendingPaperRemoval {
                    Text(removalConfirmationMessage(for: id))
                }
            }
            .task(id: libraryStore.selectedPaperID) {
                await Task.yield()
                openSelectedPaper()
            }
            .onChange(of: appSettings.automaticTranslation) {
                if !appSettings.automaticTranslation {
                    translationController.cancelPendingAutomaticTranslation()
                }
            }
            .onChange(of: inlineTitleFieldFocused) {
                guard !inlineTitleFieldFocused,
                      let editingID = inlineTitleEditID else { return }
                commitInlineTitleEdit(for: editingID)
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    libraryStore.flushPendingSave()
                }
            }
            .inspector(isPresented: $translationController.isInspectorPresented) {
                TranslationInspector(
                    controller: translationController,
                    settings: appSettings,
                    highlightStore: highlightStore,
                    pdfController: pdfController,
                    mode: $inspectorMode,
                    paper: libraryStore.selectedPaper,
                    navigateToHighlight: navigateToHighlight,
                    deleteHighlight: deleteHighlight
                )
            }
            .translationTask(translationController.configuration) { session in
                await translationController.perform(
                    using: SystemTranslationPerformer(session: session)
                )
            }

            KeyboardCommandMonitor(
                focusLibrarySearch: focusLibrarySearch,
                openPDFSearch: openPDFSearch,
                closePDFSearch: closePDFSearch,
                previousPDFSearchResult: pdfController.previousSearchResult,
                nextPDFSearchResult: pdfController.nextSearchResult,
                isPDFSearchPresented: isPDFSearchPresented,
                togglePDFHighlight: toggleCurrentHighlight,
                beginTitleEdit: beginInlineTitleEdit
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 左侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("侧边栏", selection: $sidebarMode) {
                ForEach(ReaderSidebarMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            sidebarContent
        }
        .navigationTitle(sidebarMode.title)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch sidebarMode {
        case .library:
            librarySidebar
        case .outline:
            if hasCurrentNavigationContext {
                PDFOutlineSidebar(controller: pdfController)
            } else {
                navigationLoadingState(systemImage: "list.bullet.indent")
            }
        case .pages:
            if hasCurrentNavigationContext {
                PDFThumbnailSidebar(controller: pdfController)
            } else {
                navigationLoadingState(systemImage: "rectangle.stack")
            }
        }
    }

    private var hasCurrentNavigationContext: Bool {
        guard let selectedPaperID = libraryStore.selectedPaperID else { return false }
        return activeAccessPaperID == selectedPaperID
    }

    private func navigationLoadingState(systemImage: String) -> some View {
        ContentUnavailableView(
            libraryStore.selectedPaperID == nil ? "尚未选择论文" : "正在载入 PDF",
            systemImage: systemImage,
            description: Text(
                libraryStore.selectedPaperID == nil
                    ? "从文献列表选择一篇论文。"
                    : "目录和页面将在文档打开后显示。"
            )
        )
    }

    // MARK: - 文献列表

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            libraryOrganizationControls
            librarySearchAndImport
            libraryPaperList
        }
    }

    private var libraryOrganizationControls: some View {
        HStack(spacing: 8) {
            Picker("阅读状态", selection: $statusFilter) {
                ForEach(ReadingStatusFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Picker("排序", selection: $appSettings.librarySortOption) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var librarySearchAndImport: some View {
        HStack(spacing: 8) {
            librarySearchField

            Button {
                presentImporter()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("导入 PDF")
            .accessibilityLabel("导入 PDF")
            .disabled(libraryStore.persistenceDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var libraryPaperList: some View {
        List(selection: selection) {
            ForEach(filteredPapers) { paper in
                paperRow(for: paper)
            }
        }
        .overlay { libraryEmptyState }
    }

    private func paperRow(for paper: PaperRecord) -> some View {
        PaperRow(
            paper: paper,
            isUnavailable: libraryStore.unavailablePaperIDs.contains(paper.id),
            isEditingTitle: inlineTitleEditID == paper.id,
            titleDraft: $inlineTitleDraft,
            titleFieldFocused: $inlineTitleFieldFocused,
            commitTitle: commitActiveInlineTitleEdit,
            cancelTitle: cancelInlineTitleEdit,
            statusInteractionLocked: statusInteractionLocked,
            statusDisabled: libraryStore.persistenceDisabled,
            cycleReadingStatus: {
                changeReadingStatus(paper.readingStatus.next, for: paper.id)
            }
        )
        .tag(paper.id)
        .help(paper.originalFileName)
        .contextMenu { paperContextMenu(for: paper) }
    }

    @ViewBuilder
    private func paperContextMenu(for paper: PaperRecord) -> some View {
        Menu("阅读状态") {
            ForEach(ReadingStatus.allCases) { status in
                Button {
                    changeReadingStatus(status, for: paper.id)
                } label: {
                    Label(
                        status.title,
                        systemImage: paper.readingStatus == status
                            ? "checkmark"
                            : status.systemImage
                    )
                }
                .disabled(
                    paper.readingStatus == status
                        || libraryStore.persistenceDisabled
                )
            }
        }
        if paper.id == libraryStore.selectedPaperID {
            Button("编辑文献信息…") {
                metadataEditorTarget = paper.id
            }
            .disabled(libraryStore.persistenceDisabled)
        }
        if libraryStore.unavailablePaperIDs.contains(paper.id) {
            Button("重新定位…") {
                presentRelinker(for: paper.id)
            }
            .disabled(libraryStore.persistenceDisabled)
        }
        Button("移除引用", role: .destructive) {
            requestPaperRemoval(paper.id)
        }
        .disabled(libraryStore.persistenceDisabled)
    }

    @ViewBuilder
    private var libraryEmptyState: some View {
        if libraryStore.persistenceDisabled {
            ContentUnavailableView(
                "文献库处于只读状态",
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text("无法安全载入或升级文献库。原有数据未被覆盖，请先修复文献库后再导入或编辑。")
            )
        } else if libraryStore.papers.isEmpty {
            ContentUnavailableView(
                "尚未导入论文",
                systemImage: "doc.text.magnifyingglass",
                description: Text("点击搜索框旁的加号，或把 PDF 拖入窗口。")
            )
        } else if filteredPapers.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "此状态下没有文献" : "无匹配文献",
                systemImage: searchText.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "magnifyingglass",
                description: Text(
                    searchText.isEmpty
                        ? "选择其他阅读状态查看文献。"
                        : "试试其他标题、作者或文件名关键词。"
                )
            )
        }
    }

    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索标题、作者或文件名", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary.opacity(0.45))
        )
    }

    // MARK: - 阅读区

    @ViewBuilder
    private var detail: some View {
        if let paper = libraryStore.selectedPaper {
            if activeAccessPaperID == paper.id, let activeAccess {
                PDFReaderView(
                    paperID: paper.id,
                    documentURL: activeAccess.url,
                    initialPageIndex: paper.lastPageIndex,
                    controller: pdfController,
                    highlights: highlightStore.highlights(for: paper.id),
                    onPageChanged: { pageIndex in
                        libraryStore.updatePageIndex(pageIndex, for: paper.id)
                    },
                    onSelectionChanged: { event in
                        if event != nil {
                            inspectorMode = .translation
                        }
                        translationController.receiveSelection(
                            event,
                            paperID: paper.id,
                            paperName: paper.title,
                            automaticTranslation: appSettings.automaticTranslation,
                            targetLanguage: appSettings.targetLanguage,
                            sourceLanguage: appSettings.sourceLanguage
                        )
                    },
                    onToggleHighlight: toggleCurrentHighlight,
                    onDeleteHighlight: deleteHighlight,
                    onError: { message in
                        documentError = message
                    }
                )
                .id(paper.id)
                .overlay(alignment: .topTrailing) {
                    if let documentError {
                        DocumentErrorView(message: documentError)
                    }

                    if isPDFSearchPresented, documentError == nil {
                        PDFSearchOverlay(
                            controller: pdfController,
                            searchFieldFocused: $pdfSearchFieldFocused,
                            close: closePDFSearch
                        )
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isPDFSearchPresented)
            } else if activeAccessPaperID == paper.id {
                UnavailablePaperView(paperName: paper.title) {
                    presentRelinker(for: paper.id)
                }
            } else {
                ProgressView("正在打开 PDF…")
                    .controlSize(.small)
            }
        } else {
            ContentUnavailableView(
                "选择一篇论文",
                systemImage: "doc.richtext",
                description: Text("导入或从左侧选择 PDF 开始阅读。")
            )
        }
    }

    private func openPDFSearch() {
        guard libraryStore.selectedPaper != nil,
              activeAccessPaperID == libraryStore.selectedPaperID,
              activeAccess != nil,
              documentError == nil else {
            focusLibrarySearch()
            return
        }
        isPDFSearchPresented = true
        Task { @MainActor in
            await Task.yield()
            pdfSearchFieldFocused = true
        }
    }

    private func closePDFSearch() {
        isPDFSearchPresented = false
        pdfSearchFieldFocused = false
        pdfController.searchText = ""
        pdfController.clearSearchResults()
    }

    private func focusLibrarySearch() {
        closePDFSearch()
        sidebarMode = .library
        Task { @MainActor in
            await Task.yield()
            searchFieldFocused = true
        }
    }

    // MARK: - 行内改标题

    @discardableResult
    private func beginInlineTitleEdit() -> Bool {
        guard !returnShortcutDisabled,
              !(NSApp.keyWindow?.firstResponder is NSTextView),
              let paper = libraryStore.selectedPaper else {
            return false
        }
        inlineTitleDraft = paper.title
        inlineTitleEditID = paper.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            inlineTitleFieldFocused = true
        }
        return true
    }

    private func commitActiveInlineTitleEdit() {
        guard let id = inlineTitleEditID else { return }
        commitInlineTitleEdit(for: id)
    }

    private func commitInlineTitleEdit(for id: UUID) {
        libraryStore.setManualTitle(inlineTitleDraft, for: id)
        inlineTitleEditID = nil
        inlineTitleFieldFocused = false
        inlineTitleDraft = ""
    }

    private func cancelInlineTitleEdit() {
        // 先清 ID，触发 focus 的 onChange 时不会再误提交。
        inlineTitleEditID = nil
        inlineTitleFieldFocused = false
        inlineTitleDraft = ""
    }

    // MARK: - 导入与文件处理

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            libraryStore.importPDFs(at: urls)
            openSelectedPaper()
        case let .failure(error):
            if !isUserCancellation(error) {
                libraryStore.presentedError = error.localizedDescription
            }
        }
    }

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        let purpose = importerPurpose
        importerPurpose = nil

        switch purpose {
        case .importPDFs:
            handleImport(result)
        case .relinkPaper:
            handleRelink(result)
        case nil:
            break
        }
    }

    private func handleRelink(_ result: Result<[URL], Error>) {
        defer { relinkingPaperID = nil }
        guard let paperID = relinkingPaperID else { return }
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                try libraryStore.relinkPaper(id: paperID, to: url)
                openSelectedPaper()
            } catch {
                libraryStore.presentedError = "无法重新定位：\(error.localizedDescription)"
            }
        case let .failure(error):
            if !isUserCancellation(error) {
                libraryStore.presentedError = error.localizedDescription
            }
        }
    }

    private func presentRelinker(for paperID: UUID) {
        relinkingPaperID = paperID
        importerPurpose = .relinkPaper
        isImporterPresented = true
    }

    private func presentImporter() {
        importerPurpose = .importPDFs
        isImporterPresented = true
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSUserCancelledError
    }

    private func openSelectedPaper() {
        closePDFSearch()
        documentError = nil
        pdfController.detach()
        activeAccess = nil
        activeAccessPaperID = nil
        guard let paperID = libraryStore.selectedPaperID else { return }
        activeAccess = libraryStore.resolveFile(for: paperID)
        activeAccessPaperID = paperID
    }

    private func toggleCurrentHighlight() {
        guard let paper = libraryStore.selectedPaper,
              let candidate = pdfController.makeHighlightCandidate(paperID: paper.id),
              let result = highlightStore.toggle(candidate, undoManager: undoManager) else {
            return
        }

        switch result {
        case let .added(record):
            pdfController.currentHighlightID = record.id
        case let .removed(record):
            if pdfController.currentHighlightID == record.id {
                pdfController.currentHighlightID = nil
            }
        }
        pdfController.clearCurrentSelection()
    }

    private func navigateToHighlight(_ highlight: HighlightRecord) {
        guard highlight.paperID == libraryStore.selectedPaperID else { return }
        pdfController.clearCurrentSelection()
        pdfController.activateHighlight(highlight, translate: false)
    }

    private func deleteHighlight(_ id: UUID) {
        guard let paperID = libraryStore.selectedPaperID else { return }
        let ordered = highlightStore.highlights(for: paperID)
        let removedIndex = ordered.firstIndex { $0.id == id }
        guard highlightStore.remove(id: id, undoManager: undoManager) else { return }

        if pdfController.currentHighlightID == id {
            let remaining = highlightStore.highlights(for: paperID)
            if let removedIndex, !remaining.isEmpty {
                pdfController.currentHighlightID = remaining[min(removedIndex, remaining.count - 1)].id
            } else {
                pdfController.currentHighlightID = nil
            }
        }
    }

    private func requestPaperRemoval(_ id: UUID) {
        if highlightStore.count(for: id) > 0 {
            pendingPaperRemoval = id
        } else {
            removePaper(id)
        }
    }

    private func changeReadingStatus(_ status: ReadingStatus, for id: UUID) {
        guard !statusInteractionLocked else { return }
        let needsMisclickGuard = statusFilter != .all
        if needsMisclickGuard {
            statusInteractionLocked = true
        }
        libraryStore.setReadingStatus(status, for: id)
        guard needsMisclickGuard else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            statusInteractionLocked = false
        }
    }

    private func removePaper(_ id: UUID) {
        let removedHighlights: [HighlightRecord]
        do {
            if highlightStore.count(for: id) > 0 {
                removedHighlights = try highlightStore.removeAll(for: id)
            } else {
                removedHighlights = []
            }
        } catch {
            highlightStore.presentedError = "无法移除文献的高亮：\(error.localizedDescription)"
            return
        }

        do {
            try libraryStore.removePaper(id: id)
        } catch {
            do {
                try highlightStore.restore(removedHighlights)
                libraryStore.presentedError = "无法移除文献：\(error.localizedDescription)"
            } catch let restoreError {
                libraryStore.presentedError = "无法移除文献，且恢复高亮失败：\(restoreError.localizedDescription)"
            }
            return
        }

        translationController.paperRemoved(id)
        openSelectedPaper()
    }

    private func removalConfirmationMessage(for id: UUID) -> String {
        let count = highlightStore.count(for: id)
        return "移除后将同时删除 \(count) 条高亮。原始 PDF 不会被删除或修改。"
    }

    private func clearPresentedErrors() {
        highlightStore.presentedError = nil
        libraryStore.presentedError = nil
    }
}

private struct PDFSearchOverlay: View {
    @ObservedObject var controller: PDFReaderController
    var searchFieldFocused: FocusState<Bool>.Binding
    let close: () -> Void
    @State private var pendingSearch: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            TextField("搜索 PDF", text: $controller.searchText)
                .textFieldStyle(.plain)
                .focused(searchFieldFocused)
                .frame(minWidth: 170)
                .onSubmit(controller.nextSearchResult)
                .onChange(of: controller.searchText) {
                    scheduleSearch()
                }

            Text(controller.searchResultLabel ?? "0 / 0")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 42, alignment: .trailing)

            Button(action: controller.previousSearchResult) {
                Image(systemName: "chevron.up")
            }
            .help("上一个匹配（⇧↩）")
            .disabled(!controller.canNavigateSearchResults)

            Button(action: controller.nextSearchResult) {
                Image(systemName: "chevron.down")
            }
            .help("下一个匹配（↩）")
            .disabled(!controller.canNavigateSearchResults)

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .help("关闭（Esc）")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .onExitCommand(perform: close)
        .onDisappear {
            pendingSearch?.cancel()
        }
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
        controller.searchTextDidChange()
        pendingSearch = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            controller.search()
        }
    }
}

private struct PaperRow: View {
    let paper: PaperRecord
    let isUnavailable: Bool
    let isEditingTitle: Bool
    @Binding var titleDraft: String
    var titleFieldFocused: FocusState<Bool>.Binding
    let commitTitle: () -> Void
    let cancelTitle: () -> Void
    let statusInteractionLocked: Bool
    let statusDisabled: Bool
    let cycleReadingStatus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: isUnavailable ? "exclamationmark.triangle" : "doc.richtext")
                    .foregroundStyle(isUnavailable ? .orange : .secondary)

                if isEditingTitle {
                    TextField("标题", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused(titleFieldFocused)
                        .onSubmit(commitTitle)
                        .onExitCommand(perform: cancelTitle)
                } else {
                    Text(paper.title)
                        .lineLimit(2, reservesSpace: false)
                }

                Spacer(minLength: 4)

                Button(action: cycleReadingStatus) {
                    Image(systemName: paper.readingStatus.systemImage)
                        .foregroundStyle(statusColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .allowsHitTesting(!statusInteractionLocked && !statusDisabled)
                .help(
                    "\(paper.readingStatus.title)，点击标记为\(paper.readingStatus.next.title)"
                )
                .accessibilityLabel(
                    "\(paper.readingStatus.title)，点击标记为\(paper.readingStatus.next.title)"
                )
            }
            secondaryLine
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch paper.readingStatus {
        case .unread: .secondary
        case .reading: .accentColor
        case .finished: .green
        }
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if isUnavailable {
            Text("文件不可用")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let subtitle = paper.librarySubtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(paper.originalFileName)
        }
    }
}

private struct MetadataFormView: View {
    let paper: PaperRecord
    let onClose: () -> Void

    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var titleText = ""
    @State private var authorsText = ""
    @State private var yearText = ""
    @State private var didLoadInitialValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑文献信息")
                .font(.headline)

            Form {
                TextField("标题", text: $titleText)
                TextField("作者", text: $authorsText)
                TextField("年份（如 2023）", text: $yearText)
                if case .invalid = parsedYearInput {
                    Text("年份必须是整数，或留空。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                infoRow(label: "原始文件名", value: paper.originalFileName)
                infoRow(
                    label: "文件位置",
                    value: (paper.fallbackPath as NSString).abbreviatingWithTildeInPath
                )
                infoRow(label: "导入时间", value: paper.dateAdded.formatted(date: .long, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", action: closeWithoutSaving)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedYearInput == .invalid || libraryStore.persistenceDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        guard !didLoadInitialValues else { return }
        didLoadInitialValues = true
        titleText = paper.title
        authorsText = paper.authors ?? ""
        yearText = paper.year.map(String.init) ?? ""
    }

    private func save() {
        guard parsedYearInput != .invalid else { return }
        // 只提交发生变化的字段，避免未触碰的字段被误标记为手动维护。
        if titleText.trimmingCharacters(in: .whitespacesAndNewlines) != paper.title {
            libraryStore.setManualTitle(titleText, for: paper.id)
        }
        if authorsText.trimmingCharacters(in: .whitespacesAndNewlines) != (paper.authors ?? "") {
            libraryStore.setManualAuthors(authorsText, for: paper.id)
        }
        let parsedYear: Int?
        switch parsedYearInput {
        case .empty:
            parsedYear = nil
        case let .value(year):
            parsedYear = year
        case .invalid:
            return
        }
        if parsedYear != paper.year {
            libraryStore.setManualYear(parsedYear, for: paper.id)
        }
        dismiss()
        onClose()
    }

    private var parsedYearInput: PaperYearInput {
        PaperYearRules.parse(yearText)
    }

    private func closeWithoutSaving() {
        dismiss()
        onClose()
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + "：")
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct UnavailablePaperView: View {
    let paperName: String
    let relink: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("文件不可用", systemImage: "exclamationmark.triangle")
        } description: {
            Text("无法访问“\(paperName)”。它可能已跨卷移动或被删除。")
        } actions: {
            Button("重新定位…", action: relink)
        }
    }
}

private struct DocumentErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "无法打开 PDF",
            systemImage: "doc.badge.ellipsis",
            description: Text(message)
        )
        .background(.background)
    }
}

private struct FileDropReceiver: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropReceivingView {
        FileDropReceivingView(onDrop: onDrop)
    }

    func updateNSView(_ nsView: FileDropReceivingView, context: Context) {
        nsView.onDrop = onDrop
    }
}

/// 无界面的窗口级快捷键监听，避免用隐藏 Button 产生焦点环或点击区域。
private struct KeyboardCommandMonitor: NSViewRepresentable {
    let focusLibrarySearch: () -> Void
    let openPDFSearch: () -> Void
    let closePDFSearch: () -> Void
    let previousPDFSearchResult: () -> Void
    let nextPDFSearchResult: () -> Void
    let isPDFSearchPresented: Bool
    let togglePDFHighlight: () -> Void
    let beginTitleEdit: () -> Bool

    func makeNSView(context: Context) -> KeyboardCommandMonitoringView {
        KeyboardCommandMonitoringView(
            focusLibrarySearch: focusLibrarySearch,
            openPDFSearch: openPDFSearch,
            closePDFSearch: closePDFSearch,
            previousPDFSearchResult: previousPDFSearchResult,
            nextPDFSearchResult: nextPDFSearchResult,
            isPDFSearchPresented: isPDFSearchPresented,
            togglePDFHighlight: togglePDFHighlight,
            beginTitleEdit: beginTitleEdit
        )
    }

    func updateNSView(_ nsView: KeyboardCommandMonitoringView, context: Context) {
        nsView.focusLibrarySearch = focusLibrarySearch
        nsView.openPDFSearch = openPDFSearch
        nsView.closePDFSearch = closePDFSearch
        nsView.previousPDFSearchResult = previousPDFSearchResult
        nsView.nextPDFSearchResult = nextPDFSearchResult
        nsView.isPDFSearchPresented = isPDFSearchPresented
        nsView.togglePDFHighlight = togglePDFHighlight
        nsView.beginTitleEdit = beginTitleEdit
    }

    static func dismantleNSView(_ nsView: KeyboardCommandMonitoringView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class KeyboardCommandMonitoringView: NSView {
    var focusLibrarySearch: () -> Void
    var openPDFSearch: () -> Void
    var closePDFSearch: () -> Void
    var previousPDFSearchResult: () -> Void
    var nextPDFSearchResult: () -> Void
    var isPDFSearchPresented: Bool
    var togglePDFHighlight: () -> Void
    var beginTitleEdit: () -> Bool
    private var eventMonitor: Any?

    init(
        focusLibrarySearch: @escaping () -> Void,
        openPDFSearch: @escaping () -> Void,
        closePDFSearch: @escaping () -> Void,
        previousPDFSearchResult: @escaping () -> Void,
        nextPDFSearchResult: @escaping () -> Void,
        isPDFSearchPresented: Bool,
        togglePDFHighlight: @escaping () -> Void,
        beginTitleEdit: @escaping () -> Bool
    ) {
        self.focusLibrarySearch = focusLibrarySearch
        self.openPDFSearch = openPDFSearch
        self.closePDFSearch = closePDFSearch
        self.previousPDFSearchResult = previousPDFSearchResult
        self.nextPDFSearchResult = nextPDFSearchResult
        self.isPDFSearchPresented = isPDFSearchPresented
        self.togglePDFHighlight = togglePDFHighlight
        self.beginTitleEdit = beginTitleEdit
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoringIfNeeded()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func startMonitoringIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.charactersIgnoringModifiers?.lowercased() == "h",
           modifiers == [.command, .control],
           !(window?.firstResponder is NSTextView) {
            togglePDFHighlight()
            return nil
        }

        if event.charactersIgnoringModifiers?.lowercased() == "f",
           modifiers == [.command, .option] {
            focusLibrarySearch()
            return nil
        }

        if event.charactersIgnoringModifiers?.lowercased() == "f",
           modifiers == .command {
            openPDFSearch()
            return nil
        }

        if isPDFSearchPresented, event.keyCode == 53 {
            closePDFSearch()
            return nil
        }

        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isPDFSearchPresented, isReturn {
            if modifiers == .shift {
                previousPDFSearchResult()
                return nil
            }
            if modifiers.isEmpty {
                nextPDFSearchResult()
                return nil
            }
        }

        if modifiers.isEmpty,
           isReturn,
           !(window?.firstResponder is NSTextView),
           beginTitleEdit() {
            return nil
        }

        return event
    }
}

private final class FileDropReceivingView: NSView {
    var onDrop: ([URL]) -> Void

    init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []
        return objects.compactMap { ($0 as? NSURL)?.absoluteURL }
    }
}
