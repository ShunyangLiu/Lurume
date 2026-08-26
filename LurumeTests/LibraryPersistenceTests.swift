import Foundation
import XCTest
@testable import Lurume

final class LibraryPersistenceTests: XCTestCase {
    func testRoundTripPreservesLibrarySnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = LibraryPersistence(
            fileURL: directory.appendingPathComponent("library.json")
        )
        let paperID = UUID()
        let snapshot = LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [
                PaperRecord(
                    id: paperID,
                    identity: FileIdentity(
                        volumeUUID: "volume-a",
                        documentIdentifier: 42,
                        fallbackPath: "/tmp/paper.pdf"
                    ),
                    bookmarkData: Data([0, 1, 2]),
                    displayName: "Paper",
                    dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    lastPageIndex: 17
                ),
            ],
            selectedPaperID: paperID
        )

        try persistence.save(snapshot)

        XCTAssertEqual(try persistence.load(), snapshot)
    }

    func testMissingFileLoadsEmptySnapshot() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("library.json")

        XCTAssertEqual(
            try LibraryPersistence(fileURL: fileURL).load(),
            .empty
        )
    }
}
