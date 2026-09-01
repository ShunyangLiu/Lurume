import CryptoKit
import Foundation
import XCTest

@testable import Lurume

final class P8ZoteroTransactionTests: XCTestCase {
    private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writePDF(_ url: URL, payload: String = "fixture") throws -> Data {
        let data = Data("%PDF-1.7\n\(payload)\n%%EOF\n".utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return data
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func migration(sourceURL: URL, libraryName: String = "测试/文库") -> ZoteroMigrationPreview {
        let library = ZoteroServiceLibrary(type: "user", id: 0, name: libraryName, version: nil)
        let identity = ZoteroLibraryIdentity(type: "user", id: 0)
        let collectionSource = ImportSourceIdentity.zoteroCollection(
            library: identity,
            collectionKey: "COLL1",
            serverID: "fixture"
        )
        let paperSource = ImportSourceIdentity.zoteroAttachment(
            library: identity,
            parentItemKey: "ITEM1",
            attachmentKey: "PDF1",
            serverID: "fixture"
        )
        let plan = LibraryImportPlan(
            collections: [
                PlannedImportCollection(
                    source: collectionSource,
                    name: "研究",
                    parentSource: nil
                )
            ],
            papers: [
                PlannedPaperImport(
                    source: paperSource,
                    identity: nil,
                    originalFileName: "paper.pdf",
                    metadata: BibliographicMetadata(title: "Fixture Paper"),
                    attachmentLabel: "Accepted PDF",
                    fingerprint: nil,
                    collectionSources: [collectionSource],
                    disposition: .create
                )
            ]
        )
        return ZoteroMigrationPreview(
            library: library,
            scannedItemCount: 2,
            parentItemCount: 1,
            pdfAttachmentCount: 1,
            unavailableAttachmentCount: 0,
            unsupportedAttachmentCount: 0,
            nonPDFAttachmentCount: 0,
            unsupportedItemCount: 0,
            ignoredTagCount: 0,
            ignoredRelationCount: 0,
            parentItemsWithoutPDFCount: 0,
            plannedCollectionCount: 1,
            rows: [
                ZoteroMigrationPreview.PaperRow(
                    attachmentKey: "PDF1",
                    title: "Fixture Paper",
                    fileName: "paper.pdf",
                    sourceURL: sourceURL,
                    collectionNames: ["研究"],
                    disposition: .create
                )
            ],
            plan: plan
        )
    }

    private func preview(
        migration: ZoteroMigrationPreview,
        inspected: FolderVerifiedFile,
        existingPapers: [PaperRecord] = [],
        existingCollections: [CollectionRecord] = []
    ) -> ZoteroCopyPreview {
        let source = migration.plan.papers[0].source
        var options = ZoteroCopyPreviewOptions()
        options.createdCollectionIDs[migration.plan.collections[0].source] = UUID()
        options.createdPaperIDs[source] = UUID()
        return ZoteroCopyPreviewBuilder.build(
            migration: migration,
            inspectedFiles: [source: inspected],
            existingPapers: existingPapers,
            existingCollections: existingCollections,
            options: options,
            authorizationDiagnostics: []
        )
    }

    private func authorized(_ url: URL, readOnly: Bool) throws -> ZoteroAuthorizedDirectory {
        try ZoteroPathAuthorization.authorizeDirectory(at: url, readOnly: readOnly)
    }

    @MainActor
    private func makeStore(
        under root: URL,
        papers: [PaperRecord] = [],
        collections: [CollectionRecord] = []
    ) throws -> (LibraryStore, LibraryPersistence) {
        let persistence = LibraryPersistence(fileURL: root.appendingPathComponent("library.json"))
        try persistence.save(
            LibrarySnapshot(
                schemaVersion: LibrarySchema.currentVersion,
                papers: papers,
                collections: collections,
                selectedPaperID: papers.first?.id
            ))
        return (LibraryStore(persistence: persistence), persistence)
    }

    func testAuthorizationRejectsOverlapAndSymbolicLinkCandidates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = source.appendingPathComponent("target", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsidePDF = outside.appendingPathComponent("outside.pdf")
        try writePDF(outsidePDF)
        let linkedPDF = source.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: linkedPDF, withDestinationURL: outsidePDF)

        let sourceRoot = try authorized(source, readOnly: true)
        let targetRoot = try authorized(target, readOnly: false)
        XCTAssertThrowsError(
            try ZoteroPathAuthorization.validateNoOverlap(
                sourceRoots: [sourceRoot],
                target: targetRoot
            )
        ) { error in
            XCTAssertEqual(error as? ZoteroImportAuthorizationError, .sourceTargetOverlap)
        }
        let containingTarget = try authorized(root, readOnly: false)
        XCTAssertThrowsError(
            try ZoteroPathAuthorization.validateNoOverlap(
                sourceRoots: [sourceRoot],
                target: containingTarget
            )
        ) { error in
            XCTAssertEqual(error as? ZoteroImportAuthorizationError, .sourceTargetOverlap)
        }
        XCTAssertThrowsError(
            try ZoteroPathAuthorization.authorizedRoot(
                containing: linkedPDF,
                roots: [sourceRoot]
            )
        ) { error in
            XCTAssertEqual(error as? ZoteroImportAuthorizationError, .sourceReferenceNotAllowed)
        }
    }

    func testTargetReplacementIsRejectedBeforeTransactionStarts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        let moved = root.appendingPathComponent("moved-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let authorization = try authorized(target, readOnly: false)
        try FileManager.default.moveItem(at: target, to: moved)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: replacement)
        XCTAssertThrowsError(try ZoteroPathAuthorization.validateUnchangedDirectory(authorization)) {
            XCTAssertEqual($0 as? ZoteroImportTransactionError, .targetChanged)
        }
    }

