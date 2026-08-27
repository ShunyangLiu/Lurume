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

enum PDFSearchViewport {
    static func centeredScrollOrigin(
        targetCenter: CGPoint,
        viewportSize: CGSize,
        documentBounds: CGRect
    ) -> CGPoint {
        let maximumX = max(documentBounds.minX, documentBounds.maxX - viewportSize.width)
        let maximumY = max(documentBounds.minY, documentBounds.maxY - viewportSize.height)
        return CGPoint(
            x: min(max(targetCenter.x - viewportSize.width / 2, documentBounds.minX), maximumX),
            y: min(max(targetCenter.y - viewportSize.height / 2, documentBounds.minY), maximumY)
        )
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
    @Published var currentHighlightID: UUID?
    @Published private(set) var skippedHighlightFragmentCount = 0

    weak var pdfView: PDFView?
    private var searchResults: [PDFSelection] = []
    private var renderedHighlights: [HighlightRecord] = []
    private var highlightAnnotations: [PDFAnnotation] = []
    private var highlightIDByAnnotation: [ObjectIdentifier: UUID] = [:]

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
        removeRenderedHighlights()
        self.pdfView = pdfView
        renderedHighlights = []
        skippedHighlightFragmentCount = 0
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

    func makeHighlightCandidate(paperID: UUID) -> HighlightRecord? {
        guard let pdfView,
              let document = pdfView.document,
              let selection = pdfView.currentSelection,
              !isCurrentSearchSelection(selection),
              let rawText = selection.string,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var pageOrder: [Int] = []
        var rectsByPage: [Int: [HighlightRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let pageIndex = document.index(for: page)
                guard pageIndex >= 0,
                      let rect = HighlightRect(cgRect: line.bounds(for: page)) else {
                    continue
                }
                if rectsByPage[pageIndex] == nil {
                    pageOrder.append(pageIndex)
                }
                rectsByPage[pageIndex, default: []].append(rect)
            }
        }

        let segments = pageOrder.compactMap { pageIndex in
            HighlightSegment(pageIndex: pageIndex, rects: rectsByPage[pageIndex] ?? [])
        }
        return HighlightRecord(
            paperID: paperID,
            rawText: rawText,
            segments: segments
        )
    }

    func currentSelectionMatchesHighlight(paperID: UUID) -> Bool {
        guard let candidate = makeHighlightCandidate(paperID: paperID) else { return false }
        return renderedHighlights.contains { $0.approximatelyMatches(candidate) }
    }

    func clearCurrentSelection() {
        pdfView?.clearSelection()
    }

    func renderHighlights(_ highlights: [HighlightRecord]) {
        guard let pdfView, let document = pdfView.document else { return }
        guard renderedHighlights != highlights else { return }
        removeRenderedHighlights()
        renderedHighlights = highlights
        var skippedFragmentCount = 0

        for highlight in highlights {
            for segment in highlight.segments {
                guard let page = document.page(at: segment.pageIndex) else {
                    skippedFragmentCount += segment.rects.count
                    continue
                }
                let pageBounds = page.bounds(for: .cropBox)
                for storedRect in segment.rects {
                    let rect = storedRect.cgRect
                    guard rect.intersects(pageBounds),
                          !rect.intersection(pageBounds).isEmpty else {
                        skippedFragmentCount += 1
                        continue
                    }
                    let annotation = PDFAnnotation(
                        bounds: rect,
                        forType: .highlight,
                        withProperties: nil
                    )
                    annotation.color = .systemYellow.withAlphaComponent(0.45)
                    annotation.quadrilateralPoints = [
                        NSValue(point: NSPoint(x: 0, y: rect.height)),
                        NSValue(point: NSPoint(x: rect.width, y: rect.height)),
                        NSValue(point: NSPoint(x: 0, y: 0)),
                        NSValue(point: NSPoint(x: rect.width, y: 0)),
                    ]
                    page.addAnnotation(annotation)
                    highlightAnnotations.append(annotation)
                    highlightIDByAnnotation[ObjectIdentifier(annotation)] = highlight.id
                }
            }
        }
        skippedHighlightFragmentCount = skippedFragmentCount

        if let currentHighlightID,
           !highlights.contains(where: { $0.id == currentHighlightID }) {
            self.currentHighlightID = nil
        }
    }

    func highlightID(at viewPoint: CGPoint) -> UUID? {
        guard let pdfView,
              let page = pdfView.page(for: viewPoint, nearest: false) else {
            return nil
        }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        for annotation in page.annotations.reversed()
        where annotation.bounds.contains(pagePoint) {
            if let id = highlightIDByAnnotation[ObjectIdentifier(annotation)] {
                return id
            }
        }
        return nil
    }

    func activateHighlight(_ highlight: HighlightRecord, translate: Bool) {
        guard let pdfView,
              let selection = selection(for: highlight) else {
            return
        }
        currentHighlightID = highlight.id
        if translate {
            pdfView.setCurrentSelection(selection, animate: true)
        }
        pdfView.go(to: selection)
        centerSelection(selection, in: pdfView)
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
        centerSelection(currentResult, in: pdfView)
    }

    private func selection(for highlight: HighlightRecord) -> PDFSelection? {
        guard let document = pdfView?.document else { return nil }
        var selections: [PDFSelection] = []
        for segment in highlight.segments {
            guard let page = document.page(at: segment.pageIndex) else { continue }
            for rect in segment.rects {
                if let selection = page.selection(for: rect.cgRect.insetBy(dx: -0.5, dy: -0.5)) {
                    selections.append(selection)
                }
            }
        }
        guard !selections.isEmpty else { return nil }
        let combined = PDFSelection(document: document)
        combined.add(selections)
        return combined
    }

    private func centerSelection(_ selection: PDFSelection, in pdfView: PDFView) {
        guard let page = selection.pages.first,
              let documentView = pdfView.documentView,
              let scrollView = documentView.enclosingScrollView else {
            return
        }

        pdfView.layoutSubtreeIfNeeded()
        let pageRect = selection.bounds(for: page)
        let pdfViewRect = pdfView.convert(pageRect, from: page)
        let documentRect = pdfView.convert(pdfViewRect, to: documentView)
        let clipView = scrollView.contentView
        let origin = PDFSearchViewport.centeredScrollOrigin(
            targetCenter: CGPoint(x: documentRect.midX, y: documentRect.midY),
            viewportSize: clipView.bounds.size,
            documentBounds: documentView.bounds
        )
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func removeRenderedHighlights() {
        for annotation in highlightAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        highlightAnnotations = []
        highlightIDByAnnotation = [:]
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
    let paperID: UUID
    let documentURL: URL
    let initialPageIndex: Int
    let controller: PDFReaderController
    let highlights: [HighlightRecord]
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (PDFSelectionEvent?) -> Void
    let onToggleHighlight: () -> Void
    let onHighlightActivated: (UUID) -> Void
    let onDeleteHighlight: (UUID) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = HighlightPDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        context.coordinator.observe(pdfView)
        context.coordinator.installHighlightClickRecognizer(on: pdfView)
        controller.attach(pdfView)
        configureHighlightActions(on: pdfView)
        loadDocument(in: pdfView, coordinator: context.coordinator)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self
        controller.attach(pdfView)
        configureHighlightActions(on: pdfView)
        if context.coordinator.loadedURL != documentURL {
            loadDocument(in: pdfView, coordinator: context.coordinator)
        }
        controller.renderHighlights(highlights)
    }

    private func configureHighlightActions(on pdfView: PDFView) {
        guard let highlightView = pdfView as? HighlightPDFView else { return }
        highlightView.highlightIDAtEvent = { [weak highlightView, weak controller] event in
            guard let highlightView else { return nil }
            let point = highlightView.convert(event.locationInWindow, from: nil)
            return controller?.highlightID(at: point)
        }
        highlightView.toggleHighlightTitle = { [weak controller] in
            guard let controller,
                  controller.makeHighlightCandidate(paperID: paperID) != nil else {
                return nil
            }
            return controller.currentSelectionMatchesHighlight(paperID: paperID)
                ? "取消高亮"
                : "添加高亮"
        }
        highlightView.onToggleHighlight = onToggleHighlight
        highlightView.onDeleteHighlight = onDeleteHighlight
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
        controller.renderHighlights(highlights)
        coordinator.scheduleStateUpdate()
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate, @unchecked Sendable {
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

        @MainActor
        func installHighlightClickRecognizer(on pdfView: PDFView) {
            let recognizer = NSClickGestureRecognizer(
                target: self,
                action: #selector(highlightClicked(_:))
            )
            recognizer.buttonMask = 0x1
            recognizer.numberOfClicksRequired = 1
            // 只观察高亮上的点击；普通点击必须完整交还 PDFKit，
            // 否则它无法按系统行为清除现有蓝色选区。
            recognizer.delaysPrimaryMouseButtonEvents = false
            recognizer.delegate = self
            pdfView.addGestureRecognizer(recognizer)
        }

        @MainActor
        @objc private func highlightClicked(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended,
                  let pdfView = recognizer.view as? PDFView else {
                return
            }
            let point = recognizer.location(in: pdfView)
            if let id = parent.controller.highlightID(at: point) {
                parent.onHighlightActivated(id)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard let pdfView = gestureRecognizer.view as? PDFView else { return false }
            let point = pdfView.convert(event.locationInWindow, from: nil)
            return parent.controller.highlightID(at: point) != nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
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
