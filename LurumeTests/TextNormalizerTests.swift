import XCTest
@testable import Lurume

final class TextNormalizerTests: XCTestCase {
    func testJoinsWrappedLinesAndPreservesParagraphs() {
        let raw = "A paper line\ncontinues here.\n\nA new paragraph."

        XCTAssertEqual(
            TextNormalizer.translationInput(from: raw),
            "A paper line continues here.\n\nA new paragraph."
        )
    }

    func testRepairsSimpleLineEndHyphenation() {
        XCTAssertEqual(
            TextNormalizer.translationInput(from: "trans-\nlation"),
            "translation"
        )
    }

    func testBlankSelectionNormalizesToEmptyString() {
        XCTAssertEqual(TextNormalizer.translationInput(from: " \n\t\n "), "")
    }
}
