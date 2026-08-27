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

enum MetadataField: String, Codable, Hashable, Sendable, CaseIterable {
    case title
    case authors
    case year
}

enum PaperYearInput: Equatable, Sendable {
    case empty
    case value(Int)
    case invalid
}

enum PaperYearRules {
    static func parse(_ raw: String) -> PaperYearInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let year = Int(trimmed) else { return .invalid }
        return .value(year)
    }
}

/// PDF 文件自带的标题与作者属性读取结果。
struct PaperMetadata: Equatable, Sendable {
    let title: String?
    let authors: String?

    init(title: String?, authors: String?) {
        self.title = Self.normalized(title)
        self.authors = Self.normalized(authors)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

protocol PaperMetadataReading: Sendable {
    /// 读取文件自带的标题与作者属性。实现不得要求在主线程调用。
    func metadata(at url: URL) async -> PaperMetadata?
}

/// P1 标题判废规则：属性标题只有空白、或与文件名相同两种情况不可信，其余一律可信。
enum PaperTitleRules {
    static func usablePropertyTitle(
        _ raw: String?,
        comparingAgainstFileName fileName: String?
    ) -> String? {
        guard let usable = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !usable.isEmpty else {
            return nil
        }
        if let fileName {
            let nameOnly = (fileName as NSString).lastPathComponent
            if normalize(nameOnly) == normalize(usable) {
                return nil
            }
        }
        return usable
    }

    private static func normalize(_ value: String) -> String {
        var lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasSuffix(".pdf") {
            lowered.removeLast(4)
        }
        return lowered
    }
}

/// v2 文献记录。自动元数据只在导入时与存量库惰性补全时各读取一次。
struct PaperRecord: Identifiable, Codable, Equatable, Sendable {
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

    var identity: FileIdentity {
        FileIdentity(
            volumeUUID: volumeUUID,
            documentIdentifier: documentIdentifier,
            fallbackPath: fallbackPath
        )
    }

    var fallbackTitle: String {
        let stem = (originalFileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? originalFileName : stem
    }

    var librarySubtitle: String? {
        var segments: [String] = []
        if let authors = authors?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authors.isEmpty {
            segments.append(authors)
        }
        if let year {
            segments.append(String(year))
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    /// 导入与迁移共用：标题以文件名起步，等待一次性自动补全或用户编辑。
    init(
        id: UUID = UUID(),
        identity: FileIdentity,
        bookmarkData: Data,
        displayName: String,
        originalFileName: String? = nil,
        dateAdded: Date = Date(),
        lastOpenedAt: Date? = nil,
        lastPageIndex: Int = 0
    ) {
        self.id = id
        self.volumeUUID = identity.volumeUUID
        self.documentIdentifier = identity.documentIdentifier
        self.bookmarkData = bookmarkData
        self.fallbackPath = identity.fallbackPath
        self.originalFileName = originalFileName ?? displayName
        self.title = displayName
        self.authors = nil
        self.year = nil
        self.manuallyEditedFields = []
        self.didReadAutoMetadata = false
        self.dateAdded = dateAdded
        self.lastOpenedAt = lastOpenedAt
        self.lastPageIndex = max(0, lastPageIndex)
    }

    mutating func replaceFileReference(
        identity: FileIdentity,
        bookmarkData: Data,
        originalFileName: String
    ) {
        let previousFallbackTitle = fallbackTitle
        volumeUUID = identity.volumeUUID
        documentIdentifier = identity.documentIdentifier
        fallbackPath = identity.fallbackPath
        self.bookmarkData = bookmarkData
        self.originalFileName = originalFileName
        if !manuallyEditedFields.contains(.title), title == previousFallbackTitle {
            title = fallbackTitle
        }
    }

    /// 修复早期 v2 构建把回退标题误存为 originalFileName 的记录。
    @discardableResult
    mutating func synchronizeOriginalFileNameWithFallbackPath() -> Bool {
        let pathName = (fallbackPath as NSString).lastPathComponent
        guard !pathName.isEmpty, pathName != originalFileName else { return false }

        let previousFallbackTitle = fallbackTitle
        originalFileName = pathName
        if !manuallyEditedFields.contains(.title), title == previousFallbackTitle {
            title = fallbackTitle
        }
        return true
    }

    mutating func setManualTitle(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? fallbackTitle : trimmed
        manuallyEditedFields.insert(.title)
    }

    mutating func setManualAuthors(_ newValue: String?) {
        let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        authors = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // 清空同样是用户决定，之后不得被自动结果复活。
        manuallyEditedFields.insert(.authors)
    }

    mutating func setManualYear(_ newValue: Int?) {
        year = newValue
        manuallyEditedFields.insert(.year)
    }

    mutating func applyAutoMetadata(_ metadata: PaperMetadata?) {
        guard !didReadAutoMetadata else { return }
        didReadAutoMetadata = true

        guard let metadata else { return }
        let currentFileName = (fallbackPath as NSString).lastPathComponent
        if !manuallyEditedFields.contains(.title),
           let trustedTitle = PaperTitleRules.usablePropertyTitle(
            metadata.title,
            comparingAgainstFileName: currentFileName
           ) {
            title = trustedTitle
        }
        if !manuallyEditedFields.contains(.authors), authors == nil,
           let autoAuthors = metadata.authors {
            authors = autoAuthors
        }
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
