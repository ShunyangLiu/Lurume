import Foundation

enum ZoteroCopyDiagnosticKind: String, Codable, Error, Equatable, Sendable {
    case unauthorized
    case sourceChanged
    case sourceUnreadable
    case copyFailed
    case targetVerificationFailed
    case bookmarkUnavailable

    var title: String {
        switch self {
        case .unauthorized: "来源未授权"
        case .sourceChanged: "来源在迁移期间变化"
        case .sourceUnreadable: "来源无法读取"
        case .copyFailed: "复制失败"
        case .targetVerificationFailed: "目标校验失败"
        case .bookmarkUnavailable: "无法保存目标文件授权"
        }
    }
}

struct ZoteroCopyDiagnostic: Identifiable, Codable, Equatable, Sendable {
    var fileName: String
    var kind: ZoteroCopyDiagnosticKind

    var id: String { "\(kind.rawValue)|\(fileName)" }
}

struct ZoteroCopyPaperPreview: Identifiable, Equatable, Sendable {
    var source: ImportSourceIdentity
    var sourceURL: URL
    var title: String
    var fileName: String
    var byteCount: Int64
    var action: FolderPaperImportAction
    var plannedRecordID: UUID?
    var collectionIDs: [UUID]
    var changedMetadataFields: Set<MetadataField>
    var blockedManualFields: Set<MetadataField>
    var isUserExcluded: Bool
    var isIncluded: Bool

    var id: ImportSourceIdentity { source }
    var requiresCopy: Bool {
        guard isIncluded else { return false }
        switch action {
        case .create, .createNewVersion: return true
        default: return false
        }
    }
}

struct ZoteroCopyPreview: Equatable, Sendable {
    var library: ZoteroServiceLibrary
    var plan: LibraryImportPlan
    var collections: [FolderCollectionPreview]
    var papers: [ZoteroCopyPaperPreview]
    var authorizationDiagnostics: [ZoteroCopyDiagnostic]
    var targetParentID: UUID?

    var includedPaperCount: Int { papers.lazy.filter(\.isIncluded).count }
    var copiedPaperCount: Int { papers.lazy.filter(\.requiresCopy).count }
    var reusedPaperCount: Int {
        papers.lazy.filter { row in
            guard row.isIncluded else { return false }
            if case .reuse = row.action { return true }
            return false
        }.count
    }
    var keptVersionConflictCount: Int {
        papers.lazy.filter { if case .keepExistingVersion = $0.action { true } else { false } }.count
    }
    var copiedByteCount: Int64 {
        papers.lazy.filter(\.requiresCopy).reduce(into: 0) { $0 += $1.byteCount }
    }
}

struct ZoteroCopyPreviewOptions: Equatable, Sendable {
    var targetParentID: UUID?
    var excludedSources: Set<ImportSourceIdentity> = []
    var importChangedSourcesAsNew: Set<ImportSourceIdentity> = []
    var mergedCollectionTargets: [ImportSourceIdentity: UUID] = [:]
    var createdCollectionIDs: [ImportSourceIdentity: UUID] = [:]
    var createdPaperIDs: [ImportSourceIdentity: UUID] = [:]
}

