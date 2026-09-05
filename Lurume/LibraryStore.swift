import Foundation

enum LibraryStoreError: LocalizedError, Equatable {
    case persistenceUnavailable
    case collectionNotFound
    case invalidCollectionName
    case duplicateCollectionName
    case invalidCollectionMove
    case paperNotFound

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            "文献库当前为只读状态。为保护原有数据，无法保存这项操作。"
        case .collectionNotFound:
            "找不到这个文献集。"
        case .invalidCollectionName:
            "文献集名称不能为空。"
        case .duplicateCollectionName:
            "同一层级已有同名文献集。"
        case .invalidCollectionMove:
            "不能把文献集移入自身或它的子文献集。"
        case .paperNotFound:
            "部分文献已不在文献库中。"
        }
    }
}

struct RemovedLibraryPapers: Sendable {
    let papers: [PaperRecord]
    let selectedPaperID: UUID?
}

struct CollectionDeletionSummary: Equatable, Sendable {
    let collectionCount: Int
    let affectedPaperCount: Int
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var papers: [PaperRecord] = []
    @Published private(set) var collections: [CollectionRecord] = []
    @Published var selectedPaperID: UUID?
    @Published private(set) var unavailablePaperIDs: Set<UUID> = []
    @Published var presentedError: String?
    @Published private(set) var persistenceFailure: String?

    /// 载入失败或版本无法迁移时为真：所有写盘被禁止，避免静默清空重建用户文献库。
    private(set) var persistenceDisabled = false

    private let persistence: LibraryPersistence
    private let metadataReader: any PaperMetadataReading
    private var lastSavedSnapshot: LibrarySnapshot = .empty
    private var pageSaveTask: Task<Void, Never>?
    private var pdfImportTask: Task<Void, Never>?
    private var pdfImportRequestID = UUID()

    init(
        persistence: LibraryPersistence,
        metadataReader: any PaperMetadataReading = SystemPaperMetadataReader()
    ) {
        self.persistence = persistence
        self.metadataReader = metadataReader
        load()
        recoverInterruptedZoteroImport()
    }

    convenience init() {
        do {
            try self.init(persistence: .applicationDefault())
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Lurume-library.json")
            self.init(persistence: LibraryPersistence(fileURL: fallback))
            presentedError = error.localizedDescription
        }
    }

    deinit {
        pageSaveTask?.cancel()
        pdfImportTask?.cancel()
    }

    var selectedPaper: PaperRecord? {
        guard let selectedPaperID else { return nil }
        return papers.first { $0.id == selectedPaperID }
    }

    // MARK: - 检索

    func papers(
        in source: LibrarySource = .all,
        matching rawQuery: String,
        status: ReadingStatusFilter = .all,
        sortedBy sort: LibrarySortOption? = nil
    ) -> [PaperRecord] {
        let sourcePapers = papers(in: source)
        guard let sort else {
            let filtered = LibraryQuery.apply(
                to: sourcePapers,
                searchText: rawQuery,
                status: status,
                sort: .dateAdded
            )
            let ids = Set(filtered.map(\.id))
            return sourcePapers.filter { ids.contains($0.id) }
        }
        return LibraryQuery.apply(
            to: sourcePapers,
            searchText: rawQuery,
            status: status,
            sort: sort
        )
    }

    func count(in source: LibrarySource) -> Int {
        papers(in: source).count
    }

    var sortedCollections: [CollectionRecord] {
        sorted(collections)
    }

    var rootCollections: [CollectionRecord] {
        sorted(collections.filter { $0.parentID == nil })
    }

    func childCollections(of parentID: UUID) -> [CollectionRecord] {
        sorted(collections.filter { $0.parentID == parentID })
    }

    func collectionPath(for id: UUID) -> [CollectionRecord] {
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        var path: [CollectionRecord] = []
        var current = byID[id]
        var visited: Set<UUID> = []
        while let collection = current, visited.insert(collection.id).inserted {
            path.append(collection)
            current = collection.parentID.flatMap { byID[$0] }
        }
        return path.reversed()
    }

