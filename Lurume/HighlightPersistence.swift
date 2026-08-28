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
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = applicationSupport
            .appendingPathComponent("Lurume", isDirectory: true)
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
