import AppKit
import PDFKit
import XCTest
@testable import Lurume

final class LurumeSmokeTests: XCTestCase {
    func testApplicationTargetLoads() {
        XCTAssertEqual(LibrarySchema.currentVersion, 3)
    }

    @MainActor
    func testOutlineBuildsHierarchyAndRejectsExternalActions() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()

        let section = PDFOutline()
        section.label = "Section"
        section.destination = PDFDestination(page: page, at: CGPoint(x: 10, y: 20))
        let subsection = PDFOutline()
        subsection.label = "Subsection"
        subsection.destination = PDFDestination(page: page, at: CGPoint(x: 30, y: 40))
        section.insertChild(subsection, at: 0)
        root.insertChild(section, at: 0)

        let external = PDFOutline()
        external.label = "External"
        external.action = PDFActionURL(url: URL(string: "https://example.com")!)
        root.insertChild(external, at: 1)
        document.outlineRoot = root

        let nodes = PDFOutlineNode.roots(in: document)

        XCTAssertEqual(nodes.map(\.label), ["Section", "External"])
        XCTAssertNotNil(nodes[0].destination)
        XCTAssertEqual(nodes[0].children?.map(\.label), ["Subsection"])
        XCTAssertNotNil(nodes[0].children?.first?.destination)
        XCTAssertNil(nodes[1].destination, "外部 URL 目录动作不得成为可执行的文档内跳转")
    }

    @MainActor
    func testThumbnailNavigationUsesTheLivePDFReaderState() throws {
        let document = PDFDocument()
        let firstPage = PDFPage()
        let secondPage = PDFPage()
        document.insert(firstPage, at: 0)
        document.insert(secondPage, at: 1)
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        let controller = PDFReaderController()
        controller.attach(pdfView)
        controller.updatePageState()

        XCTAssertTrue(controller.pdfView === pdfView)
        XCTAssertEqual(controller.pageCount, 2)
        XCTAssertEqual(controller.currentPageIndex, 0)

        controller.go(toOneBasedPage: 2)
        controller.updatePageState()

        XCTAssertTrue(pdfView.currentPage === secondPage)
        XCTAssertEqual(controller.currentPageIndex, 1)
    }

    @MainActor
    func testPDFSearchNavigatesAndWrapsThroughMatches() throws {
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta alpha"))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        pdfView.layoutSubtreeIfNeeded()
        let controller = PDFReaderController()
        controller.attach(pdfView)
        controller.searchText = "alpha"

        controller.search()

        XCTAssertEqual(controller.searchResultCount, 2)
        XCTAssertEqual(controller.currentSearchResultIndex, 0)
        XCTAssertEqual(controller.searchResultLabel, "1 / 2")
        XCTAssertTrue(controller.isCurrentSearchSelection(pdfView.currentSelection))
        XCTAssertEqual(pdfView.currentSelection?.color, .selectedTextBackgroundColor)
        XCTAssertEqual(pdfView.highlightedSelections?.count, 1)
        XCTAssertEqual(
            pdfView.highlightedSelections?.first?.color,
            .systemYellow.withAlphaComponent(0.5)
        )
        let currentSelection = try XCTUnwrap(pdfView.currentSelection)
        let currentPage = try XCTUnwrap(currentSelection.pages.first)
        let documentView = try XCTUnwrap(pdfView.documentView)
        let scrollView = try XCTUnwrap(documentView.enclosingScrollView)
        let selectionInPDFView = pdfView.convert(
            currentSelection.bounds(for: currentPage),
            from: currentPage
        )
        let selectionInDocument = pdfView.convert(selectionInPDFView, to: documentView)
        XCTAssertEqual(
            selectionInDocument.midY,
            scrollView.contentView.bounds.midY,
            accuracy: 2,
            "当前匹配项应位于阅读视口的垂直中央"
        )

        controller.nextSearchResult()
        XCTAssertEqual(controller.currentSearchResultIndex, 1)
        XCTAssertEqual(controller.searchResultLabel, "2 / 2")
        XCTAssertTrue(controller.isCurrentSearchSelection(pdfView.currentSelection))
        XCTAssertEqual(pdfView.highlightedSelections?.count, 1)

        controller.nextSearchResult()
        XCTAssertEqual(controller.currentSearchResultIndex, 0, "下一项应从末尾循环到开头")

        controller.previousSearchResult()
        XCTAssertEqual(controller.currentSearchResultIndex, 1, "上一项应从开头循环到末尾")

        controller.searchText = "beta"
        controller.searchTextDidChange()
        XCTAssertEqual(controller.searchResultCount, 0)
        XCTAssertNil(controller.searchResultLabel)
        XCTAssertNil(pdfView.highlightedSelections)

        controller.nextSearchResult()
        XCTAssertEqual(controller.searchResultCount, 1, "输入后立即按 Return 也应先执行新搜索")
        XCTAssertEqual(controller.currentSearchResultIndex, 0)
        XCTAssertEqual(controller.searchResultLabel, "1 / 1")
        XCTAssertTrue(controller.isCurrentSearchSelection(pdfView.currentSelection))
        XCTAssertNil(pdfView.highlightedSelections, "单个结果只使用当前选区，不需要普通高亮")

        controller.clearSearchResults()
        XCTAssertNil(pdfView.currentSelection)

        let centeredOrigin = PDFSearchViewport.centeredScrollOrigin(
            targetCenter: CGPoint(x: 700, y: 1_200),
            viewportSize: CGSize(width: 400, height: 600),
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 2_000)
        )
        XCTAssertEqual(centeredOrigin, CGPoint(x: 500, y: 900))
        let clampedOrigin = PDFSearchViewport.centeredScrollOrigin(
            targetCenter: CGPoint(x: 20, y: 1_950),
            viewportSize: CGSize(width: 400, height: 600),
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 2_000)
        )
        XCTAssertEqual(clampedOrigin, CGPoint(x: 0, y: 1_400))
    }

    @MainActor
    func testPDFSelectionCreatesRendersAndReactivatesHighlight() throws {
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta gamma"))
        let page = try XCTUnwrap(document.page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        pdfView.layoutSubtreeIfNeeded()
        let controller = PDFReaderController()
        controller.attach(pdfView)
        let selection = try XCTUnwrap(
            document.findString("beta", withOptions: .caseInsensitive).first
        )
        pdfView.setCurrentSelection(selection, animate: false)
        let paperID = UUID()

        let highlight = try XCTUnwrap(controller.makeHighlightCandidate(paperID: paperID))
        XCTAssertEqual(highlight.paperID, paperID)
        XCTAssertEqual(highlight.rawText, "beta")
        XCTAssertEqual(highlight.segments.count, 1)

        controller.renderHighlights([highlight])
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(controller.skippedHighlightFragmentCount, 0)
        let rect = try XCTUnwrap(highlight.segments.first?.rects.first?.cgRect)
        let viewPoint = pdfView.convert(
            CGPoint(x: rect.midX, y: rect.midY),
            from: page
        )
        XCTAssertEqual(controller.highlightID(at: viewPoint), highlight.id)
        let ordinaryPoint = pdfView.convert(CGPoint(x: 500, y: 100), from: page)
        XCTAssertNil(
            controller.highlightID(at: ordinaryPoint),
            "普通页面点击不应进入自定义高亮点击手势"
        )

        pdfView.clearSelection()
        controller.activateHighlight(highlight, translate: true)
        XCTAssertEqual(pdfView.currentSelection?.string, "beta")
        XCTAssertEqual(controller.currentHighlightID, highlight.id)

        controller.renderHighlights([])
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor
    func testHighlightSelectionAndNoteMarkersUseTemporaryAnnotations() throws {
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta gamma"))
        let page = try XCTUnwrap(document.page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        pdfView.layoutSubtreeIfNeeded()
        let controller = PDFReaderController()
        controller.attach(pdfView)
        let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
        pdfView.setCurrentSelection(selection, animate: false)
        let base = try XCTUnwrap(controller.makeHighlightCandidate(paperID: UUID()))
        let noted = base.updatingNote("remember this")

        controller.renderHighlights([noted])
        XCTAssertEqual(
            page.annotations.filter { $0.type != "Popup" }.count,
            2,
            "黄色高亮和一个常驻笔记标志：\(page.annotations.map { $0.type ?? "nil" })"
        )
        let markerRect = try XCTUnwrap(controller.noteMarkerAnchorRect(for: noted.id))
        XCTAssertEqual(
            controller.noteMarkerID(at: CGPoint(x: markerRect.midX, y: markerRect.midY)),
            noted.id
        )

        controller.currentHighlightID = noted.id
        XCTAssertEqual(
            page.annotations.filter { $0.type != "Popup" }.count,
            3,
            "选择后逐行增加一个虚线轮廓：\(page.annotations.map { $0.type ?? "nil" })"
        )
        XCTAssertEqual(page.annotations.filter { $0.border?.style == .dashed }.count, 1)

        controller.renderHighlights([])
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor
    func testNoteMarkerCanMoveAndRestoreItsSavedPagePosition() throws {
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta gamma"))
        let page = try XCTUnwrap(document.page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        pdfView.layoutSubtreeIfNeeded()
        let controller = PDFReaderController()
        controller.attach(pdfView)
        let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
        pdfView.setCurrentSelection(selection, animate: false)
        let highlight = try XCTUnwrap(
            controller.makeHighlightCandidate(paperID: UUID())?.updatingNote("move me")
        )
        controller.renderHighlights([highlight])
        let initialRect = try XCTUnwrap(controller.noteMarkerAnchorRect(for: highlight.id))
        let start = CGPoint(x: initialRect.midX, y: initialRect.midY)
        let target = CGPoint(x: start.x + 45, y: start.y + 35)

        XCTAssertNotNil(
            controller.moveNoteMarker(
                id: highlight.id,
                from: start,
                to: target,
                finished: false
            )
        )
        let liveMovedRect = try XCTUnwrap(controller.noteMarkerAnchorRect(for: highlight.id))
        XCTAssertEqual(liveMovedRect.midX, target.x, accuracy: 1)
        XCTAssertEqual(liveMovedRect.midY, target.y, accuracy: 1)
        let savedPosition = try XCTUnwrap(
            controller.moveNoteMarker(
                id: highlight.id,
                from: start,
                to: target,
                finished: true
            )
        )
        let movedRect = try XCTUnwrap(controller.noteMarkerAnchorRect(for: highlight.id))
        XCTAssertEqual(movedRect.midX, target.x, accuracy: 1)
        XCTAssertEqual(movedRect.midY, target.y, accuracy: 1)

        controller.renderHighlights([highlight.updatingNoteMarkerPosition(savedPosition)])
        let restoredRect = try XCTUnwrap(controller.noteMarkerAnchorRect(for: highlight.id))
        let restoredPageCenter = pdfView.convert(
            CGPoint(x: restoredRect.midX, y: restoredRect.midY),
            to: page
        )
        XCTAssertEqual(restoredPageCenter.x, savedPosition.x, accuracy: 1)
        XCTAssertEqual(restoredPageCenter.y, savedPosition.y, accuracy: 1)
    }

    @MainActor
    func testReadOnlyModeHidesTransientAddNoteMarker() throws {
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta gamma"))
        let page = try XCTUnwrap(document.page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        let controller = PDFReaderController()
        controller.attach(pdfView)
        let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
        pdfView.setCurrentSelection(selection, animate: false)
        let highlight = try XCTUnwrap(controller.makeHighlightCandidate(paperID: UUID()))

        controller.renderHighlights([highlight])
        controller.currentHighlightID = highlight.id
        XCTAssertNotNil(controller.noteMarkerAnchorRect(for: highlight.id))

        controller.renderHighlights([highlight], noteEditingEnabled: false)
        XCTAssertNil(controller.noteMarkerAnchorRect(for: highlight.id))
        XCTAssertEqual(page.annotations.filter { $0.border?.style == .dashed }.count, 1)
    }

    @MainActor
    func testCrossPageNoteMarkerAndNavigationUseFinalFragment() throws {
        let document = try XCTUnwrap(makeSearchablePDF(pages: ["first target", "final target"]))
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let finalPage = try XCTUnwrap(document.page(at: 1))
        let firstSelection = try XCTUnwrap(document.findString("first", withOptions: []).first)
        let finalSelection = try XCTUnwrap(document.findString("final", withOptions: []).first)
        let firstRect = try XCTUnwrap(HighlightRect(cgRect: firstSelection.bounds(for: firstPage)))
        let finalRect = try XCTUnwrap(HighlightRect(cgRect: finalSelection.bounds(for: finalPage)))
        let highlight = try XCTUnwrap(HighlightRecord(
            paperID: UUID(),
            rawText: "first final",
            segments: [
                try XCTUnwrap(HighlightSegment(pageIndex: 0, rects: [firstRect])),
                try XCTUnwrap(HighlightSegment(pageIndex: 1, rects: [finalRect])),
            ],
            noteText: "cross-page note"
        ))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        pdfView.layoutSubtreeIfNeeded()
        let controller = PDFReaderController()
        controller.attach(pdfView)

        controller.renderHighlights([highlight])
        XCTAssertEqual(firstPage.annotations.count, 1)
        XCTAssertEqual(
            finalPage.annotations.filter { $0.type != "Popup" }.count,
            2,
            "标志只锚定在最后片段所在页：\(finalPage.annotations.map { $0.type ?? "nil" })"
        )

        controller.activateHighlight(highlight, translate: false)
        XCTAssertTrue(pdfView.currentPage === finalPage)
        XCTAssertNil(pdfView.currentSelection)
    }

    @MainActor
    func testPDFSearchResultCannotBeSavedAsUserHighlight() throws {
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta"))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        let controller = PDFReaderController()
        controller.attach(pdfView)
        controller.searchText = "alpha"

        controller.search()

        XCTAssertNil(controller.makeHighlightCandidate(paperID: UUID()))
    }

    @MainActor
    func testRenderingHighlightDoesNotModifyOriginalPDFFile() throws {
        let generated = try XCTUnwrap(makeSearchablePDF(text: "alpha beta gamma"))
        let originalData = try XCTUnwrap(generated.dataRepresentation())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lurume-highlight-source-\(UUID().uuidString).pdf")
        try originalData.write(to: fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let document = try XCTUnwrap(PDFDocument(url: fileURL))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        pdfView.document = document
        let controller = PDFReaderController()
        controller.attach(pdfView)
        let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
        pdfView.setCurrentSelection(selection, animate: false)
        let highlight = try XCTUnwrap(controller.makeHighlightCandidate(paperID: UUID()))

        controller.renderHighlights([highlight])

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    @MainActor
    func testPDFContextMenuKeepsOnlySelectionAndHighlightActionsWithoutCopyingIt() throws {
        let pdfView = HighlightPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let document = try XCTUnwrap(makeSearchablePDF(text: "alpha beta"))
        pdfView.document = document
        pdfView.setCurrentSelection(
            try XCTUnwrap(document.findString("alpha", withOptions: []).first),
            animate: false
        )
        pdfView.toggleHighlightTitle = { "添加高亮" }
        let systemMenu = NSMenu()
        systemMenu.addItem(withTitle: "查询“alpha”", action: nil, keyEquivalent: "")
        systemMenu.addItem(withTitle: "翻译“alpha”", action: nil, keyEquivalent: "")
        systemMenu.addItem(withTitle: "用“Google”搜索", action: nil, keyEquivalent: "")
        systemMenu.addItem(
            withTitle: "拷贝",
            action: NSSelectorFromString("copy:"),
            keyEquivalent: ""
        )
        systemMenu.addItem(withTitle: "自动调整大小", action: nil, keyEquivalent: "")
        systemMenu.addItem(withTitle: "服务", action: nil, keyEquivalent: "")
        pdfView.layoutSubtreeIfNeeded()
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(pdfView.currentSelection)
        let selectionPoint = pdfView.convert(
            CGPoint(
                x: selection.bounds(for: page).midX,
                y: selection.bounds(for: page).midY
            ),
            from: page
        )
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: selectionPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        let result = try XCTUnwrap(pdfView.configureContextMenu(systemMenu, for: event))

        XCTAssertTrue(result === systemMenu, "PDFKit 的视图型菜单项不能通过复制来扩展")
        XCTAssertEqual(
            result.items.map(\.title),
            ["拷贝", "翻译所选文字", "查询“alpha”", "", "添加高亮"]
        )
    }

    @MainActor
    func testPDFContextMenuIsHiddenForBlankPageAndShowsDeleteForHighlight() throws {
        let pdfView = HighlightPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        XCTAssertNil(pdfView.configureContextMenu(NSMenu(), for: event))

        let highlightID = UUID()
        pdfView.highlightIDAtEvent = { _ in highlightID }
        let highlightMenu = try XCTUnwrap(pdfView.configureContextMenu(NSMenu(), for: event))
        XCTAssertEqual(highlightMenu.items.map(\.title), ["删除高亮"])
    }

    @MainActor
    func testSameHighlightsAreRevalidatedAfterPDFDocumentChanges() throws {
        let onePageDocument = try makeBlankPDF(pageCount: 1)
        let sixPageDocument = try makeBlankPDF(pageCount: 6)
        let rect = try XCTUnwrap(
            HighlightRect(cgRect: CGRect(x: 360, y: 660, width: 90, height: 10))
        )
        let segment = try XCTUnwrap(HighlightSegment(pageIndex: 5, rects: [rect]))
        let highlight = try XCTUnwrap(
            HighlightRecord(paperID: UUID(), rawText: "persisted text", segments: [segment])
        )
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let controller = PDFReaderController()
        controller.attach(pdfView)

        pdfView.document = onePageDocument
        controller.renderHighlights([highlight])
        XCTAssertEqual(controller.skippedHighlightFragmentCount, 1)

        pdfView.document = sixPageDocument
        controller.renderHighlights([highlight])
        XCTAssertEqual(controller.skippedHighlightFragmentCount, 0)
        XCTAssertEqual(sixPageDocument.page(at: 5)?.annotations.count, 1)
    }

    @MainActor
    private func makeSearchablePDF(text: String) -> PDFDocument? {
        makeSearchablePDF(pages: [text])
    }

    @MainActor
    private func makeSearchablePDF(pages: [String]) -> PDFDocument? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(
                at: NSPoint(x: 72, y: 400),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        return PDFDocument(data: data as Data)
    }

    @MainActor
    private func makeBlankPDF(pageCount: Int) throws -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: index)
        }
        return document
    }
}
