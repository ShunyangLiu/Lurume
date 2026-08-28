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
