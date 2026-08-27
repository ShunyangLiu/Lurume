import Foundation
import XCTest
@testable import Lurume

final class LibraryPersistenceTests: XCTestCase {
    private func makeTempFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
    }

    private func legacySnapshot() -> LibrarySnapshotV1 {
        LibrarySnapshotV1(
            schemaVersion: 1,
            papers: [
                PaperRecordV1(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    volumeUUID: "volume-a",
                    documentIdentifier: 42,
                    bookmarkData: Data([0, 1, 2]),
                    fallbackPath: "/tmp/paper.pdf",
                    displayName: "Old Display Name",
                    dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    lastPageIndex: 17
                ),
            ],
            selectedPaperID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
    }

    private func writeLegacyJSON(_ legacy: LibrarySnapshotV1, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(legacy).write(to: url)
    }

    func testRoundTripPreservesLibrarySnapshot() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let persistence = LibraryPersistence(fileURL: fileURL)
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

        let loaded = try persistence.load()
        XCTAssertEqual(loaded.snapshot, snapshot)
        XCTAssertFalse(loaded.migratedFromLegacy)
    }

    func testMissingFileLoadsEmptySnapshot() throws {
        let fileURL = makeTempFileURL("library.json")

        XCTAssertEqual(
            try LibraryPersistence(fileURL: fileURL).load(),
            .empty
        )
    }

    func testMigratesLegacySnapshotPreservingAllData() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let legacy = legacySnapshot()
        try writeLegacyJSON(legacy, to: fileURL)

        let loaded = try LibraryPersistence(fileURL: fileURL).load()

        XCTAssertTrue(loaded.migratedFromLegacy)
        XCTAssertEqual(loaded.snapshot.schemaVersion, LibrarySchema.currentVersion)
        XCTAssertEqual(loaded.snapshot.selectedPaperID, legacy.selectedPaperID)

        let migrated = try XCTUnwrap(loaded.snapshot.papers.first)
        XCTAssertEqual(migrated.id, legacy.papers[0].id)
        XCTAssertEqual(migrated.volumeUUID, "volume-a")
        XCTAssertEqual(migrated.documentIdentifier, 42)
        XCTAssertEqual(migrated.bookmarkData, Data([0, 1, 2]))
        XCTAssertEqual(migrated.fallbackPath, "/tmp/paper.pdf")
        XCTAssertEqual(migrated.title, "Old Display Name")
        XCTAssertEqual(migrated.originalFileName, "Old Display Name")
        XCTAssertNil(migrated.authors)
        XCTAssertNil(migrated.year)
        XCTAssertTrue(migrated.manuallyEditedFields.isEmpty)
        XCTAssertFalse(migrated.didReadAutoMetadata)
        XCTAssertEqual(migrated.dateAdded, legacy.papers[0].dateAdded)
        XCTAssertEqual(migrated.lastOpenedAt, legacy.papers[0].lastOpenedAt)
        XCTAssertEqual(migrated.lastPageIndex, 17)
    }

    func testCorruptLibraryFailsToLoadInsteadOfSilentReset() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: fileURL)

        XCTAssertThrowsError(try LibraryPersistence(fileURL: fileURL).load())
    }

    func testFutureSchemaVersionIsRejected() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: fileURL)

        XCTAssertThrowsError(try LibraryPersistence(fileURL: fileURL).load()) { error in
            XCTAssertEqual(
                error as? LibraryPersistenceError,
                .unsupportedSchema(found: 99)
            )
        }
    }
}
