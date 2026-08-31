import Foundation
import XCTest
@testable import Lurume

final class PaperRemovalCoordinatorTests: XCTestCase {
    private func makePaper(id: UUID = UUID()) -> PaperRecord {
        PaperRecord(
            id: id,
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: nil,
                fallbackPath: "/tmp/\(id.uuidString).pdf"
            ),
            bookmarkData: Data(),
            initialTitle: "Paper",
            originalFileName: "\(id.uuidString).pdf"
        )
    }

    private func makeHighlight(paperID: UUID) throws -> HighlightRecord {
        let rect = try XCTUnwrap(HighlightRect(cgRect: .init(x: 1, y: 2, width: 30, height: 8)))
        let segment = try XCTUnwrap(HighlightSegment(pageIndex: 0, rects: [rect]))
        return try XCTUnwrap(HighlightRecord(
            paperID: paperID,
            rawText: "highlight",
            segments: [segment],
            noteText: "note"
        ))
    }

    @MainActor
    func testBatchRemovalAndUndoRestorePapersHighlightsAndNotesTogether() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryPersistence = LibraryPersistence(
            fileURL: directory.appendingPathComponent("library.json")
        )
        let highlightPersistence = HighlightPersistence(
            fileURL: directory.appendingPathComponent("highlights.json")
        )
        let first = makePaper()
        let second = makePaper()
        let highlight = try makeHighlight(paperID: first.id)
        try libraryPersistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [first, second],
            selectedPaperID: first.id
        ))
        try highlightPersistence.save(HighlightSnapshot(
            schemaVersion: HighlightSchema.currentVersion,
            highlights: [highlight]
        ))
        let libraryStore = LibraryStore(persistence: libraryPersistence)
        let highlightStore = HighlightStore(persistence: highlightPersistence)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let coordinator = PaperRemovalCoordinator(
            libraryStore: libraryStore,
            highlightStore: highlightStore
        )

        undoManager.beginUndoGrouping()
        try coordinator.remove(
            paperIDs: [first.id, second.id],
            undoManager: undoManager
        )
        undoManager.endUndoGrouping()
        XCTAssertTrue(libraryStore.papers.isEmpty)
        XCTAssertTrue(highlightStore.highlights.isEmpty)
        XCTAssertEqual(undoManager.undoActionName, "文献库：移除 2 篇")

        undoManager.undo()

        XCTAssertEqual(Set(libraryStore.papers.map(\.id)), [first.id, second.id])
        XCTAssertEqual(highlightStore.highlights.map(\.id), [highlight.id])
        XCTAssertEqual(highlightStore.highlights.first?.noteText, "note")
        XCTAssertEqual(undoManager.redoActionName, "文献库：移除 2 篇")
    }

    @MainActor
    func testLibraryFailureRollsBackAlreadyRemovedHighlights() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryDirectory = parent.appendingPathComponent("library", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let libraryPersistence = LibraryPersistence(
            fileURL: libraryDirectory.appendingPathComponent("library.json")
        )
        let highlightPersistence = HighlightPersistence(
            fileURL: parent.appendingPathComponent("highlights.json")
        )
        let paper = makePaper()
        let highlight = try makeHighlight(paperID: paper.id)
        try libraryPersistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [paper],
            selectedPaperID: paper.id
        ))
        try highlightPersistence.save(HighlightSnapshot(
            schemaVersion: HighlightSchema.currentVersion,
            highlights: [highlight]
        ))
        let libraryStore = LibraryStore(persistence: libraryPersistence)
        let highlightStore = HighlightStore(persistence: highlightPersistence)
        try FileManager.default.removeItem(at: libraryDirectory)
        try Data("blocking-file".utf8).write(to: libraryDirectory)
        let coordinator = PaperRemovalCoordinator(
            libraryStore: libraryStore,
            highlightStore: highlightStore
        )

        XCTAssertThrowsError(try coordinator.remove(paperIDs: [paper.id], undoManager: nil))
        XCTAssertEqual(libraryStore.papers.map(\.id), [paper.id])
        XCTAssertEqual(highlightStore.highlights.map(\.id), [highlight.id])
        XCTAssertEqual(
            try highlightPersistence.load().snapshot.highlights.map(\.id),
            [highlight.id]
        )
    }
}
