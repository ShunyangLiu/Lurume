import PDFKit
import SwiftUI

// NotificationCenter delivers these on OperationQueue.main. PDFKit selections are only
// inspected on the main actor; the wrapper bridges that documented queue boundary.
private struct PDFSearchMatch: @unchecked Sendable {
    let selection: PDFSelection
    let documentID: ObjectIdentifier
}

private final class PDFSearchObservations: @unchecked Sendable {
    let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

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
    @Published private(set) var document: PDFDocument?
    @Published var searchText = ""
    @Published private(set) var searchResultCount = 0
    @Published private(set) var currentSearchResultIndex: Int?
    @Published private(set) var activeSearchQuery: String?
    @Published private(set) var isSearching = false
    @Published var currentHighlightID: UUID? {
        didSet {
            guard currentHighlightID != oldValue else { return }
            if let noteEditorSession,
               noteEditorSession.highlightID != currentHighlightID {
                noteEditorSession.close()
            }
            refreshHighlightAdornments()
        }
    }
    @Published private(set) var skippedHighlightFragmentCount = 0

    weak var pdfView: PDFView?
    private var searchResults: [PDFSelection] = []
    private var searchGeneration = 0
    private var searchObservers: PDFSearchObservations?
    private weak var searchingDocument: PDFDocument?
    private var searchPublishTask: Task<Void, Never>?
    private var selectsLastResultWhenSearchEnds = false
    private var renderedHighlights: [HighlightRecord] = []
    private weak var renderedHighlightDocument: PDFDocument?
    private var highlightAnnotations: [PDFAnnotation] = []
    private var highlightIDByAnnotation: [ObjectIdentifier: UUID] = [:]
    private var selectionAnnotations: [PDFAnnotation] = []
    private var noteMarkerAnnotations: [PDFAnnotation] = []
    private var noteMarkerIDByAnnotation: [ObjectIdentifier: UUID] = [:]
    private var noteMarkerDragOffsets: [UUID: CGPoint] = [:]
    private var hoveredHighlightID: UUID?
    private var noteEditingEnabled = true
    private var noteEditorSession: HighlightNoteEditorSession?
    private var noteEditorInitialViewport: CGRect?
    private let noteDraftStore: HighlightNoteDraftStore
    @Published var noteSaveWarning: String?

    init(noteDraftStore: HighlightNoteDraftStore = HighlightNoteDraftStore()) {
        self.noteDraftStore = noteDraftStore
        if noteDraftStore.loadError != nil {
            noteSaveWarning = "恢复草稿文件无法读取，原文件已保留。请先备份应用数据。"
        }
    }

