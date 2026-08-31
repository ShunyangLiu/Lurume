import Foundation

enum FolderCollectionImportAction: Equatable, Sendable {
    case create(id: UUID, name: String, parentID: UUID?)
    case reuse(id: UUID, matchedSource: Bool)

    var collectionID: UUID {
        switch self {
        case let .create(id, _, _), let .reuse(id, _): id
        }
    }
}

enum FolderPaperImportAction: Equatable, Sendable {
    case create
    case reuse(id: UUID, reason: ImportDuplicateReason)
    case keepExistingVersion(id: UUID)
    case createNewVersion(previousID: UUID)
}

struct FolderCollectionPreview: Identifiable, Equatable, Sendable {
    var source: ImportSourceIdentity
    var name: String
    var depth: Int
    var isIncluded: Bool
    var action: FolderCollectionImportAction?
    var mergeTargetIDs: [UUID]

    var id: ImportSourceIdentity { source }
}

struct FolderPaperPreview: Identifiable, Equatable, Sendable {
    var source: ImportSourceIdentity
    var relativePath: String
    var title: String
    var byteCount: Int64
    var directorySource: ImportSourceIdentity
    var action: FolderPaperImportAction
    var collectionIDs: [UUID]
    var changedMetadataFields: Set<MetadataField>
    var blockedManualFields: Set<MetadataField>
    var isUserExcluded: Bool
    var isIncluded: Bool

    var id: ImportSourceIdentity { source }
}

struct FolderImportPreview: Equatable, Sendable {
    var plan: LibraryImportPlan
    var collections: [FolderCollectionPreview]
    var papers: [FolderPaperPreview]
    var diagnostics: [FolderScanDiagnostic]
    var unsupportedFileCount: Int
    var targetParentID: UUID?

    var includedPaperCount: Int { papers.lazy.filter(\.isIncluded).count }
    var newPaperCount: Int {
        papers.lazy.filter {
            guard $0.isIncluded else { return false }
            switch $0.action {
            case .create, .createNewVersion: return true
            default: return false
            }
        }.count
    }
    var reusedPaperCount: Int {
        papers.lazy.filter {
            guard $0.isIncluded else { return false }
            if case .reuse = $0.action { return true }
            return false
        }.count
    }
    var keptVersionConflictCount: Int {
        papers.lazy.filter {
            if case .keepExistingVersion = $0.action { return true }
            return false
        }.count
    }
    var versionConflictCount: Int {
        papers.lazy.filter {
            switch $0.action {
            case .keepExistingVersion, .createNewVersion: return true
            default: return false
            }
        }.count
    }
    var includedByteCount: Int64 {
        papers.lazy.filter(\.isIncluded).reduce(into: 0) { $0 += $1.byteCount }
    }
}

struct FolderImportPreviewOptions: Equatable, Sendable {
    var targetParentID: UUID?
    var excludedPaperSources: Set<ImportSourceIdentity> = []
    var excludedDirectorySources: Set<ImportSourceIdentity> = []
    var importChangedSourcesAsNew: Set<ImportSourceIdentity> = []
    var mergedCollectionTargets: [ImportSourceIdentity: UUID] = [:]
    var createdCollectionIDs: [ImportSourceIdentity: UUID] = [:]
}

