import Foundation
import Darwin

/// Plaintext, device-local credentials. Never consults Keychain or UserDefaults.
struct LocalTranslationAPIKeyStore: TranslationAPIKeyStoring {
    let scope: String
    var fileURL: URL?

    func read() async throws -> String? {
        try await LocalTranslationCredentialFile.shared.read(scope: scope, at: resolvedURL())
    }

    func save(_ apiKey: String) async throws {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 16_384,
              !apiKey.contains(where: { $0.isNewline }) else {
            throw LocalTranslationCredentialError.invalidKey
        }
        try await LocalTranslationCredentialFile.shared.update(scope: scope, key: apiKey, at: resolvedURL())
    }

    func delete() async throws {
        try await LocalTranslationCredentialFile.shared.update(scope: scope, key: nil, at: resolvedURL())
    }

    private func resolvedURL() throws -> URL {
        if let fileURL { return fileURL }
        return try LibraryPersistence.applicationDefault().fileURL.deletingLastPathComponent()
            .appendingPathComponent("translation-credentials", isDirectory: true)
            .appendingPathComponent("keys.json")
    }
}

enum LocalTranslationCredentialError: LocalizedError {
    case invalidKey, inaccessible, invalidFile

    var errorDescription: String? {
        switch self {
        case .invalidKey: "API Key 不能为空、包含换行或超过 16 KiB。"
        case .inaccessible: "无法访问本地 API Key 文件；原有配置未更改。"
        case .invalidFile: "本地 API Key 文件损坏、版本不兼容或权限异常，未覆盖原有文件。"
        }
    }
}

/// Serializes read-modify-write across all provider-scoped stores in this process.
private actor LocalTranslationCredentialFile {
    static let shared = LocalTranslationCredentialFile()
    private struct Snapshot: Codable {
        var version = 1
        var keys: [String: String] = [:]
    }

    func read(scope: String, at url: URL) throws -> String? {
        try load(at: url).keys[scope]
    }

    func update(scope: String, key: String?, at url: URL) throws {
        var snapshot = try load(at: url)
        guard snapshot.keys[scope] != key else { return }
        snapshot.keys[scope] = key
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw LocalTranslationCredentialError.invalidFile }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateDirectory(directory)
        let temporaryURL = directory.appendingPathComponent(".keys-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalTranslationCredentialError.inaccessible }
        defer {
            close(descriptor)
            // Only the exact temporary file created by this write is removed.
            unlink(temporaryURL.path)
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LocalTranslationCredentialError.inaccessible }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporaryURL.path, url.path) == 0 else {
            throw LocalTranslationCredentialError.inaccessible
        }
    }

    private func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              chmod(url.path, 0o700) == 0 else {
            throw LocalTranslationCredentialError.invalidFile
        }
    }

    private func load(at url: URL) throws -> Snapshot {
        var directoryInfo = stat()
        let directory = url.deletingLastPathComponent()
        if lstat(directory.path, &directoryInfo) == 0 {
            try validateDirectory(directory)
        } else if errno != ENOENT {
            throw LocalTranslationCredentialError.inaccessible
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Snapshot() }
            throw LocalTranslationCredentialError.inaccessible
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size <= 1_048_576,
              fchmod(descriptor, 0o600) == 0 else {
            throw LocalTranslationCredentialError.invalidFile
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw LocalTranslationCredentialError.inaccessible }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 1_048_576 else { throw LocalTranslationCredentialError.invalidFile }
        }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { throw LocalTranslationCredentialError.invalidFile }
        return snapshot
    }
}
