import Foundation

enum HighlightPersistenceError: LocalizedError, Equatable {
    case invalidTopLevel
    case unsupportedSchema(found: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTopLevel:
            "高亮数据格式已损坏。为保护原有数据，高亮功能已进入只读状态。"
        case let .unsupportedSchema(found):
            "高亮数据格式版本为 \(found)，当前应用只支持版本 \(HighlightSchema.currentVersion)。"
        }
    }
}

struct LoadedHighlights: Equatable, Sendable {
    let snapshot: HighlightSnapshot
    let invalidRecordCount: Int

    static let empty = LoadedHighlights(snapshot: .empty, invalidRecordCount: 0)
}

struct HighlightPersistence: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func applicationDefault(fileManager: FileManager = .default) throws -> Self {
        let directory = try LibraryPersistence.applicationDefault(fileManager: fileManager)
            .fileURL.deletingLastPathComponent()
        return Self(fileURL: directory.appendingPathComponent("highlights.json"))
    }

    func load(fileManager: FileManager = .default) throws -> LoadedHighlights {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versionNumber = object["schemaVersion"] as? NSNumber,
              let records = object["highlights"] as? [Any] else {
            throw HighlightPersistenceError.invalidTopLevel
        }
        let version = versionNumber.intValue
        guard version == HighlightSchema.previousVersion
                || version == HighlightSchema.currentVersion else {
            throw HighlightPersistenceError.unsupportedSchema(found: version)
        }

        var highlights: [HighlightRecord] = []
        var invalidRecordCount = 0
        for recordObject in records {
            do {
                let recordData = try JSONSerialization.data(withJSONObject: recordObject)
                highlights.append(try Self.decoder.decode(HighlightRecord.self, from: recordData))
            } catch {
                invalidRecordCount += 1
            }
        }
        let snapshot = HighlightSnapshot(
            schemaVersion: HighlightSchema.currentVersion,
            highlights: highlights
        )
        if version == HighlightSchema.previousVersion, invalidRecordCount == 0 {
            // Migration is published only after the upgraded snapshot is safely on disk.
            try save(snapshot, fileManager: fileManager)
        }
        return LoadedHighlights(snapshot: snapshot, invalidRecordCount: invalidRecordCount)
    }

    func save(_ snapshot: HighlightSnapshot, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try SnapshotBackup.preservePrevious(at: fileURL, replacingWith: data, fileManager: fileManager) {
            let previous = try Self.decoder.decode(HighlightSnapshot.self, from: $0)
            guard [HighlightSchema.previousVersion, HighlightSchema.currentVersion].contains(previous.schemaVersion) else {
                throw HighlightPersistenceError.unsupportedSchema(found: previous.schemaVersion)
            }
        }
        try data.write(to: fileURL, options: .atomic)
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

/// Separate recovery storage: a failed primary save must not destroy the user's draft.
@MainActor
final class HighlightNoteDraftStore {
    private(set) var drafts: [UUID: String] = [:]
    private(set) var loadError: Error?
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            drafts = try JSONDecoder().decode([UUID: String].self, from: Data(contentsOf: fileURL))
        } catch {
            // Never overwrite a recovery file that we could not read.
            loadError = error
        }
    }

    static func applicationDefault() -> HighlightNoteDraftStore {
        let url = try? HighlightPersistence.applicationDefault().fileURL
            .deletingLastPathComponent().appendingPathComponent("note-drafts.json")
        return HighlightNoteDraftStore(fileURL: url)
    }

    func set(_ text: String, for id: UUID) { drafts[id] = text }
    @discardableResult
    func remove(_ id: UUID) -> Bool { drafts.removeValue(forKey: id) != nil }

    @discardableResult
    func persist() -> Bool {
        guard loadError == nil, let fileURL else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(drafts).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