enum FolderImportPreviewBuilder {
    static func build(
        scan: FolderScanResult,
        existingPapers: [PaperRecord],
        existingCollections: [CollectionRecord],
        options: FolderImportPreviewOptions
    ) -> FolderImportPreview {
        let plan = FolderImportPlanner.plan(root: scan.root, existingPapers: existingPapers)
        let plannedCollectionBySource = Dictionary(
            uniqueKeysWithValues: plan.collections.map { ($0.source, $0) }
        )
        let scanBySource = scan.fileBySource
        var preliminaryPapers: [(PlannedPaperImport, ScannedFolderPDF, Bool, FolderPaperImportAction)] = []
        preliminaryPapers.reserveCapacity(plan.papers.count)

        for paper in plan.papers {
            guard let scanned = scanBySource[paper.source],
                  let directorySource = paper.collectionSources.first else { continue }
            let userExcluded = options.excludedPaperSources.contains(paper.source)
                || options.excludedDirectorySources.contains(where: {
                    source(directorySource, isDescendantOf: $0)
                })
            let action: FolderPaperImportAction
            switch paper.disposition {
            case .create:
                action = .create
            case let .reuse(id, reason):
                action = .reuse(id: id, reason: reason)
            case let .sourceContentChanged(id):
                action = options.importChangedSourcesAsNew.contains(paper.source)
                    ? .createNewVersion(previousID: id)
                    : .keepExistingVersion(id: id)
            }
            let versionIsKept: Bool
            if case .keepExistingVersion = action { versionIsKept = true } else { versionIsKept = false }
            preliminaryPapers.append((paper, scanned, !userExcluded && !versionIsKept, action))
        }

        var neededCollectionSources = Set(preliminaryPapers.compactMap { item in
            item.2 ? item.0.collectionSources.first : nil
        })
        var pendingAncestors = Array(neededCollectionSources)
        while let current = pendingAncestors.popLast(),
              let parent = plannedCollectionBySource[current]?.parentSource,
              neededCollectionSources.insert(parent).inserted {
            pendingAncestors.append(parent)
        }

        var candidateCollections = existingCollections
        var collectionIDBySource: [ImportSourceIdentity: UUID] = [:]
        var collectionRows: [FolderCollectionPreview] = []
        for collection in plan.collections {
            let depth = depth(of: collection.source, in: plannedCollectionBySource)
            guard neededCollectionSources.contains(collection.source) else {
                collectionRows.append(FolderCollectionPreview(
                    source: collection.source,
                    name: collection.name,
                    depth: depth,
                    isIncluded: false,
                    action: nil,
                    mergeTargetIDs: []
                ))
                continue
            }
            if let matched = existingCollections.first(where: {
                $0.importSources.contains(collection.source)
            }) {
                collectionIDBySource[collection.source] = matched.id
                collectionRows.append(FolderCollectionPreview(
                    source: collection.source,
                    name: matched.name,
                    depth: depth,
                    isIncluded: true,
                    action: .reuse(id: matched.id, matchedSource: true),
                    mergeTargetIDs: []
                ))
                continue
            }

            let parentID = collection.parentSource.flatMap { collectionIDBySource[$0] }
                ?? (collection.parentSource == nil ? options.targetParentID : nil)
            let nameKey = CollectionNameRules.comparisonKey(collection.name)
            let mergeTargets = existingCollections.filter {
                $0.parentID == parentID
                    && CollectionNameRules.comparisonKey($0.name) == nameKey
            }.map(\.id)
            if let selectedTarget = options.mergedCollectionTargets[collection.source],
               mergeTargets.contains(selectedTarget) {
                collectionIDBySource[collection.source] = selectedTarget
                collectionRows.append(FolderCollectionPreview(
                    source: collection.source,
                    name: existingCollections.first(where: { $0.id == selectedTarget })?.name
                        ?? collection.name,
                    depth: depth,
                    isIncluded: true,
                    action: .reuse(id: selectedTarget, matchedSource: false),
                    mergeTargetIDs: mergeTargets
                ))
                continue
            }

            let proposedName = uniqueName(
                collection.name,
                parentID: parentID,
                collections: candidateCollections
            )
            let id = options.createdCollectionIDs[collection.source] ?? UUID()
            let created = CollectionRecord(
                id: id,
                name: proposedName,
                parentID: parentID,
                importSources: [collection.source],
                sourceName: collection.name
            )
            candidateCollections.append(created)
            collectionIDBySource[collection.source] = id
            collectionRows.append(FolderCollectionPreview(
                source: collection.source,
                name: proposedName,
                depth: depth,
                isIncluded: true,
                action: .create(id: id, name: proposedName, parentID: parentID),
                mergeTargetIDs: mergeTargets
            ))
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingPapers.map { ($0.id, $0) })
        let paperRows = preliminaryPapers.map { planned, scanned, isIncluded, action in
            let metadataPreview: MetadataImportPreview?
            switch action {
            case let .reuse(id, _), let .keepExistingVersion(id):
                metadataPreview = existingByID[id].map {
                    MetadataImportMerger.preview(
                        current: $0.metadata,
                        imported: planned.metadata,
                        manuallyEditedFields: $0.manuallyEditedFields
                    )
                }
            case .create, .createNewVersion:
                metadataPreview = nil
            }
            return FolderPaperPreview(
                source: planned.source,
                relativePath: scanned.relativePath,
                title: planned.metadata.title,
                byteCount: planned.fingerprint?.byteCount ?? 0,
                directorySource: planned.collectionSources[0],
                action: action,
                collectionIDs: planned.collectionSources.compactMap { collectionIDBySource[$0] },
                changedMetadataFields: metadataPreview?.changedFields ?? [],
                blockedManualFields: metadataPreview?.blockedManualFields ?? [],
                isUserExcluded: !isIncluded && {
                    if case .keepExistingVersion = action { return false }
                    return true
                }(),
                isIncluded: isIncluded
            )
        }
        return FolderImportPreview(
            plan: plan,
            collections: collectionRows,
            papers: paperRows,
            diagnostics: scan.diagnostics,
            unsupportedFileCount: scan.unsupportedFileCount,
            targetParentID: options.targetParentID
        )
    }

