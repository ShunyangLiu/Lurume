import AppKit
import PDFKit

@MainActor
final class HighlightPDFView: PDFView {
    var highlightIDAtEvent: ((NSEvent) -> UUID?)?
    var toggleHighlightTitle: (() -> String?)?
    var onToggleHighlight: (() -> Void)?
    var onDeleteHighlight: ((UUID) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        var customItems: [NSMenuItem] = []

        let highlightID = highlightIDAtEvent?(event)
        let toggleTitle = toggleHighlightTitle?()

        if let highlightID {
            let delete = NSMenuItem(
                title: "删除高亮",
                action: #selector(deleteHighlight(_:)),
                keyEquivalent: ""
            )
            delete.target = self
            delete.representedObject = highlightID.uuidString
            customItems.append(delete)
        }

        if let title = toggleTitle,
           highlightID == nil || title != "取消高亮" {
            let toggle = NSMenuItem(
                title: title,
                action: #selector(toggleHighlight(_:)),
                keyEquivalent: ""
            )
            toggle.target = self
            customItems.append(toggle)
        }

        guard !customItems.isEmpty else { return menu }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        customItems.forEach(menu.addItem)
        return menu
    }

    @objc private func toggleHighlight(_ sender: Any?) {
        onToggleHighlight?()
    }

    @objc private func deleteHighlight(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID) else {
            return
        }
        onDeleteHighlight?(id)
    }
}
