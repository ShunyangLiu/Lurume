import AppKit
import Foundation
import XCTest
@testable import Lurume

final class LibrarySaveSafetyTests: XCTestCase {
    @MainActor
    func testFailedTitleSaveRemainsPendingAndRetryPersistsIt() throws {
        let fixture = try makeFixture()
        try fixture.blockWrites()
        fixture.store.setManualTitle("Unsaved title", for: fixture.paper.id)

        XCTAssertEqual(fixture.store.papers.first?.title, "Unsaved title")
        XCTAssertEqual(try fixture.persistence.load().snapshot.papers.first?.title, "Original title")
        XCTAssertTrue(fixture.store.hasUnsavedChanges)
        XCTAssertFalse(fixture.store.flushPendingSave())
        XCTAssertNotNil(fixture.store.presentedError)

        try fixture.restoreWrites()
        XCTAssertTrue(fixture.store.flushPendingSave())
        XCTAssertFalse(fixture.store.hasUnsavedChanges)
        XCTAssertEqual(try fixture.persistence.load().snapshot.papers.first?.title, "Unsaved title")
    }

    @MainActor
    func testUnchangedLibraryCanExitEvenIfDirectoryStopsBeingWritable() throws {
        let fixture = try makeFixture()
        try fixture.blockWrites()
        XCTAssertFalse(fixture.store.hasUnsavedChanges)
        XCTAssertTrue(fixture.store.flushPendingSave())
        XCTAssertNil(fixture.store.presentedError)
    }

    @MainActor
    func testReadOnlyLibraryCanExitWithoutOverwritingCorruptData() throws {
        let fixture = try makeFixture()
        let corrupt = Data("{ invalid library".utf8)
        try corrupt.write(to: fixture.persistence.fileURL)
        let store = LibraryStore(persistence: fixture.persistence)
        XCTAssertTrue(store.persistenceDisabled)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertTrue(store.flushPendingSave())
        XCTAssertEqual(try Data(contentsOf: fixture.persistence.fileURL), corrupt)
    }

    @MainActor
    func testPendingPageSaveReportsFailureAndCanBeRetried() throws {
        let fixture = try makeFixture()
        try fixture.blockWrites()
        fixture.store.updatePageIndex(12, for: fixture.paper.id)
        XCTAssertFalse(fixture.store.flushPendingSave())
        XCTAssertTrue(fixture.store.hasUnsavedChanges)
        try fixture.restoreWrites()
        XCTAssertTrue(fixture.store.flushPendingSave())
        XCTAssertFalse(fixture.store.hasUnsavedChanges)
        XCTAssertEqual(try fixture.persistence.load().snapshot.papers.first?.lastPageIndex, 12)
    }

    @MainActor
    func testFailedRelinkPreservesFileReferenceAndUnavailableStateThenCanRetry() throws {
        let fixture = try makeFixture()
        XCTAssertNil(fixture.store.resolveFile(for: fixture.paper.id))
        XCTAssertEqual(fixture.store.unavailablePaperIDs, [fixture.paper.id])
        let before = fixture.store.papers
        let diskBefore = try Data(contentsOf: fixture.persistence.fileURL)
        try fixture.blockWrites()

        XCTAssertThrowsError(try fixture.store.relinkPaper(id: fixture.paper.id, to: fixture.replacementURL))
        XCTAssertEqual(fixture.store.papers, before)
        XCTAssertEqual(fixture.store.unavailablePaperIDs, [fixture.paper.id])
        XCTAssertEqual(try Data(contentsOf: fixture.persistence.fileURL), diskBefore)
        XCTAssertFalse(fixture.store.hasUnsavedChanges)

        try fixture.restoreWrites()
        try fixture.store.relinkPaper(id: fixture.paper.id, to: fixture.replacementURL)
        XCTAssertTrue(fixture.store.unavailablePaperIDs.isEmpty)
        XCTAssertEqual(fixture.store.papers.first?.fallbackPath, fixture.replacementURL.path)
        XCTAssertEqual(fixture.store.papers.first?.originalFileName, "replacement.pdf")
        XCTAssertEqual(try fixture.persistence.load().snapshot.papers, fixture.store.papers)
        XCTAssertFalse(fixture.store.hasUnsavedChanges)
    }