    private static func uniqueName(
        _ requested: String,
        parentID: UUID?,
        collections: [CollectionRecord]
    ) -> String {
        let base = CollectionNameRules.trimmed(requested)
        let siblingKeys = Set(collections.lazy.filter { $0.parentID == parentID }.map {
            CollectionNameRules.comparisonKey($0.name)
        })
        if !siblingKeys.contains(CollectionNameRules.comparisonKey(base)) { return base }
        var suffix = 2
        while siblingKeys.contains(CollectionNameRules.comparisonKey("\(base) \(suffix)")) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func depth(
        of source: ImportSourceIdentity,
        in collections: [ImportSourceIdentity: PlannedImportCollection]
    ) -> Int {
        var depth = 0
        var next = collections[source]?.parentSource
        var visited: Set<ImportSourceIdentity> = [source]
        while let current = next, visited.insert(current).inserted {
            depth += 1
            next = collections[current]?.parentSource
        }
        return depth
    }

    private static func source(
        _ candidate: ImportSourceIdentity,
        isDescendantOf directory: ImportSourceIdentity
    ) -> Bool {
        guard case let .folder(candidateFolder) = candidate,
              case let .folder(directoryFolder) = directory,
              candidateFolder.rootVolumeUUID == directoryFolder.rootVolumeUUID,
              candidateFolder.rootDocumentIdentifier == directoryFolder.rootDocumentIdentifier else {
            return false
        }
        let directoryPath = directoryFolder.relativePath
        return directoryPath.isEmpty
            || candidateFolder.relativePath == directoryPath
            || candidateFolder.relativePath.hasPrefix(directoryPath + "/")
    }
}

struct FolderImportExecutionPreparation: Equatable, Sendable {
    var verifiedFiles: [ImportSourceIdentity: FolderVerifiedFile]
    var diagnostics: [FolderScanDiagnostic]
}

enum FolderImportExecutor {
    static func prepare(
        scan: FolderScanResult,
        preview: FolderImportPreview,
        maximumConcurrentFiles: Int = FolderImportScanner.defaultMaximumConcurrentFiles,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> FolderImportExecutionPreparation {
        let scanBySource = scan.fileBySource
        let includedRows = preview.papers.filter(\.isIncluded)
        var nextIndex = 0
        var finished = 0
        var verified: [ImportSourceIdentity: FolderVerifiedFile] = [:]
        var diagnostics: [FolderScanDiagnostic] = []
        progress(0, includedRows.count)

        await withTaskGroup(of: VerificationResult.self) { group in
            func addNext() {
                guard nextIndex < includedRows.count else { return }
                let row = includedRows[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard let scanned = scanBySource[row.source],
                          let fingerprint = scanned.descriptor.fingerprint else {
                        return VerificationResult(
                            source: row.source,
                            relativePath: row.relativePath,
                            verified: nil,
                            diagnosticKind: .unreadable
                        )
                    }
                    let needsBookmark: Bool
                    switch row.action {
                    case .create, .createNewVersion: needsBookmark = true
                    default: needsBookmark = false
                    }
                    do {
                        let item = try await FolderImportScanner.verifyFile(
                            at: scanned.url,
                            expectedIdentity: scanned.descriptor.identity,
                            expectedFingerprint: fingerprint,
                            makeBookmark: needsBookmark
                        )
                        return VerificationResult(
                            source: row.source,
                            relativePath: row.relativePath,
                            verified: item,
                            diagnosticKind: nil
                        )
                    } catch {
                        let kind: FolderScanDiagnosticKind
                        if let verificationError = error as? FolderFileVerificationError,
                           verificationError == .bookmarkUnavailable {
                            kind = .bookmarkUnavailable
                        } else if error is FolderFileVerificationError {
                            kind = .changedDuringScan
                        } else {
                            kind = .unreadable
                        }
                        return VerificationResult(
                            source: row.source,
                            relativePath: row.relativePath,
                            verified: nil,
                            diagnosticKind: kind
                        )
                    }
                }
            }

            for _ in 0..<min(max(1, maximumConcurrentFiles), includedRows.count) { addNext() }
            for await result in group {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                finished += 1
                if let item = result.verified {
                    verified[result.source] = item
                } else {
                    diagnostics.append(FolderScanDiagnostic(
                        relativePath: result.relativePath,
                        kind: result.diagnosticKind ?? .unreadable,
                        detail: nil
                    ))
                }
                progress(finished, includedRows.count)
                addNext()
            }
        }
        try Task.checkCancellation()
        return FolderImportExecutionPreparation(
            verifiedFiles: verified,
            diagnostics: diagnostics.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        )
    }

    private struct VerificationResult: Sendable {
        var source: ImportSourceIdentity
        var relativePath: String
        var verified: FolderVerifiedFile?
        var diagnosticKind: FolderScanDiagnosticKind?
    }
}

struct FolderImportReport: Equatable, Sendable {
    var createdPaperCount: Int
    var reusedPaperCount: Int
    var createdCollectionCount: Int
    var reusedCollectionCount: Int
    var skippedPaperCount: Int
    var keptVersionConflictCount: Int
    var failedPaperCount: Int
    var referencedByteCount: Int64
    var diagnostics: [FolderScanDiagnostic]

