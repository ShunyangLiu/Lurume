import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var papers: [PaperRecord] = []
    @Published var selectedPaperID: UUID?
    @Published private(set) var unavailablePaperIDs: Set<UUID> = []
    @Published var presentedError: String?

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

    func papers(matching rawQuery: String) -> [PaperRecord] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return papers }
        let needle = query.lowercased()
        return papers.filter { paper in
            paper.title.lowercased().contains(needle)
                || (paper.authors?.lowercased().contains(needle) ?? false)
                || paper.originalFileName.lowercased().contains(needle)
        }
    }

    // MARK: - 导入与选择

    @discardableResult
    func importPDF(at url: URL) throws -> UUID {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let identity = try FileIdentity(url: url)
        if let existing = papers.first(where: {
            $0.identity.identifiesSameFile(as: identity)
        }) {
            selectPaper(id: existing.id)
            return existing.id
        }

        let bookmarkData = try SecurityScopedFile.makeBookmark(for: url)
        let record = PaperRecord(
            identity: identity,
            bookmarkData: bookmarkData,
            displayName: url.deletingPathExtension().lastPathComponent,
            lastOpenedAt: Date()
        )
        papers.append(record)
        selectedPaperID = record.id
        try saveNow()
        scheduleMetadataRead(for: record.id, resolvedURL: nil)
        return record.id
    }

    func importPDFs(at urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            do {
                _ = try importPDF(at: url)
            } catch {
                presentedError = "无法导入“\(url.lastPathComponent)”：\(error.localizedDescription)"
            }
        }
    }

    func selectPaper(id: UUID?) {
        guard selectedPaperID != id else { return }
        flushPendingSave()
        selectedPaperID = id
        if let id, let index = papers.firstIndex(where: { $0.id == id }) {
            papers[index].lastOpenedAt = Date()
        }
        persistReportingErrors()
    }

    func removePaper(id: UUID) {
        flushPendingSave()
        papers.removeAll { $0.id == id }
        unavailablePaperIDs.remove(id)
        if selectedPaperID == id {
            selectedPaperID = papers.first?.id
        }
        persistReportingErrors()
    }

    func updatePageIndex(_ pageIndex: Int, for paperID: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let normalizedIndex = max(0, pageIndex)
        guard papers[index].lastPageIndex != normalizedIndex else { return }
        papers[index].lastPageIndex = normalizedIndex
        schedulePageSave()
    }

    // MARK: - 手动编辑

    func setManualTitle(_ value: String, for id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].setManualTitle(value)
        flushPendingSave()
        persistReportingErrors()
    }

    func setManualAuthors(_ value: String?, for id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].setManualAuthors(value)
        flushPendingSave()
        persistReportingErrors()
    }

    func setManualYear(_ value: Int?, for id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].setManualYear(value)
        flushPendingSave()
        persistReportingErrors()
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
                papers[index].volumeUUID = resolvedIdentity.volumeUUID
                papers[index].documentIdentifier = resolvedIdentity.documentIdentifier
                papers[index].fallbackPath = resolvedIdentity.fallbackPath
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
            bookmarkData: bookmarkData
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
            selectedPaperID = loaded.snapshot.selectedPaperID.flatMap { selectedID in
                papers.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
            if loaded.migratedFromLegacy {
                persistReportingErrors()
            }
        } catch {
            persistenceDisabled = true
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
        guard !persistenceDisabled else { return }
        try persistence.save(snapshot)
    }

    private var snapshot: LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: papers,
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