    private func sorted(_ values: [CollectionRecord]) -> [CollectionRecord] {
        values.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func validSource(_ source: LibrarySource) -> LibrarySource {
        guard case let .collection(id) = source else { return source }
        return collections.contains(where: { $0.id == id }) ? source : .all
    }

    // MARK: - 文献集

    @discardableResult
    func createCollection(
        named rawName: String,
        parentID: UUID? = nil,
        undoManager: UndoManager? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> UUID {
        if let parentID,
           !collections.contains(where: { $0.id == parentID }) {
            throw LibraryStoreError.collectionNotFound
        }
        let name = try validatedCollectionName(rawName, parentID: parentID)
        var updatedCollections = collections
        updatedCollections.append(CollectionRecord(
            id: id,
            name: name,
            createdAt: createdAt,
            parentID: parentID
        ))
        try applyOrganizationChange(
            papers: papers,
            collections: updatedCollections,
            undoManager: undoManager,
            actionName: "文献集：新建“\(name)”"
        )
        return id
    }

    func renameCollection(
        id: UUID,
        to rawName: String,
        undoManager: UndoManager? = nil
    ) throws {
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.collectionNotFound
        }
        let name = try validatedCollectionName(
            rawName,
            parentID: collections[index].parentID,
            excluding: id
        )
        guard collections[index].name != name else { return }
        var updatedCollections = collections
        updatedCollections[index].name = name
        try applyOrganizationChange(
            papers: papers,
            collections: updatedCollections,
            undoManager: undoManager,
            actionName: "文献集：重命名为“\(name)”"
        )
    }

    func deleteCollection(id: UUID, undoManager: UndoManager? = nil) throws {
        guard let collection = collections.first(where: { $0.id == id }) else {
            throw LibraryStoreError.collectionNotFound
        }
        guard let candidate = CollectionHierarchy.deletionCandidate(
            for: id,
            papers: papers,
            collections: collections
        ) else {
            throw LibraryStoreError.collectionNotFound
        }
        let removedIDs = Set(candidate.removedCollections.map(\.id))
        let updatedCollections = collections.filter { !removedIDs.contains($0.id) }
        try applyOrganizationChange(
            papers: candidate.updatedPapers,
            collections: updatedCollections,
            undoManager: undoManager,
            actionName: "文献集：删除“\(collection.name)”"
        )
    }

    func deletionSummary(forCollectionID id: UUID) -> CollectionDeletionSummary? {
        guard let candidate = CollectionHierarchy.deletionCandidate(
            for: id,
            papers: papers,
            collections: collections
        ) else {
            return nil
        }
        return CollectionDeletionSummary(
            collectionCount: candidate.removedCollections.count,
            affectedPaperCount: candidate.affectedPaperCount
        )
    }

    func moveCollection(
        id: UUID,
        toParentID parentID: UUID?,
        undoManager: UndoManager? = nil
    ) throws {
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.collectionNotFound
        }
        guard CollectionHierarchy.canMove(
            collectionID: id,
            to: parentID,
            in: collections
        ) else {
            throw LibraryStoreError.invalidCollectionMove
        }
        guard collections[index].parentID != parentID else { return }
        _ = try validatedCollectionName(
            collections[index].name,
            parentID: parentID,
            excluding: id
        )
        var updatedCollections = collections
        updatedCollections[index].parentID = parentID
        updatedCollections[index].wasManuallyOrganized = true
        try applyOrganizationChange(
            papers: papers,
            collections: updatedCollections,
            undoManager: undoManager,
            actionName: "文献集：移动“\(collections[index].name)”"
        )
    }

    func canMoveCollection(_ id: UUID, to parentID: UUID?) -> Bool {
        guard let collection = collections.first(where: { $0.id == id }),
              collection.parentID != parentID else {
            return false
        }
        guard CollectionHierarchy.canMove(
            collectionID: id,
            to: parentID,
            in: collections
        ) else {
            return false
        }
        let nameKey = CollectionNameRules.comparisonKey(collection.name)
        return !collections.contains {
            $0.id != id
                && $0.parentID == parentID
                && CollectionNameRules.comparisonKey($0.name) == nameKey
        }
    }