enum ZoteroCopyPreviewBuilder {
    static func build(
        migration: ZoteroMigrationPreview,
        inspectedFiles: [ImportSourceIdentity: FolderVerifiedFile],
        existingPapers: [PaperRecord],
        existingCollections: [CollectionRecord],
        options: ZoteroCopyPreviewOptions,
        authorizationDiagnostics: [ZoteroCopyDiagnostic]
    ) -> ZoteroCopyPreview {
        let sourceURLByAttachmentKey = Dictionary(
            uniqueKeysWithValues: migration.rows.map { ($0.attachmentKey, $0.sourceURL) }
        )
        var plannedPapers: [PlannedPaperImport] = []
        plannedPapers.reserveCapacity(migration.plan.papers.count)
        for var paper in migration.plan.papers {
            guard let inspected = inspectedFiles[paper.source] else { continue }
            paper.identity = inspected.identity
            paper.fingerprint = inspected.fingerprint
            paper.disposition = ImportDeduplicator.classify(
                source: paper.source,
                identity: inspected.identity,
                fingerprint: inspected.fingerprint,
                existingPapers: existingPapers
            )
            plannedPapers.append(paper)
        }
        let plan = LibraryImportPlan(collections: migration.plan.collections, papers: plannedPapers)
        let plannedCollectionBySource = Dictionary(
            uniqueKeysWithValues: plan.collections.map { ($0.source, $0) }
        )
        var neededSources = Set(plannedPapers.flatMap(\.collectionSources))
        var pending = Array(neededSources)
        while let source = pending.popLast(),
            let parent = plannedCollectionBySource[source]?.parentSource,
            neededSources.insert(parent).inserted
        {
            pending.append(parent)
        }

        var candidateCollections = existingCollections
        var collectionIDBySource: [ImportSourceIdentity: UUID] = [:]
        var collectionRows: [FolderCollectionPreview] = []
        for collection in plan.collections where neededSources.contains(collection.source) {
            let depth = depth(of: collection.source, in: plannedCollectionBySource)
            if let matched = existingCollections.first(where: {
                $0.importSources.contains(collection.source)
            }) {
                collectionIDBySource[collection.source] = matched.id
                collectionRows.append(
                    FolderCollectionPreview(
                        source: collection.source,
                        name: matched.name,
                        depth: depth,
                        isIncluded: true,
                        action: .reuse(id: matched.id, matchedSource: true),
                        mergeTargetIDs: []
                    ))
                continue
            }
            let parentID =
                collection.parentSource.flatMap { collectionIDBySource[$0] }
                ?? (collection.parentSource == nil ? options.targetParentID : nil)
            let key = CollectionNameRules.comparisonKey(collection.name)
            let mergeTargets = existingCollections.filter {
                $0.parentID == parentID && CollectionNameRules.comparisonKey($0.name) == key
            }.map(\.id)
            if let mergedID = options.mergedCollectionTargets[collection.source],
                mergeTargets.contains(mergedID)
            {
                collectionIDBySource[collection.source] = mergedID
                collectionRows.append(
                    FolderCollectionPreview(
                        source: collection.source,
                        name: existingCollections.first(where: { $0.id == mergedID })?.name ?? collection.name,
                        depth: depth,
                        isIncluded: true,
                        action: .reuse(id: mergedID, matchedSource: false),
                        mergeTargetIDs: mergeTargets
                    ))
                continue
            }
            let name = uniqueCollectionName(
                collection.name,
                parentID: parentID,
                collections: candidateCollections
            )
            let id = options.createdCollectionIDs[collection.source] ?? UUID()
            candidateCollections.append(CollectionRecord(id: id, name: name, parentID: parentID))
            collectionIDBySource[collection.source] = id
            collectionRows.append(
                FolderCollectionPreview(
                    source: collection.source,
                    name: name,
                    depth: depth,
                    isIncluded: true,
                    action: .create(id: id, name: name, parentID: parentID),
                    mergeTargetIDs: mergeTargets
                ))
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingPapers.map { ($0.id, $0) })
        let rows = plannedPapers.compactMap { planned -> ZoteroCopyPaperPreview? in
            guard case .zoteroAttachment(_, _, let attachmentKey, _) = planned.source,
                let sourceURL = sourceURLByAttachmentKey[attachmentKey],
                let fingerprint = inspectedFiles[planned.source]?.fingerprint
            else { return nil }
            let userExcluded = options.excludedSources.contains(planned.source)
            let action: FolderPaperImportAction
            switch planned.disposition {
            case .create:
                action = .create
            case .reuse(let id, let reason):
                action = .reuse(id: id, reason: reason)
            case .sourceContentChanged(let id):
                action =
                    options.importChangedSourcesAsNew.contains(planned.source)
                    ? .createNewVersion(previousID: id)
                    : .keepExistingVersion(id: id)
            }
            let versionKept: Bool
            if case .keepExistingVersion = action {
                versionKept = true
            } else {
                versionKept = false
            }
            let metadataPreview: MetadataImportPreview?
            switch action {
            case .reuse(let id, _), .keepExistingVersion(let id):
                metadataPreview = existingByID[id].map {
                    MetadataImportMerger.preview(
                        current: $0.metadata,
                        imported: planned.metadata,
                        manuallyEditedFields: $0.manuallyEditedFields
                    )
                }
            default:
                metadataPreview = nil
            }
            let plannedID: UUID?
            switch action {
            case .create, .createNewVersion:
                plannedID = options.createdPaperIDs[planned.source] ?? UUID()
            default:
                plannedID = nil
            }
            return ZoteroCopyPaperPreview(
                source: planned.source,
                sourceURL: sourceURL,
                title: planned.metadata.title,
                fileName: planned.originalFileName,
                byteCount: fingerprint.byteCount,
                action: action,
                plannedRecordID: plannedID,
                collectionIDs: planned.collectionSources.compactMap { collectionIDBySource[$0] },
                changedMetadataFields: metadataPreview?.changedFields ?? [],
                blockedManualFields: metadataPreview?.blockedManualFields ?? [],
                isUserExcluded: userExcluded,
                isIncluded: !userExcluded && !versionKept
            )
        }
        return ZoteroCopyPreview(
            library: migration.library,
            plan: LibraryImportPlan(collections: plan.collections, papers: plannedPapers),
            collections: collectionRows,
            papers: rows,
            authorizationDiagnostics: authorizationDiagnostics,
            targetParentID: options.targetParentID
        )
    }