    func testReimportDecisionsCoverUnchangedChangedAndSameHashAliases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("paper.pdf")
        try writePDF(sourceURL, payload: "new")
        let inspected = try await FolderImportScanner.inspectAuthorizedPDF(at: sourceURL)
        let migration = migration(sourceURL: sourceURL)
        let source = migration.plan.papers[0].source
        let existingID = UUID()
        let oldFingerprint = PDFContentFingerprint(
            sha256: String(repeating: "0", count: 64),
            byteCount: inspected.fingerprint.byteCount,
            modificationDate: inspected.fingerprint.modificationDate
        )
        let existing = PaperRecord(
            id: existingID,
            identity: FileIdentity(
                volumeUUID: "another-volume",
                documentIdentifier: 99,
                fallbackPath: "/existing/paper.pdf"
            ),
            bookmarkData: Data("bookmark".utf8),
            initialTitle: "Existing",
            contentFingerprint: oldFingerprint,
            importSources: [source]
        )

        let defaultChanged = preview(
            migration: migration,
            inspected: inspected,
            existingPapers: [existing]
        )
        guard case .keepExistingVersion(let id) = defaultChanged.papers[0].action else {
            return XCTFail("Changed source must default to keeping the existing version")
        }
        XCTAssertEqual(id, existingID)
        XCTAssertFalse(defaultChanged.papers[0].isIncluded)

        var newVersionOptions = ZoteroCopyPreviewOptions()
        newVersionOptions.importChangedSourcesAsNew = [source]
        newVersionOptions.createdCollectionIDs[migration.plan.collections[0].source] = UUID()
        newVersionOptions.createdPaperIDs[source] = UUID()
        let newVersion = ZoteroCopyPreviewBuilder.build(
            migration: migration,
            inspectedFiles: [source: inspected],
            existingPapers: [existing],
            existingCollections: [],
            options: newVersionOptions,
            authorizationDiagnostics: []
        )
        guard case .createNewVersion(let previousID) = newVersion.papers[0].action else {
            return XCTFail("Explicit version decision must create a new record")
        }
        XCTAssertEqual(previousID, existingID)
        XCTAssertTrue(newVersion.papers[0].requiresCopy)

