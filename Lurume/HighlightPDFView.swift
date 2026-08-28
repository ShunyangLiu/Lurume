import AppKit
import PDFKit
import SwiftUI

final class HighlightNoteMarkerAnnotation: PDFAnnotation {
    enum Style {
        case add
        case note
    }

    let markerStyle: Style

    init(bounds: CGRect, style: Style) {
        markerStyle = style
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        isReadOnly = true
    }

    required init?(coder: NSCoder) {
        markerStyle = .note
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let rect = bounds.insetBy(dx: 1, dy: 1)
        switch markerStyle {
        case .add:
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.6)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: rect.midX, y: rect.minY + 3.5))
            context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3.5))
            context.move(to: CGPoint(x: rect.minX + 3.5, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX - 3.5, y: rect.midY))
            context.strokePath()
        case .note:
            let body = CGRect(
                x: rect.minX,
                y: rect.minY + 2.5,
                width: rect.width,
                height: rect.height - 2.5
            )
            let bubble = CGPath(
                roundedRect: body,
                cornerWidth: 2.5,
                cornerHeight: 2.5,
                transform: nil
            )
            context.addPath(bubble)
            context.setFillColor(NSColor.systemYellow.cgColor)
            context.fillPath()
            context.move(to: CGPoint(x: body.minX + 3, y: body.minY))
            context.addLine(to: CGPoint(x: body.minX + 3, y: rect.minY))
            context.addLine(to: CGPoint(x: body.minX + 6, y: body.minY))
            context.closePath()
            context.setFillColor(NSColor.systemYellow.cgColor)
            context.fillPath()
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.75).cgColor)
            context.setLineWidth(1)
            context.setLineCap(.round)
            for offset in [4.5, 7.5, 10.5] {
                context.move(to: CGPoint(x: body.minX + 3, y: body.minY + offset))
                context.addLine(to: CGPoint(x: body.maxX - 3, y: body.minY + offset))
            }
            context.strokePath()
        }
    }
}

