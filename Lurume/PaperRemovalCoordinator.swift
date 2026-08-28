import Foundation

@MainActor
final class PaperRemovalCoordinator {
    private unowned let libraryStore: LibraryStore
    private unowned let highlightStore: HighlightStore

    init(libraryStore: LibraryStore, highlightStore: HighlightStore) {
        self.libraryStore = libraryStore
        self.highlightStore = highlightStore
    }

    func remove(paperIDs: Set<UUID>, undoManager: UndoManager?) throws {
        guard !paperIDs.isEmpty else { return }
        let removedHighlights = try highlightStore.removeAll(for: paperIDs)
        let removedPapers: RemovedLibraryPapers
        do {
            removedPapers = try libraryStore.removePapers(ids: paperIDs)
        } catch {
            try? highlightStore.restore(removedHighlights)
            throw error
        }
        registerRestore(
            removedPapers: removedPapers,
            removedHighlights: removedHighlights,
            undoManager: undoManager
        )
    }

    private func restore(
        removedPapers: RemovedLibraryPapers,
        removedHighlights: [HighlightRecord],
        undoManager: UndoManager?
    ) throws {
        try libraryStore.restorePapers(removedPapers)
        do {
            try highlightStore.restore(removedHighlights)
        } catch {
            _ = try? libraryStore.removePapers(ids: Set(removedPapers.papers.map(\.id)))
            throw error
        }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] coordinator in
            do {
                try coordinator.remove(
                    paperIDs: Set(removedPapers.papers.map(\.id)),
                    undoManager: undoManager
                )
            } catch {
                coordinator.present(error, prefix: "无法重做文献库移除")
            }
        }
        undoManager?.setActionName("文献库：移除 \(removedPapers.papers.count) 篇")
    }

    private func registerRestore(
        removedPapers: RemovedLibraryPapers,
        removedHighlights: [HighlightRecord],
        undoManager: UndoManager?
    ) {
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] coordinator in
            do {
                try coordinator.restore(
                    removedPapers: removedPapers,
                    removedHighlights: removedHighlights,
                    undoManager: undoManager
                )
            } catch {
                coordinator.present(error, prefix: "无法撤销文献库移除")
            }
        }
        undoManager?.setActionName("文献库：移除 \(removedPapers.papers.count) 篇")
    }

    private func present(_ error: Error, prefix: String) {
        libraryStore.presentedError = "\(prefix)：\(error.localizedDescription)"
    }
}
