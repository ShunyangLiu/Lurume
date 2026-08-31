import Foundation
import XCTest
@testable import Lurume

final class P8LibraryModelTests: XCTestCase {
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("library.json")
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url)
    }

    private func paper(
        title: String,
        collections: [UUID] = []
    ) -> PaperRecord {
        PaperRecord(
            identity: FileIdentity(
                volumeUUID: nil,
                documentIdentifier: nil,
                fallbackPath: "/tmp/\(UUID().uuidString).pdf"
            ),
            bookmarkData: Data(),
            initialTitle: title,
            collectionIDs: collections
        )
    }

    func testV4MigrationPreservesLegacyFieldsAndCreatesStructuredMetadata() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let collectionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let paperID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let legacy = LibrarySnapshotV4(
            schemaVersion: 4,
            papers: [
                PaperRecordV4(
                    id: paperID,
                    volumeUUID: "legacy-volume",
                    documentIdentifier: 405,
                    bookmarkData: Data([4, 0, 5]),
                    fallbackPath: "/tmp/legacy-v4.pdf",
                    originalFileName: "legacy-v4.pdf",
                    title: "Legacy V4 Title",
                    authors: "Family, Given; Research Group",
                    year: 2024,
                    manuallyEditedFields: [.title, .authors, .year],
                    didReadAutoMetadata: true,
                    dateAdded: Date(timeIntervalSince1970: 1_730_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_730_000_100),
                    lastPageIndex: 27,
                    readingStatus: .reading,
                    collectionIDs: [collectionID]
                ),
            ],
            collections: [
                CollectionRecordV4(
                    id: collectionID,
                    name: "Legacy Collection",
                    createdAt: Date(timeIntervalSince1970: 1_720_000_000)
                ),
            ],
            selectedPaperID: paperID
        )
        try writeJSON(legacy, to: fileURL)

        let loaded = try LibraryPersistence(fileURL: fileURL).load()

        XCTAssertTrue(loaded.migratedFromLegacy)
        XCTAssertEqual(loaded.snapshot.schemaVersion, 5)
        let migrated = try XCTUnwrap(loaded.snapshot.papers.first)
        XCTAssertEqual(migrated.title, "Legacy V4 Title")
        XCTAssertEqual(migrated.metadata.title, "Legacy V4 Title")
        XCTAssertEqual(migrated.metadata.creators, [
            BibliographicCreator(role: .author, literalName: "Family, Given; Research Group"),
        ])
        XCTAssertEqual(migrated.year, 2024)
        XCTAssertEqual(migrated.manuallyEditedFields, [.title, .creators, .issuedDate])
        XCTAssertTrue(migrated.didReadAutoMetadata)
        XCTAssertNil(migrated.contentFingerprint)
        XCTAssertTrue(migrated.importSources.isEmpty)
        XCTAssertNil(migrated.lastImportedMetadata)
        XCTAssertEqual(loaded.snapshot.collections.first?.parentID, nil)
        XCTAssertTrue(loaded.snapshot.collections.first?.importSources.isEmpty == true)
    }

    @MainActor
    func testV4OnDiskLibraryOpensRewritesAndSupportsCheckpointTwoOperations() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let collectionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let paperID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let legacy = LibrarySnapshotV4(
            schemaVersion: 4,
            papers: [
                PaperRecordV4(
                    id: paperID,
                    volumeUUID: "legacy-volume",
                    documentIdentifier: 405,
                    bookmarkData: Data([4, 0, 5]),
                    fallbackPath: "/tmp/legacy-v4.pdf",
                    originalFileName: "legacy-v4.pdf",
                    title: "Legacy V4 Title",
                    authors: "Research Group",
                    year: 2024,
                    manuallyEditedFields: [.authors],
                    didReadAutoMetadata: true,
                    dateAdded: Date(timeIntervalSince1970: 1_730_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_730_000_100),
                    lastPageIndex: 27,
                    readingStatus: .reading,
                    collectionIDs: [collectionID]
                ),
            ],
            collections: [
                CollectionRecordV4(
                    id: collectionID,
                    name: "Legacy Collection",
                    createdAt: Date(timeIntervalSince1970: 1_720_000_000)
                ),
            ],
            selectedPaperID: paperID
        )
        try writeJSON(legacy, to: fileURL)

        let persistence = LibraryPersistence(fileURL: fileURL)
        let store = LibraryStore(persistence: persistence)
        let childID = try store.createCollection(
            named: "Nested Child",
            parentID: collectionID
        )
        try store.setMembership(of: [paperID], in: childID, isMember: true)
        var edited = try XCTUnwrap(store.papers.first).metadata
        edited.containerTitle = "Migrated Journal"
        try store.setManualMetadata(
            edited,
            attachmentLabel: "Accepted manuscript",
            for: paperID
        )

        let rewritten = try persistence.load()
        XCTAssertFalse(rewritten.migratedFromLegacy)
        XCTAssertEqual(rewritten.snapshot.schemaVersion, 5)
        XCTAssertEqual(rewritten.snapshot.selectedPaperID, paperID)
        XCTAssertEqual(rewritten.snapshot.papers.first?.lastPageIndex, 27)
        XCTAssertEqual(rewritten.snapshot.papers.first?.readingStatus, .reading)
        XCTAssertEqual(
            Set(rewritten.snapshot.papers.first?.collectionIDs ?? []),
            [collectionID, childID]
        )
        XCTAssertEqual(rewritten.snapshot.papers.first?.metadata.containerTitle, "Migrated Journal")
        XCTAssertEqual(rewritten.snapshot.papers.first?.attachmentLabel, "Accepted manuscript")
        XCTAssertEqual(
            rewritten.snapshot.collections.first(where: { $0.id == childID })?.parentID,
            collectionID
        )
    }

    func testV5PersistsOnlyMetadataTitleAndCompatibilityFacadeMutatesIt() throws {
        var record = paper(title: "Initial")
        record.title = "Changed"
        record.authors = "Literal Author"
        record.year = 2026

        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])

        XCTAssertNil(object["title"])
        XCTAssertNil(object["authors"])
        XCTAssertNil(object["year"])
        XCTAssertEqual(metadata["title"] as? String, "Changed")
        XCTAssertEqual(record.metadata.authorsDisplay, "Literal Author")
        XCTAssertEqual(record.metadata.issuedDate?.year, 2026)
    }

    func testManualEmptyTitlePersistsDecisionWhileDisplayUsesFilenameFallback() {
        var record = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: 8,
                fallbackPath: "/tmp/fallback.pdf"
            ),
            bookmarkData: Data(),
            initialTitle: "Original",
            originalFileName: "fallback.pdf"
        )

        record.setManualTitle("  \n")

        XCTAssertEqual(record.metadata.title, "")
        XCTAssertEqual(record.title, "")
        XCTAssertEqual(record.displayTitle, "fallback")
        XCTAssertTrue(record.manuallyEditedFields.contains(.title))
    }

    func testPersistenceAcceptsSameNameUnderDifferentParents() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let left = CollectionRecord(name: "Left")
        let right = CollectionRecord(name: "Right")
        let snapshot = LibrarySnapshot(
            schemaVersion: 5,
            papers: [],
            collections: [
                left,
                right,
                CollectionRecord(name: "Papers", parentID: left.id),
                CollectionRecord(name: "papers", parentID: right.id),
            ],
            selectedPaperID: nil
        )

        XCTAssertNoThrow(try LibraryPersistence(fileURL: fileURL).save(snapshot))
    }

    func testPersistenceRejectsMissingParentCycleAndDuplicateSibling() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let persistence = LibraryPersistence(fileURL: fileURL)
        let missing = CollectionRecord(name: "Missing", parentID: UUID())
        XCTAssertThrowsError(try persistence.save(LibrarySnapshot(
            schemaVersion: 5,
            papers: [],
            collections: [missing],
            selectedPaperID: nil
        )))

        let firstID = UUID()
        let secondID = UUID()
        let first = CollectionRecord(id: firstID, name: "First", parentID: secondID)
        let second = CollectionRecord(id: secondID, name: "Second", parentID: firstID)
        XCTAssertThrowsError(try persistence.save(LibrarySnapshot(
            schemaVersion: 5,
            papers: [],
            collections: [first, second],
            selectedPaperID: nil
        )))

        let duplicateA = CollectionRecord(name: "Résumé")
        let duplicateB = CollectionRecord(name: " resume ")
        XCTAssertThrowsError(try persistence.save(LibrarySnapshot(
            schemaVersion: 5,
            papers: [],
            collections: [duplicateA, duplicateB],
            selectedPaperID: nil
        )))
    }

    func testRecursiveMembershipAndDeletionCandidateDeduplicatePapers() throws {
        let root = CollectionRecord(name: "Root")
        let childA = CollectionRecord(name: "A", parentID: root.id)
        let childB = CollectionRecord(name: "B", parentID: root.id)
        let grandchild = CollectionRecord(name: "Leaf", parentID: childA.id)
        let outside = CollectionRecord(name: "Outside")
        let duplicated = paper(title: "Both", collections: [childA.id, grandchild.id, outside.id])
        let childOnly = paper(title: "Child B", collections: [childB.id])
        let unaffected = paper(title: "Outside", collections: [outside.id])
        let collections = [root, childA, childB, grandchild, outside]
        let papers = [duplicated, childOnly, unaffected]

        XCTAssertFalse(CollectionHierarchy.canMove(
            collectionID: root.id,
            to: grandchild.id,
            in: collections
        ))
        XCTAssertFalse(CollectionHierarchy.canMove(
            collectionID: root.id,
            to: root.id,
            in: collections
        ))
        XCTAssertTrue(CollectionHierarchy.canMove(
            collectionID: childA.id,
            to: outside.id,
            in: collections
        ))
        XCTAssertEqual(
            CollectionHierarchy.recursivePaperIDs(in: root.id, papers: papers, collections: collections),
            [duplicated.id, childOnly.id]
        )
        let candidate = try XCTUnwrap(CollectionHierarchy.deletionCandidate(
            for: root.id,
            papers: papers,
            collections: collections
        ))
        XCTAssertEqual(Set(candidate.removedCollections.map(\.id)), [root.id, childA.id, childB.id, grandchild.id])
        XCTAssertEqual(candidate.affectedPaperCount, 2)
        XCTAssertEqual(candidate.updatedPapers[0].collectionIDs, [outside.id])
        XCTAssertTrue(candidate.updatedPapers[1].collectionIDs.isEmpty)
        XCTAssertEqual(candidate.updatedPapers[2], unaffected)
    }

    func testDOINormalizationRemovesOnlyKnownPrefixes() {
        XCTAssertEqual(
            BibliographicIdentifier(kind: .doi, displayValue: "https://doi.org/10.1000/ABC").comparisonValue,
            "10.1000/abc"
        )
        XCTAssertEqual(
            BibliographicIdentifier(kind: .doi, displayValue: "https://example.test/?doi=10.1/x").comparisonValue,
            "https://example.test/?doi=10.1/x"
        )
    }

    func testPersistenceRejectsAbsoluteOrEscapingFolderSource() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        for path in ["/Users/private/paper.pdf", "folder/../paper.pdf"] {
            let source: ImportSourceIdentity = .folder(FolderImportSource(
                rootVolumeUUID: "volume",
                rootDocumentIdentifier: 1,
                relativePath: path
            ))
            let record = PaperRecord(
                identity: FileIdentity(
                    volumeUUID: "volume",
                    documentIdentifier: 2,
                    fallbackPath: "/tmp/paper.pdf"
                ),
                bookmarkData: Data(),
                initialTitle: "Paper",
                importSources: [source]
            )
            XCTAssertThrowsError(try LibraryPersistence(fileURL: fileURL).save(LibrarySnapshot(
                schemaVersion: 5,
                papers: [record],
                selectedPaperID: record.id
            )))
        }
    }
}
