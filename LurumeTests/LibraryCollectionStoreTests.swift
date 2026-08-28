import Foundation
import XCTest
@testable import Lurume

final class LibraryCollectionStoreTests: XCTestCase {
    private func makePaper(
        id: UUID = UUID(),
        title: String,
        collectionIDs: [UUID] = []
    ) -> PaperRecord {
        var paper = PaperRecord(
            id: id,
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: nil,
                fallbackPath: "/tmp/\(id.uuidString).pdf"
            ),
            bookmarkData: Data(),
            displayName: title,
            originalFileName: "\(id.uuidString).pdf",
            collectionIDs: collectionIDs
        )
        paper.title = title
        return paper
    }

    @MainActor
    private func makeStore(
        papers: [PaperRecord] = [],
        collections: [CollectionRecord] = []
    ) throws -> (LibraryStore, LibraryPersistence, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = LibraryPersistence(fileURL: directory.appendingPathComponent("library.json"))
        try persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: papers,
            collections: collections,
            selectedPaperID: papers.first?.id
        ))
        return (LibraryStore(persistence: persistence), persistence, directory)
    }

    @MainActor
    func testSourcesComposeBeforeSearchAndStatusFilters() throws {
        let collectionID = UUID()
        let reading = makePaper(title: "Target Reading", collectionIDs: [collectionID])
        var unfiled = makePaper(title: "Target Unfiled")
        unfiled.readingStatus = .finished
        let collection = CollectionRecord(id: collectionID, name: "课题")
        let (store, _, directory) = try makeStore(
            papers: [reading, unfiled],
            collections: [collection]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(store.count(in: .all), 2)
        XCTAssertEqual(store.count(in: .unfiled), 1)
        XCTAssertEqual(store.count(in: .collection(collectionID)), 1)
        XCTAssertEqual(
            store.papers(
                in: .collection(collectionID),
                matching: "target",
                status: .unread,
                sortedBy: .title
            ).map(\.id),
            [reading.id]
        )
    }

    @MainActor
    func testCreateRenameDeleteAndUndoRoundTrip() throws {
        let paper = makePaper(title: "Paper")
        let (store, persistence, directory) = try makeStore(papers: [paper])
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()

        let collectionID = try store.createCollection(named: "  Migration  ")
        try store.setMembership(
            of: [paper.id],
            in: collectionID,
            isMember: true
        )
        try store.renameCollection(id: collectionID, to: "迁移学习")
        try store.deleteCollection(id: collectionID, undoManager: undoManager)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertTrue(store.papers[0].collectionIDs.isEmpty)

        undoManager.undo()

        XCTAssertEqual(store.collections.first?.name, "迁移学习")
        XCTAssertEqual(store.papers.first?.collectionIDs, [collectionID])
        XCTAssertEqual(try persistence.load().snapshot.collections.first?.id, collectionID)
        XCTAssertTrue(undoManager.redoActionName.hasPrefix("文献集："))
    }

    @MainActor
    func testCollectionNameValidationUsesTrimmedLocalizedKey() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try store.createCollection(named: "Research")
        XCTAssertThrowsError(try store.createCollection(named: "  research  ")) { error in
            XCTAssertEqual(error as? LibraryStoreError, .duplicateCollectionName)
        }
        XCTAssertThrowsError(try store.createCollection(named: "  \n")) { error in
            XCTAssertEqual(error as? LibraryStoreError, .invalidCollectionName)
        }
    }

    @MainActor
    func testBatchMembershipIsSetSemanticAndOneUndoStep() throws {
        let collection = CollectionRecord(name: "Batch")
        let first = makePaper(title: "First")
        let second = makePaper(title: "Second", collectionIDs: [collection.id])
        let (store, _, directory) = try makeStore(
            papers: [first, second],
            collections: [collection]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()
        let ids: Set<UUID> = [first.id, second.id]

        XCTAssertEqual(store.membershipState(paperIDs: ids, collectionID: collection.id), .mixed)
        try store.setMembership(
            of: ids,
            in: collection.id,
            isMember: true,
            undoManager: undoManager
        )
        XCTAssertEqual(store.membershipState(paperIDs: ids, collectionID: collection.id), .on)
        XCTAssertEqual(undoManager.undoActionName, "文献集：加入 2 篇")

        undoManager.undo()

        XCTAssertEqual(store.membershipState(paperIDs: ids, collectionID: collection.id), .mixed)
    }

    @MainActor
    func testFailedCollectionSaveDoesNotPublishCandidate() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let persistence = LibraryPersistence(fileURL: directory.appendingPathComponent("library.json"))
        try persistence.save(.empty)
        let store = LibraryStore(persistence: persistence)
        try FileManager.default.removeItem(at: directory)
        try Data("blocking-file".utf8).write(to: directory)

        XCTAssertThrowsError(try store.createCollection(named: "Should Roll Back"))
        XCTAssertTrue(store.collections.isEmpty)
    }
}
