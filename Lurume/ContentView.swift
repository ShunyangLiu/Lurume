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
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var translationController: TranslationController
    @StateObject private var pdfController = PDFReaderController()
    @State private var isImporterPresented = false
    @State private var importerPurpose: FileImporterPurpose?
    @State private var relinkingPaperID: UUID?
    @State private var activeAccess: SecurityScopedAccess?
    @State private var documentError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var metadataEditorTarget: UUID?
    @State private var inlineTitleEditID: UUID?
    @State private var inlineTitleDraft = ""
    @FocusState private var inlineTitleFieldFocused: Bool

    private var selection: Binding<UUID?> {
        Binding(
            get: { libraryStore.selectedPaperID },
            set: { libraryStore.selectPaper(id: $0) }
        )
    }

    private var filteredPapers: [PaperRecord] {
        libraryStore.papers(matching: searchText)
    }

    /// Return 改名快捷键只在没有文本输入进行时生效。
    private var returnShortcutDisabled: Bool {
        libraryStore.persistenceDisabled
            || inlineTitleEditID != nil
            || metadataEditorTarget != nil
            || searchFieldFocused
            || libraryStore.selectedPaperID == nil
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                librarySidebar
                    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
            } detail: {
                detail
            }
            .frame(minWidth: 900, minHeight: 600)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        presentImporter()
                    } label: {
                        Label("导入 PDF", systemImage: "plus")
                    }
                    .help("导入 PDF")
                    .disabled(libraryStore.persistenceDisabled)

                    if libraryStore.selectedPaper != nil {
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
                    get: { libraryStore.presentedError != nil },
                    set: { if !$0 { libraryStore.presentedError = nil } }
                )
            ) {
                Button("好", role: .cancel) {
                    libraryStore.presentedError = nil
                }
            } message: {
                Text(libraryStore.presentedError ?? "发生未知错误。")
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
                    settings: appSettings
                )
            }
            .translationTask(translationController.configuration) { session in
                await translationController.perform(
                    using: SystemTranslationPerformer(session: session)
                )
            }

            KeyboardCommandMonitor(
                focusLibrarySearch: { searchFieldFocused = true },
                beginTitleEdit: beginInlineTitleEdit
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 文献列表

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            librarySearchField
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            List(selection: selection) {
                ForEach(filteredPapers) { paper in
                    PaperRow(
                        paper: paper,
                        isUnavailable: libraryStore.unavailablePaperIDs.contains(paper.id),
                        isEditingTitle: inlineTitleEditID == paper.id,
                        titleDraft: $inlineTitleDraft,
                        titleFieldFocused: $inlineTitleFieldFocused,
                        commitTitle: commitActiveInlineTitleEdit,
                        cancelTitle: cancelInlineTitleEdit
                    )
                    .tag(paper.id)
                    .help(paper.originalFileName)
                    .contextMenu {
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
                            removePaper(paper.id)
                        }
                        .disabled(libraryStore.persistenceDisabled)
                    }
                }
            }
            .overlay {
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
                        description: Text("点击工具栏的加号，或把 PDF 拖入窗口。")
                    )
                } else if filteredPapers.isEmpty {
                    ContentUnavailableView(
                        "无匹配文献",
                        systemImage: "magnifyingglass",
                        description: Text("试试其他标题、作者或文件名关键词。")
                    )
                }
            }
        }
        .navigationTitle("文献")
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
            if let activeAccess {
                PDFReaderView(
                    documentURL: activeAccess.url,
                    initialPageIndex: paper.lastPageIndex,
                    controller: pdfController,
                    onPageChanged: { pageIndex in
                        libraryStore.updatePageIndex(pageIndex, for: paper.id)
                    },
                    onSelectionChanged: { event in
                        translationController.receiveSelection(
                            event,
                            paperID: paper.id,
                            paperName: paper.title,
                            automaticTranslation: appSettings.automaticTranslation,
                            targetLanguage: appSettings.targetLanguage,
                            sourceLanguage: appSettings.sourceLanguage
                        )
                    },
                    onError: { message in
                        documentError = message
                    }
                )
                .id(paper.id)
                .overlay {
                    if let documentError {
                        DocumentErrorView(message: documentError)
                    }
                }
            } else {
                UnavailablePaperView(paperName: paper.title) {
                    presentRelinker(for: paper.id)
                }
            }
        } else {
            ContentUnavailableView(
                "选择一篇论文",
                systemImage: "doc.richtext",
                description: Text("导入或从左侧选择 PDF 开始阅读。")
            )
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
        documentError = nil
        activeAccess = libraryStore.selectedPaperID.flatMap {
            libraryStore.resolveFile(for: $0)
        }
    }

    private func removePaper(_ id: UUID) {
        translationController.paperRemoved(id)
        if libraryStore.selectedPaperID == id {
            activeAccess = nil
        }
        libraryStore.removePaper(id: id)
        openSelectedPaper()
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
            }
            secondaryLine
        }
        .padding(.vertical, 3)
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
    let beginTitleEdit: () -> Bool

    func makeNSView(context: Context) -> KeyboardCommandMonitoringView {
        KeyboardCommandMonitoringView(
            focusLibrarySearch: focusLibrarySearch,
            beginTitleEdit: beginTitleEdit
        )
    }

    func updateNSView(_ nsView: KeyboardCommandMonitoringView, context: Context) {
        nsView.focusLibrarySearch = focusLibrarySearch
        nsView.beginTitleEdit = beginTitleEdit
    }

    static func dismantleNSView(_ nsView: KeyboardCommandMonitoringView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class KeyboardCommandMonitoringView: NSView {
    var focusLibrarySearch: () -> Void
    var beginTitleEdit: () -> Bool
    private var eventMonitor: Any?

    init(
        focusLibrarySearch: @escaping () -> Void,
        beginTitleEdit: @escaping () -> Bool
    ) {
        self.focusLibrarySearch = focusLibrarySearch
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

        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            focusLibrarySearch()
            return nil
        }

        let isReturn = event.keyCode == 36 || event.keyCode == 76
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
