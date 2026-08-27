import PDFKit
import SwiftUI

struct PDFSelectionEvent: Equatable, Sendable {
    let rawText: String
    let pageIndex: Int
    let languageSample: String

    init(rawText: String, pageIndex: Int, languageSample: String? = nil) {
        self.rawText = rawText
        self.pageIndex = pageIndex
        self.languageSample = languageSample ?? rawText
    }
}

@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var pageCount = 0
    @Published var searchText = ""
    @Published private(set) var searchResultCount = 0
    @Published private(set) var currentSearchResultIndex: Int?
    @Published private(set) var activeSearchQuery: String?

    weak var pdfView: PDFView?
    private var searchResults: [PDFSelection] = []

    var pageCountLabel: String {
        guard pageCount > 0 else { return "/ —" }
        return "/ \(pageCount)"
    }

    var searchResultLabel: String? {
        guard activeSearchQuery != nil else { return nil }
        guard let currentSearchResultIndex else { return "0 / 0" }
        return "\(currentSearchResultIndex + 1) / \(searchResultCount)"
    }

    var canNavigateSearchResults: Bool {
        !searchResults.isEmpty
    }

    func attach(_ pdfView: PDFView) {
        guard self.pdfView !== pdfView else { return }
        self.pdfView = pdfView
    }

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func previousPage() { pdfView?.goToPreviousPage(nil) }
    func nextPage() { pdfView?.goToNextPage(nil) }

    func go(toOneBasedPage page: Int) {
        guard let document = pdfView?.document, document.pageCount > 0 else { return }
        let index = min(max(page - 1, 0), document.pageCount - 1)
        guard let destinationPage = document.page(at: index) else { return }
        pdfView?.go(to: destinationPage)
    }

    func search() {
        guard let pdfView, let document = pdfView.document else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearchResults()
            return
        }
        guard activeSearchQuery != query else { return }

        clearSearchResults()
        activeSearchQuery = query
        searchResults = document.findString(query, withOptions: .caseInsensitive)
        searchResultCount = searchResults.count
        if !searchResults.isEmpty {
            showSearchResult(at: 0)
        }
    }

    func searchTextDidChange() {
        guard let activeSearchQuery else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != activeSearchQuery {
            clearSearchResults()
        }
    }

    func previousSearchResult() {
        if refreshSearchIfNeeded() {
            if !searchResults.isEmpty {
                showSearchResult(at: searchResults.count - 1)
            }
            return
        }
        moveSearchResult(by: -1)
    }

    func nextSearchResult() {
        if refreshSearchIfNeeded() {
            return
        }
        moveSearchResult(by: 1)
    }

    func clearSearchResults() {
        let shouldClearCurrentSelection = isCurrentSearchSelection(pdfView?.currentSelection)
        searchResults = []
        searchResultCount = 0
        currentSearchResultIndex = nil
        activeSearchQuery = nil
        pdfView?.highlightedSelections = nil
        if shouldClearCurrentSelection {
            pdfView?.clearSelection()
        }
    }

    func isCurrentSearchSelection(_ selection: PDFSelection?) -> Bool {
        guard let selection,
              let currentSearchResultIndex,
              searchResults.indices.contains(currentSearchResultIndex) else {
            return false
        }
        return selection === searchResults[currentSearchResultIndex]
    }

    private func moveSearchResult(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let current = currentSearchResultIndex ?? 0
        let count = searchResults.count
        let destination = (current + offset + count) % count
        showSearchResult(at: destination)
    }

    private func refreshSearchIfNeeded() -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeSearchQuery != query else { return false }
        search()
        return true
    }

    private func showSearchResult(at index: Int) {
        guard searchResults.indices.contains(index), let pdfView else { return }
        currentSearchResultIndex = index
        for (resultIndex, selection) in searchResults.enumerated() {
            selection.color = resultIndex == index
                ? .selectedTextBackgroundColor
                : .systemYellow.withAlphaComponent(0.5)
        }
        let currentResult = searchResults[index]
        let otherResults = searchResults.enumerated().compactMap { resultIndex, selection in
            resultIndex == index ? nil : selection
        }
        pdfView.highlightedSelections = otherResults.isEmpty ? nil : otherResults
        pdfView.setCurrentSelection(currentResult, animate: true)
        pdfView.go(to: currentResult)
    }

    func updatePageState() {
        guard let pdfView, let document = pdfView.document else {
            if currentPageIndex != 0 {
                currentPageIndex = 0
            }
            if pageCount != 0 {
                pageCount = 0
            }
            return
        }

        if pageCount != document.pageCount {
            pageCount = document.pageCount
        }
        if let page = pdfView.currentPage {
            let newPageIndex = max(0, document.index(for: page))
            if currentPageIndex != newPageIndex {
                currentPageIndex = newPageIndex
            }
        }
    }
}

