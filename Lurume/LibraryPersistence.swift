import Foundation

enum LibraryPersistenceError: LocalizedError, Equatable {
    case unsupportedSchema(found: Int)
    case invalidSnapshot(reason: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found):
            "文献库格式版本为 \(found)，当前应用只支持版本 1–4 的自动升级和版本 \(LibrarySchema.currentVersion)。"
        case let .invalidSnapshot(reason):
            "文献库数据不一致：\(reason)"
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

/// v2 快照原样保留：P3 迁移只补充阅读状态，不改动任何 P0–P2 字段。
struct PaperRecordV2: Codable, Equatable, Sendable {
    let id: UUID
    var volumeUUID: String?
    var documentIdentifier: Int?
    var bookmarkData: Data
    var fallbackPath: String
    var originalFileName: String
    var title: String
    var authors: String?
    var year: Int?
    var manuallyEditedFields: Set<MetadataField>
    var didReadAutoMetadata: Bool
    let dateAdded: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int
}

struct LibrarySnapshotV2: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var papers: [PaperRecordV2]
    var selectedPaperID: UUID?
}

/// v3 快照原样保留：P5 迁移只补充空文献集关系，不改动任何 P0–P3 字段。
struct PaperRecordV3: Codable, Equatable, Sendable {
    let id: UUID
    var volumeUUID: String?
    var documentIdentifier: Int?
    var bookmarkData: Data
    var fallbackPath: String
    var originalFileName: String
    var title: String
    var authors: String?
    var year: Int?
    var manuallyEditedFields: Set<MetadataField>
    var didReadAutoMetadata: Bool
    let dateAdded: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int
    var readingStatus: ReadingStatus
}

struct LibrarySnapshotV3: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var papers: [PaperRecordV3]
    var selectedPaperID: UUID?
}

/// v4 快照原样保留：P8 迁移结构化书目字段并把扁平文献集放到顶层。
struct PaperRecordV4: Codable, Equatable, Sendable {
    let id: UUID
    var volumeUUID: String?
    var documentIdentifier: Int?
    var bookmarkData: Data
    var fallbackPath: String
    var originalFileName: String
    var title: String
    var authors: String?
    var year: Int?
    var manuallyEditedFields: Set<MetadataField>
    var didReadAutoMetadata: Bool
    let dateAdded: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int
    var readingStatus: ReadingStatus
    var collectionIDs: [UUID]
}

struct CollectionRecordV4: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
}

