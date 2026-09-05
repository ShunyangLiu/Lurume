import Foundation
import XCTest
@testable import Lurume

final class ReaderModeTransitionTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        func read() -> Int {
            lock.withLock { value }
        }
    }

    @MainActor
    func testLeavingReadingModeFlushesBeforeDetachingAndReleasingAccess() {
        var events: [String] = []
        let boundary = ReadingSessionBoundary(
            flushPendingPageSave: { events.append("page") },
            closeNoteEditor: { events.append("note") },
            detachReader: { events.append("detach") },
            releaseSecurityScope: { events.append("scope") }
        )

        boundary.leaveReadingMode()

        XCTAssertEqual(events, ["page", "note", "detach", "scope"])
    }

    @MainActor
    func testLeavingReadingModePersistsPendingPageImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(
            fileURL: directory.appendingPathComponent("library.json")
        )
        let paper = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: 5,
                fallbackPath: "/tmp/page.pdf"
            ),
            bookmarkData: Data(),
            initialTitle: "Page"
        )
        try persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [paper],
            selectedPaperID: paper.id
        ))
        let store = LibraryStore(persistence: persistence)
        store.updatePageIndex(27, for: paper.id)
        let boundary = ReadingSessionBoundary(
            flushPendingPageSave: store.flushPendingSave,
            closeNoteEditor: {},
            detachReader: {},
            releaseSecurityScope: {}
        )

        boundary.leaveReadingMode()

        XCTAssertEqual(try persistence.load().snapshot.papers.first?.lastPageIndex, 27)
    }

    @MainActor
    func testClosingNoteBoundaryFlushesDraft() {
        var savedText: String?
        let model = HighlightNoteDraftModel(
            text: "旧笔记",
            persistedText: "旧笔记",
            readOnly: false,
            save: { value in
                savedText = value
                return true
            },
            onDraftChanged: { _ in },
            onSaveSucceeded: {}
        )
        model.text = "切换前的新笔记"
        let boundary = ReadingSessionBoundary(
            flushPendingPageSave: {},
            closeNoteEditor: model.flush,
            detachReader: {},
            releaseSecurityScope: {}
        )

        boundary.leaveReadingMode()

        XCTAssertEqual(savedText, "切换前的新笔记")
    }

    @MainActor
    func testUpdateInstallationFlushesLibraryAndNoteBeforeRelaunch() {
        var events: [String] = []
        let boundary = UpdateInstallationSaveBoundary(
            flushPendingLibrarySave: { events.append("library") },
            closeNoteEditor: { events.append("note") }
        )

        boundary.prepareForInstallation()

        XCTAssertEqual(events, ["library", "note"])
    }

    @MainActor
    func testTerminationHonorsUnsavedNoteBoundary() {
        let controller = LurumeTerminationController()
        controller.prepareForTermination = { false }
        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        controller.prepareForTermination = { true }
        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    @MainActor
    func testUpdateRelaunchWaitsForSaveApprovalAndResumesOnce() {
        let delegate = LurumeUpdaterDelegate()
        var mayExit = false
        var installed = 0
        delegate.mayRelaunch = { mayExit }
        XCTAssertTrue(delegate.postponeRelaunchIfNeeded { installed += 1 })
        delegate.resumePendingRelaunch()
        XCTAssertEqual(installed, 0)
        mayExit = true
        delegate.resumePendingRelaunch()
        delegate.resumePendingRelaunch()
        XCTAssertEqual(installed, 1)
        XCTAssertNil(delegate.pendingRelaunch)
    }

    @MainActor
    func testSecurityScopedAccessStopsExactlyOnceAfterRelease() {
        let startCount = LockedCounter()
        let stopCount = LockedCounter()
        var access: SecurityScopedAccess? = SecurityScopedAccess(
            url: URL(fileURLWithPath: "/tmp/paper.pdf"),
            startAccessing: { _ in
                startCount.increment()
                return true
            },
            stopAccessing: { _ in stopCount.increment() }
        )
        XCTAssertNotNil(access)
        XCTAssertEqual(startCount.read(), 1)
        XCTAssertEqual(stopCount.read(), 0)

        access = nil

        XCTAssertEqual(stopCount.read(), 1)
    }

    @MainActor
    func testMainWindowModePersistsAndInvalidValueFallsBackToReading() {
        let suiteName = "LurumeTests.MainWindowMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mainWindowMode, .reading)
        settings.mainWindowMode = .library
        XCTAssertEqual(AppSettings(defaults: defaults).mainWindowMode, .library)

        defaults.set("future-mode", forKey: "mainWindowMode")
        XCTAssertEqual(AppSettings(defaults: defaults).mainWindowMode, .reading)
    }

    func testLibraryModeDoesNotOverwriteReaderInspectorVisibility() {
        XCTAssertNil(
            ReaderInspectorPresentationPolicy.persistedValue(false, while: .library)
        )
        XCTAssertEqual(
            ReaderInspectorPresentationPolicy.persistedValue(false, while: .reading),
            false
        )
        XCTAssertEqual(
            ReaderInspectorPresentationPolicy.persistedValue(true, while: .reading),
            true
        )
    }

    @MainActor
    func testLastLibrarySourcePersistsAndMalformedValueFallsBackToAll() {
        let suiteName = "LurumeTests.LibrarySource.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let collectionID = UUID()

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.lastLibrarySource, .all)
        settings.lastLibrarySource = .collection(collectionID)
        XCTAssertEqual(
            AppSettings(defaults: defaults).lastLibrarySource,
            .collection(collectionID)
        )

        defaults.set("collection:not-a-uuid", forKey: "lastLibrarySource")
        XCTAssertEqual(AppSettings(defaults: defaults).lastLibrarySource, .all)
    }

    func testReadingSidebarInheritsOnlyAValidSourceContainingTheOpenedPaper() {
        let collection = CollectionRecord(name: "课题")
        let paper = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: nil,
                fallbackPath: "/tmp/paper.pdf"
            ),
            bookmarkData: Data(),
            initialTitle: "Paper",
            collectionIDs: [collection.id]
        )

        XCTAssertEqual(
            ReadingSidebarSourcePolicy.resolvedSource(
                proposed: .collection(collection.id),
                selectedPaperID: paper.id,
                papers: [paper],
                collections: [collection]
            ),
            .collection(collection.id)
        )
        XCTAssertEqual(
            ReadingSidebarSourcePolicy.resolvedSource(
                proposed: .unfiled,
                selectedPaperID: paper.id,
                papers: [paper],
                collections: [collection]
            ),
            .all
        )
        XCTAssertEqual(
            ReadingSidebarSourcePolicy.resolvedSource(
                proposed: .collection(collection.id),
                selectedPaperID: paper.id,
                papers: [paper],
                collections: []
            ),
            .all
        )
    }

    func testReadingSidebarImportTargetsOnlyAValidUserCollection() {
        let collection = CollectionRecord(name: "课题")

        XCTAssertEqual(
            ReadingSidebarSourcePolicy.importCollectionID(
                for: .collection(collection.id),
                collections: [collection]
            ),
            collection.id
        )
        XCTAssertNil(
            ReadingSidebarSourcePolicy.importCollectionID(
                for: .all,
                collections: [collection]
            )
        )
        XCTAssertNil(
            ReadingSidebarSourcePolicy.importCollectionID(
                for: .collection(collection.id),
                collections: []
            )
        )
    }
}
