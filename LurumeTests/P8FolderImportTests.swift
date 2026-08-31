import CryptoKit
import Foundation
import XCTest
@testable import Lurume

final class P8FolderImportTests: XCTestCase {
    private struct NilMetadataReader: PaperMetadataReading {
        func metadata(at url: URL) async -> PaperMetadata? { nil }
    }

    private actor MutatingMetadataReader: PaperMetadataReading {
        func metadata(at url: URL) async -> PaperMetadata? {
            try? Data("changed".utf8).append(to: url)
            return nil
        }
    }

    private actor TrackingMetadataReader: PaperMetadataReading {
        private var active = 0
        private var maximum = 0

        func metadata(at url: URL) async -> PaperMetadata? {
            active += 1
            maximum = max(maximum, active)
            try? await Task.sleep(for: .milliseconds(20))
            active -= 1
            return PaperMetadata(title: url.deletingPathExtension().lastPathComponent, authors: nil)
        }

        func maximumConcurrency() -> Int { maximum }
    }

    private actor DelayedScanner: FolderImportScanning {
        func scan(
            rootURL: URL,
            progress: @escaping @Sendable (FolderScanProgress) -> Void
        ) async throws -> FolderScanResult {
            let isSlow = rootURL.lastPathComponent == "slow"
            try? await Task.sleep(for: isSlow ? .milliseconds(250) : .milliseconds(10))
            progress(FolderScanProgress(discoveredPDFCount: 1, processedPDFCount: 1, validPDFCount: 1))
            let rootSource = ImportSourceIdentity.folder(FolderImportSource(
                rootVolumeUUID: "fake",
                rootDocumentIdentifier: isSlow ? 1 : 2,
                relativePath: ""
            ))
            let fileSource = ImportSourceIdentity.folder(FolderImportSource(
                rootVolumeUUID: "fake",
                rootDocumentIdentifier: isSlow ? 1 : 2,
                relativePath: "\(rootURL.lastPathComponent).pdf"
            ))
            let fingerprint = PDFContentFingerprint(
                sha256: String(repeating: isSlow ? "a" : "b", count: 64),
                byteCount: 20,
                modificationDate: Date(timeIntervalSince1970: 1)
            )
            let descriptor = FolderPDFDescriptor(
                source: fileSource,
                identity: FileIdentity(
                    volumeUUID: "fake",
                    documentIdentifier: isSlow ? 1 : 2,
                    fallbackPath: rootURL.appendingPathComponent("paper.pdf").path
                ),
                originalFileName: "\(rootURL.lastPathComponent).pdf",
                propertyMetadata: nil,
                fingerprint: fingerprint
            )
            return FolderScanResult(
                rootURL: rootURL,
                root: FolderDirectoryDescriptor(
                    source: rootSource,
                    name: rootURL.lastPathComponent,
                    pdfs: [descriptor],
                    children: []
                ),
                files: [ScannedFolderPDF(
                    url: rootURL.appendingPathComponent("paper.pdf"),
                    relativePath: "\(rootURL.lastPathComponent).pdf",
                    descriptor: descriptor
                )],
                diagnostics: [],
                unsupportedFileCount: 0
            )
        }
    }

    private func temporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writePDF(
        _ url: URL,
        payload: String = "fixture"
    ) throws -> Data {
        let data = Data("%PDF-1.7\n\(payload)\n%%EOF\n".utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func source(_ path: String) -> ImportSourceIdentity {
        .folder(FolderImportSource(
            rootVolumeUUID: "test-volume",
            rootDocumentIdentifier: 7,
            relativePath: path
        ))
    }

    func testRootBookmarkDoesNotChangeFolderSourceIdentityAndCannotAppearOnChildren() {
        let first = ImportSourceIdentity.folder(FolderImportSource(
            rootVolumeUUID: "volume",
            rootDocumentIdentifier: 9,
            relativePath: "",
            rootBookmarkData: Data("first".utf8)
        ))
        let refreshed = ImportSourceIdentity.folder(FolderImportSource(
            rootVolumeUUID: "volume",
            rootDocumentIdentifier: 9,
            relativePath: "",
            rootBookmarkData: Data("second".utf8)
        ))
        let invalidChild = ImportSourceIdentity.folder(FolderImportSource(
            rootVolumeUUID: "volume",
            rootDocumentIdentifier: 9,
            relativePath: "child",
            rootBookmarkData: Data("must-not-repeat".utf8)
        ))

        XCTAssertEqual(first, refreshed)
        XCTAssertEqual(Set([first, refreshed]).count, 1)
        XCTAssertTrue(ImportSourceRules.isValid(first))
        XCTAssertFalse(ImportSourceRules.isValid(invalidChild))
    }

    @MainActor
    private func makeStore(
        papers: [PaperRecord] = [],
        collections: [CollectionRecord] = []
    ) throws -> (LibraryStore, LibraryPersistence, URL) {
        let directory = try temporaryDirectory()
        let persistence = LibraryPersistence(fileURL: directory.appendingPathComponent("library.json"))
        try persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: papers,
            collections: collections,
            selectedPaperID: papers.first?.id
        ))
        return (LibraryStore(persistence: persistence), persistence, directory)
    }

