import XCTest
@testable import Lurume

final class LurumeSmokeTests: XCTestCase {
    func testApplicationTargetLoads() {
        XCTAssertEqual(LibrarySchema.currentVersion, 1)
    }
}
