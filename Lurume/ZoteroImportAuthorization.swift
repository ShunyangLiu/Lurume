import Foundation

enum ZoteroImportAuthorizationError: LocalizedError, Equatable, Sendable {
    case invalidDirectory
    case bookmarkUnavailable
    case sourceOutsideAuthorizedRoots
    case sourceReferenceNotAllowed
    case sourceTargetOverlap

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "所选位置不是可安全使用的普通文件夹。"
        case .bookmarkUnavailable:
            "无法保存所选文件夹的安全访问权限。"
        case .sourceOutsideAuthorizedRoots:
            "部分 Zotero PDF 不在已授权的来源目录内。"
        case .sourceReferenceNotAllowed:
            "Zotero PDF 是符号链接、Finder 替身或非普通文件，已拒绝访问。"
        case .sourceTargetOverlap:
            "来源目录与目标目录不能相同、互相包含或位于彼此内部。"
        }
    }
}

struct ZoteroAuthorizedDirectory: Equatable, Sendable {
    var selectedURL: URL
    var resolvedURL: URL
    var identity: FileIdentity
    var bookmarkData: Data
    var readOnly: Bool

    var displayName: String {
        let name = selectedURL.lastPathComponent
        return name.isEmpty ? "所选文件夹" : name
    }
}

struct ZoteroDirectoryBookmarkSet: Codable, Equatable, Sendable {
    var sourceBookmarks: [Data]
    var targetBookmark: Data?

    static let empty = Self(sourceBookmarks: [], targetBookmark: nil)
}

struct ZoteroDirectoryBookmarkStore: Sendable {
    let fileURL: URL

    func load(fileManager: FileManager = .default) throws -> ZoteroDirectoryBookmarkSet {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        return try JSONDecoder().decode(
            ZoteroDirectoryBookmarkSet.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(
        _ bookmarks: ZoteroDirectoryBookmarkSet,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(bookmarks).write(to: fileURL, options: .atomic)
    }
}

enum ZoteroPathAuthorization {
    static func authorizeDirectory(at selectedURL: URL, readOnly: Bool) throws
        -> ZoteroAuthorizedDirectory
    {
        let selected = selectedURL.standardizedFileURL
        let values = try selected.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
        ])
        guard values.isDirectory == true,
            values.isSymbolicLink != true,
            values.isAliasFile != true,
            values.isPackage != true
        else {
            throw ZoteroImportAuthorizationError.invalidDirectory
        }
        let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
        let bookmark: Data
        do {
            bookmark = try SecurityScopedFile.makeBookmark(for: selected, readOnly: readOnly)
        } catch {
            throw ZoteroImportAuthorizationError.bookmarkUnavailable
        }
        return ZoteroAuthorizedDirectory(
            selectedURL: selected,
            resolvedURL: resolved,
            identity: try FileIdentity(url: resolved),
            bookmarkData: bookmark,
            readOnly: readOnly
        )
    }

    static func restoreDirectory(bookmarkData: Data, readOnly: Bool) throws
        -> ZoteroAuthorizedDirectory
    {
        let resolved = try SecurityScopedFile.resolve(bookmarkData: bookmarkData)
        let didStartAccessing = resolved.url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { resolved.url.stopAccessingSecurityScopedResource() } }
        return try authorizeDirectory(at: resolved.url, readOnly: readOnly)
    }

    static func authorizedRoot(
        containing candidateURL: URL,
        roots: [ZoteroAuthorizedDirectory]
    ) throws -> ZoteroAuthorizedDirectory? {
        let candidate = candidateURL.standardizedFileURL
        let values = try candidate.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
        ])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.isAliasFile != true
        else {
            throw ZoteroImportAuthorizationError.sourceReferenceNotAllowed
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let identity = try FileIdentity(url: resolved)
        return roots.first { root in
            sameVolume(identity, root.identity) && isDescendant(resolved, of: root.resolvedURL)
        }
    }

    static func validateNoOverlap(
        sourceRoots: [ZoteroAuthorizedDirectory],
        target: ZoteroAuthorizedDirectory
    ) throws {
        for source in sourceRoots
        where
            isDescendant(target.resolvedURL, of: source.resolvedURL)
            || isDescendant(source.resolvedURL, of: target.resolvedURL)
        {
            throw ZoteroImportAuthorizationError.sourceTargetOverlap
        }
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let supportsCaseSensitiveNames =
            (try? root.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames) ?? true
        let candidateComponents = normalizedPathComponents(
            candidate,
            caseSensitive: supportsCaseSensitiveNames
        )
        let rootComponents = normalizedPathComponents(
            root,
            caseSensitive: supportsCaseSensitiveNames
        )
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func validateUnchangedDirectory(_ directory: ZoteroAuthorizedDirectory) throws {
        let selected = directory.selectedURL.standardizedFileURL
        let values = try selected.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
        ])
        let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
        guard values.isDirectory == true,
            values.isSymbolicLink != true,
            values.isAliasFile != true,
            values.isPackage != true,
            resolved == directory.resolvedURL,
            try FileIdentity(url: resolved).identifiesSameFile(as: directory.identity)
        else {
            throw ZoteroImportTransactionError.targetChanged
        }
    }

    static func sanitizedFileName(_ rawName: String, fallback: String = "Zotero PDF") -> String {
        let leaf = (rawName as NSString).lastPathComponent
        var result = sanitizedComponent(leaf)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = fallback }
        let stem =
            result.lowercased().hasSuffix(".pdf")
            ? String(result.dropLast(4))
            : result
        return String(stem.prefix(235)) + ".pdf"
    }

    static func sanitizedDirectoryName(_ rawName: String) -> String {
        var cleaned = sanitizedComponent((rawName as NSString).lastPathComponent)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Zotero 文库" : String(cleaned.prefix(240))
    }

    private static func sameVolume(_ lhs: FileIdentity, _ rhs: FileIdentity) -> Bool {
        guard let left = lhs.volumeUUID, let right = rhs.volumeUUID else { return true }
        return left == right
    }

    private static func normalizedPathComponents(_ url: URL, caseSensitive: Bool) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { component in
            let normalized = component.precomposedStringWithCanonicalMapping
            guard !caseSensitive else { return normalized }
            return normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
        return value.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