struct PDFReaderView: NSViewRepresentable {
    let documentURL: URL
    let initialPageIndex: Int
    let controller: PDFReaderController
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (PDFSelectionEvent?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        context.coordinator.observe(pdfView)
        controller.attach(pdfView)
        loadDocument(in: pdfView, coordinator: context.coordinator)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self
        controller.attach(pdfView)
        if context.coordinator.loadedURL != documentURL {
            loadDocument(in: pdfView, coordinator: context.coordinator)
        }
    }

    private func loadDocument(in pdfView: PDFView, coordinator: Coordinator) {
        coordinator.loadedURL = documentURL
        guard let document = PDFDocument(url: documentURL) else {
            pdfView.document = nil
            coordinator.scheduleStateUpdate(error: "文件已损坏，或不是有效的 PDF。")
            return
        }
        guard !document.isLocked else {
            pdfView.document = nil
            coordinator.scheduleStateUpdate(error: "这份 PDF 受密码保护，P0 暂不支持解锁。")
            return
        }

        pdfView.document = document
        let index = min(max(initialPageIndex, 0), max(document.pageCount - 1, 0))
        if let page = document.page(at: index) {
            pdfView.go(to: page)
        }
        coordinator.scheduleStateUpdate()
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        var parent: PDFReaderView
        var loadedURL: URL?
        private var observationTokens: [NSObjectProtocol] = []

        init(parent: PDFReaderView) {
            self.parent = parent
        }

        deinit {
            observationTokens.forEach(NotificationCenter.default.removeObserver)
        }

        func observe(_ pdfView: PDFView) {
            let center = NotificationCenter.default
            observationTokens.append(
                center.addObserver(
                    forName: .PDFViewPageChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.parent.controller.updatePageState()
                        self.parent.onPageChanged(self.parent.controller.currentPageIndex)
                    }
                }
            )
            observationTokens.append(
                center.addObserver(
                    forName: .PDFViewSelectionChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self, weak pdfView] _ in
                    Task { @MainActor [weak self, weak pdfView] in
                        guard let self, let pdfView else { return }
                        guard !self.parent.controller.isCurrentSearchSelection(
                            pdfView.currentSelection
                        ) else { return }
                        self.parent.onSelectionChanged(self.selectionEvent(from: pdfView))
                    }
                }
            )
        }

        func scheduleStateUpdate(error: String? = nil) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.parent.controller.updatePageState()
                if let error {
                    self.parent.onError(error)
                } else {
                    self.parent.onPageChanged(self.parent.controller.currentPageIndex)
                }
            }
        }

        @MainActor
        private func selectionEvent(from pdfView: PDFView) -> PDFSelectionEvent? {
            guard let selection = pdfView.currentSelection,
                  let rawText = selection.string,
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let page = selection.pages.first,
                  let document = pdfView.document else {
                return nil
            }
            return PDFSelectionEvent(
                rawText: rawText,
                pageIndex: max(0, document.index(for: page)),
                languageSample: String((page.string ?? rawText).prefix(2_000))
            )
        }
    }
}

struct PDFToolbar: View {
    @ObservedObject var controller: PDFReaderController
    @State private var requestedPage = 1

    var body: some View {
        Group {
            Button(action: controller.previousPage) {
                Label("上一页", systemImage: "chevron.left")
            }
            .help("上一页")

            HStack(spacing: 4) {
                TextField("页码", value: $requestedPage, format: .number)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        controller.go(toOneBasedPage: requestedPage)
                    }

                Text(controller.pageCountLabel)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()

            Button(action: controller.nextPage) {
                Label("下一页", systemImage: "chevron.right")
            }
            .help("下一页")

            Button(action: controller.zoomOut) {
                Label("缩小", systemImage: "minus.magnifyingglass")
            }
            .help("缩小")

            Button(action: controller.zoomIn) {
                Label("放大", systemImage: "plus.magnifyingglass")
            }
            .help("放大")
        }
        .onChange(of: controller.currentPageIndex, initial: true) {
            requestedPage = controller.currentPageIndex + 1
        }
    }
}
