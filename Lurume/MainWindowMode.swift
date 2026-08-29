import Foundation

enum MainWindowMode: String, CaseIterable, Identifiable, Sendable {
    case library
    case reading

    var id: Self { self }

    var title: String {
        switch self {
        case .library: "文献库"
        case .reading: "阅读"
        }
    }
}

enum ReaderInspectorPresentationPolicy {
    /// 文献库模式只会临时隐藏检查器，不应覆盖用户在阅读模式中的可见性选择。
    static func persistedValue(
        _ requestedValue: Bool,
        while mode: MainWindowMode
    ) -> Bool? {
        guard mode == .reading else { return nil }
        return requestedValue
    }
}

enum ReadingSidebarSourcePolicy {
    static func resolvedSource(
        proposed: LibrarySource,
        selectedPaperID: UUID?,
        papers: [PaperRecord],
        collections: [CollectionRecord]
    ) -> LibrarySource {
        let validSource: LibrarySource
        if case let .collection(id) = proposed,
           !collections.contains(where: { $0.id == id }) {
            validSource = .all
        } else {
            validSource = proposed
        }

        guard let selectedPaperID,
              let selectedPaper = papers.first(where: { $0.id == selectedPaperID }),
              validSource.includes(selectedPaper) else {
            return .all
        }
        return validSource
    }

    static func importCollectionID(
        for source: LibrarySource,
        collections: [CollectionRecord]
    ) -> UUID? {
        guard case let .collection(id) = source,
              collections.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }
}

/// 离开阅读模式时的单一保存边界。执行顺序不可交换：先保存状态，再释放 PDF 资源。
@MainActor
struct ReadingSessionBoundary {
    let flushPendingPageSave: () -> Void
    let closeNoteEditor: () -> Void
    let detachReader: () -> Void
    let releaseSecurityScope: () -> Void

    func leaveReadingMode() {
        flushPendingPageSave()
        closeNoteEditor()
        detachReader()
        releaseSecurityScope()
    }
}