        var unchanged = existing
        unchanged.contentFingerprint = inspected.fingerprint
        let unchangedPreview = preview(
            migration: migration,
            inspected: inspected,
            existingPapers: [unchanged]
        )
        guard case .reuse(let id, let reason) = unchangedPreview.papers[0].action else {
            return XCTFail("Unchanged source must be reused")
        }
        XCTAssertEqual(id, existingID)
        XCTAssertEqual(reason, .source)
        XCTAssertEqual(unchangedPreview.copiedPaperCount, 0)
        let reuseTargetURL = root.appendingPathComponent("reuse-target", isDirectory: true)
        try FileManager.default.createDirectory(at: reuseTargetURL, withIntermediateDirectories: true)
        let reuseJournal = ZoteroImportJournalStore(
            fileURL: root.appendingPathComponent("reuse-journal.json"))
        let reusePrepared = try await ZoteroImportTransactionExecutor.prepare(
            preview: unchangedPreview,
            target: try authorized(reuseTargetURL, readOnly: false),
            journalStore: reuseJournal
        ) { _, _ in }
        XCTAssertFalse(reusePrepared.hasExternalChanges)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: reuseTargetURL.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reuseJournal.fileURL.path))

        var alias = unchanged
        alias.importSources = []
        let aliasPreview = preview(
            migration: migration,
            inspected: inspected,
            existingPapers: [alias]
        )
        guard case .reuse(let id, let reason) = aliasPreview.papers[0].action else {
            return XCTFail("Identical content from another source must be reused")
        }
        XCTAssertEqual(id, existingID)
        XCTAssertEqual(reason, .contentSHA256)
    }

    func testSourceChangedAfterPreviewIsSkippedAndReported() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let sourceURL = sourceRoot.appendingPathComponent("paper.pdf")
        try writePDF(sourceURL, payload: "before")
        let inspected = try await FolderImportScanner.inspectAuthorizedPDF(at: sourceURL)
        let copyPreview = preview(migration: migration(sourceURL: sourceURL), inspected: inspected)
        try writePDF(sourceURL, payload: "after changed bytes")

        let journalStore = ZoteroImportJournalStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let prepared = try await ZoteroImportTransactionExecutor.prepare(
            preview: copyPreview,
            target: try authorized(targetRoot, readOnly: false),
            journalStore: journalStore
        ) { _, _ in }
        XCTAssertTrue(prepared.copiedFiles.isEmpty)
        XCTAssertEqual(prepared.diagnostics.map(\.kind), [.sourceChanged])
        try prepared.rollback()
    }

    func testSetupFailureRemovesJournalAndDoesNotCreateLibraryDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let sourceURL = sourceRoot.appendingPathComponent("paper.pdf")
        try writePDF(sourceURL)
        let inspected = try await FolderImportScanner.inspectAuthorizedPDF(at: sourceURL)
        let copyPreview = preview(
            migration: migration(sourceURL: sourceURL, libraryName: "Setup Failure"),
            inspected: inspected
        )
        let stagingObstacle = targetRoot.appendingPathComponent(".lurume-import-staging")
        try Data("not a directory".utf8).write(to: stagingObstacle)
        let journalStore = ZoteroImportJournalStore(
            fileURL: root.appendingPathComponent("journal.json"))

        await XCTAssertThrowsErrorAsync {
            _ = try await ZoteroImportTransactionExecutor.prepare(
                preview: copyPreview,
                target: try self.authorized(targetRoot, readOnly: false),
                journalStore: journalStore
            ) { _, _ in }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalStore.fileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: targetRoot.appendingPathComponent("Setup Failure", isDirectory: true).path
            ))
    }

    func testJournalRejectsTraversalAndPartialRecoveryStopsWithoutDeleting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let target = try authorized(targetURL, readOnly: false)
        let firstURL = targetURL.appendingPathComponent("Library/first.pdf")
        let secondURL = targetURL.appendingPathComponent("Library/second.pdf")
        try writePDF(firstURL, payload: "first")
        try writePDF(secondURL, payload: "second")
        let firstID = UUID()
        let secondID = UUID()
        let store = ZoteroImportJournalStore(fileURL: root.appendingPathComponent("journal.json"))

        let unsafe = ZoteroImportJournal(
            transactionID: UUID(),
            targetBookmarkData: target.bookmarkData,
            phase: .staging,
            entries: [
                ZoteroImportJournalEntry(
                    paperID: firstID,
                    stagingRelativePath: "../escape.pdf",
                    finalRelativePath: "Library/first.pdf",
                    finalIdentity: try FileIdentity(url: firstURL)
                )
            ]
        )
        XCTAssertThrowsError(try store.save(unsafe)) { error in
            XCTAssertEqual(error as? ZoteroImportTransactionError, .invalidJournal)
        }

        let journal = ZoteroImportJournal(
            transactionID: UUID(),
            targetBookmarkData: target.bookmarkData,
            phase: .finalized,
            entries: [
                ZoteroImportJournalEntry(
                    paperID: firstID,
                    stagingRelativePath: ".lurume-import-staging/one/first.pdf",
                    finalRelativePath: "Library/first.pdf",
                    finalIdentity: try FileIdentity(url: firstURL)
                ),
                ZoteroImportJournalEntry(
                    paperID: secondID,
                    stagingRelativePath: ".lurume-import-staging/one/second.pdf",
                    finalRelativePath: "Library/second.pdf",
                    finalIdentity: try FileIdentity(url: secondURL)
                ),
            ]
        )
        try store.save(journal)
        let referencedPaper = PaperRecord(
            id: firstID,
            identity: try FileIdentity(url: firstURL),
            bookmarkData: Data("bookmark".utf8),
            initialTitle: "First"
        )
        let snapshot = LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [referencedPaper],
            collections: [],
            selectedPaperID: nil
        )
        XCTAssertThrowsError(
            try ZoteroImportRecovery.recoverIfNeeded(
                journalStore: store,
                snapshot: snapshot,
                targetOverride: target
            )
        ) { error in
            XCTAssertEqual(error as? ZoteroImportTransactionError, .recoveryNeedsReview)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @MainActor
    func testCopyTransactionNeverOverwritesPersistsAndUndoKeepsCopiedPDF() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRootURL = root.appendingPathComponent("source", isDirectory: true)
        let targetRootURL = root.appendingPathComponent("target", isDirectory: true)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)
        let sourceURL = sourceRootURL.appendingPathComponent("paper.pdf")
        let sourceData = try writePDF(sourceURL, payload: "source")
        let libraryDirectory = targetRootURL.appendingPathComponent("文库", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let existingURL = libraryDirectory.appendingPathComponent("paper.pdf")
        let existingData = try writePDF(existingURL, payload: "must survive")

        let inspected = try await FolderImportScanner.inspectAuthorizedPDF(at: sourceURL)
        let migration = migration(sourceURL: sourceURL)
        let copyPreview = preview(migration: migration, inspected: inspected)
        let target = try authorized(targetRootURL, readOnly: false)
        let journalStore = ZoteroImportJournalStore(
            fileURL: storeRoot.appendingPathComponent("transaction.json")
        )
        let prepared = try await ZoteroImportTransactionExecutor.prepare(
            preview: copyPreview,
            target: target,
            journalStore: journalStore
        ) { _, _ in }

        XCTAssertEqual(prepared.diagnostics, [])
        let copied = try XCTUnwrap(prepared.copiedFiles.values.first)
        XCTAssertEqual(copied.finalURL.lastPathComponent, "paper 2.pdf")
        XCTAssertEqual(try Data(contentsOf: existingURL), existingData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(copied.fingerprint.sha256, hash(sourceData))

        let (store, persistence) = try makeStore(under: storeRoot)
        let candidate = ZoteroImportCandidateBuilder.build(
            preview: copyPreview,
            prepared: prepared,
            existingPapers: [],
            existingCollections: []
        )
        let undo = UndoManager()
        try store.applyZoteroImport(
            candidate,
            expectedPapers: [],
            expectedCollections: [],
            undoManager: undo
        )
        try prepared.markPublishedAndClean()

        XCTAssertEqual(store.papers.count, 1)
        XCTAssertEqual(try persistence.load().snapshot.papers.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalStore.fileURL.path))
        undo.undo()
        XCTAssertTrue(store.papers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.finalURL.path))
    }

    func testRollbackAndRecoveryRemoveOnlyProvenTransactionFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRootURL = root.appendingPathComponent("source", isDirectory: true)
        let targetRootURL = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)
        let sourceURL = sourceRootURL.appendingPathComponent("paper.pdf")
        try writePDF(sourceURL)
        let inspected = try await FolderImportScanner.inspectAuthorizedPDF(at: sourceURL)
        let migration = migration(sourceURL: sourceURL, libraryName: "Recovery")
        let copyPreview = preview(migration: migration, inspected: inspected)
        let target = try authorized(targetRootURL, readOnly: false)
        let journalStore = ZoteroImportJournalStore(
            fileURL: root.appendingPathComponent("transaction.json"))

        let first = try await ZoteroImportTransactionExecutor.prepare(
            preview: copyPreview,
            target: target,
            journalStore: journalStore
        ) { _, _ in }
        XCTAssertEqual(first.diagnostics, [])
        let firstURL = try XCTUnwrap(first.copiedFiles.values.first?.finalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        try first.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: targetRootURL.appendingPathComponent("Recovery", isDirectory: true).path
            ))

        let second = try await ZoteroImportTransactionExecutor.prepare(
            preview: copyPreview,
            target: target,
            journalStore: journalStore
        ) { _, _ in }
        let secondURL = try XCTUnwrap(second.copiedFiles.values.first?.finalURL)
        XCTAssertTrue(
            try ZoteroImportRecovery.recoverIfNeeded(
                journalStore: journalStore,
                snapshot: .empty,
                targetOverride: target
            ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testRecoveryPreservesFilesProvenByPublishedSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRootURL = root.appendingPathComponent("source", isDirectory: true)
        let targetRootURL = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)
        let sourceURL = sourceRootURL.appendingPathComponent("paper.pdf")
        try writePDF(sourceURL)
        let inspected = try await FolderImportScanner.inspectAuthorizedPDF(at: sourceURL)
        let migration = migration(sourceURL: sourceURL, libraryName: "Published")
        let copyPreview = preview(migration: migration, inspected: inspected)
        let target = try authorized(targetRootURL, readOnly: false)
        let journalStore = ZoteroImportJournalStore(
            fileURL: root.appendingPathComponent("transaction.json"))
        let prepared = try await ZoteroImportTransactionExecutor.prepare(
            preview: copyPreview,
            target: target,
            journalStore: journalStore
        ) { _, _ in }
        XCTAssertEqual(prepared.diagnostics, [])
        let candidate = ZoteroImportCandidateBuilder.build(
            preview: copyPreview,
            prepared: prepared,
            existingPapers: [],
            existingCollections: []
        )
        let finalURL = try XCTUnwrap(prepared.copiedFiles.values.first?.finalURL)
        let snapshot = LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: candidate.papers,
            collections: candidate.collections,
            selectedPaperID: nil
        )
        XCTAssertTrue(
            try ZoteroImportRecovery.recoverIfNeeded(
                journalStore: journalStore,
                snapshot: snapshot,
                targetOverride: target
            ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalStore.fileURL.path))
    }

    func testThousandPaperSyntheticPlanningIsBoundedAndKeepsMultipleMembership() {
        let library = ZoteroServiceLibrary(type: "user", id: 0, name: "Large Fixture", version: nil)
        let identity = ZoteroLibraryIdentity(type: "user", id: 0)
        let collectionSources = (0..<100).map { index in
            ImportSourceIdentity.zoteroCollection(
                library: identity,
                collectionKey: "C\(index)",
                serverID: "fixture"
            )
        }
        let collections = collectionSources.enumerated().map { index, source in
            PlannedImportCollection(
                source: source,
                name: "Collection \(index)",
                parentSource: index == 0 ? nil : collectionSources[index - 1]
            )
        }
        var papers: [PlannedPaperImport] = []
        var rows: [ZoteroMigrationPreview.PaperRow] = []
        var inspected: [ImportSourceIdentity: FolderVerifiedFile] = [:]
        var options = ZoteroCopyPreviewOptions()
        for index in 0..<1_000 {
            let source = ImportSourceIdentity.zoteroAttachment(
                library: identity,
                parentItemKey: "I\(index)",
                attachmentKey: "P\(index)",
                serverID: "fixture"
            )
            let memberships = [collectionSources[index % 100], collectionSources[(index + 1) % 100]]
            papers.append(
                PlannedPaperImport(
                    source: source,
                    identity: nil,
                    originalFileName: "paper-\(index).pdf",
                    metadata: BibliographicMetadata(title: "Paper \(index)"),
                    attachmentLabel: nil,
                    fingerprint: nil,
                    collectionSources: memberships,
                    disposition: .create
                ))
            rows.append(
                ZoteroMigrationPreview.PaperRow(
                    attachmentKey: "P\(index)",
                    title: "Paper \(index)",
                    fileName: "paper-\(index).pdf",
                    sourceURL: URL(fileURLWithPath: "/fixture/P\(index).pdf"),
                    collectionNames: [],
                    disposition: .create
                ))
            inspected[source] = FolderVerifiedFile(
                identity: FileIdentity(
                    volumeUUID: "fixture",
                    documentIdentifier: index,
                    fallbackPath: "/fixture/P\(index).pdf"
                ),
                fingerprint: PDFContentFingerprint(
                    sha256: String(format: "%064x", index + 1),
                    byteCount: 1_024,
                    modificationDate: Date(timeIntervalSince1970: 1)
                ),
                bookmarkData: nil
            )
            options.createdPaperIDs[source] = UUID()
        }
        for source in collectionSources { options.createdCollectionIDs[source] = UUID() }
        let migration = ZoteroMigrationPreview(
            library: library,
            scannedItemCount: 2_000,
            parentItemCount: 1_000,
            pdfAttachmentCount: 1_000,
            unavailableAttachmentCount: 0,
            unsupportedAttachmentCount: 0,
            nonPDFAttachmentCount: 0,
            unsupportedItemCount: 0,
            ignoredTagCount: 0,
            ignoredRelationCount: 0,
            parentItemsWithoutPDFCount: 0,
            plannedCollectionCount: 100,
            rows: rows,
            plan: LibraryImportPlan(collections: collections, papers: papers)
        )
        let started = ContinuousClock.now
        let result = ZoteroCopyPreviewBuilder.build(
            migration: migration,
            inspectedFiles: inspected,
            existingPapers: [],
            existingCollections: [],
            options: options,
            authorizationDiagnostics: []
        )
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(result.papers.count, 1_000)
        XCTAssertEqual(result.collections.count, 100)
        XCTAssertEqual(result.papers[0].collectionIDs.count, 2)
        XCTAssertLessThan(elapsed, .seconds(5))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