    func membershipState(
        paperIDs: Set<UUID>,
        collectionID: UUID
    ) -> CollectionMembershipState {
        guard !paperIDs.isEmpty else { return .off }
        let memberCount = papers.lazy.filter {
            paperIDs.contains($0.id) && $0.collectionIDs.contains(collectionID)
        }.count
        if memberCount == 0 { return .off }
        if memberCount == paperIDs.count { return .on }
        return .mixed
    }

    func setMembership(
        of paperIDs: Set<UUID>,
        in collectionID: UUID,
        isMember: Bool,
        undoManager: UndoManager? = nil
    ) throws {
        guard collections.contains(where: { $0.id == collectionID }) else {
            throw LibraryStoreError.collectionNotFound
        }
        guard !paperIDs.isEmpty else { return }
        let knownPaperIDs = Set(papers.map(\.id))
        guard paperIDs.isSubset(of: knownPaperIDs) else {
            throw LibraryStoreError.paperNotFound
        }

        var updatedPapers = papers
        var didChange = false
        for index in updatedPapers.indices where paperIDs.contains(updatedPapers[index].id) {
            var memberships = Set(updatedPapers[index].collectionIDs)
            let changed = isMember
                ? memberships.insert(collectionID).inserted
                : memberships.remove(collectionID) != nil
            guard changed else { continue }
            updatedPapers[index].collectionIDs = memberships.sorted {
                $0.uuidString < $1.uuidString
            }
            didChange = true
        }
        guard didChange else { return }

        let verb = isMember ? "加入" : "移出"
        try applyOrganizationChange(
            papers: updatedPapers,
            collections: collections,
            undoManager: undoManager,
            actionName: "文献集：\(verb) \(paperIDs.count) 篇"
        )
    }

    func removeMemberships(
        of paperIDs: Set<UUID>,
        fromCollectionHierarchy collectionID: UUID,
        undoManager: UndoManager? = nil
    ) throws {
        guard collections.contains(where: { $0.id == collectionID }) else {
            throw LibraryStoreError.collectionNotFound
        }
        guard paperIDs.isSubset(of: Set(papers.map(\.id))) else {
            throw LibraryStoreError.paperNotFound
        }
        let removedCollectionIDs = CollectionHierarchy.descendantIDs(
            of: collectionID,
            in: collections
        )
        var updatedPapers = papers
        var didChange = false
        for index in updatedPapers.indices where paperIDs.contains(updatedPapers[index].id) {
            let previous = updatedPapers[index].collectionIDs
            updatedPapers[index].collectionIDs.removeAll(where: removedCollectionIDs.contains)
            didChange = didChange || previous != updatedPapers[index].collectionIDs
        }
        guard didChange else { return }
        try applyOrganizationChange(
            papers: updatedPapers,
            collections: collections,
            undoManager: undoManager,
            actionName: "文献集：移出 \(paperIDs.count) 篇"
        )
    }

    // MARK: - 导入与选择

    @discardableResult
    func importPDF(
        at url: URL,
        collectionID: UUID? = nil,
        selectAfterImport: Bool = true
    ) throws -> UUID {
        guard let id = try importPDFBatch(
            at: [url],
            collectionID: collectionID,
            selectAfterImport: selectAfterImport
        ).first else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return id
    }

