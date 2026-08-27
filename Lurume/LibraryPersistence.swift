import Foundation

enum LibraryPersistenceError: LocalizedError, Equatable {
    case unsupportedSchema(found: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found):
            "文献库格式版本为 \(found)，当前应用只支持版本 1 的自动升级和版本 \(LibrarySchema.currentVersion)。"
        }
    }
}

/// v1 快照原样保留：迁移把 displayName 平移为回退标题，其余字段逐项照搬。
struct PaperRecordV1: Codable, Equatable, Sendable {
    let id: UUID
    var volumeUUID: String?
    var documentIdentifier: Int?
    var bookmarkData: Data
    var fallbackPath: String
    var displayName: String
    let dateAdded: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int
}

struct LibrarySnapshotV1: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var papers: [PaperRecordV1]
    var selectedPaperID: UUID?
}

/// 载入结果。migratedFromLegacy 为真时调用方应尽快落盘，保证升级尽早持久化。
struct LoadedLibrary: Equatable, Sendable {
    let snapshot: LibrarySnapshot
    let migratedFromLegacy: Bool

    static let empty = LoadedLibrary(snapshot: .empty, migratedFromLegacy: false)
}

enum LibraryMigrations {
    static func migrate(_ legacy: LibrarySnapshotV1) -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: legacy.papers.map { paper in
                PaperRecord(
                    id: paper.id,
                    identity: FileIdentity(
                        volumeUUID: paper.volumeUUID,
                        documentIdentifier: paper.documentIdentifier,
                        fallbackPath: paper.fallbackPath
                    ),
                    bookmarkData: paper.bookmarkData,
                    displayName: paper.displayName,
                    dateAdded: paper.dateAdded,
                    lastOpenedAt: paper.lastOpenedAt,
                    lastPageIndex: paper.lastPageIndex
                )
            },
            selectedPaperID: legacy.selectedPaperID
        )
    }
}

struct LibraryPersistence: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func applicationDefault(fileManager: FileManager = .default) throws -> Self {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = applicationSupport
            .appendingPathComponent("Lurume", isDirectory: true)
        return Self(fileURL: directory.appendingPathComponent("library.json"))
    }

    func load(fileManager: FileManager = .default) throws -> LoadedLibrary {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        let version = try Self.decoder.decode(LibraryVersionEnvelope.self, from: data).schemaVersion
        switch version {
        case LibrarySchema.currentVersion:
            let snapshot = try Self.decoder.decode(LibrarySnapshot.self, from: data)
            return LoadedLibrary(snapshot: snapshot, migratedFromLegacy: false)
        case 1:
            let legacy = try Self.decoder.decode(LibrarySnapshotV1.self, from: data)
            return LoadedLibrary(
                snapshot: LibraryMigrations.migrate(legacy),
                migratedFromLegacy: true
            )
        default:
            throw LibraryPersistenceError.unsupportedSchema(found: version)
        }
    }

    func save(_ snapshot: LibrarySnapshot, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private struct LibraryVersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
