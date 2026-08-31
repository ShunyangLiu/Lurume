import XCTest
@testable import Lurume

final class CollectionExpansionStateTests: XCTestCase {
    func testCodecIsStableAndDiscardsMalformedAndMissingIDs() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let storage = "malformed,\(second.uuidString),\(first.uuidString),\(second.uuidString)"

        XCTAssertEqual(CollectionExpansionStateCodec.decode(storage), [first, second])
        XCTAssertEqual(
            CollectionExpansionStateCodec.encode([second, first]),
            "\(first.uuidString),\(second.uuidString)"
        )
        XCTAssertEqual(
            CollectionExpansionStateCodec.pruning(storage, validIDs: [second]),
            second.uuidString
        )
    }
}