    /// Called before ordinary termination and before an updater-driven restart.
    func prepareNotesForExit() -> Bool {
        closeNoteEditor()
        // Recovered drafts must be reviewed in their editor, not silently applied on exit.
        guard !noteDraftStore.drafts.isEmpty else { return true }
        let durable = noteDraftStore.persist()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "还有 \(noteDraftStore.drafts.count) 条笔记草稿未保存"
        alert.informativeText = durable
            ? "恢复草稿已保存到本机。继续退出后，下次打开对应笔记可以恢复并核对。"
            : "笔记和恢复草稿均未能写入磁盘。继续退出会丢失尚未保存的内容，请先返回复制备份。"
        alert.addButton(withTitle: "返回检查")
        alert.addButton(withTitle: durable ? "保留草稿并退出" : "丢弃草稿并退出")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func discardNoteDrafts(for highlightIDs: Set<UUID>) {
        var removed = false
        for id in highlightIDs { removed = noteDraftStore.remove(id) || removed }
        guard removed else { return }
        if !noteDraftStore.persist() {
            noteSaveWarning = "旧恢复草稿未能清理，请检查应用数据目录的可写状态。"
        }
    }

    var pageCountLabel: String {
        guard pageCount > 0 else { return "/ —" }
        return "/ \(pageCount)"
    }

    var searchResultLabel: String? {
        guard activeSearchQuery != nil else { return nil }
        let progress = isSearching ? " · 搜索中" : ""
        return "\(currentSearchResultIndex.map { $0 + 1 } ?? 0) / \(searchResultCount)\(progress)"
    }

    var canNavigateSearchResults: Bool {
        !searchResults.isEmpty
    }

    func attach(_ pdfView: PDFView) {
        guard self.pdfView !== pdfView else { return }
        clearSearchResults()
        removeRenderedHighlights()
        self.pdfView = pdfView
        if document !== pdfView.document {
            document = pdfView.document
        }
        renderedHighlights = []
        renderedHighlightDocument = nil
        if skippedHighlightFragmentCount != 0 {
            skippedHighlightFragmentCount = 0
        }
    }

    func detach() {
        closeNoteEditor()
        clearSearchResults()
        removeRenderedHighlights()
        pdfView = nil
        if document != nil {
            document = nil
        }
        renderedHighlights = []
        renderedHighlightDocument = nil
        if currentHighlightID != nil {
            currentHighlightID = nil
        }
        if skippedHighlightFragmentCount != 0 {
            skippedHighlightFragmentCount = 0
        }
        if currentPageIndex != 0 {
            currentPageIndex = 0
        }
        if pageCount != 0 {
            pageCount = 0
        }
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

    func go(to destination: PDFDestination) {
        guard destination.page?.document === pdfView?.document else { return }
        pdfView?.go(to: destination)
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
        isSearching = true
        searchingDocument = document
        let generation = searchGeneration
        let center = NotificationCenter.default
        searchObservers = PDFSearchObservations([
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) {
                [weak self] notification in
                guard let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
                      let document = notification.object as? PDFDocument else { return }
                let match = PDFSearchMatch(selection: selection, documentID: ObjectIdentifier(document))
                MainActor.assumeIsolated {
                    guard let self, self.searchGeneration == generation,
                          let currentDocument = self.pdfView?.document,
                          ObjectIdentifier(currentDocument) == match.documentID else { return }
                    self.searchResults.append(match.selection)
                    self.scheduleSearchPublication()
                }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.searchGeneration == generation else { return }
                    self.isSearching = false
                    self.publishSearchResults()
                }
            }
        ])
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    private func scheduleSearchPublication() {
        guard searchPublishTask == nil else { return }
        searchPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.publishSearchResults()
        }
    }