    private static func uniqueCollectionName(
        _ rawName: String,
        parentID: UUID?,
        collections: [CollectionRecord]
    ) -> String {
        let base = CollectionNameRules.trimmed(rawName)
        let keys = Set(
            collections.lazy.filter { $0.parentID == parentID }.map {
                CollectionNameRules.comparisonKey($0.name)
            })
        if !keys.contains(CollectionNameRules.comparisonKey(base)) { return base }
        var number = 2
        while keys.contains(CollectionNameRules.comparisonKey("\(base) \(number)")) { number += 1 }
        return "\(base) \(number)"
    }

    private static func depth(
        of source: ImportSourceIdentity,
        in collections: [ImportSourceIdentity: PlannedImportCollection]
    ) -> Int {
        var result = 0
        var next = collections[source]?.parentSource
        var visited: Set<ImportSourceIdentity> = [source]
        while let current = next, visited.insert(current).inserted {
            result += 1
            next = collections[current]?.parentSource
        }
        return result
    }
}

enum ZoteroImportJournalPhase: String, Codable, Equatable, Sendable {
    case staging
    case finalized
    case published
}

struct ZoteroImportJournalEntry: Codable, Equatable, Sendable {
    var paperID: UUID
    var stagingRelativePath: String
    var finalRelativePath: String
    var finalIdentity: FileIdentity
}

struct ZoteroImportJournal: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var transactionID: UUID
    var targetBookmarkData: Data
    var phase: ZoteroImportJournalPhase
    var entries: [ZoteroImportJournalEntry]
    var createdLibraryDirectoryRelativePath: String? = nil
    var createdLibraryDirectoryIdentity: FileIdentity? = nil
}

struct ZoteroImportJournalStore: Sendable {
    let fileURL: URL

