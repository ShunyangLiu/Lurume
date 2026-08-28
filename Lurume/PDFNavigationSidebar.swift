import AppKit
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let document = controller.document, controller.pdfView != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                                if let page = document.page(at: pageIndex) {
                                    PDFPageThumbnailRow(
                                        page: page,
                                        pageIndex: pageIndex,
                                        isCurrent: controller.currentPageIndex == pageIndex
                                    ) {
                                        controller.go(toOneBasedPage: pageIndex + 1)
                                    }
                                    .id(pageIndex)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        proxy.scrollTo(controller.currentPageIndex, anchor: .center)
                    }
                    .onChange(of: controller.currentPageIndex) { _, pageIndex in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(pageIndex, anchor: .center)
                        }
                    }
                }
                .id(ObjectIdentifier(document))
            } else {
                ContentUnavailableView(
                    "尚未载入 PDF",
                    systemImage: "rectangle.stack",
                    description: Text("选择并成功打开一篇论文后显示页面。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFPageThumbnailRow: View {
    let page: PDFPage
    let pageIndex: Int
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(pageIndex + 1)")
                    .font(.callout.monospacedDigit())
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 32, alignment: .trailing)
                    .padding(.top, 4)

                PDFPageThumbnailImage(page: page)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackground)
            }
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.42), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("前往第 \(pageIndex + 1) 页")
        .accessibilityLabel("第 \(pageIndex + 1) 页")
        .accessibilityValue(isCurrent ? "当前页" : "")
    }

    private var rowBackground: Color {
        if isCurrent {
            return Color.accentColor.opacity(0.13)
        }
        return isHovering ? Color.primary.opacity(0.055) : .clear
    }
}

private struct PDFPageThumbnailImage: View {
    let page: PDFPage

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 76, height: 98)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.black.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
        .task(id: ObjectIdentifier(page)) {
            image = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            image = PDFPageThumbnailCache.shared.image(for: page)
        }
    }
}

@MainActor
private final class PDFPageThumbnailCache {
    static let shared = PDFPageThumbnailCache()

    private let images = NSCache<PDFPage, NSImage>()

    private init() {
        images.countLimit = 80
    }

    func image(for page: PDFPage) -> NSImage {
        if let cached = images.object(forKey: page) {
            return cached
        }
        let image = page.thumbnail(of: NSSize(width: 152, height: 196), for: .cropBox)
        images.setObject(image, forKey: page)
        return image
    }
}
