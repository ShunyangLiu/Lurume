import AppKit
import PDFKit
import XCTest
@testable import Lurume

final class LurumeSmokeTests: XCTestCase {
    func testApplicationTargetLoads() {
        XCTAssertEqual(LibrarySchema.currentVersion, 2)
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

        pdfView.clearSelection()
        controller.activateHighlight(highlight, translate: true)
        XCTAssertEqual(pdfView.currentSelection?.string, "beta")
        XCTAssertEqual(controller.currentHighlightID, highlight.id)

        controller.renderHighlights([])
        XCTAssertTrue(page.annotations.isEmpty)
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
    private func makeSearchablePDF(text: String) -> PDFDocument? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: NSPoint(x: 72, y: 400),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        return PDFDocument(data: data as Data)
    }
}
