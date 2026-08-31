import AppKit
import Foundation

enum LibraryDropPayload: Equatable {
    case internalPapers([UUID])
    case internalCollections([UUID])
    case finderPDFs([URL])
    case unsupported
}

private struct LibraryPaperDragEnvelope: Codable {
    let schemaVersion: Int
    let paperIDs: [UUID]
}

private struct LibraryCollectionDragEnvelope: Codable {
    let schemaVersion: Int
    let collectionIDs: [UUID]
}

enum LibraryDragDropCodec {
    static let internalPaperType = NSPasteboard.PasteboardType(
        "app.lurume.internal-paper-ids"
    )
    static let internalCollectionType = NSPasteboard.PasteboardType(
        "app.lurume.internal-collection-ids"
    )

    static func pasteboardItem(paperIDs: [UUID]) -> NSPasteboardItem? {
        let normalizedIDs = normalized(paperIDs)
        guard !normalizedIDs.isEmpty else { return nil }
        let envelope = LibraryPaperDragEnvelope(
            schemaVersion: 1,
            paperIDs: normalizedIDs
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: internalPaperType)
        return item
    }

    static func itemProvider(collectionIDs: [UUID]) -> NSItemProvider? {
        let normalizedIDs = normalized(collectionIDs)
        guard !normalizedIDs.isEmpty,
              let data = try? JSONEncoder().encode(LibraryCollectionDragEnvelope(
                schemaVersion: 1,
                collectionIDs: normalizedIDs
              )) else {
            return nil
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: internalCollectionType.rawValue,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func pasteboardItem(collectionIDs: [UUID]) -> NSPasteboardItem? {
        let normalizedIDs = normalized(collectionIDs)
        guard !normalizedIDs.isEmpty,
              let data = try? JSONEncoder().encode(LibraryCollectionDragEnvelope(
                schemaVersion: 1,
                collectionIDs: normalizedIDs
              )) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: internalCollectionType)
        return item
    }

    static func resolve(_ pasteboard: NSPasteboard) -> LibraryDropPayload {
        let items = pasteboard.pasteboardItems ?? []
        let collectionItems = items.filter {
            $0.availableType(from: [internalCollectionType]) != nil
        }
        if !collectionItems.isEmpty {
            var collectionIDs: [UUID] = []
            for item in collectionItems {
                guard let data = item.data(forType: internalCollectionType),
                      let envelope = try? JSONDecoder().decode(
                        LibraryCollectionDragEnvelope.self,
                        from: data
                      ),
                      envelope.schemaVersion == 1,
                      !envelope.collectionIDs.isEmpty else {
                    return .unsupported
                }
                collectionIDs.append(contentsOf: envelope.collectionIDs)
            }
            let normalizedIDs = normalized(collectionIDs)
            return normalizedIDs.isEmpty ? .unsupported : .internalCollections(normalizedIDs)
        }

        let internalItems = items.filter {
            $0.availableType(from: [internalPaperType]) != nil
        }
        if !internalItems.isEmpty {
            var paperIDs: [UUID] = []
            for item in internalItems {
                guard let data = item.data(forType: internalPaperType),
                      let envelope = try? JSONDecoder().decode(
                        LibraryPaperDragEnvelope.self,
                        from: data
                      ),
                      envelope.schemaVersion == 1,
                      !envelope.paperIDs.isEmpty else {
                    return .unsupported
                }
                paperIDs.append(contentsOf: envelope.paperIDs)
            }
            let normalizedIDs = normalized(paperIDs)
            return normalizedIDs.isEmpty ? .unsupported : .internalPapers(normalizedIDs)
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? [])
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
            .map(\.standardizedFileURL)
        let uniqueURLs = Dictionary(grouping: fileURLs, by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return uniqueURLs.isEmpty ? .unsupported : .finderPDFs(uniqueURLs)
    }

    private static func normalized(_ paperIDs: [UUID]) -> [UUID] {
        Array(Set(paperIDs)).sorted { $0.uuidString < $1.uuidString }
    }
}
