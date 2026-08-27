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
        let pdfView = PDFView()
        pdfView.document = document
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
            at: NSPoint(x: 72, y: 700),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        return PDFDocument(data: data as Data)
    }
}