    private func publishSearchResults() {
        searchPublishTask?.cancel()
        searchPublishTask = nil
        searchResultCount = searchResults.count
        if !isSearching, selectsLastResultWhenSearchEnds, !searchResults.isEmpty {
            selectsLastResultWhenSearchEnds = false
            showSearchResult(at: searchResults.count - 1)
        } else if currentSearchResultIndex == nil, !searchResults.isEmpty, !selectsLastResultWhenSearchEnds {
            showSearchResult(at: 0)
        } else if let index = currentSearchResultIndex {
            updateSearchHighlights(currentIndex: index)
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
            if isSearching {
                selectsLastResultWhenSearchEnds = true
            } else if !searchResults.isEmpty {
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
        selectsLastResultWhenSearchEnds = false
        searchGeneration += 1
        searchPublishTask?.cancel()
        searchPublishTask = nil
        searchObservers = nil
        searchingDocument?.cancelFindString()
        searchingDocument = nil
        isSearching = false
        let shouldClearCurrentSelection = isCurrentSearchSelection(pdfView?.currentSelection)
        searchResults = []
        if searchResultCount != 0 {
            searchResultCount = 0
        }
        if currentSearchResultIndex != nil {
            currentSearchResultIndex = nil
        }
        if activeSearchQuery != nil {
            activeSearchQuery = nil
        }
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

    func currentSelectionOverlapsHighlight(paperID: UUID) -> Bool {
        guard let candidate = makeHighlightCandidate(paperID: paperID) else { return false }
        return renderedHighlights.contains { $0.overlaps(candidate) }
    }

    func clearCurrentSelection() {
        pdfView?.clearSelection()
    }

    func renderHighlights(
        _ highlights: [HighlightRecord],
        noteEditingEnabled: Bool = true
    ) {
        guard let pdfView, let document = pdfView.document else { return }
        guard renderedHighlightDocument !== document
                || renderedHighlights != highlights
                || self.noteEditingEnabled != noteEditingEnabled else {
            return
        }
        removeRenderedHighlights()
        renderedHighlightDocument = document
        renderedHighlights = highlights
        self.noteEditingEnabled = noteEditingEnabled
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
                    annotation.isReadOnly = true
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
        refreshHighlightAdornments()
        if skippedHighlightFragmentCount != skippedFragmentCount {
            skippedHighlightFragmentCount = skippedFragmentCount
        }

        if let currentHighlightID,
           !highlights.contains(where: { $0.id == currentHighlightID }) {
            self.currentHighlightID = nil
        }
    }

    func setHoveredHighlightID(_ id: UUID?) {
        guard hoveredHighlightID != id else { return }
        hoveredHighlightID = id
        refreshHighlightAdornments()
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

    func noteMarkerID(at viewPoint: CGPoint) -> UUID? {
        guard let pdfView,
              let page = pdfView.page(for: viewPoint, nearest: false) else {
            return nil
        }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        for annotation in page.annotations.reversed()
        where annotation.bounds.insetBy(dx: -3, dy: -3).contains(pagePoint) {
            if let id = noteMarkerIDByAnnotation[ObjectIdentifier(annotation)] {
                return id
            }
        }
        return nil
    }

    func interactiveHighlightID(at viewPoint: CGPoint) -> UUID? {
        noteMarkerID(at: viewPoint) ?? highlightID(at: viewPoint)
    }

    func noteMarkerAnchorRect(for id: UUID) -> CGRect? {
        guard let pdfView,
              let annotation = noteMarkerAnnotations.first(where: {
                  noteMarkerIDByAnnotation[ObjectIdentifier($0)] == id
              }),
              let page = annotation.page else {
            return nil
        }
        return pdfView.convert(annotation.bounds, from: page)
    }

    func moveNoteMarker(
        id: UUID,
        from startViewPoint: CGPoint,
        to viewPoint: CGPoint,
        finished: Bool
    ) -> HighlightPoint? {
        guard noteEditingEnabled,
              let pdfView,
              let annotation = noteMarkerAnnotations.first(where: {
                  noteMarkerIDByAnnotation[ObjectIdentifier($0)] == id
              }),
              let page = annotation.page else {
            noteMarkerDragOffsets.removeValue(forKey: id)
            return nil
        }
        if noteMarkerDragOffsets[id] == nil {
            let currentRect = pdfView.convert(annotation.bounds, from: page)
            noteMarkerDragOffsets[id] = CGPoint(
                x: startViewPoint.x - currentRect.midX,
                y: startViewPoint.y - currentRect.midY
            )
            closeNoteEditor()
        }
        let offset = noteMarkerDragOffsets[id] ?? .zero
        let targetViewCenter = CGPoint(
            x: viewPoint.x - offset.x,
            y: viewPoint.y - offset.y
        )
        let targetPageCenter = pdfView.convert(targetViewCenter, to: page)
        let pageBounds = page.bounds(for: .cropBox)
        let halfWidth = annotation.bounds.width / 2
        let halfHeight = annotation.bounds.height / 2
        let clampedCenter = CGPoint(
            x: min(max(targetPageCenter.x, pageBounds.minX + halfWidth), pageBounds.maxX - halfWidth),
            y: min(max(targetPageCenter.y, pageBounds.minY + halfHeight), pageBounds.maxY - halfHeight)
        )
        annotation.bounds.origin = CGPoint(
            x: clampedCenter.x - halfWidth,
            y: clampedCenter.y - halfHeight
        )
        if finished {
            noteMarkerDragOffsets.removeValue(forKey: id)
        }
        return HighlightPoint(cgPoint: clampedCenter)
    }

    func presentNoteEditor(
        for highlight: HighlightRecord,
        readOnly: Bool,
        save: @escaping (String?) -> Bool
    ) {
        guard let pdfView,
              let documentView = pdfView.documentView else {
            return
        }
        currentHighlightID = highlight.id
        if noteEditorSession?.highlightID == highlight.id,
           noteEditorSession?.isShown == true {
            return
        }
        closeNoteEditor()
        guard let pdfViewRect = noteMarkerAnchorRect(for: highlight.id) else { return }
        let documentRect = pdfView.convert(pdfViewRect, to: documentView)
        let recoveredDraft = noteDraftStore.drafts[highlight.id]
        let initialText = recoveredDraft ?? highlight.noteText ?? ""
        let model = HighlightNoteDraftModel(
            text: initialText,
            persistedText: highlight.noteText ?? "",
            readOnly: readOnly,
            save: save,
            onDraftChanged: { [weak self] text in
                self?.noteDraftStore.set(text, for: highlight.id)
            },
            onSaveSucceeded: { [weak self] in
                guard let self else { return }
                guard self.noteDraftStore.remove(highlight.id) else { return }
                if !self.noteDraftStore.persist() {
                    self.noteSaveWarning = "笔记已保存，但旧恢复草稿未能清理，请先备份应用数据。"
                }
            },
            onSaveFailed: { [weak self] in
                guard let self else { return "无法保存笔记。" }
                let durable = self.noteDraftStore.persist()
                let message = durable ? "笔记保存失败，已保留可恢复草稿。"
                    : "笔记和恢复草稿均保存失败，请勿退出应用，先复制笔记备份。"
                self.noteSaveWarning = message
                return message
            },
            recoveryMessage: recoveredDraft == nil ? nil : "已恢复未保存草稿，请核对后保存；原笔记尚未改动。"
        )
        let session = HighlightNoteEditorSession(
            highlightID: highlight.id,
            anchorRect: documentRect,
            in: documentView,
            model: model
        ) { [weak self] in
            guard let self,
                  self.noteEditorSession?.highlightID == highlight.id else { return }
            self.noteEditorSession = nil
            self.noteEditorInitialViewport = nil
        }
        noteEditorSession = session
        noteEditorInitialViewport = documentView.enclosingScrollView?.contentView.bounds
        session.show()
    }

    func closeNoteEditor() {
        noteEditorSession?.close()
    }

    func viewportDidChange() {
        guard noteEditorSession != nil,
              let initial = noteEditorInitialViewport,
              let current = pdfView?.documentView?.enclosingScrollView?.contentView.bounds else {
            return
        }
        if abs(current.minY - initial.minY) >= max(initial.height, 1)
            || abs(current.minX - initial.minX) >= max(initial.width, 1) {
            closeNoteEditor()
        }
    }

    func activateHighlight(_ highlight: HighlightRecord, translate: Bool) {
        guard let pdfView,
              let selection = selection(for: highlight),
              let targetSelection = terminalSelection(for: highlight) else {
            return
        }
        currentHighlightID = highlight.id
        if translate {
            pdfView.setCurrentSelection(selection, animate: true)
        }
        pdfView.go(to: targetSelection)
        centerSelection(targetSelection, in: pdfView)
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
        selectsLastResultWhenSearchEnds = false
        currentSearchResultIndex = index
        updateSearchHighlights(currentIndex: index)
        let currentResult = searchResults[index]
        pdfView.setCurrentSelection(currentResult, animate: true)
        pdfView.go(to: currentResult)
        centerSelection(currentResult, in: pdfView)
    }

    private func updateSearchHighlights(currentIndex: Int) {
        // Bound PDFKit overlay work for very common terms while retaining every result for navigation.
        var otherResults: [PDFSelection] = []
        for (index, selection) in searchResults.enumerated() where index != currentIndex {
            otherResults.append(selection)
            if otherResults.count == 500 { break }
        }
        for selection in otherResults { selection.color = .systemYellow.withAlphaComponent(0.5) }
        searchResults[currentIndex].color = .selectedTextBackgroundColor
        pdfView?.highlightedSelections = otherResults.isEmpty ? nil : otherResults
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

    private func terminalSelection(for highlight: HighlightRecord) -> PDFSelection? {
        guard let document = pdfView?.document else { return nil }
        for segment in highlight.segments.reversed() {
            guard let page = document.page(at: segment.pageIndex) else { continue }
            for rect in segment.rects.reversed() {
                if let selection = page.selection(for: rect.cgRect.insetBy(dx: -0.5, dy: -0.5)) {
                    return selection
                }
            }
        }
        return nil
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
        removeHighlightAdornments()
        for annotation in highlightAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        highlightAnnotations = []
        highlightIDByAnnotation = [:]
    }

    private func refreshHighlightAdornments() {
        guard let document = pdfView?.document else { return }
        removeHighlightAdornments()

        if let currentHighlightID,
           let current = renderedHighlights.first(where: { $0.id == currentHighlightID }) {
            for segment in current.segments {
                guard let page = document.page(at: segment.pageIndex) else { continue }
                let pageBounds = page.bounds(for: .cropBox)
                for storedRect in segment.rects {
                    let rect = storedRect.cgRect.insetBy(dx: -1.5, dy: -1.5)
                    guard rect.intersects(pageBounds) else { continue }
                    let outline = PDFAnnotation(
                        bounds: rect.intersection(pageBounds),
                        forType: .square,
                        withProperties: nil
                    )
                    outline.isReadOnly = true
                    let border = PDFBorder()
                    border.lineWidth = 1.2
                    border.style = .dashed
                    border.dashPattern = [3, 2]
                    outline.border = border
                    outline.color = .controlAccentColor.withAlphaComponent(0.9)
                    page.addAnnotation(outline)
                    selectionAnnotations.append(outline)
                }
            }
        }

        var occupiedByPage: [Int: [CGRect]] = [:]
        for highlight in renderedHighlights where
            highlight.hasNote
                || noteEditingEnabled
                    && (highlight.id == currentHighlightID
                        || highlight.id == hoveredHighlightID) {
            guard let anchor = markerAnchor(for: highlight, document: document) else { continue }
            let markerRect = markerRect(
                beside: anchor.rect,
                pageBounds: anchor.page.bounds(for: .cropBox),
                occupied: occupiedByPage[anchor.pageIndex, default: []],
                savedPosition: highlight.noteMarkerPosition?.cgPoint
            )
            occupiedByPage[anchor.pageIndex, default: []].append(markerRect)
            let marker = HighlightNoteMarkerAnnotation(
                bounds: markerRect,
                style: highlight.hasNote ? .note : .add
            )
            marker.contents = highlight.hasNote ? "打开高亮笔记" : "添加高亮笔记"
            anchor.page.addAnnotation(marker)
            noteMarkerAnnotations.append(marker)
            noteMarkerIDByAnnotation[ObjectIdentifier(marker)] = highlight.id
        }
    }

    private func removeHighlightAdornments() {
        for annotation in selectionAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        for annotation in noteMarkerAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        selectionAnnotations = []
        noteMarkerAnnotations = []
        noteMarkerIDByAnnotation = [:]
        noteMarkerDragOffsets = [:]
    }

    private func markerAnchor(
        for highlight: HighlightRecord,
        document: PDFDocument
    ) -> (page: PDFPage, pageIndex: Int, rect: CGRect)? {
        for segment in highlight.segments.reversed() {
            guard let page = document.page(at: segment.pageIndex) else { continue }
            for rect in segment.rects.reversed() {
                let pageBounds = page.bounds(for: .cropBox)
                let candidate = rect.cgRect.intersection(pageBounds)
                if !candidate.isEmpty {
                    return (page, segment.pageIndex, candidate)
                }
            }
        }
        return nil
    }

    private func markerRect(
        beside highlightRect: CGRect,
        pageBounds: CGRect,
        occupied: [CGRect],
        savedPosition: CGPoint?
    ) -> CGRect {
        let size = CGSize(width: 16, height: 16)
        if let savedPosition {
            let center = CGPoint(
                x: min(
                    max(savedPosition.x, pageBounds.minX + size.width / 2),
                    pageBounds.maxX - size.width / 2
                ),
                y: min(
                    max(savedPosition.y, pageBounds.minY + size.height / 2),
                    pageBounds.maxY - size.height / 2
                )
            )
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        let gap: CGFloat = 4
        var originX = highlightRect.maxX + gap
        if originX + size.width > pageBounds.maxX {
            originX = highlightRect.minX - gap - size.width
        }
        originX = min(max(originX, pageBounds.minX), pageBounds.maxX - size.width)
        var originY = min(
            max(highlightRect.midY - size.height / 2, pageBounds.minY),
            pageBounds.maxY - size.height
        )
        var candidate = CGRect(origin: CGPoint(x: originX, y: originY), size: size)
        for _ in 0..<8 where occupied.contains(where: { $0.intersects(candidate) }) {
            originY = min(originY + size.height + 2, pageBounds.maxY - size.height)
            candidate.origin.y = originY
        }
        return candidate
    }

    func updatePageState() {
        guard let pdfView, let document = pdfView.document else {
            if self.document != nil {
                self.document = nil
            }
            if currentPageIndex != 0 {
                currentPageIndex = 0
            }
            if pageCount != 0 {
                pageCount = 0
            }
            return
        }

        if self.document !== document {
            self.document = document
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
    let noteEditingEnabled: Bool
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (PDFSelectionEvent?) -> Void
    let onTranslateSelection: () -> Void
    let onToggleHighlight: () -> Void
    let onDeleteHighlight: (UUID) -> Void
    let onOpenHighlightNote: (UUID) -> Void
    let onMoveHighlightNoteMarker: (UUID, HighlightPoint) -> Void
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
        controller.renderHighlights(highlights, noteEditingEnabled: noteEditingEnabled)
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
                  controller.makeHighlightCandidate(paperID: paperID) != nil,
                  !controller.currentSelectionOverlapsHighlight(paperID: paperID) else {
                return nil
            }
            return "添加高亮"
        }
        highlightView.onTranslateSelection = onTranslateSelection
        highlightView.onToggleHighlight = onToggleHighlight
        highlightView.onDeleteHighlight = onDeleteHighlight
        highlightView.noteMarkerIDAtEvent = { [weak highlightView, weak controller] event in
            guard let highlightView else { return nil }
            let point = highlightView.convert(event.locationInWindow, from: nil)
            return controller?.noteMarkerID(at: point)
        }
        highlightView.interactiveHighlightIDAtEvent = { [weak highlightView, weak controller] event in
            guard let highlightView else { return nil }
            let point = highlightView.convert(event.locationInWindow, from: nil)
            return controller?.interactiveHighlightID(at: point)
        }
        highlightView.onSelectHighlight = { [weak controller] id in
            controller?.currentHighlightID = id
        }
        highlightView.onOpenHighlightNote = onOpenHighlightNote
        highlightView.onMoveHighlightNoteMarker = {
            [weak controller] id, startPoint, point, finished in
            guard let position = controller?.moveNoteMarker(
                id: id,
                from: startPoint,
                to: point,
                finished: finished
            ), finished else {
                return
            }
            onMoveHighlightNoteMarker(id, position)
        }
        highlightView.onHoverHighlight = { [weak controller] id in
            controller?.setHoveredHighlightID(id)
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
        controller.renderHighlights(highlights, noteEditingEnabled: noteEditingEnabled)
        // Publish the initial page count synchronously. Import can otherwise race a second
        // selection update and leave the toolbar showing “/ —” until the first navigation.
        controller.updatePageState()
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

        @MainActor
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
                        self.parent.controller.closeNoteEditor()
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
            observationTokens.append(
                center.addObserver(
                    forName: .PDFViewScaleChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.parent.controller.closeNoteEditor()
                    }
                }
            )
            if let clipView = pdfView.documentView?.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                observationTokens.append(
                    center.addObserver(
                        forName: NSView.boundsDidChangeNotification,
                        object: clipView,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.parent.controller.viewportDidChange()
                        }
                    }
                )
            }
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
