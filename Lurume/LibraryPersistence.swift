import Foundation

enum LibraryPersistenceError: LocalizedError, Equatable {
    case unsupportedSchema(found: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found, expected):
            "文献库格式版本为 \(found)，当前原型只支持版本 \(expected)。"
        }
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

    func load(fileManager: FileManager = .default) throws -> LibrarySnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        let snapshot = try Self.decoder.decode(LibrarySnapshot.self, from: data)
        guard snapshot.schemaVersion == LibrarySchema.currentVersion else {
            throw LibraryPersistenceError.unsupportedSchema(
                found: snapshot.schemaVersion,
                expected: LibrarySchema.currentVersion
            )
        }
        return snapshot
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
