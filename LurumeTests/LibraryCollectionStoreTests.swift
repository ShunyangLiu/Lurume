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
            initialTitle: title,
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

    @MainActor
    func testImportIntoCollectionAlsoClassifiesExistingDuplicate() throws {
        let collection = CollectionRecord(name: "Imports")
        let (store, persistence, directory) = try makeStore(collections: [collection])
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdfURL = directory.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdfURL)

        let firstID = try store.importPDF(
            at: pdfURL,
            selectAfterImport: false
        )
        let duplicateID = try store.importPDF(
            at: pdfURL,
            collectionID: collection.id,
            selectAfterImport: false
        )

        XCTAssertEqual(firstID, duplicateID)
        XCTAssertEqual(store.papers.count, 1)
        XCTAssertEqual(store.papers.first?.collectionIDs, [collection.id])
        XCTAssertNil(store.selectedPaperID)
        XCTAssertEqual(
            try persistence.load().snapshot.papers.first?.collectionIDs,
            [collection.id]
        )
    }

    @MainActor
    func testBatchImportFailurePublishesNoneOfTheEarlierFiles() throws {
        let (store, persistence, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validURL = directory.appendingPathComponent("valid.pdf")
        let missingURL = directory.appendingPathComponent("missing.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: validURL)

        XCTAssertThrowsError(try store.importPDFBatch(
            at: [validURL, missingURL],
            selectAfterImport: false
        ))

        XCTAssertTrue(store.papers.isEmpty)
        XCTAssertTrue(try persistence.load().snapshot.papers.isEmpty)
    }

    @MainActor
    func testNestedSourceRecursivelyDeduplicatesMembersAndCounts() throws {
        let root = CollectionRecord(name: "Root")
        let first = CollectionRecord(name: "First", parentID: root.id)
        let second = CollectionRecord(name: "Second", parentID: root.id)
        let shared = makePaper(title: "Shared", collectionIDs: [first.id, second.id])
        let direct = makePaper(title: "Direct", collectionIDs: [root.id])
        let (store, _, directory) = try makeStore(
            papers: [shared, direct],
            collections: [root, first, second]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(store.count(in: .collection(root.id)), 2)
        XCTAssertEqual(
            Set(store.papers(in: .collection(root.id), matching: "").map(\.id)),
            [shared.id, direct.id]
        )
        XCTAssertEqual(store.count(in: .collection(first.id)), 1)
    }

    @MainActor
    func testCreateMoveRenameUseSiblingNamesAndRejectCyclesWithUndo() throws {
        let left = CollectionRecord(name: "Left")
        let right = CollectionRecord(name: "Right")
        let child = CollectionRecord(name: "Papers", parentID: left.id)
        let (store, persistence, directory) = try makeStore(collections: [left, right, child])
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()

        let rightChildID = try store.createCollection(named: "Papers", parentID: right.id)
        XCTAssertThrowsError(try store.createCollection(named: " papers ", parentID: left.id)) {
            XCTAssertEqual($0 as? LibraryStoreError, .duplicateCollectionName)
        }
        XCTAssertFalse(store.canMoveCollection(child.id, to: right.id))
        try store.renameCollection(id: rightChildID, to: "Other")
        XCTAssertTrue(store.canMoveCollection(child.id, to: right.id))
        XCTAssertThrowsError(try store.moveCollection(id: left.id, toParentID: child.id)) {
            XCTAssertEqual($0 as? LibraryStoreError, .invalidCollectionMove)
        }

        try store.moveCollection(id: child.id, toParentID: right.id, undoManager: undoManager)
        XCTAssertEqual(store.collections.first(where: { $0.id == child.id })?.parentID, right.id)
        XCTAssertTrue(store.collections.first(where: { $0.id == child.id })?.wasManuallyOrganized == true)

        undoManager.undo()
        XCTAssertEqual(store.collections.first(where: { $0.id == child.id })?.parentID, left.id)
        XCTAssertEqual(
            try persistence.load().snapshot.collections.first(where: { $0.id == child.id })?.parentID,
            left.id
        )
    }

    @MainActor
    func testCreateAndRenameEachProvideACompleteUndoStep() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()

        let id = try store.createCollection(
            named: "Draft",
            undoManager: undoManager
        )
        XCTAssertEqual(store.collections.first?.name, "Draft")
        undoManager.undo()
        XCTAssertTrue(store.collections.isEmpty)
        undoManager.redo()
        XCTAssertEqual(store.collections.first?.id, id)

        try store.renameCollection(
            id: id,
            to: "Final",
            undoManager: undoManager
        )
        XCTAssertEqual(store.collections.first?.name, "Final")
        undoManager.undo()
        XCTAssertEqual(store.collections.first?.name, "Draft")
    }

    @MainActor
    func testRecursiveDeleteSummaryAndUndoRestoreWholeSubtreeAndMemberships() throws {
        let root = CollectionRecord(name: "Root")
        let child = CollectionRecord(name: "Child", parentID: root.id)
        let leaf = CollectionRecord(name: "Leaf", parentID: child.id)
        let outside = CollectionRecord(name: "Outside")
        let first = makePaper(title: "First", collectionIDs: [root.id, leaf.id, outside.id])
        let second = makePaper(title: "Second", collectionIDs: [child.id])
        let (store, _, directory) = try makeStore(
            papers: [first, second],
            collections: [root, child, leaf, outside]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()

        XCTAssertEqual(
            store.deletionSummary(forCollectionID: root.id),
            CollectionDeletionSummary(collectionCount: 3, affectedPaperCount: 2)
        )
        try store.deleteCollection(id: root.id, undoManager: undoManager)
        XCTAssertEqual(store.collections.map(\.id), [outside.id])
        XCTAssertEqual(store.papers[0].collectionIDs, [outside.id])
        XCTAssertTrue(store.papers[1].collectionIDs.isEmpty)

        undoManager.undo()
        XCTAssertEqual(Set(store.collections.map(\.id)), [root.id, child.id, leaf.id, outside.id])
        XCTAssertEqual(store.papers[0].collectionIDs, first.collectionIDs)
        XCTAssertEqual(store.papers[1].collectionIDs, second.collectionIDs)
    }

    @MainActor
    func testRemovingFromParentHierarchyRemovesDescendantMembershipsInOneUndoStep() throws {
        let root = CollectionRecord(name: "Root")
        let child = CollectionRecord(name: "Child", parentID: root.id)
        let outside = CollectionRecord(name: "Outside")
        let paper = makePaper(title: "Paper", collectionIDs: [child.id, outside.id])
        let (store, _, directory) = try makeStore(
            papers: [paper],
            collections: [root, child, outside]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()

        try store.removeMemberships(
            of: [paper.id],
            fromCollectionHierarchy: root.id,
            undoManager: undoManager
        )
        XCTAssertEqual(store.papers.first?.collectionIDs, [outside.id])

        undoManager.undo()
        XCTAssertEqual(store.papers.first?.collectionIDs, paper.collectionIDs)

        XCTAssertThrowsError(try store.removeMemberships(
            of: [UUID()],
            fromCollectionHierarchy: root.id
        )) {
            XCTAssertEqual($0 as? LibraryStoreError, .paperNotFound)
        }
    }

    @MainActor
    func testStructuredMetadataSaveIsAtomicAndMarksOnlyChangedFields() throws {
        let paper = makePaper(title: "Paper")
        let (store, persistence, directory) = try makeStore(papers: [paper])
        defer { try? FileManager.default.removeItem(at: directory) }
        var metadata = paper.metadata
        metadata.containerTitle = "Journal"
        metadata.language = "en"

        try store.setManualMetadata(
            metadata,
            attachmentLabel: "Accepted manuscript",
            for: paper.id
        )

        let saved = try XCTUnwrap(store.papers.first)
        XCTAssertEqual(saved.metadata.containerTitle, "Journal")
        XCTAssertEqual(saved.metadata.language, "en")
        XCTAssertEqual(saved.attachmentLabel, "Accepted manuscript")
        XCTAssertEqual(saved.manuallyEditedFields, [.containerTitle, .language])
        XCTAssertEqual(try persistence.load().snapshot.papers.first, saved)
    }
}
