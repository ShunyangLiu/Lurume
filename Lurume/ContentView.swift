import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var translationController: TranslationController
    @StateObject private var pdfController = PDFReaderController()
    @State private var isImporterPresented = false
    @State private var isRelinkerPresented = false
    @State private var relinkingPaperID: UUID?
    @State private var activeAccess: SecurityScopedAccess?
    @State private var documentError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selection: Binding<UUID?> {
        Binding(
            get: { libraryStore.selectedPaperID },
            set: { libraryStore.selectPaper(id: $0) }
        )
    }

    var body: some View {
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
                    isImporterPresented = true
                } label: {
                    Label("导入 PDF", systemImage: "plus")
                }
                .help("导入 PDF")

                if libraryStore.selectedPaper != nil {
                    PDFToolbar(controller: pdfController)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .fileImporter(
            isPresented: $isRelinkerPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleRelink
        )
        .dropDestination(for: URL.self) { urls, _ in
            let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfURLs.isEmpty else { return false }
            libraryStore.importPDFs(at: pdfURLs)
            return true
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
        .onChange(of: libraryStore.selectedPaperID, initial: true) {
            openSelectedPaper()
        }
        .onChange(of: appSettings.automaticTranslation) {
            if !appSettings.automaticTranslation {
                translationController.cancelPendingAutomaticTranslation()
            }
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
    }

    private var librarySidebar: some View {
        List(selection: selection) {
            ForEach(libraryStore.papers) { paper in
                PaperRow(
                    paper: paper,
                    isUnavailable: libraryStore.unavailablePaperIDs.contains(paper.id)
                )
                .tag(paper.id)
                .contextMenu {
                    if libraryStore.unavailablePaperIDs.contains(paper.id) {
                        Button("重新定位…") {
                            presentRelinker(for: paper.id)
                        }
                    }
                    Button("移除引用", role: .destructive) {
                        removePaper(paper.id)
                    }
                }
            }
        }
        .overlay {
            if libraryStore.papers.isEmpty {
                ContentUnavailableView(
                    "尚未导入论文",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("点击工具栏的加号，或把 PDF 拖入窗口。")
                )
            }
        }
        .navigationTitle("文献")
    }

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
                            paperName: paper.displayName,
                            automaticTranslation: appSettings.automaticTranslation,
                            targetLanguage: appSettings.targetLanguage
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
                UnavailablePaperView(paperName: paper.displayName) {
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
        isRelinkerPresented = true
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: isUnavailable ? "exclamationmark.triangle" : "doc.richtext")
                    .foregroundStyle(isUnavailable ? .orange : .secondary)
                Text(paper.displayName)
                    .lineLimit(2)
            }
            Text(isUnavailable ? "文件不可用" : readingStatus)
                .font(.caption)
                .foregroundStyle(isUnavailable ? .orange : .secondary)
        }
        .padding(.vertical, 3)
    }

    private var readingStatus: String {
        if let lastOpenedAt = paper.lastOpenedAt {
            return "第 \(paper.lastPageIndex + 1) 页 · \(lastOpenedAt.formatted(.relative(presentation: .named)))"
        }
        return "尚未阅读"
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
