import Foundation
import XCTest
@testable import Lurume

final class HighlightPersistenceTests: XCTestCase {
    func testRoundTripPreservesHighlightSnapshot() throws {
        let persistence = HighlightPersistence(fileURL: try temporaryFileURL())
        let record = try makeRecord()
        let snapshot = HighlightSnapshot(
            schemaVersion: HighlightSchema.currentVersion,
            highlights: [record]
        )

        try persistence.save(snapshot)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded.snapshot, snapshot)
        XCTAssertEqual(loaded.invalidRecordCount, 0)
    }

    func testMissingFileLoadsEmptySnapshot() throws {
        let persistence = HighlightPersistence(fileURL: try temporaryFileURL())
        XCTAssertEqual(try persistence.load(), .empty)
    }

    func testFutureSchemaIsRejectedWithoutOverwritingFile() throws {
        let fileURL = try temporaryFileURL()
        let original = Data(#"{"schemaVersion":99,"highlights":[]}"#.utf8)
        try original.write(to: fileURL)
        let persistence = HighlightPersistence(fileURL: fileURL)

        XCTAssertThrowsError(try persistence.load()) { error in
            XCTAssertEqual(
                error as? HighlightPersistenceError,
                .unsupportedSchema(found: 99)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testPartiallyCorruptSnapshotReturnsValidRecordsAndCount() throws {
        let fileURL = try temporaryFileURL()
        let record = try makeRecord()
        let validData = try encoder.encode(record)
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        let root: [String: Any] = [
            "schemaVersion": HighlightSchema.currentVersion,
            "highlights": [validObject, ["id": "broken"]],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let loaded = try HighlightPersistence(fileURL: fileURL).load()

        XCTAssertEqual(loaded.snapshot.highlights, [record])
        XCTAssertEqual(loaded.invalidRecordCount, 1)
    }

    @MainActor
    func testStoreBecomesReadOnlyWhenAnyRecordIsCorrupt() throws {
        let fileURL = try temporaryFileURL()
        let root: [String: Any] = [
            "schemaVersion": HighlightSchema.currentVersion,
            "highlights": [["id": "broken"]],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let store = HighlightStore(persistence: HighlightPersistence(fileURL: fileURL))

        XCTAssertTrue(store.persistenceDisabled)
        XCTAssertNotNil(store.persistenceFailure)
        XCTAssertTrue(store.highlights.isEmpty)
        XCTAssertNil(store.toggle(try makeRecord(), undoManager: nil))
    }

    @MainActor
    func testTogglePersistsAndUndoRedoRoundTrips() throws {
        let fileURL = try temporaryFileURL()
        let store = HighlightStore(persistence: HighlightPersistence(fileURL: fileURL))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let record = try makeRecord()

        undoManager.beginUndoGrouping()
        XCTAssertEqual(store.toggle(record, undoManager: undoManager), .added(record))
        XCTAssertEqual(store.highlights, [record])
        undoManager.endUndoGrouping()

        let duplicate = try XCTUnwrap(HighlightRecord(
            paperID: record.paperID,
            rawText: "same geometry, different text",
            segments: record.segments
        ))
        undoManager.beginUndoGrouping()
        XCTAssertEqual(store.toggle(duplicate, undoManager: undoManager), .removed(record))
        XCTAssertTrue(store.highlights.isEmpty)
        undoManager.endUndoGrouping()
        XCTAssertEqual(undoManager.undoActionName, "删除高亮")

        undoManager.undo()
        XCTAssertEqual(store.highlights, [record])
        XCTAssertEqual(undoManager.redoActionName, "删除高亮")
        undoManager.redo()
        XCTAssertTrue(store.highlights.isEmpty)

        XCTAssertTrue(try HighlightPersistence(fileURL: fileURL).load().snapshot.highlights.isEmpty)
    }

    @MainActor
    func testFailedSaveDoesNotPublishMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lurume-HighlightTests-\(UUID().uuidString)")
        let fileURL = root.appendingPathComponent("nested/highlights.json")
        let store = HighlightStore(persistence: HighlightPersistence(fileURL: fileURL))
        try Data("not a directory".utf8).write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(store.toggle(try makeRecord(), undoManager: nil))
        XCTAssertTrue(store.highlights.isEmpty)
        XCTAssertNotNil(store.presentedError)
    }

    func testInvalidGeometryIsRejected() {
        XCTAssertNil(HighlightRect(cgRect: .zero))
        XCTAssertNil(
            HighlightRect(
                cgRect: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)
            )
        )
    }

    func testCrossPageRecordUsesOneLogicalItemAndPageRange() throws {
        let paperID = UUID()
        let firstRect = try XCTUnwrap(
            HighlightRect(cgRect: CGRect(x: 20, y: 30, width: 120, height: 16))
        )
        let secondRect = try XCTUnwrap(
            HighlightRect(cgRect: CGRect(x: 20, y: 700, width: 80, height: 16))
        )
        let record = try XCTUnwrap(
            HighlightRecord(
                paperID: paperID,
                rawText: "cross page selection",
                segments: [
                    try XCTUnwrap(HighlightSegment(pageIndex: 3, rects: [firstRect])),
                    try XCTUnwrap(HighlightSegment(pageIndex: 4, rects: [secondRect])),
                ]
            )
        )

        XCTAssertEqual(record.segments.count, 2)
        XCTAssertEqual(record.pageLabel, "第 4–5 页")
    }

    @MainActor
    func testPartialOverlapRemainsIndependent() throws {
        let store = HighlightStore(
            persistence: HighlightPersistence(fileURL: try temporaryFileURL())
        )
        let paperID = UUID()
        let first = try makeRecord(paperID: paperID, x: 20, width: 120)
        let overlapping = try makeRecord(paperID: paperID, x: 40, width: 120)

        XCTAssertEqual(store.toggle(first, undoManager: nil), .added(first))
        XCTAssertEqual(store.toggle(overlapping, undoManager: nil), .added(overlapping))
        XCTAssertEqual(store.highlights.count, 2)
    }

    @MainActor
    func testDocumentOrderingAndRemoveAllRestoreRoundTrip() throws {
        let fileURL = try temporaryFileURL()
        let store = HighlightStore(persistence: HighlightPersistence(fileURL: fileURL))
        let paperID = UUID()
        let otherPaperID = UUID()
        let laterPage = try makeRecord(paperID: paperID, pageIndex: 3, y: 700)
        let lowerOnFirstPage = try makeRecord(paperID: paperID, pageIndex: 1, y: 200)
        let upperOnFirstPage = try makeRecord(paperID: paperID, pageIndex: 1, y: 600)
        let otherPaper = try makeRecord(paperID: otherPaperID, pageIndex: 0)

        for record in [laterPage, lowerOnFirstPage, upperOnFirstPage, otherPaper] {
            XCTAssertNotNil(store.toggle(record, undoManager: nil))
        }
        XCTAssertEqual(
            store.highlights(for: paperID).map(\.id),
            [upperOnFirstPage.id, lowerOnFirstPage.id, laterPage.id]
        )

        let removed = try store.removeAll(for: paperID)
        XCTAssertEqual(Set(removed.map(\.id)), Set([laterPage.id, lowerOnFirstPage.id, upperOnFirstPage.id]))
        XCTAssertEqual(store.highlights, [otherPaper])

        try store.restore(removed)
        XCTAssertEqual(store.count(for: paperID), 3)
        XCTAssertEqual(
            try HighlightPersistence(fileURL: fileURL).load().snapshot.highlights.count,
            4
        )
    }

    private func makeRecord(
        paperID: UUID = UUID(),
        pageIndex: Int = 2,
        x: CGFloat = 20,
        y: CGFloat = 30,
        width: CGFloat = 120
    ) throws -> HighlightRecord {
        let rect = try XCTUnwrap(
            HighlightRect(cgRect: CGRect(x: x, y: y, width: width, height: 16))
        )
        let segment = try XCTUnwrap(
            HighlightSegment(pageIndex: pageIndex, rects: [rect])
        )
        return try XCTUnwrap(
            HighlightRecord(
                paperID: paperID,
                rawText: "highlighted text",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                segments: [segment]
            )
        )
    }

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lurume-HighlightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("highlights.json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
