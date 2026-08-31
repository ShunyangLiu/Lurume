import Foundation

@MainActor
final class FolderImportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case preview
        case executing
        case completed
        case failed
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scanProgress = FolderScanProgress(
        discoveredPDFCount: 0,
        processedPDFCount: 0,
        validPDFCount: 0
    )
    @Published private(set) var executionCompletedCount = 0
    @Published private(set) var executionTotalCount = 0
    @Published private(set) var preview: FolderImportPreview?
    @Published private(set) var report: FolderImportReport?
    @Published private(set) var failureMessage: String?

    private let scanner: any FolderImportScanning
    private var scanResult: FolderScanResult?
    private var selectedRootURL: URL?
    private var options = FolderImportPreviewOptions(targetParentID: nil)
    private var basePapers: [PaperRecord] = []
    private var baseCollections: [CollectionRecord] = []
    private var rootAccess: SecurityScopedAccess?
    private var workTask: Task<Void, Never>?
    private var requestID = UUID()

    init(scanner: any FolderImportScanning = FolderImportScanner()) {
        self.scanner = scanner
    }

    var isPresented: Bool { phase != .idle }
    var isBusy: Bool { phase == .scanning || phase == .executing }

    func begin(
        rootURL: URL,
        targetParentID: UUID?,
        store: LibraryStore
    ) {
        invalidateCurrentWork()
        let currentRequestID = UUID()
        requestID = currentRequestID
        rootAccess = SecurityScopedAccess(url: rootURL)
        selectedRootURL = rootURL
        options = FolderImportPreviewOptions(targetParentID: targetParentID)
        basePapers = []
        baseCollections = []
        scanResult = nil
        preview = nil
        report = nil
        failureMessage = nil
        scanProgress = FolderScanProgress(
            discoveredPDFCount: 0,
            processedPDFCount: 0,
            validPDFCount: 0
        )
        phase = .scanning
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan(rootURL: rootURL) { progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.requestID == currentRequestID,
                              self.phase == .scanning else { return }
                        self.scanProgress = progress
                    }
                }
                try Task.checkCancellation()
                guard requestID == currentRequestID else { return }
                guard !result.files.isEmpty else {
                    throw FolderImportError.noImportablePDFs
                }
                basePapers = store.papers
                baseCollections = store.collections
                scanResult = result
                let initialPlan = FolderImportPlanner.plan(
                    root: result.root,
                    existingPapers: basePapers
                )
                for collection in initialPlan.collections
                    where options.createdCollectionIDs[collection.source] == nil {
                    options.createdCollectionIDs[collection.source] = UUID()
                }
                rebuildPreview()
                phase = .preview
            } catch is CancellationError {
                guard requestID == currentRequestID else { return }
                phase = .cancelled
            } catch {
                guard requestID == currentRequestID else { return }
                failureMessage = error.localizedDescription
                phase = .failed
            }
            if requestID == currentRequestID { workTask = nil }
            releaseAccessIfFinished()
        }
    }

    func rescan(store: LibraryStore) {
        guard let rootURL = selectedRootURL else { return }
        begin(rootURL: rootURL, targetParentID: options.targetParentID, store: store)
    }

    func setTargetParentID(_ id: UUID?) {
        guard phase == .preview else { return }
        options.targetParentID = id
        options.mergedCollectionTargets = [:]
        rebuildPreview()
    }

    func setPaperIncluded(_ included: Bool, source: ImportSourceIdentity) {
        guard phase == .preview else { return }
        if included {
            options.excludedPaperSources.remove(source)
        } else {
            options.excludedPaperSources.insert(source)
        }
        rebuildPreview()
    }

    func setDirectoryIncluded(_ included: Bool, source: ImportSourceIdentity) {
        guard phase == .preview else { return }
        if included {
            options.excludedDirectorySources.remove(source)
        } else {
            options.excludedDirectorySources.insert(source)
        }
        rebuildPreview()
    }

    func directoryIsIncluded(_ source: ImportSourceIdentity) -> Bool {
        preview?.collections.first(where: { $0.source == source })?.isIncluded == true
    }

    func setChangedSourceImportedAsNew(_ importedAsNew: Bool, source: ImportSourceIdentity) {
        guard phase == .preview else { return }
        if importedAsNew {
            options.importChangedSourcesAsNew.insert(source)
        } else {
            options.importChangedSourcesAsNew.remove(source)
        }
        rebuildPreview()
    }

    func setAllChangedSourcesImportedAsNew(_ importedAsNew: Bool) {
        guard phase == .preview, let preview else { return }
        let sources = Set(preview.papers.compactMap { row -> ImportSourceIdentity? in
            switch row.action {
            case .keepExistingVersion, .createNewVersion: row.source
            default: nil
            }
        })
        if importedAsNew {
            options.importChangedSourcesAsNew.formUnion(sources)
        } else {
            options.importChangedSourcesAsNew.subtract(sources)
        }
        rebuildPreview()
    }

    func setCollectionMergeTarget(_ targetID: UUID?, source: ImportSourceIdentity) {
        guard phase == .preview else { return }
        if let targetID {
            options.mergedCollectionTargets[source] = targetID
        } else {
            options.mergedCollectionTargets.removeValue(forKey: source)
        }
        rebuildPreview()
    }

    func confirm(store: LibraryStore, undoManager: UndoManager?) {
        guard phase == .preview,
              let scanResult,
              let preview else { return }
        guard store.papers == basePapers, store.collections == baseCollections else {
            failureMessage = FolderImportError.libraryChanged.localizedDescription
            phase = .failed
            return
        }
        let currentRequestID = requestID
        executionCompletedCount = 0
        executionTotalCount = preview.includedPaperCount
        phase = .executing
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let preparation = try await FolderImportExecutor.prepare(
                    scan: scanResult,
                    preview: preview
                ) { completed, total in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.requestID == currentRequestID,
                              self.phase == .executing else { return }
                        self.executionCompletedCount = completed
                        self.executionTotalCount = total
                    }
                }
                try Task.checkCancellation()
                guard requestID == currentRequestID else { return }
                guard store.papers == basePapers, store.collections == baseCollections else {
                    throw FolderImportError.libraryChanged
                }
                let candidate = FolderImportCandidateBuilder.build(
                    preview: preview,
                    preparation: preparation,
                    existingPapers: basePapers,
                    existingCollections: baseCollections
                )
                if candidate.papers != basePapers || candidate.collections != baseCollections {
                    try store.applyFolderImport(
                        papers: candidate.papers,
                        collections: candidate.collections,
                        undoManager: undoManager
                    )
                }
                report = candidate.report
                phase = .completed
            } catch is CancellationError {
                guard requestID == currentRequestID else { return }
                phase = .cancelled
            } catch {
                guard requestID == currentRequestID else { return }
                failureMessage = error.localizedDescription
                phase = .failed
            }
            if requestID == currentRequestID { workTask = nil }
            releaseAccessIfFinished()
        }
    }

    func cancel() {
        guard phase == .scanning || phase == .executing else { return }
        workTask?.cancel()
        phase = .cancelled
    }

    func dismiss() {
        retireCurrentWork()
        requestID = UUID()
        phase = .idle
        preview = nil
        report = nil
        failureMessage = nil
        scanResult = nil
        selectedRootURL = nil
    }

    private func rebuildPreview() {
        guard let scanResult else { return }
        preview = FolderImportPreviewBuilder.build(
            scan: scanResult,
            existingPapers: basePapers,
            existingCollections: baseCollections,
            options: options
        )
    }

    private func invalidateCurrentWork() {
        retireCurrentWork()
        requestID = UUID()
    }

    private func retireCurrentWork() {
        let previousTask = workTask
        let previousAccess = rootAccess
        previousTask?.cancel()
        workTask = nil
        rootAccess = nil
        if previousTask != nil || previousAccess != nil {
            Task { @MainActor in
                _ = await previousTask?.result
                withExtendedLifetime(previousAccess) {}
            }
        }
    }

    private func releaseAccessIfFinished() {
        if phase == .completed || phase == .failed || phase == .cancelled || phase == .idle {
            rootAccess = nil
        }
    }
}