    @MainActor
    func testFailedLibrarySaveBlocksQuitAndUpdaterUntilRetrySucceeds() throws {
        let fixture = try makeFixture()
        try fixture.blockWrites()
        fixture.store.setManualTitle("Pending title", for: fixture.paper.id)
        var noteChecks = 0
        let boundary = ApplicationTerminationSaveBoundary(
            flushPendingLibrarySave: fixture.store.flushPendingSave,
            confirmDiscardingLibraryChanges: { false },
            prepareNotesForExit: { noteChecks += 1; return true }
        )
        let termination = LurumeTerminationController()
        termination.prepareForTermination = boundary.prepareForTermination
        XCTAssertEqual(termination.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        let updater = LurumeUpdaterDelegate()
        updater.mayRelaunch = boundary.prepareForTermination
        var installed = 0
        XCTAssertTrue(updater.postponeRelaunchIfNeeded { installed += 1 })
        updater.resumePendingRelaunch()
        XCTAssertEqual(installed, 0)
        XCTAssertEqual(noteChecks, 0)

        try fixture.restoreWrites()
        updater.resumePendingRelaunch()
        updater.resumePendingRelaunch()
        XCTAssertEqual(installed, 1)
        XCTAssertEqual(noteChecks, 1)
        XCTAssertEqual(try fixture.persistence.load().snapshot.papers.first?.title, "Pending title")
        XCTAssertEqual(termination.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    @MainActor
    func testExplicitDiscardStillHonorsUnsavedNoteProtection() {
        var notesMayExit = false
        var confirmations = 0
        let boundary = ApplicationTerminationSaveBoundary(
            flushPendingLibrarySave: { false },
            confirmDiscardingLibraryChanges: { confirmations += 1; return true },
            prepareNotesForExit: { notesMayExit }
        )
        XCTAssertFalse(boundary.prepareForTermination())
        notesMayExit = true
        XCTAssertTrue(boundary.prepareForTermination())
        XCTAssertEqual(confirmations, 2)
    }

    @MainActor
    func testSuccessfulSaveSkipsDiscardConfirmationAndChecksNotes() {
        var events: [String] = []
        let boundary = ApplicationTerminationSaveBoundary(
            flushPendingLibrarySave: { events.append("library"); return true },
            confirmDiscardingLibraryChanges: { XCTFail("Saved changes need no discard confirmation"); return false },
            prepareNotesForExit: { events.append("notes"); return true }
        )
        XCTAssertTrue(boundary.prepareForTermination())
        XCTAssertEqual(events, ["library", "notes"])
    }

    @MainActor
    private func makeFixture() throws -> LibrarySaveFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lurume-SaveSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try LibrarySaveFixture(directory: directory)
    }
}

@MainActor
private struct LibrarySaveFixture {
    let persistence: LibraryPersistence
    let store: LibraryStore
    let paper: PaperRecord
    let replacementURL: URL

    init(directory: URL) throws {
        persistence = LibraryPersistence(fileURL: directory.appendingPathComponent("library.json"))
        replacementURL = directory.appendingPathComponent("replacement.pdf")
        // Relinking tests bookmark persistence, not PDF parsing; no real document is used.
        try Data("temporary bookmark fixture".utf8).write(to: replacementURL)
        paper = PaperRecord(
            identity: FileIdentity(volumeUUID: nil, documentIdentifier: nil,
                                   fallbackPath: directory.appendingPathComponent("missing.pdf").path),
            bookmarkData: Data(),
            initialTitle: "Original title",
            originalFileName: "missing.pdf",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try persistence.save(LibrarySnapshot(schemaVersion: LibrarySchema.currentVersion,
                                             papers: [paper], selectedPaperID: paper.id))
        store = LibraryStore(persistence: persistence)
    }

    func blockWrites() throws {
        try FileManager.default.createDirectory(at: persistence.fileURL.appendingPathExtension("previous"),
                                                withIntermediateDirectories: false)
    }

    func restoreWrites() throws {
        try FileManager.default.removeItem(at: persistence.fileURL.appendingPathExtension("previous"))
    }
}