@MainActor
final class HighlightPDFView: PDFView {
    var highlightIDAtEvent: ((NSEvent) -> UUID?)?
    var toggleHighlightTitle: (() -> String?)?
    var onTranslateSelection: (() -> Void)?
    var onToggleHighlight: (() -> Void)?
    var onDeleteHighlight: ((UUID) -> Void)?
    var noteMarkerIDAtEvent: ((NSEvent) -> UUID?)?
    var interactiveHighlightIDAtEvent: ((NSEvent) -> UUID?)?
    var onSelectHighlight: ((UUID?) -> Void)?
    var onOpenHighlightNote: ((UUID) -> Void)?
    var onMoveHighlightNoteMarker: ((UUID, CGPoint, CGPoint, Bool) -> Void)?
    var onHoverHighlight: ((UUID?) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var mouseDownHighlightID: UUID?
    private var mouseDownNoteMarkerID: UUID?
    private var didDragSinceMouseDown = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownNoteMarkerID = noteMarkerIDAtEvent?(event)
        mouseDownHighlightID = interactiveHighlightIDAtEvent?(event)
        didDragSinceMouseDown = false
        if mouseDownNoteMarkerID == nil {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let mouseDownPoint {
            let current = convert(event.locationInWindow, from: nil)
            if hypot(current.x - mouseDownPoint.x, current.y - mouseDownPoint.y) > 3 {
                didDragSinceMouseDown = true
            }
        }
        if let markerID = mouseDownNoteMarkerID, let mouseDownPoint {
            let point = convert(event.locationInWindow, from: nil)
            onMoveHighlightNoteMarker?(markerID, mouseDownPoint, point, false)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownHighlightID = nil
            mouseDownNoteMarkerID = nil
            didDragSinceMouseDown = false
        }
        let releasedMarkerID = noteMarkerIDAtEvent?(event)
        if didDragSinceMouseDown,
           let markerID = mouseDownNoteMarkerID,
           let mouseDownPoint {
            let point = convert(event.locationInWindow, from: nil)
            onMoveHighlightNoteMarker?(markerID, mouseDownPoint, point, true)
            clearSelection()
            onSelectHighlight?(markerID)
            return
        }
        if !didDragSinceMouseDown,
           let markerID = mouseDownNoteMarkerID,
           markerID == releasedMarkerID {
            clearSelection()
            onSelectHighlight?(markerID)
            onOpenHighlightNote?(markerID)
            return
        }
        super.mouseUp(with: event)
        guard !didDragSinceMouseDown else { return }
        let releasedHighlightID = interactiveHighlightIDAtEvent?(event)
        if let highlightID = mouseDownHighlightID, highlightID == releasedHighlightID {
            clearSelection()
            onSelectHighlight?(highlightID)
        } else {
            onSelectHighlight?(nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverHighlight?(interactiveHighlightIDAtEvent?(event))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverHighlight?(nil)
        super.mouseExited(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // PDFKit's menu contains private view-backed items (including its markup
        // style picker). Copying that menu leaves those views attached to an
        // invalid menu hierarchy and crashes while AppKit updates tracking areas.
        // Extend the original menu instance instead.
        let menu = super.menu(for: event) ?? NSMenu()
        return configureContextMenu(menu, for: event)
    }

    @discardableResult
    func configureContextMenu(_ menu: NSMenu, for event: NSEvent) -> NSMenu? {
        let selectedText = currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelectedText = selectedText?.isEmpty == false && selectionContains(event)
        let highlightID = highlightIDAtEvent?(event)
        let toggleTitle = toggleHighlightTitle?()
        let copyItem = menu.items.first { $0.action.map(NSStringFromSelector) == "copy:" }
        let lookupItem = menu.items.first { $0.title.hasPrefix("查询") }

        // Reuse the original menu and its responder-backed Copy/Look Up items,
        // but remove PDFKit's page layout, zoom, navigation, search, and Services
        // commands. Those controls already exist in Lurume's reading interface.
        menu.allowsContextMenuPlugIns = false
        menu.delegate = nil
        menu.removeAllItems()

        if hasSelectedText {
            if let copyItem {
                menu.addItem(copyItem)
            }
            let translate = NSMenuItem(
                title: "翻译所选文字",
                action: #selector(translateSelection(_:)),
                keyEquivalent: ""
            )
            translate.target = self
            menu.addItem(translate)
            if let lookupItem {
                menu.addItem(lookupItem)
            }
        }

        var highlightItems: [NSMenuItem] = []

        if let highlightID {
            let delete = NSMenuItem(
                title: "删除高亮",
                action: #selector(deleteHighlight(_:)),
                keyEquivalent: ""
            )
            delete.target = self
            delete.representedObject = highlightID.uuidString
            highlightItems.append(delete)
        }

        if let title = toggleTitle, highlightID == nil {
            let toggle = NSMenuItem(
                title: title,
                action: #selector(toggleHighlight(_:)),
                keyEquivalent: ""
            )
            toggle.target = self
            highlightItems.append(toggle)
        }

        if !highlightItems.isEmpty {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            highlightItems.forEach(menu.addItem)
        }

        return menu.items.isEmpty ? nil : menu
    }

    private func selectionContains(_ event: NSEvent) -> Bool {
        guard let selection = currentSelection else { return false }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { return false }
        let pagePoint = convert(viewPoint, to: page)
        let lineSelections = selection.selectionsByLine()
        let fragments = lineSelections.isEmpty ? [selection] : lineSelections
        return fragments.contains { fragment in
            fragment.pages.contains { $0 === page }
                && fragment.bounds(for: page)
                    .insetBy(dx: -2, dy: -2)
                    .contains(pagePoint)
        }
    }

    @objc private func translateSelection(_ sender: Any?) {
        onTranslateSelection?()
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

@MainActor
final class HighlightNoteDraftModel: ObservableObject {
    @Published var text: String {
        didSet {
            guard !readOnly else { return }
            onDraftChanged(text)
            scheduleSave()
        }
    }
    @Published private(set) var saveError: String?

    let readOnly: Bool
    private var lastSavedText: String?
    private let save: (String?) -> Bool
    private let onDraftChanged: (String) -> Void
    private let onSaveSucceeded: () -> Void
    private var saveTask: Task<Void, Never>?

    init(
        text: String,
        persistedText: String,
        readOnly: Bool,
        save: @escaping (String?) -> Bool,
        onDraftChanged: @escaping (String) -> Void,
        onSaveSucceeded: @escaping () -> Void
    ) {
        self.text = text
        self.readOnly = readOnly
        self.save = save
        self.onDraftChanged = onDraftChanged
        self.onSaveSucceeded = onSaveSucceeded
        lastSavedText = Self.normalized(persistedText)
    }

    deinit {
        saveTask?.cancel()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !readOnly else { return }
        let candidate = Self.normalized(text)
        guard candidate != lastSavedText else {
            saveError = nil
            onSaveSucceeded()
            return
        }
        if save(candidate) {
            lastSavedText = candidate
            saveError = nil
            onSaveSucceeded()
        } else {
            saveError = "无法保存笔记，草稿会保留到本次运行结束。"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private static func normalized(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

private struct HighlightNotePopoverView: View {
    @ObservedObject var model: HighlightNoteDraftModel
    let close: () -> Void
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: model.readOnly ? "lock" : "note.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18, alignment: .center)
                Text("笔记")
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭笔记")
            }

            if model.readOnly {
                ScrollView {
                    Text(model.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                .frame(minHeight: 110, maxHeight: 220)
            } else {
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text("添加你的想法……")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 8)
                                .padding(.top, 9)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($editorFocused)
                    .frame(minHeight: 110, maxHeight: 220)
            }

            if let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.readOnly {
                Text("高亮数据处于只读状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
        .task {
            if !model.readOnly {
                editorFocused = true
            }
        }
        .onExitCommand(perform: close)
    }
}

@MainActor
final class HighlightNoteEditorSession: NSObject, NSPopoverDelegate {
    let highlightID: UUID
    let model: HighlightNoteDraftModel

    private let popover = NSPopover()
    private let anchorView: NSView
    private let onClose: () -> Void
    private var didClose = false

    init(
        highlightID: UUID,
        anchorRect: CGRect,
        in documentView: NSView,
        model: HighlightNoteDraftModel,
        onClose: @escaping () -> Void
    ) {
        self.highlightID = highlightID
        self.model = model
        self.onClose = onClose
        anchorView = NSView(frame: anchorRect)
        anchorView.alphaValue = 0.001
        super.init()

        documentView.addSubview(anchorView)
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: AnyView(
                HighlightNotePopoverView(model: model) { [weak self] in
                    self?.close()
                }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    var isShown: Bool {
        popover.isShown
    }

    func show() {
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
    }

    func close() {
        model.flush()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            finishClosing()
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        model.flush()
        return true
    }

    func popoverWillClose(_ notification: Notification) {
        model.flush()
    }

    func popoverDidClose(_ notification: Notification) {
        finishClosing()
    }

    private func finishClosing() {
        guard !didClose else { return }
        didClose = true
        anchorView.removeFromSuperview()
        onClose()
    }
}