    func testScannerBuildsPrunedTreeAndSkipsHiddenReferencesPackagesAndInvalidPDFs() async throws {
        let root = try temporaryDirectory(named: "P8 Scanner \(UUID().uuidString)")
        let outside = try temporaryDirectory(named: "P8 Outside \(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try writePDF(root.appendingPathComponent("root.pdf"))
        try writePDF(root.appendingPathComponent("Topic/Sub/paper.PDF"))
        try writePDF(root.appendingPathComponent(".hidden.pdf"))
        try Data("not a pdf".utf8).write(to: root.appendingPathComponent("broken.pdf"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try writePDF(outside.appendingPathComponent("outside.pdf"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.pdf"),
            withDestinationURL: outside.appendingPathComponent("outside.pdf")
        )
        try writePDF(root.appendingPathComponent("Reader.app/inside.pdf"))

        let result = try await FolderImportScanner(metadataReader: NilMetadataReader())
            .scan(rootURL: root) { _ in }

        XCTAssertEqual(result.files.map(\.relativePath), ["root.pdf", "Topic/Sub/paper.PDF"])
        XCTAssertEqual(result.unsupportedFileCount, 1)
        XCTAssertEqual(result.root.pdfs.count, 1)
        XCTAssertEqual(result.root.children.map(\.name), ["Topic"])
        XCTAssertEqual(result.root.children.first?.children.map(\.name), ["Sub"])
        XCTAssertTrue(result.diagnostics.contains { $0.relativePath == "broken.pdf" && $0.kind == .invalidPDF })
        XCTAssertTrue(result.diagnostics.contains { $0.relativePath == "linked.pdf" && $0.kind == .skippedReference })
        XCTAssertTrue(result.diagnostics.contains { $0.relativePath == "Reader.app" && $0.kind == .skippedReference })
        XCTAssertFalse(result.files.contains { $0.relativePath.contains("hidden") || $0.relativePath.contains("inside") })
    }

    func testScannerRejectsFileChangedWhileMetadataIsRead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePDF(root.appendingPathComponent("moving.pdf"))

        let result = try await FolderImportScanner(metadataReader: MutatingMetadataReader())
            .scan(rootURL: root) { _ in }

        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.diagnostics.contains {
            $0.relativePath == "moving.pdf" && $0.kind == .changedDuringScan
        })
    }

    func testScannerRejectsSymlinkRootAndEnforcesEntryLimit() async throws {
        let root = try temporaryDirectory()
        let parent = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: parent)
        }
        try writePDF(root.appendingPathComponent("one.pdf"))
        try writePDF(root.appendingPathComponent("two.pdf"))
        let linkedRoot = parent.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)

