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

    func testCollapsesInternalWhitespaceRuns() {
        XCTAssertEqual(
            TextNormalizer.translationInput(from: "a  \tb\u{00A0}c"),
            "a b c"
        )
    }

    func testJoinsChineseWrappedLinesWithoutSpace() {
        XCTAssertEqual(
            TextNormalizer.translationInput(from: "本文提出一种新方法。\n进一步实验验证了其有效性。"),
            "本文提出一种新方法。进一步实验验证了其有效性。"
        )
    }

    func testKeepsSpaceBetweenChineseAndLatinBoundary() {
        XCTAssertEqual(
            TextNormalizer.translationInput(from: "我们基于\nBERT 构建模型"),
            "我们基于 BERT 构建模型"
        )
    }

    func testStripsFullWidthIndentation() {
        XCTAssertEqual(
            TextNormalizer.translationInput(from: "\u{3000}\u{3000}本文提出\n\u{3000}一种新方法。"),
            "本文提出一种新方法。"
        )
    }
}