struct LibrarySnapshotV4: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var papers: [PaperRecordV4]
    var collections: [CollectionRecordV4]
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
                    initialTitle: paper.displayName,
                    originalFileName: Self.originalFileName(for: paper),
                    dateAdded: paper.dateAdded,
                    lastOpenedAt: paper.lastOpenedAt,
                    lastPageIndex: paper.lastPageIndex
                )
            },
            selectedPaperID: legacy.selectedPaperID
        )
    }

    static func migrate(_ legacy: LibrarySnapshotV2) -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: legacy.papers.map { paper in
                var migrated = PaperRecord(
                    id: paper.id,
                    identity: FileIdentity(
                        volumeUUID: paper.volumeUUID,
                        documentIdentifier: paper.documentIdentifier,
                        fallbackPath: paper.fallbackPath
                    ),
                    bookmarkData: paper.bookmarkData,
                    initialTitle: paper.title,
                    originalFileName: paper.originalFileName,
                    dateAdded: paper.dateAdded,
                    lastOpenedAt: paper.lastOpenedAt,
                    lastPageIndex: paper.lastPageIndex,
                    readingStatus: .unread
                )
                migrated.title = paper.title
                migrated.authors = paper.authors
                migrated.year = paper.year
                migrated.manuallyEditedFields = migratedManualFields(paper.manuallyEditedFields)
                migrated.didReadAutoMetadata = paper.didReadAutoMetadata
                return migrated
            },
            selectedPaperID: legacy.selectedPaperID
        )
    }

    static func migrate(_ legacy: LibrarySnapshotV3) -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: legacy.papers.map { paper in
                var migrated = PaperRecord(
                    id: paper.id,
                    identity: FileIdentity(
                        volumeUUID: paper.volumeUUID,
                        documentIdentifier: paper.documentIdentifier,
                        fallbackPath: paper.fallbackPath
                    ),
                    bookmarkData: paper.bookmarkData,
                    initialTitle: paper.title,
                    originalFileName: paper.originalFileName,
                    dateAdded: paper.dateAdded,
                    lastOpenedAt: paper.lastOpenedAt,
                    lastPageIndex: paper.lastPageIndex,
                    readingStatus: paper.readingStatus
                )
                migrated.title = paper.title
                migrated.authors = paper.authors
                migrated.year = paper.year
                migrated.manuallyEditedFields = migratedManualFields(paper.manuallyEditedFields)
                migrated.didReadAutoMetadata = paper.didReadAutoMetadata
                return migrated
            },
            collections: [],
            selectedPaperID: legacy.selectedPaperID
        )
    }

    static func migrate(_ legacy: LibrarySnapshotV4) -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: legacy.papers.map { paper in
                var metadata = BibliographicMetadata(title: paper.title)
                metadata.setLegacyAuthors(paper.authors)
                if let year = paper.year {
                    metadata.issuedDate = BibliographicDate(year: year)
                }
                var migrated = PaperRecord(
                    id: paper.id,
                    identity: FileIdentity(
                        volumeUUID: paper.volumeUUID,
                        documentIdentifier: paper.documentIdentifier,
                        fallbackPath: paper.fallbackPath
                    ),
                    bookmarkData: paper.bookmarkData,
                    initialTitle: paper.title,
                    originalFileName: paper.originalFileName,
                    dateAdded: paper.dateAdded,
                    lastOpenedAt: paper.lastOpenedAt,
                    lastPageIndex: paper.lastPageIndex,
                    readingStatus: paper.readingStatus,
                    collectionIDs: paper.collectionIDs,
                    metadata: metadata
                )
                migrated.manuallyEditedFields = migratedManualFields(paper.manuallyEditedFields)
                migrated.didReadAutoMetadata = paper.didReadAutoMetadata
                return migrated
            },
            collections: legacy.collections.map {
                CollectionRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt)
            },
            selectedPaperID: legacy.selectedPaperID
        )
    }

    private static func originalFileName(for paper: PaperRecordV1) -> String {
        let pathName = (paper.fallbackPath as NSString).lastPathComponent
        return pathName.isEmpty ? paper.displayName : pathName
    }

    private static func migratedManualFields(_ fields: Set<MetadataField>) -> Set<MetadataField> {
        Set(fields.map { field in
            switch field {
            case .authors: .creators
            case .year: .issuedDate
            default: field
            }
        })
    }
}

