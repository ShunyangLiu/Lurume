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
        try writeJSON(legacy, to: url)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url)
    }

    func testRoundTripPreservesLibrarySnapshot() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let persistence = LibraryPersistence(fileURL: fileURL)
        let paperID = UUID()
        let collection = CollectionRecord(
            id: UUID(),
            name: "迁移学习",
            createdAt: Date(timeIntervalSince1970: 1_699_999_900)
        )
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
                    lastPageIndex: 17,
                    collectionIDs: [collection.id]
                ),
            ],
            collections: [collection],
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
        XCTAssertEqual(migrated.originalFileName, "paper.pdf")
        XCTAssertNil(migrated.authors)
        XCTAssertNil(migrated.year)
        XCTAssertTrue(migrated.manuallyEditedFields.isEmpty)
        XCTAssertFalse(migrated.didReadAutoMetadata)
        XCTAssertEqual(migrated.dateAdded, legacy.papers[0].dateAdded)
        XCTAssertEqual(migrated.lastOpenedAt, legacy.papers[0].lastOpenedAt)
        XCTAssertEqual(migrated.lastPageIndex, 17)
        XCTAssertEqual(migrated.readingStatus, .unread)
    }

    func testMigratesV2SnapshotPreservingP0ThroughP2Data() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let paperID = UUID()
        let legacy = LibrarySnapshotV2(
            schemaVersion: 2,
            papers: [
                PaperRecordV2(
                    id: paperID,
                    volumeUUID: "volume-v2",
                    documentIdentifier: 72,
                    bookmarkData: Data([7, 2]),
                    fallbackPath: "/tmp/v2.pdf",
                    originalFileName: "v2.pdf",
                    title: "V2 Title",
                    authors: "Ada, Lin",
                    year: 2025,
                    manuallyEditedFields: [.title, .year],
                    didReadAutoMetadata: true,
                    dateAdded: Date(timeIntervalSince1970: 1_710_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_710_000_100),
                    lastPageIndex: 23
                ),
            ],
            selectedPaperID: paperID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(legacy).write(to: fileURL)

        let loaded = try LibraryPersistence(fileURL: fileURL).load()

        XCTAssertTrue(loaded.migratedFromLegacy)
        XCTAssertEqual(loaded.snapshot.schemaVersion, LibrarySchema.currentVersion)
        XCTAssertEqual(loaded.snapshot.selectedPaperID, paperID)
        let migrated = try XCTUnwrap(loaded.snapshot.papers.first)
        XCTAssertEqual(migrated.id, paperID)
        XCTAssertEqual(migrated.volumeUUID, "volume-v2")
        XCTAssertEqual(migrated.documentIdentifier, 72)
        XCTAssertEqual(migrated.bookmarkData, Data([7, 2]))
        XCTAssertEqual(migrated.fallbackPath, "/tmp/v2.pdf")
        XCTAssertEqual(migrated.originalFileName, "v2.pdf")
        XCTAssertEqual(migrated.title, "V2 Title")
        XCTAssertEqual(migrated.authors, "Ada, Lin")
        XCTAssertEqual(migrated.year, 2025)
        XCTAssertEqual(migrated.manuallyEditedFields, [.title, .year])
        XCTAssertTrue(migrated.didReadAutoMetadata)
        XCTAssertEqual(migrated.lastPageIndex, 23)
        XCTAssertEqual(migrated.readingStatus, .unread)
        XCTAssertTrue(migrated.collectionIDs.isEmpty)
        XCTAssertTrue(loaded.snapshot.collections.isEmpty)
    }

    func testMigratesV3SnapshotPreservingP0ThroughP3Data() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let paperID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let legacy = LibrarySnapshotV3(
            schemaVersion: 3,
            papers: [
                PaperRecordV3(
                    id: paperID,
                    volumeUUID: "volume-v3",
                    documentIdentifier: 303,
                    bookmarkData: Data([3, 0, 3]),
                    fallbackPath: "/tmp/v3.pdf",
                    originalFileName: "v3.pdf",
                    title: "V3 Title",
                    authors: "Lin, Ada",
                    year: 2026,
                    manuallyEditedFields: [.authors],
                    didReadAutoMetadata: true,
                    dateAdded: Date(timeIntervalSince1970: 1_720_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_720_000_100),
                    lastPageIndex: 31,
                    readingStatus: .reading
                ),
            ],
            selectedPaperID: paperID
        )
        try writeJSON(legacy, to: fileURL)

        let loaded = try LibraryPersistence(fileURL: fileURL).load()

        XCTAssertTrue(loaded.migratedFromLegacy)
        XCTAssertEqual(loaded.snapshot.schemaVersion, LibrarySchema.currentVersion)
        XCTAssertEqual(loaded.snapshot.selectedPaperID, paperID)
        XCTAssertTrue(loaded.snapshot.collections.isEmpty)
        let migrated = try XCTUnwrap(loaded.snapshot.papers.first)
        XCTAssertEqual(migrated.id, paperID)
        XCTAssertEqual(migrated.volumeUUID, "volume-v3")
        XCTAssertEqual(migrated.documentIdentifier, 303)
        XCTAssertEqual(migrated.bookmarkData, Data([3, 0, 3]))
        XCTAssertEqual(migrated.fallbackPath, "/tmp/v3.pdf")
        XCTAssertEqual(migrated.originalFileName, "v3.pdf")
        XCTAssertEqual(migrated.title, "V3 Title")
        XCTAssertEqual(migrated.authors, "Lin, Ada")
        XCTAssertEqual(migrated.year, 2026)
        XCTAssertEqual(migrated.manuallyEditedFields, [.authors])
        XCTAssertTrue(migrated.didReadAutoMetadata)
        XCTAssertEqual(migrated.dateAdded, legacy.papers[0].dateAdded)
        XCTAssertEqual(migrated.lastOpenedAt, legacy.papers[0].lastOpenedAt)
        XCTAssertEqual(migrated.lastPageIndex, 31)
        XCTAssertEqual(migrated.readingStatus, .reading)
        XCTAssertTrue(migrated.collectionIDs.isEmpty)
    }

    func testVersionFourRejectsUnknownCollectionReference() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let paper = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: 4,
                fallbackPath: "/tmp/unknown.pdf"
            ),
            bookmarkData: Data(),
            displayName: "Unknown Collection",
            collectionIDs: [UUID()]
        )
        let invalid = LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [paper],
            collections: [],
            selectedPaperID: paper.id
        )

        XCTAssertThrowsError(try LibraryPersistence(fileURL: fileURL).save(invalid)) { error in
            guard case .invalidSnapshot = error as? LibraryPersistenceError else {
                return XCTFail("Expected invalid snapshot, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testVersionFourRejectsDuplicateNormalizedCollectionNames() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let invalid = LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [],
            collections: [
                CollectionRecord(name: "Migration"),
                CollectionRecord(name: "  migration  "),
            ],
            selectedPaperID: nil
        )

        XCTAssertThrowsError(try LibraryPersistence(fileURL: fileURL).save(invalid)) { error in
            guard case .invalidSnapshot = error as? LibraryPersistenceError else {
                return XCTFail("Expected invalid snapshot, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testStoreLoadAndSavePreservesCollectionsAndMemberships() throws {
        let fileURL = makeTempFileURL("library.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let collection = CollectionRecord(
            name: "项目 A",
            createdAt: Date(timeIntervalSince1970: 1_730_000_000)
        )
        let paper = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: 44,
                fallbackPath: "/tmp/project-a.pdf"
            ),
            bookmarkData: Data(),
            displayName: "Project A",
            collectionIDs: [collection.id]
        )
        let persistence = LibraryPersistence(fileURL: fileURL)
        try persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [paper],
            collections: [collection],
            selectedPaperID: paper.id
        ))

        let store = LibraryStore(persistence: persistence)
        store.flushPendingSave()

        let reloaded = try persistence.load().snapshot
        XCTAssertEqual(store.collections, [collection])
        XCTAssertEqual(reloaded.collections, [collection])
        XCTAssertEqual(reloaded.papers.first?.collectionIDs, [collection.id])
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
