import XCTest
@testable import Lurume

final class FileIdentityTests: XCTestCase {
    func testPersistentIdentifiersTakePriorityOverPath() {
        let first = FileIdentity(
            volumeUUID: "volume-a",
            documentIdentifier: 7,
            fallbackPath: "/old/Paper.pdf"
        )
        let moved = FileIdentity(
            volumeUUID: "volume-a",
            documentIdentifier: 7,
            fallbackPath: "/new/Paper.pdf"
        )

        XCTAssertTrue(first.identifiesSameFile(as: moved))
    }

    func testCrossVolumeCopyIsDistinct() {
        let original = FileIdentity(
            volumeUUID: "volume-a",
            documentIdentifier: 7,
            fallbackPath: "/Volumes/A/Paper.pdf"
        )
        let copy = FileIdentity(
            volumeUUID: "volume-b",
            documentIdentifier: 7,
            fallbackPath: "/Volumes/B/Paper.pdf"
        )

        XCTAssertFalse(original.identifiesSameFile(as: copy))
    }

    func testPathIsFallbackWhenPersistentIdentityIsUnavailable() {
        let first = FileIdentity(
            volumeUUID: nil,
            documentIdentifier: nil,
            fallbackPath: "/tmp/folder/../Paper.pdf"
        )
        let second = FileIdentity(
            volumeUUID: nil,
            documentIdentifier: nil,
            fallbackPath: "/tmp/Paper.pdf"
        )

        XCTAssertTrue(first.identifiesSameFile(as: second))
    }
}
