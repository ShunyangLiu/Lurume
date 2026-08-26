import Foundation

struct FileIdentity: Codable, Equatable, Sendable {
    let volumeUUID: String?
    let documentIdentifier: Int?
    let fallbackPath: String

    init(volumeUUID: String?, documentIdentifier: Int?, fallbackPath: String) {
        self.volumeUUID = volumeUUID
        self.documentIdentifier = documentIdentifier
        self.fallbackPath = URL(fileURLWithPath: fallbackPath).standardizedFileURL.path
    }

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .documentIdentifierKey,
        ])
        self.init(
            volumeUUID: values.volumeUUIDString,
            documentIdentifier: values.documentIdentifier,
            fallbackPath: url.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func identifiesSameFile(as other: FileIdentity) -> Bool {
        if let volumeUUID,
           let documentIdentifier,
           let otherVolumeUUID = other.volumeUUID,
           let otherDocumentIdentifier = other.documentIdentifier {
            return volumeUUID == otherVolumeUUID
                && documentIdentifier == otherDocumentIdentifier
        }

        return fallbackPath == other.fallbackPath
    }
}

struct PaperRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var volumeUUID: String?
    var documentIdentifier: Int?
    var bookmarkData: Data
    var fallbackPath: String
    var displayName: String
    let dateAdded: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int

    var identity: FileIdentity {
        FileIdentity(
            volumeUUID: volumeUUID,
            documentIdentifier: documentIdentifier,
            fallbackPath: fallbackPath
        )
    }

    init(
        id: UUID = UUID(),
        identity: FileIdentity,
        bookmarkData: Data,
        displayName: String,
        dateAdded: Date = Date(),
        lastOpenedAt: Date? = nil,
        lastPageIndex: Int = 0
    ) {
        self.id = id
        self.volumeUUID = identity.volumeUUID
        self.documentIdentifier = identity.documentIdentifier
        self.bookmarkData = bookmarkData
        self.fallbackPath = identity.fallbackPath
        self.displayName = displayName
        self.dateAdded = dateAdded
        self.lastOpenedAt = lastOpenedAt
        self.lastPageIndex = max(0, lastPageIndex)
    }

    mutating func replaceFileReference(
        identity: FileIdentity,
        bookmarkData: Data,
        displayName: String
    ) {
        volumeUUID = identity.volumeUUID
        documentIdentifier = identity.documentIdentifier
        fallbackPath = identity.fallbackPath
        self.bookmarkData = bookmarkData
        self.displayName = displayName
    }
}

struct LibrarySnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var papers: [PaperRecord]
    var selectedPaperID: UUID?

    static let empty = LibrarySnapshot(
        schemaVersion: LibrarySchema.currentVersion,
        papers: [],
        selectedPaperID: nil
    )
}
