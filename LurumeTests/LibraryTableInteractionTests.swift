import XCTest
@testable import Lurume

final class LibraryTableInteractionTests: XCTestCase {
    func testReturnEditsExactlyOneSelectedPaper() {
        let paperID = UUID()

        XCTAssertEqual(
            LibraryTableCommandResolver.returnCommand(selection: [paperID]),
            .editMetadata(paperID)
        )
        XCTAssertNil(LibraryTableCommandResolver.returnCommand(selection: []))
        XCTAssertNil(
            LibraryTableCommandResolver.returnCommand(selection: [paperID, UUID()])
        )
        XCTAssertNil(
            LibraryTableCommandResolver.returnCommand(
                selection: [paperID],
                isTextEditing: true
            )
        )
    }

    func testOpenCommandRequiresExactlyOneSelection() {
        let paperID = UUID()

        XCTAssertEqual(
            LibraryTableCommandResolver.openCommand(selection: [paperID]),
            .open(paperID)
        )
        XCTAssertNil(LibraryTableCommandResolver.openCommand(selection: []))
        XCTAssertNil(
            LibraryTableCommandResolver.openCommand(selection: [paperID, UUID()])
        )
    }

    func testDoubleClickOpensClickedPaperWithoutDependingOnOldSelection() {
        let clickedID = UUID()

        XCTAssertEqual(
            LibraryTableCommandResolver.doubleClickCommand(paperID: clickedID),
            .open(clickedID)
        )
    }

    func testFilteringRetainsOnlyVisibleSelectionsWithoutAutoSelectingReplacement() {
        let visibleID = UUID()
        let hiddenID = UUID()
        let nextRowID = UUID()

        XCTAssertEqual(
            LibraryTableCommandResolver.retainedSelection(
                [visibleID, hiddenID],
                availablePaperIDs: [visibleID, nextRowID]
            ),
            [visibleID]
        )
        XCTAssertTrue(
            LibraryTableCommandResolver.retainedSelection(
                [hiddenID],
                availablePaperIDs: [nextRowID]
            ).isEmpty
        )
    }
}
