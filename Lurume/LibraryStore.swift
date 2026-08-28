import Foundation

enum LibraryStoreError: LocalizedError, Equatable {
    case persistenceUnavailable
    case collectionNotFound
    case invalidCollectionName
    case duplicateCollectionName
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
            "已有同名文献集。"
        case .paperNotFound:
            "部分文献已不在文献库中。"
        }
    }
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
    private var pageSaveTask: Task<Void, Never>?

    init(
        persistence: LibraryPersistence,
        metadataReader: any PaperMetadataReading = SystemPaperMetadataReader()
    ) {
        self.persistence = persistence
        self.metadataReader = metadataReader
        load()
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
        let sourcePapers = papers.filter(source.includes)
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
        papers.lazy.filter(source.includes).count
    }

    var sortedCollections: [CollectionRecord] {
        collections.sorted { lhs, rhs in
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
        undoManager: UndoManager? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> UUID {
        let name = try validatedCollectionName(rawName)
        var updatedCollections = collections
        updatedCollections.append(CollectionRecord(id: id, name: name, createdAt: createdAt))
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
        let name = try validatedCollectionName(rawName, excluding: id)
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
        var updatedPapers = papers
        for index in updatedPapers.indices {
            updatedPapers[index].collectionIDs.removeAll { $0 == id }
        }
        let updatedCollections = collections.filter { $0.id != id }
        try applyOrganizationChange(
            papers: updatedPapers,
            collections: updatedCollections,
            undoManager: undoManager,
            actionName: "文献集：删除“\(collection.name)”"
        )
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

    // MARK: - 导入与选择

    @discardableResult
    func importPDF(
        at url: URL,
        collectionID: UUID? = nil,
        selectAfterImport: Bool = true
    ) throws -> UUID {
        try requireWritableLibrary()
        if let collectionID,
           !collections.contains(where: { $0.id == collectionID }) {
            throw LibraryStoreError.collectionNotFound
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let identity = try FileIdentity(url: url)
        if let existingIndex = papers.firstIndex(where: {
            $0.identity.identifiesSameFile(as: identity)
        }) {
            let existingID = papers[existingIndex].id
            if let collectionID,
               !papers[existingIndex].collectionIDs.contains(collectionID) {
                var updatedPapers = papers
                updatedPapers[existingIndex].collectionIDs.append(collectionID)
                updatedPapers[existingIndex].collectionIDs.sort { $0.uuidString < $1.uuidString }
                try commit(
                    papers: updatedPapers,
                    collections: collections,
                    selectedPaperID: selectAfterImport ? existingID : selectedPaperID
                )
            } else if selectAfterImport {
                selectPaper(id: existingID)
            }
            return existingID
        }

        let bookmarkData = try SecurityScopedFile.makeBookmark(for: url)
        let record = PaperRecord(
            identity: identity,
            bookmarkData: bookmarkData,
            displayName: url.deletingPathExtension().lastPathComponent,
            originalFileName: url.lastPathComponent,
            lastOpenedAt: selectAfterImport ? Date() : nil,
            collectionIDs: collectionID.map { [$0] } ?? []
        )
        try commit(
            papers: papers + [record],
            collections: collections,
            selectedPaperID: selectAfterImport ? record.id : selectedPaperID
        )
        scheduleMetadataRead(for: record.id, resolvedURL: nil)
        return record.id
    }

    func importPDFs(
        at urls: [URL],
        collectionID: UUID? = nil,
        selectAfterImport: Bool = true
    ) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            do {
                _ = try importPDF(
                    at: url,
                    collectionID: collectionID,
                    selectAfterImport: selectAfterImport
                )
            } catch {
                presentedError = "无法导入“\(url.lastPathComponent)”：\(error.localizedDescription)"
            }
        }
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
        try requireWritableLibrary()
        flushPendingSave()

        let previousPapers = papers
        let previousUnavailablePaperIDs = unavailablePaperIDs
        let previousSelectedPaperID = selectedPaperID
        papers.removeAll { $0.id == id }
        unavailablePaperIDs.remove(id)
        if selectedPaperID == id {
            selectedPaperID = papers.first?.id
        }
        do {
            try saveNow()
        } catch {
            papers = previousPapers
            unavailablePaperIDs = previousUnavailablePaperIDs
            selectedPaperID = previousSelectedPaperID
            throw error
        }
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
        papers[index].replaceFileReference(
            identity: identity,
            bookmarkData: bookmarkData,
            originalFileName: url.lastPathComponent
        )
        unavailablePaperIDs.remove(id)
        try saveNow()
    }

    // MARK: - 持久化

    func flushPendingSave() {
        pageSaveTask?.cancel()
        pageSaveTask = nil
        persistReportingErrors()
    }

    private func load() {
        do {
            let loaded = try persistence.load()
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
                    try persistence.save(snapshot)
                } catch {
                    disablePersistence(because: error)
                }
            }
        } catch {
            disablePersistence(because: error)
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
        try persistence.save(snapshot)
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
        excluding excludedID: UUID? = nil
    ) throws -> String {
        let name = CollectionNameRules.trimmed(rawName)
        guard !name.isEmpty else { throw LibraryStoreError.invalidCollectionName }
        let key = CollectionNameRules.comparisonKey(name)
        guard !collections.contains(where: {
            $0.id != excludedID && CollectionNameRules.comparisonKey($0.name) == key
        }) else {
            throw LibraryStoreError.duplicateCollectionName
        }
        return name
    }

    private var snapshot: LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: papers,
            collections: collections,
            selectedPaperID: selectedPaperID
        )
    }

    private func persistReportingErrors() {
        guard !persistenceDisabled else { return }
        do {
            try saveNow()
        } catch {
            presentedError = error.localizedDescription
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
