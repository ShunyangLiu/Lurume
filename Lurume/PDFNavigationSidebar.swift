import PDFKit
import SwiftUI

enum ReaderSidebarMode: String, Hashable, CaseIterable, Identifiable {
    case library
    case outline
    case pages

    var id: Self { self }

    var title: String {
        switch self {
        case .library: "文献"
        case .outline: "目录"
        case .pages: "页面"
        }
    }
}

@MainActor
struct PDFOutlineNode: Identifiable {
    let id: ObjectIdentifier
    let label: String
    let destination: PDFDestination?
    let children: [PDFOutlineNode]?

    init(outline: PDFOutline, document: PDFDocument) {
        id = ObjectIdentifier(outline)
        let trimmedLabel = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        label = trimmedLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名目录项"
        destination = Self.localDestination(for: outline, in: document)

        let childNodes = (0..<outline.numberOfChildren).compactMap { index in
            outline.child(at: index).map { PDFOutlineNode(outline: $0, document: document) }
        }
        children = childNodes.isEmpty ? nil : childNodes
    }

    static func roots(in document: PDFDocument) -> [PDFOutlineNode] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            root.child(at: index).map { PDFOutlineNode(outline: $0, document: document) }
        }
    }

    private static func localDestination(
        for outline: PDFOutline,
        in document: PDFDocument
    ) -> PDFDestination? {
        let candidate: PDFDestination?
        if let action = outline.action {
            guard let goTo = action as? PDFActionGoTo else { return nil }
            candidate = goTo.destination
        } else {
            candidate = outline.destination
        }
        guard let candidate, candidate.page?.document === document else { return nil }
        return candidate
    }
}

struct PDFOutlineSidebar: View {
    @ObservedObject var controller: PDFReaderController
    @State private var selectedNodeID: ObjectIdentifier?
    @State private var nodes: [PDFOutlineNode] = []

    private var documentID: ObjectIdentifier? {
        controller.document.map(ObjectIdentifier.init)
    }

    var body: some View {
        Group {
            if controller.document == nil {
                ContentUnavailableView(
                    "尚未载入 PDF",
                    systemImage: "list.bullet.indent",
                    description: Text("选择并成功打开一篇论文后显示目录。")
                )
            } else if nodes.isEmpty {
                ContentUnavailableView(
                    "这份 PDF 没有目录",
                    systemImage: "list.bullet.indent",
                    description: Text("Lurume 不会自动分析正文生成目录。")
                )
            } else {
                List(selection: $selectedNodeID) {
                    OutlineGroup(nodes, children: \.children) { node in
                        HStack(spacing: 6) {
                            Text(node.label)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            if node.destination == nil {
                                Image(systemName: "nosign")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .help("这个目录项不是当前 PDF 内的可用跳转")
                            }
                        }
                        .contentShape(Rectangle())
                        .foregroundStyle(node.destination == nil ? .secondary : .primary)
                        .tag(node.id)
                        .onTapGesture {
                            guard let destination = node.destination else { return }
                            selectedNodeID = node.id
                            controller.go(to: destination)
                        }
                    }
                }
            }
        }
        .onAppear(perform: reloadOutline)
        .onChange(of: documentID) {
            selectedNodeID = nil
            reloadOutline()
        }
    }

    private func reloadOutline() {
        nodes = controller.document.map(PDFOutlineNode.roots(in:)) ?? []
    }
}

struct PDFThumbnailSidebar: View {
    @ObservedObject var controller: PDFReaderController

    var body: some View {
        Group {
            if controller.document == nil || controller.pdfView == nil {
                ContentUnavailableView(
                    "尚未载入 PDF",
                    systemImage: "rectangle.stack",
                    description: Text("选择并成功打开一篇论文后显示页面。")
                )
            } else {
                PDFThumbnailRepresentable(pdfView: controller.pdfView)
            }
        }
    }
}

struct PDFThumbnailRepresentable: NSViewRepresentable {
    let pdfView: PDFView?

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        configure(thumbnailView)
        return thumbnailView
    }

    func updateNSView(_ thumbnailView: PDFThumbnailView, context: Context) {
        configure(thumbnailView)
    }

    private func configure(_ thumbnailView: PDFThumbnailView) {
        if thumbnailView.pdfView !== pdfView {
            thumbnailView.pdfView = pdfView
        }
        thumbnailView.maximumNumberOfColumns = 1
        thumbnailView.thumbnailSize = NSSize(width: 132, height: 172)
        thumbnailView.allowsDragging = false
        thumbnailView.allowsMultipleSelection = false
        thumbnailView.backgroundColor = .clear
    }
}
