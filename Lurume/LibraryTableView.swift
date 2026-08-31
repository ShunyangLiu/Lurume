import AppKit
import SwiftUI

enum LibraryTableCommand: Equatable {
    case editMetadata(UUID)
    case open(UUID)
}

enum LibraryTableCommandResolver {
    static func returnCommand(
        selection: Set<UUID>,
        isTextEditing: Bool = false
    ) -> LibraryTableCommand? {
        guard !isTextEditing, let paperID = onlyID(in: selection) else { return nil }
        return .editMetadata(paperID)
    }

    static func openCommand(selection: Set<UUID>) -> LibraryTableCommand? {
        guard let paperID = onlyID(in: selection) else { return nil }
        return .open(paperID)
    }

    static func doubleClickCommand(paperID: UUID) -> LibraryTableCommand {
        .open(paperID)
    }

    static func retainedSelection(
        _ selection: Set<UUID>,
        availablePaperIDs: Set<UUID>
    ) -> Set<UUID> {
        selection.intersection(availablePaperIDs)
    }

    private static func onlyID(in selection: Set<UUID>) -> UUID? {
        guard selection.count == 1 else { return nil }
        return selection.first
    }
}

/// P5 文献库模式专用的原生多选表格。现有阅读侧栏继续使用原来的 SwiftUI List。
struct LibraryTableView: NSViewRepresentable {
    let papers: [PaperRecord]
    @Binding var selection: Set<UUID>
    let unavailablePaperIDs: Set<UUID>
    let collections: [CollectionRecord]
    let currentSource: LibrarySource
    let isReadOnly: Bool
    let cycleReadingStatus: (UUID) -> Void
    let editMetadata: (UUID) -> Void
    let openPaper: (UUID) -> Void
    let setMembership: (Set<UUID>, UUID, Bool) -> Void
    let removeFromCurrentCollection: (Set<UUID>, UUID) -> Void
    let removeFromLibrary: (Set<UUID>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = LibraryNSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 8, height: 1)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        tableView.commandHandler = context.coordinator.handleKeyEvent
        tableView.menuProvider = context.coordinator.makeContextMenu
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)

        for configuration in ColumnConfiguration.allCases {
            let column = NSTableColumn(identifier: configuration.identifier)
            column.title = configuration.title
            column.width = configuration.width
            column.minWidth = configuration.minimumWidth
            column.maxWidth = configuration.maximumWidth
            column.resizingMask = configuration.resizingMask
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? LibraryNSTableView else { return }
        context.coordinator.parent = self
        context.coordinator.reload(tableView)
    }

    fileprivate enum ColumnConfiguration: CaseIterable {
        case status
        case title
        case authors
        case year

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .status: .init("readingStatus")
            case .title: .init("title")
            case .authors: .init("authors")
            case .year: .init("year")
            }
        }

        var title: String {
            switch self {
            case .status: "状态"
            case .title: "标题"
            case .authors: "作者"
            case .year: "年份"
            }
        }

        var width: CGFloat {
            switch self {
            case .status: 34
            case .title: 430
            case .authors: 210
            case .year: 70
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .status: 34
            case .title: 220
            case .authors: 120
            case .year: 58
            }
        }

        var maximumWidth: CGFloat {
            switch self {
            case .status: 34
            case .title: .greatestFiniteMagnitude
            case .authors: 420
            case .year: 90
            }
        }

        var resizingMask: NSTableColumn.ResizingOptions {
            switch self {
            case .status: []
            case .title: [.autoresizingMask, .userResizingMask]
            case .authors, .year: [.userResizingMask]
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: LibraryTableView
        weak var tableView: LibraryNSTableView?
        private var isApplyingSelection = false

        init(parent: LibraryTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.papers.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard parent.papers.indices.contains(row),
                  let tableColumn,
                  let configuration = ColumnConfiguration.allCases.first(where: {
                      $0.identifier == tableColumn.identifier
                  }) else {
                return nil
            }
            let paper = parent.papers[row]
            switch configuration {
            case .status:
                return statusButton(for: paper, tableView: tableView)
            case .title:
                return textCell(
                    paper.displayTitle,
                    identifier: configuration.identifier,
                    tooltip: paper.originalFileName,
                    isUnavailable: parent.unavailablePaperIDs.contains(paper.id)
                )
            case .authors:
                return textCell(
                    paper.authors ?? "",
                    identifier: configuration.identifier
                )
            case .year:
                let cell = textCell(
                    paper.year.map(String.init) ?? "",
                    identifier: configuration.identifier
                )
                cell.textField?.alignment = .right
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { index in
                parent.papers.indices.contains(index) ? parent.papers[index].id : nil
            })
            guard selectedIDs != parent.selection else { return }
            parent.selection = selectedIDs
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? {
            guard parent.papers.indices.contains(row) else { return nil }
            let draggedIndexes: IndexSet
            if tableView.selectedRowIndexes.contains(row) {
                draggedIndexes = tableView.selectedRowIndexes
            } else {
                draggedIndexes = IndexSet(integer: row)
            }
            let paperIDs = draggedIndexes.compactMap { index in
                parent.papers.indices.contains(index) ? parent.papers[index].id : nil
            }
            return LibraryDragDropCodec.pasteboardItem(paperIDs: paperIDs)
        }

        func reload(_ tableView: NSTableView) {
            tableView.reloadData()
            let availableIDs = Set(parent.papers.map(\.id))
            let retained = LibraryTableCommandResolver.retainedSelection(
                parent.selection,
                availablePaperIDs: availableIDs
            )
            let indexes = IndexSet(parent.papers.indices.filter {
                retained.contains(parent.papers[$0].id)
            })
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
            if retained != parent.selection {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parent.selection != retained else { return }
                    self.parent.selection = retained
                }
            }
        }

        @objc func didDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard parent.papers.indices.contains(row) else { return }
            let paperID = parent.papers[row].id
            parent.selection = [paperID]
            perform(LibraryTableCommandResolver.doubleClickCommand(paperID: paperID))
        }

        func handleKeyEvent(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "o" {
                guard let command = LibraryTableCommandResolver.openCommand(
                    selection: parent.selection
                ) else { return true }
                perform(command)
                return true
            }
            if modifiers.isEmpty, (event.keyCode == 36 || event.keyCode == 76) {
                guard let command = LibraryTableCommandResolver.returnCommand(
                    selection: parent.selection
                ) else { return true }
                perform(command)
                return true
            }
            if modifiers == .command, (event.keyCode == 51 || event.keyCode == 117) {
                removeSelectionFromCurrentSource()
                return true
            }
            return false
        }

        func makeContextMenu(_ event: NSEvent) -> NSMenu? {
            guard let tableView else { return nil }
            let location = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: location)
            guard parent.papers.indices.contains(row) else { return nil }
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                parent.selection = [parent.papers[row].id]
            }
            let paperIDs = selectedPaperIDs(in: tableView)
            guard !paperIDs.isEmpty else { return nil }

            let menu = NSMenu()
            let membershipItem = NSMenuItem(title: "加入文献集", action: nil, keyEquivalent: "")
            let membershipMenu = NSMenu(title: "加入文献集")
            for collection in parent.collections.sorted(by: collectionOrderedBefore) {
                let state = membershipState(
                    paperIDs: paperIDs,
                    collectionID: collection.id
                )
                let item = NSMenuItem(
                    title: collectionPathLabel(for: collection),
                    action: #selector(toggleMembership(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = switch state {
                case .off: .off
                case .mixed: .mixed
                case .on: .on
                }
                item.representedObject = MembershipMenuPayload(
                    paperIDs: paperIDs,
                    collectionID: collection.id,
                    shouldAdd: state != .on
                )
                item.isEnabled = !parent.isReadOnly
                membershipMenu.addItem(item)
            }
            if parent.collections.isEmpty {
                let empty = NSMenuItem(title: "尚无文献集", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                membershipMenu.addItem(empty)
            }
            membershipItem.submenu = membershipMenu
            menu.addItem(membershipItem)

            if case let .collection(collectionID) = parent.currentSource,
               let collection = parent.collections.first(where: { $0.id == collectionID }) {
                let remove = NSMenuItem(
                    title: "从“\(collection.name)”移除",
                    action: #selector(removeFromCollection(_:)),
                    keyEquivalent: ""
                )
                remove.target = self
                remove.representedObject = MembershipMenuPayload(
                    paperIDs: paperIDs,
                    collectionID: collectionID,
                    shouldAdd: false
                )
                remove.isEnabled = !parent.isReadOnly
                menu.addItem(remove)
            }

            menu.addItem(.separator())
            let removeLibrary = NSMenuItem(
                title: "从文献库移除…",
                action: #selector(removeFromLibrary(_:)),
                keyEquivalent: ""
            )
            removeLibrary.target = self
            removeLibrary.representedObject = PaperSelectionMenuPayload(paperIDs: paperIDs)
            removeLibrary.isEnabled = !parent.isReadOnly
            menu.addItem(removeLibrary)
            return menu
        }

        @objc private func cycleStatus(_ sender: NSButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            guard parent.papers.indices.contains(row), !parent.isReadOnly else { return }
            parent.cycleReadingStatus(parent.papers[row].id)
        }

        @objc private func toggleMembership(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? MembershipMenuPayload else { return }
            parent.setMembership(
                payload.paperIDs,
                payload.collectionID,
                payload.shouldAdd
            )
        }

        @objc private func removeFromCollection(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? MembershipMenuPayload else { return }
            parent.removeFromCurrentCollection(payload.paperIDs, payload.collectionID)
        }

        @objc private func removeFromLibrary(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? PaperSelectionMenuPayload else { return }
            parent.removeFromLibrary(payload.paperIDs)
        }

        private func removeSelectionFromCurrentSource() {
            guard !parent.selection.isEmpty, !parent.isReadOnly else { return }
            if case let .collection(collectionID) = parent.currentSource {
                parent.removeFromCurrentCollection(parent.selection, collectionID)
            } else {
                parent.removeFromLibrary(parent.selection)
            }
        }

        private func selectedPaperIDs(in tableView: NSTableView) -> Set<UUID> {
            Set(tableView.selectedRowIndexes.compactMap { index in
                parent.papers.indices.contains(index) ? parent.papers[index].id : nil
            })
        }

        private func membershipState(
            paperIDs: Set<UUID>,
            collectionID: UUID
        ) -> CollectionMembershipState {
            let memberCount = parent.papers.lazy.filter {
                paperIDs.contains($0.id) && $0.collectionIDs.contains(collectionID)
            }.count
            if memberCount == 0 { return .off }
            if memberCount == paperIDs.count { return .on }
            return .mixed
        }

        private func collectionOrderedBefore(
            _ lhs: CollectionRecord,
            _ rhs: CollectionRecord
        ) -> Bool {
            let order = collectionPathLabel(for: lhs)
                .localizedCaseInsensitiveCompare(collectionPathLabel(for: rhs))
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        private func collectionPathLabel(for collection: CollectionRecord) -> String {
            let byID = Dictionary(uniqueKeysWithValues: parent.collections.map { ($0.id, $0) })
            var names = [collection.name]
            var parentID = collection.parentID
            var visited: Set<UUID> = [collection.id]
            while let id = parentID,
                  let ancestor = byID[id],
                  visited.insert(id).inserted {
                names.append(ancestor.name)
                parentID = ancestor.parentID
            }
            return names.reversed().joined(separator: " › ")
        }

        private func perform(_ command: LibraryTableCommand) {
            switch command {
            case let .editMetadata(paperID):
                guard !parent.isReadOnly else { return }
                parent.editMetadata(paperID)
            case let .open(paperID):
                parent.openPaper(paperID)
            }
        }

        private func statusButton(for paper: PaperRecord, tableView: NSTableView) -> NSView {
            let identifier = ColumnConfiguration.status.identifier
            let button: NSButton
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton {
                button = reused
            } else {
                button = NSButton()
                button.identifier = identifier
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(cycleStatus(_:))
            }
            button.image = NSImage(systemSymbolName: paper.readingStatus.systemImage, accessibilityDescription: nil)
            button.contentTintColor = paper.readingStatus == .unread ? .secondaryLabelColor : .controlAccentColor
            button.toolTip = "\(paper.readingStatus.title)，点击标记为\(paper.readingStatus.next.title)"
            button.setAccessibilityLabel(button.toolTip)
            button.isEnabled = !parent.isReadOnly
            return button
        }

        private func textCell(
            _ value: String,
            identifier: NSUserInterfaceItemIdentifier,
            tooltip: String? = nil,
            isUnavailable: Bool = false
        ) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: value)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.textColor = isUnavailable ? .secondaryLabelColor : .labelColor
            label.toolTip = tooltip
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}

final class LibraryNSTableView: NSTableView {
    var commandHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if commandHandler?(event) == true { return }
        super.keyDown(with: event)
    }


    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event)
    }
}

private final class MembershipMenuPayload: NSObject {
    let paperIDs: Set<UUID>
    let collectionID: UUID
    let shouldAdd: Bool

    init(paperIDs: Set<UUID>, collectionID: UUID, shouldAdd: Bool) {
        self.paperIDs = paperIDs
        self.collectionID = collectionID
        self.shouldAdd = shouldAdd
    }
}

private final class PaperSelectionMenuPayload: NSObject {
    let paperIDs: Set<UUID>

    init(paperIDs: Set<UUID>) {
        self.paperIDs = paperIDs
    }
}
