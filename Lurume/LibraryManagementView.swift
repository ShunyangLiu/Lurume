import AppKit
import SwiftUI

struct LibrarySourceSidebar: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var libraryStore: LibraryStore
    @Binding var source: LibrarySource
    @State private var isCreating = false
    @State private var editingCollectionID: UUID?
    @State private var nameDraft = ""
    @State private var nameError: String?
    @State private var pendingDeletion: CollectionRecord?
    @State private var activeDropSource: LibrarySource?
    @FocusState private var nameFieldFocused: Bool

    private var optionalSelection: Binding<LibrarySource?> {
        Binding(
            get: { source },
            set: { if let newValue = $0 { source = newValue } }
        )
    }

    var body: some View {
        List(selection: optionalSelection) {
            Section("资料库") {
                sourceRow(
                    title: "全部文献",
                    systemImage: "books.vertical",
                    count: libraryStore.count(in: .all),
                    dropSource: .all
                )
                .tag(LibrarySource.all)

                sourceRow(
                    title: "未分类",
                    systemImage: "tray",
                    count: libraryStore.count(in: .unfiled),
                    dropSource: .unfiled
                )
                .tag(LibrarySource.unfiled)
            }

            Section {
                ForEach(libraryStore.sortedCollections) { collection in
                    collectionRow(collection)
                        .tag(LibrarySource.collection(collection.id))
                        .contextMenu {
                            Button("重命名") { beginRename(collection) }
                            Button("删除文献集…", role: .destructive) {
                                pendingDeletion = collection
                            }
                            .disabled(libraryStore.persistenceDisabled)
                        }
                }

                if isCreating {
                    editableNameRow(systemImage: "folder", submit: createCollection)
                }
            } header: {
                HStack {
                    Text("文献集")
                    Spacer()
                    Button(action: beginCreate) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("新建文献集")
                    .accessibilityLabel("新建文献集")
                    .disabled(libraryStore.persistenceDisabled || isCreating)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("文献库")
        .contextMenu {
            Button("新建文献集", action: beginCreate)
                .disabled(libraryStore.persistenceDisabled || isCreating)
        }
        .onKeyPress(.return) {
            guard case let .collection(id) = source,
                  editingCollectionID == nil,
                  !isCreating,
                  let collection = libraryStore.collections.first(where: { $0.id == id }) else {
                return .ignored
            }
            beginRename(collection)
            return .handled
        }
        .confirmationDialog(
            "删除文献集？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除文献集", role: .destructive) { confirmDeletion() }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("只会删除“\(pendingDeletion?.name ?? "")”及其归属关系。论文、高亮、笔记和原始 PDF 都会保留。")
        }
    }

    private func sourceRow(
        title: String,
        systemImage: String,
        count: Int,
        dropSource: LibrarySource
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(count) 篇文献")
        .padding(.vertical, 2)
        .background {
            if activeDropSource == dropSource {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .overlay {
            LibraryDropTargetView(
                accepts: { payload in accepts(payload, at: dropSource) },
                activeChanged: { active in
                    activeDropSource = active ? dropSource : nil
                },
                perform: { payload in perform(payload, at: dropSource) }
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: CollectionRecord) -> some View {
        if editingCollectionID == collection.id {
            editableNameRow(systemImage: "folder", submit: {
                renameCollection(collection)
            })
        } else {
            sourceRow(
                title: collection.name,
                systemImage: "folder",
                count: libraryStore.count(in: .collection(collection.id)),
                dropSource: .collection(collection.id)
            )
        }
    }

    private func editableNameRow(
        systemImage: String,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                TextField("文献集名称", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancelEditing)
            }
            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func beginCreate() {
        editingCollectionID = nil
        isCreating = true
        nameDraft = ""
        nameError = nil
        focusNameField()
    }

    private func beginRename(_ collection: CollectionRecord) {
        isCreating = false
        editingCollectionID = collection.id
        nameDraft = collection.name
        nameError = nil
        focusNameField()
    }

    private func focusNameField() {
        Task { @MainActor in
            await Task.yield()
            nameFieldFocused = true
        }
    }

    private func createCollection() {
        do {
            let id = try libraryStore.createCollection(
                named: nameDraft,
                undoManager: undoManager
            )
            isCreating = false
            nameFieldFocused = false
            nameError = nil
            source = .collection(id)
        } catch {
            nameError = error.localizedDescription
            focusNameField()
        }
    }

    private func renameCollection(_ collection: CollectionRecord) {
        do {
            try libraryStore.renameCollection(
                id: collection.id,
                to: nameDraft,
                undoManager: undoManager
            )
            editingCollectionID = nil
            nameFieldFocused = false
            nameError = nil
        } catch {
            nameError = error.localizedDescription
            focusNameField()
        }
    }

    private func cancelEditing() {
        isCreating = false
        editingCollectionID = nil
        nameFieldFocused = false
        nameDraft = ""
        nameError = nil
    }

    private func confirmDeletion() {
        guard let collection = pendingDeletion else { return }
        pendingDeletion = nil
        do {
            try libraryStore.deleteCollection(
                id: collection.id,
                undoManager: undoManager
            )
            if source == .collection(collection.id) { source = .all }
        } catch {
            libraryStore.presentedError = "无法删除文献集：\(error.localizedDescription)"
        }
    }

    private func accepts(_ payload: LibraryDropPayload, at source: LibrarySource) -> Bool {
        switch (payload, source) {
        case (.finderPDFs, _):
            true
        case (.internalPapers, .collection):
            true
        default:
            false
        }
    }

    private func perform(_ payload: LibraryDropPayload, at source: LibrarySource) {
        switch payload {
        case let .internalPapers(ids):
            guard case let .collection(collectionID) = source else { return }
            do {
                try libraryStore.setMembership(
                    of: Set(ids),
                    in: collectionID,
                    isMember: true,
                    undoManager: undoManager
                )
            } catch {
                libraryStore.presentedError = "无法加入文献集：\(error.localizedDescription)"
            }
        case let .finderPDFs(urls):
            let collectionID: UUID?
            if case let .collection(id) = source {
                collectionID = id
            } else {
                collectionID = nil
            }
            libraryStore.importPDFs(
                at: urls,
                collectionID: collectionID,
                selectAfterImport: false
            )
        case .unsupported:
            break
        }
    }
}

struct LibraryTablePane: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var appSettings: AppSettings
    let source: LibrarySource
    @Binding var selection: Set<UUID>
    @Binding var searchText: String
    @Binding var statusFilter: ReadingStatusFilter
    let importPDFs: () -> Void
    let editMetadata: (UUID) -> Void
    let openPaper: (UUID) -> Void
    let removeFromLibrary: (Set<UUID>) -> Void

    private var papers: [PaperRecord] {
        libraryStore.papers(
            in: source,
            matching: searchText,
            status: statusFilter,
            sortedBy: appSettings.librarySortOption
        )
    }

    private var sourceTitle: String {
        switch source {
        case .all: "全部文献"
        case .unfiled: "未分类"
        case let .collection(id):
            libraryStore.collections.first(where: { $0.id == id })?.name ?? "全部文献"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                searchField
                    .frame(maxWidth: 380)
                organizationMenu
                Button(action: importPDFs) {
                    Image(systemName: "plus")
                }
                .help("导入 PDF")
                .accessibilityLabel("导入 PDF")
                .disabled(libraryStore.persistenceDisabled)
                Spacer()
            }
            .padding(12)

            Divider()

            if papers.isEmpty {
                emptyState
            } else {
                LibraryTableView(
                    papers: papers,
                    selection: $selection,
                    unavailablePaperIDs: libraryStore.unavailablePaperIDs,
                    collections: libraryStore.collections,
                    currentSource: source,
                    isReadOnly: libraryStore.persistenceDisabled,
                    cycleReadingStatus: libraryStore.cycleReadingStatus,
                    editMetadata: editMetadata,
                    openPaper: openPaper,
                    setMembership: setMembership,
                    removeFromCurrentCollection: removeFromCollection,
                    removeFromLibrary: removeFromLibrary
                )
            }
        }
        .navigationTitle(sourceTitle)
        .overlay {
            LibraryDropTargetView(
                accepts: { payload in
                    if case .finderPDFs = payload { return true }
                    return false
                },
                activeChanged: { _ in },
                perform: importDroppedPDFs
            )
            .allowsHitTesting(false)
        }
    }

    private func setMembership(
        _ paperIDs: Set<UUID>,
        _ collectionID: UUID,
        _ isMember: Bool
    ) {
        do {
            try libraryStore.setMembership(
                of: paperIDs,
                in: collectionID,
                isMember: isMember,
                undoManager: undoManager
            )
        } catch {
            libraryStore.presentedError = "无法修改文献集归属：\(error.localizedDescription)"
        }
    }

    private func removeFromCollection(_ paperIDs: Set<UUID>, _ collectionID: UUID) {
        setMembership(paperIDs, collectionID, false)
    }

    private func importDroppedPDFs(_ payload: LibraryDropPayload) {
        guard case let .finderPDFs(urls) = payload else { return }
        let collectionID: UUID?
        if case let .collection(id) = source {
            collectionID = id
        } else {
            collectionID = nil
        }
        libraryStore.importPDFs(
            at: urls,
            collectionID: collectionID,
            selectAfterImport: false
        )
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索标题、作者或文件名", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private var organizationMenu: some View {
        Menu {
            Section("阅读状态") {
                ForEach(ReadingStatusFilter.allCases) { filter in
                    Toggle(filter.title, isOn: Binding(
                        get: { statusFilter == filter },
                        set: { if $0 { statusFilter = filter } }
                    ))
                }
            }
            Section("排序方式") {
                ForEach(LibrarySortOption.allCases) { option in
                    Toggle(option.title, isOn: Binding(
                        get: { appSettings.librarySortOption == option },
                        set: { if $0 { appSettings.librarySortOption = option } }
                    ))
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(statusFilter == .all ? Color.primary : Color.accentColor)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("阅读状态：\(statusFilter.title)；排序方式：\(appSettings.librarySortOption.title)")
        .accessibilityLabel("文献筛选与排序")
        .accessibilityValue("\(statusFilter.title)，\(appSettings.librarySortOption.title)")
    }

    @ViewBuilder
    private var emptyState: some View {
        if libraryStore.persistenceDisabled {
            ContentUnavailableView(
                "文献库处于只读状态",
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text("可以继续浏览和打开论文，但暂时无法修改文献集。")
            )
        } else if libraryStore.count(in: source) == 0 {
            ContentUnavailableView(
                source == .unfiled ? "没有未分类文献" : "这个来源中没有文献",
                systemImage: "books.vertical",
                description: Text("导入 PDF，或把已有论文加入文献集。")
            )
        } else {
            ContentUnavailableView(
                searchText.isEmpty ? "此状态下没有文献" : "无匹配文献",
                systemImage: "magnifyingglass",
                description: Text("调整搜索词或阅读状态筛选。")
            )
        }
    }
}

private struct LibraryDropTargetView: NSViewRepresentable {
    let accepts: (LibraryDropPayload) -> Bool
    let activeChanged: (Bool) -> Void
    let perform: (LibraryDropPayload) -> Void

    func makeNSView(context: Context) -> LibraryDropReceivingView {
        LibraryDropReceivingView(
            accepts: accepts,
            activeChanged: activeChanged,
            perform: perform
        )
    }

    func updateNSView(_ nsView: LibraryDropReceivingView, context: Context) {
        nsView.accepts = accepts
        nsView.activeChanged = activeChanged
        nsView.perform = perform
    }
}

private final class LibraryDropReceivingView: NSView {
    var accepts: (LibraryDropPayload) -> Bool
    var activeChanged: (Bool) -> Void
    var perform: (LibraryDropPayload) -> Void

    init(
        accepts: @escaping (LibraryDropPayload) -> Bool,
        activeChanged: @escaping (Bool) -> Void,
        perform: @escaping (LibraryDropPayload) -> Void
    ) {
        self.accepts = accepts
        self.activeChanged = activeChanged
        self.perform = perform
        super.init(frame: .zero)
        registerForDraggedTypes([LibraryDragDropCodec.internalPaperType, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let payload = LibraryDragDropCodec.resolve(sender.draggingPasteboard)
        guard accepts(payload) else { return [] }
        activeChanged(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        activeChanged(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { activeChanged(false) }
        let payload = LibraryDragDropCodec.resolve(sender.draggingPasteboard)
        guard accepts(payload) else { return false }
        perform(payload)
        return true
    }
}