    var text: String {
        var lines = [
            "文件夹导入结果",
            "新增文献：\(createdPaperCount)",
            "复用文献：\(reusedPaperCount)",
            "新增文献集：\(createdCollectionCount)",
            "复用文献集：\(reusedCollectionCount)",
            "跳过（用户排除或非 PDF）：\(skippedPaperCount)",
            "保留旧版本冲突：\(keptVersionConflictCount)",
            "失败：\(failedPaperCount)",
            "原位引用字节：\(referencedByteCount)",
        ]
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("诊断：")
            lines.append(contentsOf: diagnostics.map {
                "- \($0.relativePath)：\($0.kind.title)\($0.detail.map { "（\($0)）" } ?? "")"
            })
        }
        return lines.joined(separator: "\n")
    }
}

struct FolderImportCandidate: Equatable, Sendable {
    var papers: [PaperRecord]
    var collections: [CollectionRecord]
    var report: FolderImportReport
}

enum FolderImportCandidateBuilder {
    static func build(
        preview: FolderImportPreview,
        preparation: FolderImportExecutionPreparation,
        existingPapers: [PaperRecord],
        existingCollections: [CollectionRecord]
    ) -> FolderImportCandidate {
        let plannedPaperBySource = Dictionary(
            uniqueKeysWithValues: preview.plan.papers.map { ($0.source, $0) }
        )
        let plannedCollectionBySource = Dictionary(
            uniqueKeysWithValues: preview.plan.collections.map { ($0.source, $0) }
        )
        let successfulRows = preview.papers.filter {
            $0.isIncluded && preparation.verifiedFiles[$0.source] != nil
        }
        var neededCollectionSources = Set(successfulRows.map(\.directorySource))
        var ancestors = Array(neededCollectionSources)
        while let current = ancestors.popLast(),
              let parent = plannedCollectionBySource[current]?.parentSource,
              neededCollectionSources.insert(parent).inserted {
            ancestors.append(parent)
        }

        var collections = existingCollections
        var createdCollectionCount = 0
        var reusedCollectionIDs: Set<UUID> = []
        for row in preview.collections where row.isIncluded && neededCollectionSources.contains(row.source) {
            guard let action = row.action,
                  let planned = plannedCollectionBySource[row.source] else { continue }
            switch action {
            case let .create(id, name, parentID):
                guard !collections.contains(where: { $0.id == id }) else { continue }
                collections.append(CollectionRecord(
                    id: id,
                    name: name,
                    parentID: parentID,
                    importSources: [row.source],
                    sourceName: planned.name
                ))
                createdCollectionCount += 1
            case let .reuse(id, _):
                guard let index = collections.firstIndex(where: { $0.id == id }) else { continue }
                if let sourceIndex = collections[index].importSources.firstIndex(of: row.source) {
                    // Refresh the root directory's read-only bookmark without changing source identity.
                    collections[index].importSources[sourceIndex] = row.source
                } else {
                    collections[index].importSources.append(row.source)
                }
                collections[index].importSources.sort(by: ImportSourceOrdering.less)
                if collections[index].sourceName == nil { collections[index].sourceName = planned.name }
                reusedCollectionIDs.insert(id)
            }
        }

        var papers = existingPapers
        var createdPaperCount = 0
        var reusedPaperIDs: Set<UUID> = []
        var referencedByteCount: Int64 = 0
        for row in successfulRows {
            guard let planned = plannedPaperBySource[row.source],
                  let verified = preparation.verifiedFiles[row.source] else { continue }
            let activeCollectionIDs = row.collectionIDs.filter { id in
                collections.contains(where: { $0.id == id })
            }
            switch row.action {
            case .create, .createNewVersion:
                if case let .createNewVersion(previousID) = row.action,
                   let previousIndex = papers.firstIndex(where: { $0.id == previousID }) {
                    papers[previousIndex].importSources.removeAll { $0 == row.source }
                }
                guard let bookmarkData = verified.bookmarkData else { continue }
                var record = PaperRecord(
                    identity: verified.identity,
                    bookmarkData: bookmarkData,
                    initialTitle: planned.metadata.title,
                    originalFileName: planned.originalFileName,
                    collectionIDs: activeCollectionIDs,
                    metadata: planned.metadata,
                    attachmentLabel: planned.attachmentLabel,
                    contentFingerprint: verified.fingerprint,
                    importSources: [row.source],
                    lastImportedMetadata: planned.metadata
                )
                record.didReadAutoMetadata = true
                papers.append(record)
                createdPaperCount += 1
                referencedByteCount += verified.fingerprint.byteCount
            case let .reuse(id, _):
                guard let index = papers.firstIndex(where: { $0.id == id }) else { continue }
                if !papers[index].importSources.contains(row.source) {
                    papers[index].importSources.append(row.source)
                    papers[index].importSources.sort(by: ImportSourceOrdering.less)
                }
                papers[index].collectionIDs = Array(Set(
                    papers[index].collectionIDs + activeCollectionIDs
                )).sorted { $0.uuidString < $1.uuidString }
                if papers[index].contentFingerprint == nil {
                    papers[index].contentFingerprint = verified.fingerprint
                }
                let merge = MetadataImportMerger.preview(
                    current: papers[index].metadata,
                    imported: planned.metadata,
                    manuallyEditedFields: papers[index].manuallyEditedFields
                )
                papers[index].metadata = merge.proposedMetadata
                papers[index].lastImportedMetadata = planned.metadata
                papers[index].didReadAutoMetadata = true
                reusedPaperIDs.insert(id)
                referencedByteCount += verified.fingerprint.byteCount
            case .keepExistingVersion:
                break
            }
        }

        let userSkipped = preview.papers.lazy.filter(\.isUserExcluded).count
        let scanFailureCount = preview.diagnostics.lazy.filter { diagnostic in
            switch diagnostic.kind {
            case .unreadable, .disappeared, .invalidPDF, .changedDuringScan,
                 .escapedRoot, .bookmarkUnavailable:
                return true
            case .skippedReference, .metadataUnavailable:
                return false
            }
        }.count
        return FolderImportCandidate(
            papers: papers,
            collections: collections,
            report: FolderImportReport(
                createdPaperCount: createdPaperCount,
                reusedPaperCount: reusedPaperIDs.count,
                createdCollectionCount: createdCollectionCount,
                reusedCollectionCount: reusedCollectionIDs.count,
                skippedPaperCount: userSkipped + preview.unsupportedFileCount,
                keptVersionConflictCount: preview.keptVersionConflictCount,
                failedPaperCount: scanFailureCount + preparation.diagnostics.count,
                referencedByteCount: referencedByteCount,
                diagnostics: preview.diagnostics + preparation.diagnostics
            )
        )
    }
}
