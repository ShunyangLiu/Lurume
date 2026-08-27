import Foundation
import PDFKit

/// 从 PDFKit 文档属性提取标题与作者。加载在后台线程完成，属性读取不阻塞导入。
struct SystemPaperMetadataReader: PaperMetadataReading {
    func metadata(at url: URL) async -> PaperMetadata? {
        await Task.detached(priority: .utility) { [url] in
            guard let document = PDFDocument(url: url) else { return nil }
            let attributes = document.documentAttributes ?? [:]

            func string(_ attribute: PDFDocumentAttribute) -> String? {
                switch attributes[attribute] {
                case let value as String:
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                case let values as [String]:
                    let joined = values
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    return joined.isEmpty ? nil : joined
                default:
                    return nil
                }
            }

            return PaperMetadata(
                title: string(.titleAttribute),
                authors: string(.authorAttribute)
            )
        }.value
    }
}
