import AppKit
import XCTest
@testable import Lurume

final class LibraryDragDropTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LurumeTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    func testInternalPayloadCarriesMultipleDeduplicatedPaperIDs() throws {
        let first = UUID()
        let second = UUID()
        let pasteboard = makePasteboard()
        let item = try XCTUnwrap(
            LibraryDragDropCodec.pasteboardItem(paperIDs: [second, first, second])
        )
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let expected = [first, second].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(
            LibraryDragDropCodec.resolve(pasteboard),
            .internalPapers(expected)
        )
    }

    func testFinderPayloadKeepsOnlyPDFFileURLs() {
        let pasteboard = makePasteboard()
        let pdfURL = URL(fileURLWithPath: "/tmp/paper.pdf")
        let textURL = URL(fileURLWithPath: "/tmp/readme.txt")
        XCTAssertTrue(pasteboard.writeObjects([pdfURL as NSURL, textURL as NSURL]))

        XCTAssertEqual(
            LibraryDragDropCodec.resolve(pasteboard),
            .finderPDFs([pdfURL.standardizedFileURL])
        )
    }

    func testInternalPayloadTakesPriorityOverFileURL() throws {
        let paperID = UUID()
        let item = try XCTUnwrap(
            LibraryDragDropCodec.pasteboardItem(paperIDs: [paperID])
        )
        item.setString(
            URL(fileURLWithPath: "/tmp/should-not-import.pdf").absoluteString,
            forType: .fileURL
        )
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(
            LibraryDragDropCodec.resolve(pasteboard),
            .internalPapers([paperID])
        )
    }

    func testCorruptInternalPayloadDoesNotFallBackToFileImport() {
        let item = NSPasteboardItem()
        item.setData(Data("not-json".utf8), forType: LibraryDragDropCodec.internalPaperType)
        item.setString(
            URL(fileURLWithPath: "/tmp/should-not-import.pdf").absoluteString,
            forType: .fileURL
        )
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(LibraryDragDropCodec.resolve(pasteboard), .unsupported)
    }

    func testNonPDFAndEmptyPayloadsAreUnsupported() {
        let pasteboard = makePasteboard()
        XCTAssertEqual(LibraryDragDropCodec.resolve(pasteboard), .unsupported)
        XCTAssertTrue(
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/readme.md") as NSURL])
        )
        XCTAssertEqual(LibraryDragDropCodec.resolve(pasteboard), .unsupported)
    }
}
