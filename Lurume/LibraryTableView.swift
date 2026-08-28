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
    let isReadOnly: Bool
    let cycleReadingStatus: (UUID) -> Void
    let editMetadata: (UUID) -> Void
    let openPaper: (UUID) -> Void

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
                    paper.title,
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
            return false
        }

        @objc private func cycleStatus(_ sender: NSButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            guard parent.papers.indices.contains(row), !parent.isReadOnly else { return }
            parent.cycleReadingStatus(parent.papers[row].id)
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

    override func keyDown(with event: NSEvent) {
        if commandHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
