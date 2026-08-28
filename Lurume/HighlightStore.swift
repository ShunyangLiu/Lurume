import Foundation

enum HighlightStoreError: LocalizedError, Equatable {
    case persistenceUnavailable

    var errorDescription: String? {
        "高亮当前为只读状态。为保护原有数据，无法保存这项操作。"
    }
}

enum HighlightToggleResult: Equatable {
    case added(HighlightRecord)
    case removed(HighlightRecord)
}

@MainActor
final class HighlightStore: ObservableObject {
    @Published private(set) var highlights: [HighlightRecord] = []
    @Published private(set) var persistenceDisabled = false
    @Published private(set) var persistenceFailure: String?
    @Published var presentedError: String?

    private let persistence: HighlightPersistence

    init(persistence: HighlightPersistence) {
        self.persistence = persistence
        load()
    }

    convenience init() {
        do {
            try self.init(persistence: .applicationDefault())
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Lurume-highlights.json")
            self.init(persistence: HighlightPersistence(fileURL: fallback))
            disablePersistence(because: error)
        }
    }

    func highlights(for paperID: UUID) -> [HighlightRecord] {
        highlights
            .filter { $0.paperID == paperID }
            .sorted(by: HighlightRecord.documentOrdered)
    }

    func highlight(id: UUID) -> HighlightRecord? {
        highlights.first { $0.id == id }
    }

    func count(for paperID: UUID) -> Int {
        highlights.lazy.filter { $0.paperID == paperID }.count
    }

    @discardableResult
    func updateNote(id: UUID, text: String?, modifiedAt: Date = Date()) -> Bool {
        guard !persistenceDisabled,
              let index = highlights.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let current = highlights[index]
        let updatedRecord = current.updatingNote(text, modifiedAt: modifiedAt)
        guard updatedRecord.noteText != current.noteText else { return true }
        var updated = highlights
        updated[index] = updatedRecord
        return saveAndPublish(updated, presentError: false)
    }

    @discardableResult
    func toggle(_ candidate: HighlightRecord, undoManager: UndoManager?) -> HighlightToggleResult? {
        guard requireWritable() else { return nil }
        if let existing = highlights.first(where: { $0.approximatelyMatches(candidate) }) {
            guard remove(
                existing,
                undoManager: undoManager,
                actionName: "删除高亮"
            ) else { return nil }
            return .removed(existing)
        }
        guard add(
            candidate,
            undoManager: undoManager,
            actionName: "添加高亮"
        ) else { return nil }
        return .added(candidate)
    }

    @discardableResult
    func remove(id: UUID, undoManager: UndoManager?) -> Bool {
        guard let record = highlight(id: id) else { return false }
        return remove(record, undoManager: undoManager, actionName: "删除高亮")
    }

    func removeAll(for paperID: UUID) throws -> [HighlightRecord] {
        try requireWritableOrThrow()
        let removed = highlights.filter { $0.paperID == paperID }
        guard !removed.isEmpty else { return [] }
        var updated = highlights
        updated.removeAll { $0.paperID == paperID }
        try persist(updated)
        highlights = updated
        return removed
    }

    func restore(_ records: [HighlightRecord]) throws {
        guard !records.isEmpty else { return }
        try requireWritableOrThrow()
        let knownIDs = Set(highlights.map(\.id))
        let restored = records.filter { !knownIDs.contains($0.id) }
        guard !restored.isEmpty else { return }
        let updated = highlights + restored
        try persist(updated)
        highlights = updated
    }

    private func add(
        _ record: HighlightRecord,
        undoManager: UndoManager?,
        actionName: String
    ) -> Bool {
        var updated = highlights
        updated.append(record)
        guard saveAndPublish(updated) else { return false }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            _ = store.remove(
                record,
                undoManager: undoManager,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
        return true
    }

    private func remove(
        _ record: HighlightRecord,
        undoManager: UndoManager?,
        actionName: String
    ) -> Bool {
        var updated = highlights
        updated.removeAll { $0.id == record.id }
        guard saveAndPublish(updated) else { return false }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            _ = store.add(
                record,
                undoManager: undoManager,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
        return true
    }

    private func load() {
        do {
            let loaded = try persistence.load()
            highlights = loaded.snapshot.highlights
            if loaded.invalidRecordCount > 0 {
                disablePersistence(
                    because: CocoaError(
                        .coderReadCorrupt,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "高亮数据中有 \(loaded.invalidRecordCount) 条记录损坏。其余记录可以查看，但为保护原文件，高亮功能已进入只读状态。",
                        ]
                    )
                )
            }
        } catch {
            disablePersistence(because: error)
        }
    }

    private func saveAndPublish(
        _ updated: [HighlightRecord],
        presentError: Bool = true
    ) -> Bool {
        do {
            try persist(updated)
            highlights = updated
            return true
        } catch {
            if presentError {
                presentedError = "无法保存高亮：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func persist(_ updated: [HighlightRecord]) throws {
        try requireWritableOrThrow()
        try persistence.save(
            HighlightSnapshot(
                schemaVersion: HighlightSchema.currentVersion,
                highlights: updated
            )
        )
    }

    private func requireWritable() -> Bool {
        guard !persistenceDisabled else {
            presentedError = HighlightStoreError.persistenceUnavailable.localizedDescription
            return false
        }
        return true
    }

    private func requireWritableOrThrow() throws {
        guard !persistenceDisabled else {
            throw HighlightStoreError.persistenceUnavailable
        }
    }

    private func disablePersistence(because error: Error) {
        persistenceDisabled = true
        persistenceFailure = error.localizedDescription
        presentedError = error.localizedDescription
    }
}
