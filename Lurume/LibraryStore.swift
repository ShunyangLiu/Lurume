import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var papers: [PaperRecord] = []
    @Published var selectedPaperID: UUID?
    @Published private(set) var unavailablePaperIDs: Set<UUID> = []
    @Published var presentedError: String?

    private let persistence: LibraryPersistence
    private var pageSaveTask: Task<Void, Never>?

    init(persistence: LibraryPersistence) {
        self.persistence = persistence
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
                papers[index].displayName = resolved.url
                    .deletingPathExtension()
                    .lastPathComponent
                didUpdateReference = true
            }
            if resolved.refreshedBookmarkData != nil || didUpdateReference {
                persistReportingErrors()
            }
            setUnavailable(false, for: paperID)
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
            bookmarkData: bookmarkData,
            displayName: url.deletingPathExtension().lastPathComponent
        )
        setUnavailable(false, for: id)
        try saveNow()
    }

    func flushPendingSave() {
        pageSaveTask?.cancel()
        pageSaveTask = nil
        persistReportingErrors()
    }

    private func load() {
        do {
            let snapshot = try persistence.load()
            papers = snapshot.papers
            selectedPaperID = snapshot.selectedPaperID.flatMap { selectedID in
                papers.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
        } catch {
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
        try persistence.save(snapshot)
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

    private var snapshot: LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: papers,
            selectedPaperID: selectedPaperID
        )
    }

    private func persistReportingErrors() {
        do {
            try saveNow()
        } catch {
            presentedError = error.localizedDescription
        }
    }
}