        do {
            _ = try await FolderImportScanner(
                metadataReader: NilMetadataReader(),
                maximumEntryCount: 1
            ).scan(rootURL: root) { _ in }
            XCTFail("Expected the entry limit to reject the scan")
        } catch {
            XCTAssertEqual(error as? FolderImportError, .tooManyEntries(limit: 1))
        }
        do {
            _ = try await FolderImportScanner(metadataReader: NilMetadataReader())
                .scan(rootURL: linkedRoot) { _ in }
            XCTFail("Expected a symlink root to be rejected")
        } catch {
            XCTAssertEqual(error as? FolderImportError, .invalidRoot)
        }
    }

    func testScannerBoundsConcurrencyAndProcessesFiftyPDFs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<50 {
            try writePDF(
                root.appendingPathComponent("L1/L2/L3/paper-\(index).pdf"),
                payload: String(index)
            )
        }
        let reader = TrackingMetadataReader()
        let started = ContinuousClock.now
        let result = try await FolderImportScanner(
            metadataReader: reader,
            maximumConcurrentFiles: 4,
            bufferSize: 4_096
        ).scan(rootURL: root) { _ in }
        let elapsed = started.duration(to: .now)

        let maximumConcurrency = await reader.maximumConcurrency()
        XCTAssertEqual(result.files.count, 50)
        XCTAssertLessThanOrEqual(maximumConcurrency, 4)
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertEqual(result.root.children.first?.children.first?.children.first?.pdfs.count, 50)
    }

    func testSecondVerificationRejectsPostPreviewMutation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try writePDF(url)
        let scan = try await FolderImportScanner(metadataReader: NilMetadataReader())
            .scan(rootURL: root) { _ in }
        let file = try XCTUnwrap(scan.files.first)
        let fingerprint = try XCTUnwrap(file.descriptor.fingerprint)
        try writePDF(url, payload: "replacement")

        await XCTAssertThrowsErrorAsync {
            _ = try await FolderImportScanner.verifyFile(
                at: url,
                expectedIdentity: file.descriptor.identity,
                expectedFingerprint: fingerprint,
                makeBookmark: false
            )
        }
    }

    @MainActor
    func testStandalonePDFEntryUsesSharedValidationHashAndMetadataCore() async throws {
        struct MetadataReader: PaperMetadataReading {
            func metadata(at url: URL) async -> PaperMetadata? {
                PaperMetadata(title: "Trusted title", authors: "Research Group")
            }
        }
        let sourceDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let validURL = sourceDirectory.appendingPathComponent("fallback.pdf")
        let validData = try writePDF(validURL)
        let (_, persistence, storeDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let metadataStore = LibraryStore(persistence: persistence, metadataReader: MetadataReader())

        metadataStore.importPDFs(at: [validURL])
        for _ in 0..<100 where metadataStore.papers.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let paper = try XCTUnwrap(metadataStore.papers.first)
        XCTAssertEqual(paper.title, "Trusted title")
        XCTAssertEqual(paper.authors, "Research Group")
        XCTAssertEqual(paper.contentFingerprint?.sha256, sha256(validData))
        XCTAssertTrue(paper.didReadAutoMetadata)
        XCTAssertEqual(try persistence.load().snapshot.papers.count, 1)

        let invalidURL = sourceDirectory.appendingPathComponent("invalid.pdf")
        try Data("invalid".utf8).write(to: invalidURL)
        metadataStore.importPDFs(at: [invalidURL])
        for _ in 0..<100 where metadataStore.presentedError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(metadataStore.papers.count, 1)
        XCTAssertNotNil(metadataStore.presentedError)
    }

    func testPreviewUsesTargetParentNumbersNameConflictAndAllowsExplicitMerge() async throws {
        let root = try temporaryDirectory(named: "Research")
        defer { try? FileManager.default.removeItem(at: root) }
        try writePDF(root.appendingPathComponent("paper.pdf"))
        let scan = try await FolderImportScanner(metadataReader: NilMetadataReader())
            .scan(rootURL: root) { _ in }
        let parent = CollectionRecord(name: "Parent")
        let conflict = CollectionRecord(name: "Research", parentID: parent.id)
        var options = FolderImportPreviewOptions(targetParentID: parent.id)
        let numbered = FolderImportPreviewBuilder.build(
            scan: scan,
            existingPapers: [],
            existingCollections: [parent, conflict],
            options: options
        )

        guard case let .create(_, name, parentID) = numbered.collections.first?.action else {
            return XCTFail("Expected a new collection")
        }
        XCTAssertEqual(name, "Research 2")
        XCTAssertEqual(parentID, parent.id)
        XCTAssertEqual(numbered.collections.first?.mergeTargetIDs, [conflict.id])

        options.mergedCollectionTargets[scan.root.source] = conflict.id
        let merged = FolderImportPreviewBuilder.build(
            scan: scan,
            existingPapers: [],
            existingCollections: [parent, conflict],
            options: options
        )
        XCTAssertEqual(merged.collections.first?.action, .reuse(id: conflict.id, matchedSource: false))
    }

    func testReimportReusesSourceCollectionAndProtectsManualMetadata() async throws {
        struct MetadataReader: PaperMetadataReading {
            func metadata(at url: URL) async -> PaperMetadata? {
                PaperMetadata(title: "Imported title", authors: "Imported Authors")
            }
        }
        let root = try temporaryDirectory(named: "Reimport \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writePDF(root.appendingPathComponent("paper.pdf"))
        let scan = try await FolderImportScanner(metadataReader: MetadataReader())
            .scan(rootURL: root) { _ in }
        let scanned = try XCTUnwrap(scan.files.first)
        let fingerprint = try XCTUnwrap(scanned.descriptor.fingerprint)
        var existingPaper = PaperRecord(
            identity: scanned.descriptor.identity,
            bookmarkData: Data("existing".utf8),
            initialTitle: "Manual title",
            originalFileName: "paper.pdf",
            contentFingerprint: fingerprint,
            importSources: [scanned.descriptor.source]
        )
        existingPaper.manuallyEditedFields = [.title]
        let existingCollection = CollectionRecord(
            name: "Manually renamed root",
            importSources: [scan.root.source],
            sourceName: scan.root.name,
            wasManuallyOrganized: true
        )
        let preview = FolderImportPreviewBuilder.build(
            scan: scan,
            existingPapers: [existingPaper],
            existingCollections: [existingCollection],
            options: FolderImportPreviewOptions(targetParentID: nil)
        )

        XCTAssertEqual(
            preview.collections.first?.action,
            .reuse(id: existingCollection.id, matchedSource: true)
        )
        XCTAssertEqual(preview.papers.first?.blockedManualFields, [.title])
        let preparation = try await FolderImportExecutor.prepare(
            scan: scan,
            preview: preview
        ) { _, _ in }
        let candidate = FolderImportCandidateBuilder.build(
            preview: preview,
            preparation: preparation,
            existingPapers: [existingPaper],
            existingCollections: [existingCollection]
        )

        XCTAssertEqual(candidate.papers.count, 1)
        XCTAssertEqual(candidate.collections.count, 1)
        XCTAssertEqual(candidate.papers[0].title, "Manual title")
        XCTAssertEqual(candidate.papers[0].authors, "Imported Authors")
        XCTAssertEqual(candidate.collections[0].name, "Manually renamed root")
        XCTAssertTrue(candidate.collections[0].wasManuallyOrganized)
    }

    @MainActor
    func testEndToEndImportReferencesOriginalsPersistsAtomicallyAndUndoesAsOneStep() async throws {
        let root = try temporaryDirectory(named: "P8 Library \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.pdf")
        let secondURL = root.appendingPathComponent("Nested/second.pdf")
        let firstData = try writePDF(firstURL, payload: "first")
        let secondData = try writePDF(secondURL, payload: "second")
        let originalHashes = [sha256(firstData), sha256(secondData)]

        let scan = try await FolderImportScanner(metadataReader: NilMetadataReader())
            .scan(rootURL: root) { _ in }
        var options = FolderImportPreviewOptions(targetParentID: nil)
        for collection in FolderImportPlanner.plan(root: scan.root, existingPapers: []).collections {
            options.createdCollectionIDs[collection.source] = UUID()
        }
        let preview = FolderImportPreviewBuilder.build(
            scan: scan,
            existingPapers: [],
            existingCollections: [],
            options: options
        )
        let preparation = try await FolderImportExecutor.prepare(
            scan: scan,
            preview: preview
        ) { _, _ in }
        let candidate = FolderImportCandidateBuilder.build(
            preview: preview,
            preparation: preparation,
            existingPapers: [],
            existingCollections: []
        )
        let (store, persistence, storeDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let undoManager = UndoManager()

        try store.applyFolderImport(
            papers: candidate.papers,
            collections: candidate.collections,
            undoManager: undoManager
        )

        XCTAssertEqual(store.papers.count, 2)
        XCTAssertEqual(store.collections.count, 2)
        XCTAssertEqual(try persistence.load().snapshot.papers.count, 2)
        let rootSource = try XCTUnwrap(store.collections.flatMap(\.importSources).first { source in
            if case let .folder(folder) = source { return folder.relativePath.isEmpty }
            return false
        })
        guard case let .folder(rootFolderSource) = rootSource else {
            return XCTFail("Expected a folder source")
        }
        XCTAssertFalse(try XCTUnwrap(rootFolderSource.rootBookmarkData).isEmpty)
        XCTAssertEqual(undoManager.undoActionName, "文件夹导入")
        XCTAssertTrue(store.papers.allSatisfy { !$0.bookmarkData.isEmpty })
        XCTAssertEqual(try Data(contentsOf: firstURL), firstData)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondData)
        XCTAssertEqual(
            [sha256(try Data(contentsOf: firstURL)), sha256(try Data(contentsOf: secondURL))],
            originalHashes
        )

        undoManager.undo()
        XCTAssertTrue(store.papers.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertTrue(try persistence.load().snapshot.papers.isEmpty)
    }

    @MainActor
    func testFailedFolderImportSavePublishesNothing() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: libraryURL)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let paper = PaperRecord(
            identity: FileIdentity(volumeUUID: nil, documentIdentifier: nil, fallbackPath: "/fixture.pdf"),
            bookmarkData: Data("bookmark".utf8),
            initialTitle: "Candidate"
        )

        XCTAssertThrowsError(try store.applyFolderImport(
            papers: [paper],
            collections: [CollectionRecord(name: "Candidate")],
            undoManager: nil
        ))
        XCTAssertTrue(store.papers.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
    }

    func testChangedSourceImportedAsNewTransfersSourceAliasFromOldRecord() {
        let fileSource = source("paper.pdf")
        let oldFingerprint = PDFContentFingerprint(
            sha256: String(repeating: "a", count: 64),
            byteCount: 10,
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        let newFingerprint = PDFContentFingerprint(
            sha256: String(repeating: "b", count: 64),
            byteCount: 20,
            modificationDate: Date(timeIntervalSince1970: 2)
        )
        let old = PaperRecord(
            identity: FileIdentity(volumeUUID: "v", documentIdentifier: 1, fallbackPath: "/old.pdf"),
            bookmarkData: Data("old".utf8),
            initialTitle: "Old",
            contentFingerprint: oldFingerprint,
            importSources: [fileSource]
        )
        let directorySource = source("")
        let collectionID = UUID()
        let plan = LibraryImportPlan(
            collections: [PlannedImportCollection(source: directorySource, name: "Root", parentSource: nil)],
            papers: [PlannedPaperImport(
                source: fileSource,
                identity: FileIdentity(volumeUUID: "v", documentIdentifier: 2, fallbackPath: "/new.pdf"),
                originalFileName: "paper.pdf",
                metadata: BibliographicMetadata(title: "New"),
                attachmentLabel: nil,
                fingerprint: newFingerprint,
                collectionSources: [directorySource],
                disposition: .sourceContentChanged(paperID: old.id)
            )]
        )
        let preview = FolderImportPreview(
            plan: plan,
            collections: [FolderCollectionPreview(
                source: directorySource,
                name: "Root",
                depth: 0,
                isIncluded: true,
                action: .create(id: collectionID, name: "Root", parentID: nil),
                mergeTargetIDs: []
            )],
            papers: [FolderPaperPreview(
                source: fileSource,
                relativePath: "paper.pdf",
                title: "New",
                byteCount: 20,
                directorySource: directorySource,
                action: .createNewVersion(previousID: old.id),
                collectionIDs: [collectionID],
                changedMetadataFields: [],
                blockedManualFields: [],
                isUserExcluded: false,
                isIncluded: true
            )],
            diagnostics: [],
            unsupportedFileCount: 0,
            targetParentID: nil
        )
        let preparation = FolderImportExecutionPreparation(
            verifiedFiles: [fileSource: FolderVerifiedFile(
                identity: FileIdentity(volumeUUID: "v", documentIdentifier: 2, fallbackPath: "/new.pdf"),
                fingerprint: newFingerprint,
                bookmarkData: Data("new".utf8)
            )],
            diagnostics: []
        )

        let candidate = FolderImportCandidateBuilder.build(
            preview: preview,
            preparation: preparation,
            existingPapers: [old],
            existingCollections: []
        )

        XCTAssertEqual(candidate.papers.count, 2)
        XCTAssertFalse(candidate.papers[0].importSources.contains(fileSource))
        XCTAssertEqual(candidate.papers[1].importSources, [fileSource])
        XCTAssertEqual(candidate.report.createdPaperCount, 1)
    }

    @MainActor
    func testCoordinatorIgnoresLateResultFromSupersededRequest() async throws {
        let (_, _, storeDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let persistence = LibraryPersistence(fileURL: storeDirectory.appendingPathComponent("library.json"))
        let store = LibraryStore(persistence: persistence)
        let coordinator = FolderImportCoordinator(scanner: DelayedScanner())

        coordinator.begin(
            rootURL: URL(fileURLWithPath: "/tmp/slow", isDirectory: true),
            targetParentID: nil,
            store: store
        )
        coordinator.begin(
            rootURL: URL(fileURLWithPath: "/tmp/fast", isDirectory: true),
            targetParentID: nil,
            store: store
        )
        for _ in 0..<100 where coordinator.phase == .scanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.phase, .preview)
        XCTAssertEqual(coordinator.preview?.papers.first?.title, "fast")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.phase, .preview)
        XCTAssertEqual(coordinator.preview?.papers.first?.title, "fast")
        XCTAssertTrue(store.papers.isEmpty)
    }

    @MainActor
    func testCoordinatorCancellationNeverPublishesPreviewOrLibraryChanges() async throws {
        let (store, _, storeDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let coordinator = FolderImportCoordinator(scanner: DelayedScanner())
        coordinator.begin(
            rootURL: URL(fileURLWithPath: "/tmp/slow", isDirectory: true),
            targetParentID: nil,
            store: store
        )
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertNil(coordinator.preview)
        XCTAssertTrue(store.papers.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
