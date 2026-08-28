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

struct CollectionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }
}

enum CollectionNameRules {
    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func comparisonKey(_ name: String) -> String {
        trimmed(name)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
    }
}

enum LibrarySource: Hashable, Sendable, Identifiable {
    case all
    case unfiled
    case collection(UUID)

    var id: String {
        switch self {
        case .all: "all"
        case .unfiled: "unfiled"
        case let .collection(id): "collection:\(id.uuidString)"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case "all": self = .all
        case "unfiled": self = .unfiled
        default:
            let prefix = "collection:"
            guard persistedValue.hasPrefix(prefix),
                  let id = UUID(uuidString: String(persistedValue.dropFirst(prefix.count))) else {
                return nil
            }
            self = .collection(id)
        }
    }

    func includes(_ paper: PaperRecord) -> Bool {
        switch self {
        case .all:
            true
        case .unfiled:
            paper.collectionIDs.isEmpty
        case let .collection(id):
            paper.collectionIDs.contains(id)
        }
    }
}

enum CollectionMembershipState: Equatable, Sendable {
    case off
    case mixed
    case on
}

enum ReadingStatus: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case unread
    case reading
    case finished

    var id: Self { self }

    var next: Self {
        switch self {
        case .unread: .reading
        case .reading: .finished
        case .finished: .unread
        }
    }

    var title: String {
        switch self {
        case .unread: "未读"
        case .reading: "阅读中"
        case .finished: "已读完"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "circle"
        case .reading: "circle.lefthalf.filled"
        case .finished: "checkmark.circle.fill"
        }
    }
}

enum ReadingStatusFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case all
    case unread
    case reading
    case finished

    var id: Self { self }

    func includes(_ status: ReadingStatus) -> Bool {
        switch self {
        case .all: true
        case .unread: status == .unread
        case .reading: status == .reading
        case .finished: status == .finished
        }
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        case .reading: "阅读中"
        case .finished: "已读完"
        }
    }
}

enum LibrarySortOption: String, Hashable, Sendable, CaseIterable, Identifiable {
    case recentlyOpened
    case dateAdded
    case title
    case year

    var id: Self { self }

    var title: String {
        switch self {
        case .recentlyOpened: "最近打开"
        case .dateAdded: "添加时间"
        case .title: "标题"
        case .year: "年份"
        }
    }
}

enum LibraryQuery {
    static func apply(
        to papers: [PaperRecord],
        searchText rawQuery: String,
        status: ReadingStatusFilter,
        sort: LibrarySortOption
    ) -> [PaperRecord] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return papers
            .filter { status.includes($0.readingStatus) }
            .filter { paper in
                guard !query.isEmpty else { return true }
                return matches(query, in: paper.title)
                    || paper.authors.map { matches(query, in: $0) } == true
                    || matches(query, in: paper.originalFileName)
            }
            .sorted { orderedBefore($0, $1, by: sort) }
    }

    private static func matches(_ query: String, in value: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }

    private static func orderedBefore(
        _ lhs: PaperRecord,
        _ rhs: PaperRecord,
        by option: LibrarySortOption
    ) -> Bool {
        switch option {
        case .recentlyOpened:
            switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return dateAddedThenID(lhs, rhs)
            }
        case .dateAdded:
            return dateAddedThenID(lhs, rhs)
        case .title:
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return dateAddedThenID(lhs, rhs)
        case .year:
            switch (lhs.year, rhs.year) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return dateAddedThenID(lhs, rhs)
            }
        }
    }

    private static func dateAddedThenID(_ lhs: PaperRecord, _ rhs: PaperRecord) -> Bool {
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded > rhs.dateAdded
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
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

/// v4 文献记录。自动元数据只在导入时与存量库惰性补全时各读取一次。
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
    var readingStatus: ReadingStatus
    /// 序列化使用稳定数组，调用方按集合语义读写并保持去重排序。
    var collectionIDs: [UUID]

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
        lastPageIndex: Int = 0,
        readingStatus: ReadingStatus = .unread,
        collectionIDs: [UUID] = []
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
        self.readingStatus = readingStatus
        self.collectionIDs = Array(Set(collectionIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
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
    var collections: [CollectionRecord]
    var selectedPaperID: UUID?

    init(
        schemaVersion: Int,
        papers: [PaperRecord],
        collections: [CollectionRecord] = [],
        selectedPaperID: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.papers = papers
        self.collections = collections
        self.selectedPaperID = selectedPaperID
    }

    static let empty = LibrarySnapshot(
        schemaVersion: LibrarySchema.currentVersion,
        papers: [],
        collections: [],
        selectedPaperID: nil
    )
}