    func load(fileManager: FileManager = .default) throws -> ZoteroImportJournal? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let journal = try JSONDecoder().decode(
            ZoteroImportJournal.self, from: Data(contentsOf: fileURL))
        guard journal.schemaVersion == 1,
            journal.entries.allSatisfy({
                safeRelativePath($0.stagingRelativePath) && safeRelativePath($0.finalRelativePath)
            }),
            journal.createdLibraryDirectoryRelativePath.map(safeRelativePath) != false,
            (journal.createdLibraryDirectoryRelativePath == nil)
                == (journal.createdLibraryDirectoryIdentity == nil)
        else {
            throw ZoteroImportTransactionError.invalidJournal
        }
        return journal
    }

    func save(_ journal: ZoteroImportJournal, fileManager: FileManager = .default) throws {
        guard
            journal.entries.allSatisfy({
                safeRelativePath($0.stagingRelativePath) && safeRelativePath($0.finalRelativePath)
            }), journal.createdLibraryDirectoryRelativePath.map(safeRelativePath) != false,
            (journal.createdLibraryDirectoryRelativePath == nil)
                == (journal.createdLibraryDirectoryIdentity == nil)
        else {
            throw ZoteroImportTransactionError.invalidJournal
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(journal).write(to: fileURL, options: .atomic)
    }

    func remove(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !(path as NSString).isAbsolutePath
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

enum ZoteroImportTransactionError: LocalizedError, Equatable, Sendable {
    case invalidJournal
    case insufficientSpace
    case targetChanged
    case noImportableFiles
    case libraryChanged
    case recoveryNeedsReview

    var errorDescription: String? {
        switch self {
        case .invalidJournal: "Zotero 迁移事务日志无效，已停止自动清理。"
        case .insufficientSpace: "目标磁盘可用空间不足。"
        case .targetChanged: "目标目录在迁移期间发生变化。"
        case .noImportableFiles: "没有可提交的 Zotero PDF。"
        case .libraryChanged: "预览期间文献库已变化，请重新生成预览。"
        case .recoveryNeedsReview: "上次 Zotero 迁移留下无法安全判定归属的文件，未自动删除。"
        }
    }
}

struct ZoteroCopiedFile: Equatable, Sendable {
    var paperID: UUID
    var identity: FileIdentity
    var bookmarkData: Data
    var fingerprint: PDFContentFingerprint
    var finalURL: URL
}

struct ZoteroPreparedTransaction: Sendable {
    var journal: ZoteroImportJournal
    var journalStore: ZoteroImportJournalStore
    var target: ZoteroAuthorizedDirectory
    var copiedFiles: [ImportSourceIdentity: ZoteroCopiedFile]
    var diagnostics: [ZoteroCopyDiagnostic]
    var hasExternalChanges: Bool = true

    func markPublishedAndClean(fileManager: FileManager = .default) throws {
        guard hasExternalChanges else { return }
        var published = journal
        published.phase = .published
        try journalStore.save(published, fileManager: fileManager)
        try Self.removeStagingDirectory(
            transactionID: journal.transactionID,
            target: target,
            fileManager: fileManager
        )
        try journalStore.remove(fileManager: fileManager)
    }

    func rollback(fileManager: FileManager = .default) throws {
        guard hasExternalChanges else { return }
        for entry in journal.entries {
            let finalURL = target.resolvedURL.appendingPathComponent(entry.finalRelativePath)
            guard fileManager.fileExists(atPath: finalURL.path),
                let identity = try? FileIdentity(url: finalURL),
                identity.identifiesSameFile(as: entry.finalIdentity)
            else { continue }
            try? fileManager.removeItem(at: finalURL)
        }
        if let relativePath = journal.createdLibraryDirectoryRelativePath,
            let expectedIdentity = journal.createdLibraryDirectoryIdentity
        {
            let directory = target.resolvedURL.appendingPathComponent(relativePath, isDirectory: true)
            if ZoteroPathAuthorization.isDescendant(directory, of: target.resolvedURL),
                (try? FileIdentity(url: directory).identifiesSameFile(as: expectedIdentity)) == true,
                (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true
            {
                try? fileManager.removeItem(at: directory)
            }
        }
        try Self.removeStagingDirectory(
            transactionID: journal.transactionID,
            target: target,
            fileManager: fileManager
        )
        try journalStore.remove(fileManager: fileManager)
    }

    static func removeStagingDirectory(
        transactionID: UUID,
        target: ZoteroAuthorizedDirectory,
        fileManager: FileManager
    ) throws {
        let container = target.resolvedURL.appendingPathComponent(
            ".lurume-import-staging", isDirectory: true)
        let directory = container.appendingPathComponent(transactionID.uuidString, isDirectory: true)
        guard ZoteroPathAuthorization.isDescendant(directory, of: container) else {
            throw ZoteroImportTransactionError.invalidJournal
        }
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        if (try? fileManager.contentsOfDirectory(atPath: container.path).isEmpty) == true {
            try? fileManager.removeItem(at: container)
        }
    }
}

enum ZoteroImportTransactionExecutor {
    static func prepare(
        preview: ZoteroCopyPreview,
        target: ZoteroAuthorizedDirectory,
        journalStore: ZoteroImportJournalStore,
        progress: @escaping @Sendable (Int, Int64) -> Void,
        fileManager: FileManager = .default
    ) async throws -> ZoteroPreparedTransaction {
        try ZoteroPathAuthorization.validateUnchangedDirectory(target)
        let rows = preview.papers.filter(\.requiresCopy)
        let transactionID = UUID()
        var journal = ZoteroImportJournal(
            transactionID: transactionID,
            targetBookmarkData: target.bookmarkData,
            phase: .staging,
            entries: []
        )
        if rows.isEmpty {
            journal.phase = .finalized
            return ZoteroPreparedTransaction(
                journal: journal,
                journalStore: journalStore,
                target: target,
                copiedFiles: [:],
                diagnostics: [],
                hasExternalChanges: false
            )
        }
        try journalStore.save(journal, fileManager: fileManager)
        do {
            let stagingContainer = target.resolvedURL
                .appendingPathComponent(".lurume-import-staging", isDirectory: true)
            let stagingDirectory =
                stagingContainer
                .appendingPathComponent(transactionID.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: stagingContainer.path) {
                let values = try stagingContainer.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey,
                ])
                guard values.isDirectory == true,
                    values.isSymbolicLink != true,
                    values.isAliasFile != true
                else {
                    throw ZoteroImportTransactionError.targetChanged
                }
            } else {
                try fileManager.createDirectory(at: stagingContainer, withIntermediateDirectories: false)
            }
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            let preparedDirectory = try preparedLibraryDirectory(
                named: preview.library.name,
                under: target,
                fileManager: fileManager
            )
            let libraryDirectory = preparedDirectory.url
            if preparedDirectory.created {
                journal.createdLibraryDirectoryRelativePath = relativePath(
                    libraryDirectory,
                    under: target.resolvedURL
                )
                journal.createdLibraryDirectoryIdentity = try FileIdentity(url: libraryDirectory)
                try journalStore.save(journal, fileManager: fileManager)
            }
            if let capacity = try? target.resolvedURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage,
                capacity < preview.copiedByteCount
            {
                try? ZoteroPreparedTransaction.removeStagingDirectory(
                    transactionID: transactionID,
                    target: target,
                    fileManager: fileManager
                )
                try? journalStore.remove(fileManager: fileManager)
                throw ZoteroImportTransactionError.insufficientSpace
            }

            let plannedBySource = Dictionary(
                uniqueKeysWithValues: preview.plan.papers.map { ($0.source, $0) })
            var copied: [ImportSourceIdentity: ZoteroCopiedFile] = [:]
            var diagnostics: [ZoteroCopyDiagnostic] = []
            var copiedBytes: Int64 = 0
            progress(0, 0)
            for (index, row) in rows.enumerated() {
                try Task.checkCancellation()
                guard let planned = plannedBySource[row.source],
                    let expected = planned.fingerprint,
                    let paperID = row.plannedRecordID
                else { continue }
                let stagingName = "\(paperID.uuidString).pdf"
                let stagingURL = stagingDirectory.appendingPathComponent(stagingName)
                do {
                    let sourceBefore = try await FolderImportScanner.verifyFile(
                        at: row.sourceURL,
                        expectedIdentity: try requiredIdentity(planned.identity),
                        expectedFingerprint: expected,
                        makeBookmark: false
                    )
                    try fileManager.copyItem(at: row.sourceURL, to: stagingURL)
                    let staged = try await FolderImportScanner.inspectAuthorizedPDF(at: stagingURL)
                    guard staged.fingerprint.sha256 == sourceBefore.fingerprint.sha256,
                        staged.fingerprint.byteCount == sourceBefore.fingerprint.byteCount
                    else {
                        throw ZoteroCopyDiagnosticKind.targetVerificationFailed
                    }
                    _ = try await FolderImportScanner.verifyFile(
                        at: row.sourceURL,
                        expectedIdentity: sourceBefore.identity,
                        expectedFingerprint: sourceBefore.fingerprint,
                        makeBookmark: false
                    )
                    let finalURL = uniqueDestination(
                        fileName: row.fileName,
                        under: libraryDirectory,
                        fileManager: fileManager
                    )
                    let finalRelativePath = relativePath(finalURL, under: target.resolvedURL)
                    let stagingRelativePath = relativePath(stagingURL, under: target.resolvedURL)
                    journal.entries.append(
                        ZoteroImportJournalEntry(
                            paperID: paperID,
                            stagingRelativePath: stagingRelativePath,
                            finalRelativePath: finalRelativePath,
                            // 链接完成前尚无最终路径身份。先保留暂存身份；若此时崩溃，
                            // 恢复逻辑只会保守地留下无法证明归属的孤立文件。
                            finalIdentity: staged.identity
                        ))
                    try journalStore.save(journal, fileManager: fileManager)
                    try fileManager.linkItem(at: stagingURL, to: finalURL)
                    let finalVerified = try await FolderImportScanner.inspectAuthorizedPDF(at: finalURL)
                    guard finalVerified.fingerprint.sha256 == expected.sha256,
                        finalVerified.fingerprint.byteCount == expected.byteCount
                    else {
                        throw ZoteroCopyDiagnosticKind.targetVerificationFailed
                    }
                    guard let journalIndex = journal.entries.lastIndex(where: { $0.paperID == paperID })
                    else {
                        throw ZoteroImportTransactionError.invalidJournal
                    }
                    journal.entries[journalIndex].finalIdentity = finalVerified.identity
                    try journalStore.save(journal, fileManager: fileManager)
                    try fileManager.removeItem(at: stagingURL)
                    let bookmark: Data
                    do {
                        bookmark = try SecurityScopedFile.makeBookmark(for: finalURL)
                    } catch {
                        throw ZoteroCopyDiagnosticKind.bookmarkUnavailable
                    }
                    copied[row.source] = ZoteroCopiedFile(
                        paperID: paperID,
                        identity: finalVerified.identity,
                        bookmarkData: bookmark,
                        fingerprint: finalVerified.fingerprint,
                        finalURL: finalURL
                    )
                    copiedBytes += finalVerified.fingerprint.byteCount
                } catch is CancellationError {
                    throw CancellationError()
                } catch let kind as ZoteroCopyDiagnosticKind {
                    cleanupFailedRow(
                        row, journal: &journal, target: target, stagingURL: stagingURL,
                        journalStore: journalStore, fileManager: fileManager)
                    diagnostics.append(ZoteroCopyDiagnostic(fileName: row.fileName, kind: kind))
                } catch let verification as FolderFileVerificationError {
                    cleanupFailedRow(
                        row, journal: &journal, target: target, stagingURL: stagingURL,
                        journalStore: journalStore, fileManager: fileManager)
                    diagnostics.append(
                        ZoteroCopyDiagnostic(
                            fileName: row.fileName,
                            kind: verification == .changedAfterPreview ? .sourceChanged : .sourceUnreadable
                        ))
                } catch {
                    cleanupFailedRow(
                        row, journal: &journal, target: target, stagingURL: stagingURL,
                        journalStore: journalStore, fileManager: fileManager)
                    diagnostics.append(
                        ZoteroCopyDiagnostic(
                            fileName: row.fileName,
                            kind: fileManager.fileExists(atPath: row.sourceURL.path)
                                ? .copyFailed : .sourceUnreadable
                        ))
                }
                progress(index + 1, copiedBytes)
            }
            if copied.isEmpty,
                let relativePath = journal.createdLibraryDirectoryRelativePath,
                let expectedIdentity = journal.createdLibraryDirectoryIdentity
            {
                let directory = target.resolvedURL.appendingPathComponent(relativePath, isDirectory: true)
                if (try? FileIdentity(url: directory).identifiesSameFile(as: expectedIdentity)) == true,
                    (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true
                {
                    try? fileManager.removeItem(at: directory)
                    journal.createdLibraryDirectoryRelativePath = nil
                    journal.createdLibraryDirectoryIdentity = nil
                }
            }
            journal.phase = .finalized
            try journalStore.save(journal, fileManager: fileManager)
            return ZoteroPreparedTransaction(
                journal: journal,
                journalStore: journalStore,
                target: target,
                copiedFiles: copied,
                diagnostics: diagnostics
            )
        } catch {
            let interrupted = ZoteroPreparedTransaction(
                journal: journal,
                journalStore: journalStore,
                target: target,
                copiedFiles: [:],
                diagnostics: []
            )
            try? interrupted.rollback(fileManager: fileManager)
            throw error
        }
    }

    private static func preparedLibraryDirectory(
        named rawName: String,
        under target: ZoteroAuthorizedDirectory,
        fileManager: FileManager
    ) throws -> (url: URL, created: Bool) {
        let directory = target.resolvedURL.appendingPathComponent(
            ZoteroPathAuthorization.sanitizedDirectoryName(rawName),
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey,
            ])
            guard values.isDirectory == true,
                values.isSymbolicLink != true,
                values.isAliasFile != true,
                ZoteroPathAuthorization.isDescendant(directory, of: target.resolvedURL)
            else {
                throw ZoteroImportTransactionError.targetChanged
            }
            return (directory, false)
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            return (directory, true)
        }
    }

    private static func uniqueDestination(
        fileName: String,
        under directory: URL,
        fileManager: FileManager
    ) -> URL {
        let safeName = ZoteroPathAuthorization.sanitizedFileName(fileName)
        let stem = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safeName)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    private static func relativePath(_ child: URL, under root: URL) -> String {
        let childPath = child.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return String(childPath.dropFirst(rootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
    }

    private static func cleanupFailedRow(
        _ row: ZoteroCopyPaperPreview,
        journal: inout ZoteroImportJournal,
        target: ZoteroAuthorizedDirectory,
        stagingURL: URL,
        journalStore: ZoteroImportJournalStore,
        fileManager: FileManager
    ) {
        try? fileManager.removeItem(at: stagingURL)
        let entries = journal.entries.filter { $0.paperID == row.plannedRecordID }
        for entry in entries {
            let finalURL = target.resolvedURL.appendingPathComponent(entry.finalRelativePath)
            if let identity = try? FileIdentity(url: finalURL),
                identity.identifiesSameFile(as: entry.finalIdentity)
            {
                try? fileManager.removeItem(at: finalURL)
            }
        }
        journal.entries.removeAll { $0.paperID == row.plannedRecordID }
        try? journalStore.save(journal, fileManager: fileManager)
    }
}

private func requiredIdentity(_ value: FileIdentity?) throws -> FileIdentity {
    guard let value else { throw ZoteroImportTransactionError.targetChanged }
    return value
}

struct ZoteroImportReport: Equatable, Sendable {
    var createdPaperCount: Int
    var reusedPaperCount: Int
    var createdCollectionCount: Int
    var reusedCollectionCount: Int
    var keptVersionConflictCount: Int
    var failedPaperCount: Int
    var copiedByteCount: Int64
    var diagnostics: [ZoteroCopyDiagnostic]

    var text: String {
        var lines = [
            "Zotero 迁移结果",
            "新增文献：\(createdPaperCount)",
            "复用文献：\(reusedPaperCount)",
            "新增文献集：\(createdCollectionCount)",
            "复用文献集：\(reusedCollectionCount)",
            "保留旧版本冲突：\(keptVersionConflictCount)",
            "失败：\(failedPaperCount)",
            "复制字节：\(copiedByteCount)",
        ]
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("诊断：")
            lines.append(contentsOf: diagnostics.map { "- \($0.fileName)：\($0.kind.title)" })
        }
        return lines.joined(separator: "\n")
    }
}

struct ZoteroImportCandidate: Equatable, Sendable {
    var papers: [PaperRecord]
    var collections: [CollectionRecord]
    var report: ZoteroImportReport
}

enum ZoteroImportCandidateBuilder {
    static func build(
        preview: ZoteroCopyPreview,
        prepared: ZoteroPreparedTransaction,
        existingPapers: [PaperRecord],
        existingCollections: [CollectionRecord]
    ) -> ZoteroImportCandidate {
        let plannedBySource = Dictionary(
            uniqueKeysWithValues: preview.plan.papers.map { ($0.source, $0) })
        let successfulRows = preview.papers.filter { row in
            guard row.isIncluded else { return false }
            return !row.requiresCopy || prepared.copiedFiles[row.source] != nil
        }
        var neededCollectionIDs = Set(successfulRows.flatMap(\.collectionIDs))
        var parentIDByCollectionID = Dictionary(
            uniqueKeysWithValues: existingCollections.compactMap { collection in
                collection.parentID.map { (collection.id, $0) }
            }
        )
        for row in preview.collections {
            guard let action = row.action else { continue }
            switch action {
            case let .create(id, _, parentID):
                if let parentID {
                    parentIDByCollectionID[id] = parentID
                } else {
                    parentIDByCollectionID.removeValue(forKey: id)
                }
            case .reuse:
                break
            }
        }
        var pendingCollectionIDs = Array(neededCollectionIDs)
        while let collectionID = pendingCollectionIDs.popLast() {
            if let parentID = parentIDByCollectionID[collectionID],
                neededCollectionIDs.insert(parentID).inserted
            {
                pendingCollectionIDs.append(parentID)
            }
        }
        var collections = existingCollections
        var createdCollections = 0
        var reusedCollectionIDs: Set<UUID> = []
        for row in preview.collections where row.isIncluded {
            guard let action = row.action else { continue }
            let id = action.collectionID
            guard neededCollectionIDs.contains(id) else { continue }
            switch action {
            case .create(let id, let name, let parentID):
                if !collections.contains(where: { $0.id == id }) {
                    collections.append(
                        CollectionRecord(
                            id: id,
                            name: name,
                            parentID: parentID,
                            importSources: [row.source],
                            sourceName: preview.plan.collections.first(where: { $0.source == row.source })?.name
                        ))
                    createdCollections += 1
                }
            case .reuse(let id, _):
                guard let index = collections.firstIndex(where: { $0.id == id }) else { continue }
                if !collections[index].importSources.contains(row.source) {
                    collections[index].importSources.append(row.source)
                    collections[index].importSources.sort(by: ImportSourceOrdering.less)
                }
                reusedCollectionIDs.insert(id)
            }
        }

        var papers = existingPapers
        var createdPapers = 0
        var reusedPaperIDs: Set<UUID> = []
        var copiedBytes: Int64 = 0
        for row in successfulRows {
            guard let planned = plannedBySource[row.source] else { continue }
            let validCollectionIDs = row.collectionIDs.filter { id in collections.contains { $0.id == id }
            }
            switch row.action {
            case .create, .createNewVersion:
                guard let copied = prepared.copiedFiles[row.source] else { continue }
                if case .createNewVersion(let previousID) = row.action,
                    let oldIndex = papers.firstIndex(where: { $0.id == previousID })
                {
                    papers[oldIndex].importSources.removeAll { $0 == row.source }
                }
                var record = PaperRecord(
                    id: copied.paperID,
                    identity: copied.identity,
                    bookmarkData: copied.bookmarkData,
                    initialTitle: planned.metadata.title,
                    originalFileName: copied.finalURL.lastPathComponent,
                    collectionIDs: validCollectionIDs,
                    metadata: planned.metadata,
                    attachmentLabel: planned.attachmentLabel,
                    contentFingerprint: copied.fingerprint,
                    importSources: [row.source],
                    lastImportedMetadata: planned.metadata
                )
                record.didReadAutoMetadata = true
                papers.append(record)
                createdPapers += 1
                copiedBytes += copied.fingerprint.byteCount
            case .reuse(let id, _):
                guard let index = papers.firstIndex(where: { $0.id == id }) else { continue }
                if !papers[index].importSources.contains(row.source) {
                    papers[index].importSources.append(row.source)
                    papers[index].importSources.sort(by: ImportSourceOrdering.less)
                }
                papers[index].collectionIDs = Array(Set(papers[index].collectionIDs + validCollectionIDs))
                    .sorted { $0.uuidString < $1.uuidString }
                let merge = MetadataImportMerger.preview(
                    current: papers[index].metadata,
                    imported: planned.metadata,
                    manuallyEditedFields: papers[index].manuallyEditedFields
                )
                papers[index].metadata = merge.proposedMetadata
                papers[index].lastImportedMetadata = planned.metadata
                papers[index].didReadAutoMetadata = true
                if papers[index].contentFingerprint == nil {
                    papers[index].contentFingerprint = planned.fingerprint
                }
                reusedPaperIDs.insert(id)
            case .keepExistingVersion:
                break
            }
        }
        return ZoteroImportCandidate(
            papers: papers,
            collections: collections,
            report: ZoteroImportReport(
                createdPaperCount: createdPapers,
                reusedPaperCount: reusedPaperIDs.count,
                createdCollectionCount: createdCollections,
                reusedCollectionCount: reusedCollectionIDs.count,
                keptVersionConflictCount: preview.keptVersionConflictCount,
                failedPaperCount: preview.authorizationDiagnostics.count + prepared.diagnostics.count,
                copiedByteCount: copiedBytes,
                diagnostics: preview.authorizationDiagnostics + prepared.diagnostics
            )
        )
    }
}

enum ZoteroImportRecovery {
    static func recoverIfNeeded(
        journalStore: ZoteroImportJournalStore,
        snapshot: LibrarySnapshot,
        targetOverride: ZoteroAuthorizedDirectory? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let journal = try journalStore.load(fileManager: fileManager) else { return false }
        let target: ZoteroAuthorizedDirectory
        if let targetOverride {
            target = targetOverride
        } else {
            target = try ZoteroPathAuthorization.restoreDirectory(
                bookmarkData: journal.targetBookmarkData,
                readOnly: false
            )
        }
        let didStartAccessing = target.selectedURL.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { target.selectedURL.stopAccessingSecurityScopedResource() } }
        let referenced = journal.entries.filter { entry in
            snapshot.papers.contains { paper in
                paper.id == entry.paperID && paper.identity.identifiesSameFile(as: entry.finalIdentity)
            }
        }
        if referenced.count == journal.entries.count {
            try ZoteroPreparedTransaction.removeStagingDirectory(
                transactionID: journal.transactionID,
                target: target,
                fileManager: fileManager
            )
            try journalStore.remove(fileManager: fileManager)
            return true
        }
        guard referenced.isEmpty else { throw ZoteroImportTransactionError.recoveryNeedsReview }
        let prepared = ZoteroPreparedTransaction(
            journal: journal,
            journalStore: journalStore,
            target: target,
            copiedFiles: [:],
            diagnostics: []
        )
        try prepared.rollback(fileManager: fileManager)
        return true
    }
}