struct LibraryPersistence: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func applicationDefault(fileManager: FileManager = .default) throws -> Self {
        if isRunningUnitTests {
            let testDirectory = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "LurumeTests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            return Self(fileURL: testDirectory.appendingPathComponent("library.json"))
        }
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

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
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
            try Self.validate(snapshot)
            return LoadedLibrary(snapshot: snapshot, migratedFromLegacy: false)
        case 4:
            let legacy = try Self.decoder.decode(LibrarySnapshotV4.self, from: data)
            let snapshot = LibraryMigrations.migrate(legacy)
            try Self.validate(snapshot)
            return LoadedLibrary(snapshot: snapshot, migratedFromLegacy: true)
        case 3:
            let legacy = try Self.decoder.decode(LibrarySnapshotV3.self, from: data)
            let snapshot = LibraryMigrations.migrate(legacy)
            try Self.validate(snapshot)
            return LoadedLibrary(snapshot: snapshot, migratedFromLegacy: true)
        case 2:
            let legacy = try Self.decoder.decode(LibrarySnapshotV2.self, from: data)
            let snapshot = LibraryMigrations.migrate(legacy)
            try Self.validate(snapshot)
            return LoadedLibrary(snapshot: snapshot, migratedFromLegacy: true)
        case 1:
            let legacy = try Self.decoder.decode(LibrarySnapshotV1.self, from: data)
            let snapshot = LibraryMigrations.migrate(legacy)
            try Self.validate(snapshot)
            return LoadedLibrary(snapshot: snapshot, migratedFromLegacy: true)
        default:
            throw LibraryPersistenceError.unsupportedSchema(found: version)
        }
    }

    func save(_ snapshot: LibrarySnapshot, fileManager: FileManager = .default) throws {
        try Self.validate(snapshot)
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

    private static func validate(_ snapshot: LibrarySnapshot) throws {
        guard snapshot.schemaVersion == LibrarySchema.currentVersion else {
            throw LibraryPersistenceError.unsupportedSchema(found: snapshot.schemaVersion)
        }

        let paperIDs = snapshot.papers.map(\.id)
        guard Set(paperIDs).count == paperIDs.count else {
            throw LibraryPersistenceError.invalidSnapshot(reason: "存在重复的论文 ID。")
        }

        let collectionIDs = snapshot.collections.map(\.id)
        guard Set(collectionIDs).count == collectionIDs.count else {
            throw LibraryPersistenceError.invalidSnapshot(reason: "存在重复的文献集 ID。")
        }

        for collection in snapshot.collections {
            let trimmedName = CollectionNameRules.trimmed(collection.name)
            guard !trimmedName.isEmpty else {
                throw LibraryPersistenceError.invalidSnapshot(reason: "存在空名称文献集。")
            }
            guard Set(collection.importSources).count == collection.importSources.count else {
                throw LibraryPersistenceError.invalidSnapshot(reason: "文献集“\(collection.name)”包含重复来源。")
            }
            guard collection.importSources == collection.importSources.sorted(by: ImportSourceOrdering.less) else {
                throw LibraryPersistenceError.invalidSnapshot(reason: "文献集“\(collection.name)”的来源顺序不稳定。")
            }
            guard collection.importSources.allSatisfy(ImportSourceRules.isValid) else {
                throw LibraryPersistenceError.invalidSnapshot(reason: "文献集“\(collection.name)”包含无效来源标识。")
            }
        }

        if let issue = CollectionHierarchy.validationIssue(in: snapshot.collections) {
            let reason: String
            switch issue {
            case .missingParent:
                reason = "文献集引用了不存在的父文献集。"
            case .cycle:
                reason = "文献集层级存在循环。"
            case .duplicateSiblingName:
                reason = "同一层级存在重复的文献集名称。"
            }
            throw LibraryPersistenceError.invalidSnapshot(reason: reason)
        }

        let validCollectionIDs = Set(collectionIDs)
        for paper in snapshot.papers {
            guard Set(paper.collectionIDs).count == paper.collectionIDs.count else {
                throw LibraryPersistenceError.invalidSnapshot(
                    reason: "论文“\(paper.displayTitle)”包含重复的文献集归属。"
                )
            }
            guard paper.collectionIDs.allSatisfy(validCollectionIDs.contains) else {
                throw LibraryPersistenceError.invalidSnapshot(
                    reason: "论文“\(paper.displayTitle)”引用了不存在的文献集。"
                )
            }
            guard Set(paper.importSources).count == paper.importSources.count else {
                throw LibraryPersistenceError.invalidSnapshot(
                    reason: "论文“\(paper.displayTitle)”包含重复导入来源。"
                )
            }
            guard paper.importSources == paper.importSources.sorted(by: ImportSourceOrdering.less) else {
                throw LibraryPersistenceError.invalidSnapshot(
                    reason: "论文“\(paper.displayTitle)”的导入来源顺序不稳定。"
                )
            }
            guard paper.importSources.allSatisfy(ImportSourceRules.isValid) else {
                throw LibraryPersistenceError.invalidSnapshot(
                    reason: "论文“\(paper.displayTitle)”包含无效导入来源。"
                )
            }
            if let fingerprint = paper.contentFingerprint {
                let isSHA256 = fingerprint.sha256.count == 64
                    && fingerprint.sha256.allSatisfy { $0.isHexDigit }
                guard isSHA256, fingerprint.byteCount >= 0 else {
                    throw LibraryPersistenceError.invalidSnapshot(
                        reason: "论文“\(paper.displayTitle)”包含无效内容哈希。"
                    )
                }
            }
        }
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