    func importPDFs(
        at urls: [URL],
        collectionID: UUID? = nil,
        selectAfterImport: Bool = true
    ) {
        guard !persistenceDisabled else {
            presentedError = LibraryStoreError.persistenceUnavailable.localizedDescription
            return
        }
        if let collectionID,
           !collections.contains(where: { $0.id == collectionID }) {
            presentedError = LibraryStoreError.collectionNotFound.localizedDescription
            return
        }
        let pdfURLs = urls.filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
        guard !pdfURLs.isEmpty else { return }
        pdfImportTask?.cancel()
        let currentRequestID = UUID()
        pdfImportRequestID = currentRequestID
        let basePapers = papers
        let baseCollections = collections
        let scanner = FolderImportScanner(metadataReader: metadataReader)
        pdfImportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scanned = try await scanner.scanStandalonePDFs(at: pdfURLs)
                try Task.checkCancellation()
                guard pdfImportRequestID == currentRequestID else { return }
                guard papers == basePapers, collections == baseCollections else {
                    throw FolderImportError.libraryChanged
                }
                try commitStandalonePDFImport(
                    scanned,
                    collectionID: collectionID,
                    selectAfterImport: selectAfterImport
                )
            } catch is CancellationError {
                // A newer explicit import superseded this request.
            } catch {
                if pdfImportRequestID == currentRequestID {
                    presentedError = "无法导入 PDF：\(error.localizedDescription)"
                }
            }
            if pdfImportRequestID == currentRequestID { pdfImportTask = nil }
        }
    }

    private func commitStandalonePDFImport(
        _ scanned: [ScannedStandalonePDF],
        collectionID: UUID?,
        selectAfterImport: Bool
    ) throws {
        try requireWritableLibrary()
        var updatedPapers = papers
        var importedIDs: [UUID] = []
        let openedAt = Date()
        for file in scanned {
            let duplicateIndex = updatedPapers.firstIndex {
                $0.identity.identifiesSameFile(as: file.identity)
                    || $0.contentFingerprint?.sha256 == file.fingerprint.sha256
            }
            if let index = duplicateIndex {
                if let collectionID,
                   !updatedPapers[index].collectionIDs.contains(collectionID) {
                    updatedPapers[index].collectionIDs.append(collectionID)
                    updatedPapers[index].collectionIDs.sort { $0.uuidString < $1.uuidString }
                }
                if updatedPapers[index].contentFingerprint == nil {
                    updatedPapers[index].contentFingerprint = file.fingerprint
                }
                let merge = MetadataImportMerger.preview(
                    current: updatedPapers[index].metadata,
                    imported: file.metadata,
                    manuallyEditedFields: updatedPapers[index].manuallyEditedFields
                )
                updatedPapers[index].metadata = merge.proposedMetadata
                updatedPapers[index].lastImportedMetadata = file.metadata
                updatedPapers[index].didReadAutoMetadata = true
                if selectAfterImport { updatedPapers[index].lastOpenedAt = openedAt }
                importedIDs.append(updatedPapers[index].id)
                continue
            }
            var record = PaperRecord(
                identity: file.identity,
                bookmarkData: file.bookmarkData,
                initialTitle: file.metadata.title,
                originalFileName: file.originalFileName,
                lastOpenedAt: selectAfterImport ? openedAt : nil,
                collectionIDs: collectionID.map { [$0] } ?? [],
                metadata: file.metadata,
                contentFingerprint: file.fingerprint,
                lastImportedMetadata: file.metadata
            )
            record.didReadAutoMetadata = true
            updatedPapers.append(record)
            importedIDs.append(record.id)
        }
        let updatedSelection = selectAfterImport
            ? importedIDs.last ?? selectedPaperID
            : selectedPaperID
        if updatedPapers != papers || updatedSelection != selectedPaperID {
            try commit(
                papers: updatedPapers,
                collections: collections,
                selectedPaperID: updatedSelection
            )
        }
    }

    @discardableResult
    func importPDFBatch(
        at urls: [URL],
        collectionID: UUID? = nil,
        selectAfterImport: Bool = true
    ) throws -> [UUID] {
        try requireWritableLibrary()
        if let collectionID,
           !collections.contains(where: { $0.id == collectionID }) {
            throw LibraryStoreError.collectionNotFound
        }

        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfURLs.isEmpty else { return [] }
        var updatedPapers = papers
        var importedIDs: [UUID] = []
        var newPaperIDs: [UUID] = []
        let openedAt = Date()

        for url in pdfURLs {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let identity = try FileIdentity(url: url)
            if let index = updatedPapers.firstIndex(where: {
                $0.identity.identifiesSameFile(as: identity)
            }) {
                if let collectionID,
                   !updatedPapers[index].collectionIDs.contains(collectionID) {
                    updatedPapers[index].collectionIDs.append(collectionID)
                    updatedPapers[index].collectionIDs.sort { $0.uuidString < $1.uuidString }
                }
                if selectAfterImport {
                    updatedPapers[index].lastOpenedAt = openedAt
                }
                importedIDs.append(updatedPapers[index].id)
                continue
            }

            let bookmarkData = try SecurityScopedFile.makeBookmark(for: url)
            let record = PaperRecord(
                identity: identity,
                bookmarkData: bookmarkData,
                initialTitle: url.deletingPathExtension().lastPathComponent,
                originalFileName: url.lastPathComponent,
                lastOpenedAt: selectAfterImport ? openedAt : nil,
                collectionIDs: collectionID.map { [$0] } ?? []
            )
            updatedPapers.append(record)
            importedIDs.append(record.id)
            newPaperIDs.append(record.id)
        }

        let updatedSelection = selectAfterImport
            ? importedIDs.last ?? selectedPaperID
            : selectedPaperID
        if updatedPapers != papers || updatedSelection != selectedPaperID {
            try commit(
                papers: updatedPapers,
                collections: collections,
                selectedPaperID: updatedSelection
            )
        }
        for id in newPaperIDs {
            scheduleMetadataRead(for: id, resolvedURL: nil)
        }
        return importedIDs
    }

    func applyFolderImport(
        papers candidatePapers: [PaperRecord],
        collections candidateCollections: [CollectionRecord],
        undoManager: UndoManager?
    ) throws {
        try applyOrganizationChange(
            papers: candidatePapers,
            collections: candidateCollections,
            undoManager: undoManager,
            actionName: "文件夹导入"
        )
    }

    func applyZoteroImport(
        _ candidate: ZoteroImportCandidate,
        expectedPapers: [PaperRecord],
        expectedCollections: [CollectionRecord],
        undoManager: UndoManager?
    ) throws {
        guard papers == expectedPapers, collections == expectedCollections else {
            throw ZoteroImportTransactionError.libraryChanged
        }
        try applyOrganizationChange(
            papers: candidate.papers,
            collections: candidate.collections,
            undoManager: undoManager,
            actionName: "Zotero 迁移（撤销不删除已复制 PDF）"
        )
    }

    var zoteroImportJournalStore: ZoteroImportJournalStore {
        ZoteroImportJournalStore(
            fileURL: persistence.fileURL.deletingLastPathComponent()
                .appendingPathComponent("zotero-import-transaction.json")
        )
    }

    var zoteroDirectoryBookmarkStore: ZoteroDirectoryBookmarkStore {
        ZoteroDirectoryBookmarkStore(
            fileURL: persistence.fileURL.deletingLastPathComponent()
                .appendingPathComponent("zotero-import-directories.json")
        )
    }

    func selectPaper(id: UUID?) {
        guard selectedPaperID != id else { return }
        if persistenceDisabled {
            selectedPaperID = id
            return
        }
        flushPendingSave()
        selectedPaperID = id
        if let id, let index = papers.firstIndex(where: { $0.id == id }) {
            papers[index].lastOpenedAt = Date()
        }
        persistReportingErrors()
    }

    func removePaper(id: UUID) throws {
        _ = try removePapers(ids: [id])
    }

    func removePapers(ids: Set<UUID>) throws -> RemovedLibraryPapers {
        try requireWritableLibrary()
        flushPendingSave()
        let removed = papers.filter { ids.contains($0.id) }
        guard !removed.isEmpty else {
            return RemovedLibraryPapers(papers: [], selectedPaperID: selectedPaperID)
        }
        let updatedPapers = papers.filter { !ids.contains($0.id) }
        let updatedSelection = selectedPaperID.flatMap { ids.contains($0) ? nil : $0 }
            ?? updatedPapers.first?.id
        let batch = RemovedLibraryPapers(
            papers: removed,
            selectedPaperID: selectedPaperID
        )
        try commit(
            papers: updatedPapers,
            collections: collections,
            selectedPaperID: updatedSelection
        )
        return batch
    }

    func restorePapers(_ batch: RemovedLibraryPapers) throws {
        guard !batch.papers.isEmpty else { return }
        try requireWritableLibrary()
        let knownIDs = Set(papers.map(\.id))
        let restored = batch.papers.filter { !knownIDs.contains($0.id) }
        guard !restored.isEmpty else { return }
        let updatedSelection = batch.selectedPaperID.flatMap { selectedID in
            (papers + restored).contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? selectedPaperID
        try commit(
            papers: papers + restored,
            collections: collections,
            selectedPaperID: updatedSelection
        )
    }

    func updatePageIndex(_ pageIndex: Int, for paperID: UUID) {
        guard !persistenceDisabled else { return }
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let normalizedIndex = max(0, pageIndex)
        guard papers[index].lastPageIndex != normalizedIndex else { return }
        papers[index].lastPageIndex = normalizedIndex
        schedulePageSave()
    }

    // MARK: - 手动编辑

    func setManualTitle(_ value: String, for id: UUID) {
        guard rejectMutationIfReadOnly() == false else { return }
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].setManualTitle(value)
        flushPendingSave()
        persistReportingErrors()
    }

    func setManualAuthors(_ value: String?, for id: UUID) {
        guard rejectMutationIfReadOnly() == false else { return }
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].setManualAuthors(value)
        flushPendingSave()
        persistReportingErrors()
    }

    func setManualYear(_ value: Int?, for id: UUID) {
        guard rejectMutationIfReadOnly() == false else { return }
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].setManualYear(value)
        flushPendingSave()
        persistReportingErrors()
    }

    func setManualMetadata(
        _ metadata: BibliographicMetadata,
        attachmentLabel: String?,
        for id: UUID
    ) throws {
        guard let index = papers.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.paperNotFound
        }
        guard papers[index].metadata != metadata
                || papers[index].attachmentLabel != attachmentLabel else {
            return
        }
        var updatedPapers = papers
        let changedFields = BibliographicMetadataChanges.fields(
            from: updatedPapers[index].metadata,
            to: metadata
        )
        updatedPapers[index].metadata = metadata
        updatedPapers[index].attachmentLabel = attachmentLabel
        updatedPapers[index].manuallyEditedFields.formUnion(changedFields)
        updatedPapers[index].manuallyEditedFields.remove(.authors)
        updatedPapers[index].manuallyEditedFields.remove(.year)
        try commit(
            papers: updatedPapers,
            collections: collections,
            selectedPaperID: selectedPaperID
        )
    }

    func cycleReadingStatus(for id: UUID) {
        guard let paper = paper(withID: id) else { return }
        setReadingStatus(paper.readingStatus.next, for: id)
    }

    func setReadingStatus(_ status: ReadingStatus, for id: UUID) {
        guard rejectMutationIfReadOnly() == false else { return }
        guard let index = papers.firstIndex(where: { $0.id == id }),
              papers[index].readingStatus != status else {
            return
        }
        flushPendingSave()
        let previous = papers[index].readingStatus
        papers[index].readingStatus = status
        do {
            try saveNow()
        } catch {
            papers[index].readingStatus = previous
            presentedError = "无法保存阅读状态：\(error.localizedDescription)"
        }
    }

    // MARK: - 文件访问与元数据补全

    func resolveFile(for paperID: UUID) -> SecurityScopedAccess? {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return nil }

        do {
            let resolved = try SecurityScopedFile.resolve(
                bookmarkData: papers[index].bookmarkData
            )
            let access = SecurityScopedAccess(url: resolved.url)
            if let refreshedBookmarkData = resolved.refreshedBookmarkData {
                papers[index].bookmarkData = refreshedBookmarkData
            }
            guard FileManager.default.fileExists(atPath: resolved.url.path) else {
                setUnavailable(true, for: paperID)
                return nil
            }
            var didUpdateReference = false
            if let resolvedIdentity = try? FileIdentity(url: resolved.url),
               papers[index].identity != resolvedIdentity {
                papers[index].replaceFileReference(
                    identity: resolvedIdentity,
                    bookmarkData: papers[index].bookmarkData,
                    originalFileName: resolved.url.lastPathComponent
                )
                didUpdateReference = true
            }
            if resolved.refreshedBookmarkData != nil || didUpdateReference {
                persistReportingErrors()
            }
            setUnavailable(false, for: paperID)
            scheduleMetadataRead(for: paperID, resolvedURL: resolved.url)
            return access
        } catch {
            setUnavailable(true, for: paperID)
            return nil
        }
    }

    func relinkPaper(id: UUID, to url: URL) throws {
        try requireWritableLibrary()
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let identity = try FileIdentity(url: url)
        let bookmarkData = try SecurityScopedFile.makeBookmark(for: url)
        var updatedPapers = papers
        updatedPapers[index].replaceFileReference(
            identity: identity,
            bookmarkData: bookmarkData,
            originalFileName: url.lastPathComponent
        )
        try commit(
            papers: updatedPapers,
            collections: collections,
            selectedPaperID: selectedPaperID
        )
        unavailablePaperIDs.remove(id)
    }

    // MARK: - 持久化

    var hasUnsavedChanges: Bool {
        !persistenceDisabled && snapshot != lastSavedSnapshot
    }

    @discardableResult
    func flushPendingSave() -> Bool {
        pageSaveTask?.cancel()
        pageSaveTask = nil
        // A read-only library or an unchanged snapshot has no pending user changes to lose.
        guard hasUnsavedChanges else { return true }
        return persistReportingErrors()
    }

    private func load() {
        do {
            let loaded = try persistence.load()
            lastSavedSnapshot = loaded.snapshot
            papers = loaded.snapshot.papers
            collections = loaded.snapshot.collections
            let repairedCurrentRecords = papers.indices.reduce(into: false) { repaired, index in
                if papers[index].synchronizeOriginalFileNameWithFallbackPath() {
                    repaired = true
                }
            }
            selectedPaperID = loaded.snapshot.selectedPaperID.flatMap { selectedID in
                papers.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
            if loaded.migratedFromLegacy || repairedCurrentRecords {
                do {
                    try saveNow()
                } catch {
                    disablePersistence(because: error)
                }
            }
        } catch {
            disablePersistence(because: error)
        }
    }

    private func recoverInterruptedZoteroImport() {
        guard !persistenceDisabled else { return }
        do {
            if try ZoteroImportRecovery.recoverIfNeeded(
                journalStore: zoteroImportJournalStore,
                snapshot: snapshot
            ) {
                presentedError = "已安全恢复上次未完成的 Zotero 迁移。"
            }
        } catch {
            // 保守恢复失败时保持文献库可用，但不自动删除任何无法证明归属的文件。
            presentedError = error.localizedDescription
        }
    }

    private func schedulePageSave() {
        pageSaveTask?.cancel()
        pageSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.pageSaveTask = nil
            self?.persistReportingErrors()
        }
    }

    private func saveNow() throws {
        try requireWritableLibrary()
        let candidate = snapshot
        try persistence.save(candidate)
        lastSavedSnapshot = candidate
    }

    private func commit(
        papers updatedPapers: [PaperRecord],
        collections updatedCollections: [CollectionRecord],
        selectedPaperID updatedSelectedPaperID: UUID?
    ) throws {
        try requireWritableLibrary()
        let candidate = LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: updatedPapers,
            collections: updatedCollections,
            selectedPaperID: updatedSelectedPaperID
        )
        try persistence.save(candidate)
        lastSavedSnapshot = candidate
        papers = updatedPapers
        collections = updatedCollections
        selectedPaperID = updatedSelectedPaperID
        unavailablePaperIDs.formIntersection(Set(updatedPapers.map(\.id)))
    }

    private func applyOrganizationChange(
        papers updatedPapers: [PaperRecord],
        collections updatedCollections: [CollectionRecord],
        undoManager: UndoManager?,
        actionName: String
    ) throws {
        flushPendingSave()
        let previousPapers = papers
        let previousCollections = collections
        try commit(
            papers: updatedPapers,
            collections: updatedCollections,
            selectedPaperID: selectedPaperID
        )
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            do {
                try store.applyOrganizationChange(
                    papers: previousPapers,
                    collections: previousCollections,
                    undoManager: undoManager,
                    actionName: actionName
                )
            } catch {
                store.presentedError = "无法撤销文献集操作：\(error.localizedDescription)"
            }
        }
        undoManager?.setActionName(actionName)
    }

    private func validatedCollectionName(
        _ rawName: String,
        parentID: UUID?,
        excluding excludedID: UUID? = nil
    ) throws -> String {
        let name = CollectionNameRules.trimmed(rawName)
        guard !name.isEmpty else { throw LibraryStoreError.invalidCollectionName }
        let key = CollectionNameRules.comparisonKey(name)
        guard !collections.contains(where: {
            $0.id != excludedID
                && $0.parentID == parentID
                && CollectionNameRules.comparisonKey($0.name) == key
        }) else {
            throw LibraryStoreError.duplicateCollectionName
        }
        return name
    }

    private func papers(in source: LibrarySource) -> [PaperRecord] {
        switch source {
        case .all:
            return papers
        case .unfiled:
            return papers.filter { $0.collectionIDs.isEmpty }
        case let .collection(id):
            let includedCollectionIDs = CollectionHierarchy.descendantIDs(
                of: id,
                in: collections
            )
            return papers.filter { paper in
                paper.collectionIDs.contains(where: includedCollectionIDs.contains)
            }
        }
    }

    private var snapshot: LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: papers,
            collections: collections,
            selectedPaperID: selectedPaperID
        )
    }

    @discardableResult
    private func persistReportingErrors() -> Bool {
        guard !persistenceDisabled else { return false }
        do {
            try saveNow()
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    private func requireWritableLibrary() throws {
        guard !persistenceDisabled else {
            throw LibraryStoreError.persistenceUnavailable
        }
    }

    @discardableResult
    private func rejectMutationIfReadOnly() -> Bool {
        guard persistenceDisabled else { return false }
        presentedError = LibraryStoreError.persistenceUnavailable.localizedDescription
        return true
    }

    private func disablePersistence(because error: Error) {
        persistenceDisabled = true
        persistenceFailure = error.localizedDescription
        presentedError = error.localizedDescription
    }

    private func setUnavailable(_ unavailable: Bool, for paperID: UUID) {
        if unavailable {
            guard !unavailablePaperIDs.contains(paperID) else { return }
            unavailablePaperIDs.insert(paperID)
        } else {
            guard unavailablePaperIDs.contains(paperID) else { return }
            unavailablePaperIDs.remove(paperID)
        }
    }

    // MARK: - 自动元数据读取（导入时一次；存量记录在首次成功打开时补偿）

    private enum MetadataReadOutcome: Sendable {
        /// 文件无法访问：不消耗唯一一次自动读取机会，等待下次成功打开。
        case inaccessible
        case value(PaperMetadata?)
    }

    private func scheduleMetadataRead(for paperID: UUID, resolvedURL: URL?) {
        guard let record = paper(withID: paperID),
              !record.didReadAutoMetadata else {
            return
        }

        let bookmarkData = record.bookmarkData
        let reader = metadataReader
        Task {
            var targetURL = resolvedURL
            if targetURL == nil {
                targetURL = (try? SecurityScopedFile.resolve(bookmarkData: bookmarkData))?.url
            }
            guard let url = targetURL else {
                self.apply(.inaccessible, paperID: paperID)
                return
            }

            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let metadata = await reader.metadata(at: url)
            self.apply(.value(metadata), paperID: paperID)
        }
    }

    private func apply(_ outcome: MetadataReadOutcome, paperID: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == paperID }),
              !papers[index].didReadAutoMetadata else {
            return
        }
        switch outcome {
        case .inaccessible:
            return
        case let .value(metadata):
            papers[index].applyAutoMetadata(metadata)
            persistReportingErrors()
        }
    }

    private func paper(withID id: UUID) -> PaperRecord? {
        papers.first { $0.id == id }
    }
}
