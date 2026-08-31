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
    /// 仅用于解码 v2–v4；迁移后统一为 creators。
    case authors
    /// 仅用于解码 v2–v4；迁移后统一为 issuedDate。
    case year
    case itemType
    case creators
    case issuedDate
    case containerTitle
    case volume
    case issue
    case pages
    case identifiers
    case publisher
    case place
    case edition
    case url
    case language
    case abstractText
}

struct BibliographicItemType: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let document = Self(rawValue: "document")
    static let journalArticle = Self(rawValue: "journalArticle")
    static let conferencePaper = Self(rawValue: "conferencePaper")
    static let preprint = Self(rawValue: "preprint")
    static let thesis = Self(rawValue: "thesis")
    static let book = Self(rawValue: "book")
    static let bookSection = Self(rawValue: "bookSection")
    static let report = Self(rawValue: "report")
}

struct BibliographicCreatorRole: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let author = Self(rawValue: "author")
    static let editor = Self(rawValue: "editor")
    static let translator = Self(rawValue: "translator")
}

struct BibliographicCreator: Codable, Equatable, Hashable, Sendable {
    var role: BibliographicCreatorRole
    var givenName: String?
    var familyName: String?
    var literalName: String?

    init(
        role: BibliographicCreatorRole,
        givenName: String? = nil,
        familyName: String? = nil,
        literalName: String? = nil
    ) {
        self.role = role
        self.givenName = Self.normalized(givenName)
        self.familyName = Self.normalized(familyName)
        self.literalName = Self.normalized(literalName)
    }

    var displayName: String? {
        if let literalName { return literalName }
        let joined = [givenName, familyName].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct BibliographicDate: Codable, Equatable, Hashable, Sendable {
    var sourceText: String?
    var year: Int?

    init(sourceText: String? = nil, year: Int? = nil) {
        let trimmed = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.year = year
    }
}

struct BibliographicIdentifierKind: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let doi = Self(rawValue: "doi")
    static let isbn = Self(rawValue: "isbn")
    static let issn = Self(rawValue: "issn")
    static let arXiv = Self(rawValue: "arxiv")
}

struct BibliographicIdentifier: Codable, Equatable, Hashable, Sendable {
    var kind: BibliographicIdentifierKind
    var displayValue: String
    var comparisonValue: String

    init(kind: BibliographicIdentifierKind, displayValue: String, comparisonValue: String? = nil) {
        let display = displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.displayValue = display
        self.comparisonValue = comparisonValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Self.defaultComparisonValue(for: display, kind: kind)
    }

    private static func defaultComparisonValue(
        for value: String,
        kind: BibliographicIdentifierKind
    ) -> String {
        guard kind == .doi else { return value.lowercased() }
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            break
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BibliographicMetadata: Codable, Equatable, Sendable {
    var itemType: BibliographicItemType
    var title: String
    var creators: [BibliographicCreator]
    var issuedDate: BibliographicDate?
    var containerTitle: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var identifiers: [BibliographicIdentifier]
    var publisher: String?
    var place: String?
    var edition: String?
    var url: String?
    var language: String?
    var abstractText: String?

    init(
        itemType: BibliographicItemType = .document,
        title: String,
        creators: [BibliographicCreator] = [],
        issuedDate: BibliographicDate? = nil,
        containerTitle: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        identifiers: [BibliographicIdentifier] = [],
        publisher: String? = nil,
        place: String? = nil,
        edition: String? = nil,
        url: String? = nil,
        language: String? = nil,
        abstractText: String? = nil
    ) {
        self.itemType = itemType
        self.title = title
        self.creators = creators
        self.issuedDate = issuedDate
        self.containerTitle = containerTitle
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.identifiers = identifiers
        self.publisher = publisher
        self.place = place
        self.edition = edition
        self.url = url
        self.language = language
        self.abstractText = abstractText
    }

    var authorsDisplay: String? {
        let names = creators
            .filter { $0.role == .author }
            .compactMap(\.displayName)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    mutating func setLegacyAuthors(_ value: String?) {
        creators.removeAll { $0.role == .author }
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return
        }
        creators.insert(BibliographicCreator(role: .author, literalName: trimmed), at: 0)
    }
}

struct FolderImportSource: Codable, Equatable, Hashable, Sendable {
    var rootVolumeUUID: String?
    var rootDocumentIdentifier: Int?
    var relativePath: String
    /// 只在根目录来源（relativePath 为空）保存；不参与来源身份比较。
    var rootBookmarkData: Data?

    init(
        rootVolumeUUID: String?,
        rootDocumentIdentifier: Int?,
        relativePath: String,
        rootBookmarkData: Data? = nil
    ) {
        self.rootVolumeUUID = rootVolumeUUID
        self.rootDocumentIdentifier = rootDocumentIdentifier
        self.relativePath = relativePath
        self.rootBookmarkData = rootBookmarkData
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootVolumeUUID == rhs.rootVolumeUUID
            && lhs.rootDocumentIdentifier == rhs.rootDocumentIdentifier
            && lhs.relativePath == rhs.relativePath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rootVolumeUUID)
        hasher.combine(rootDocumentIdentifier)
        hasher.combine(relativePath)
    }
}

struct ZoteroLibraryIdentity: Codable, Equatable, Hashable, Sendable {
    var type: String
    var id: Int
}

enum ImportSourceIdentity: Codable, Equatable, Hashable, Sendable {
    case folder(FolderImportSource)
    case zoteroCollection(library: ZoteroLibraryIdentity, collectionKey: String, serverID: String?)
    case zoteroAttachment(
        library: ZoteroLibraryIdentity,
        parentItemKey: String?,
        attachmentKey: String,
        serverID: String?
    )
}

struct PDFContentFingerprint: Codable, Equatable, Hashable, Sendable {
    var sha256: String
    var byteCount: Int64
    var modificationDate: Date

    init(sha256: String, byteCount: Int64, modificationDate: Date) {
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

struct CollectionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var parentID: UUID?
    var importSources: [ImportSourceIdentity]
    var sourceName: String?
    var wasManuallyOrganized: Bool

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        parentID: UUID? = nil,
        importSources: [ImportSourceIdentity] = [],
        sourceName: String? = nil,
        wasManuallyOrganized: Bool = false
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.parentID = parentID
        self.importSources = Array(Set(importSources)).sorted(by: ImportSourceOrdering.less)
        self.sourceName = sourceName
        self.wasManuallyOrganized = wasManuallyOrganized
    }
}

enum ImportSourceOrdering {
    static func less(_ lhs: ImportSourceIdentity, _ rhs: ImportSourceIdentity) -> Bool {
        key(lhs) < key(rhs)
    }

    static func key(_ source: ImportSourceIdentity) -> String {
        switch source {
        case let .folder(folder):
            return "folder|\(folder.rootVolumeUUID ?? "")|\(folder.rootDocumentIdentifier.map(String.init) ?? "")|\(folder.relativePath)"
        case let .zoteroCollection(library, collectionKey, serverID):
            return "zotero-collection|\(library.type)|\(library.id)|\(collectionKey)|\(serverID ?? "")"
        case let .zoteroAttachment(library, parentItemKey, attachmentKey, serverID):
            return "zotero-attachment|\(library.type)|\(library.id)|\(parentItemKey ?? "")|\(attachmentKey)|\(serverID ?? "")"
        }
    }
}

enum ImportSourceRules {
    static func isValid(_ source: ImportSourceIdentity) -> Bool {
        switch source {
        case let .folder(folder):
            let path = folder.relativePath
            guard !(path as NSString).isAbsolutePath else { return false }
            if let bookmark = folder.rootBookmarkData, bookmark.isEmpty { return false }
            if path.isEmpty { return true }
            guard folder.rootBookmarkData == nil else { return false }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        case let .zoteroCollection(library, collectionKey, _):
            return valid(library: library) && validZoteroKey(collectionKey)
        case let .zoteroAttachment(library, parentItemKey, attachmentKey, _):
            return valid(library: library)
                && parentItemKey.map(validZoteroKey) != false
                && validZoteroKey(attachmentKey)
        }
    }

    private static func valid(library: ZoteroLibraryIdentity) -> Bool {
        (library.type == "user" || library.type == "group") && library.id >= 0
    }

    private static func validZoteroKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == key
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
                return paper.searchableMetadataValues.contains { matches(query, in: $0) }
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
            let titleOrder = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
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
                let titleOrder = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
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

/// v5 文献记录。每条记录继续严格对应一个 PDF。
struct PaperRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var volumeUUID: String?
    var documentIdentifier: Int?
    var bookmarkData: Data
    var fallbackPath: String
    var originalFileName: String
    var metadata: BibliographicMetadata
    var attachmentLabel: String?
    var contentFingerprint: PDFContentFingerprint?
    var importSources: [ImportSourceIdentity]
    var lastImportedMetadata: BibliographicMetadata?
    var manuallyEditedFields: Set<MetadataField>
    var didReadAutoMetadata: Bool
    let dateAdded: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int
    var readingStatus: ReadingStatus
    /// 序列化使用稳定数组，调用方按集合语义读写并保持去重排序。
    var collectionIDs: [UUID]

    /// v1–v4 调用点的兼容门面；Codable 只持久化 metadata 中的唯一标题。
    var title: String {
        get { metadata.title }
        set { metadata.title = newValue }
    }

    var authors: String? {
        get { metadata.authorsDisplay }
        set { metadata.setLegacyAuthors(newValue) }
    }

    var year: Int? {
        get { metadata.issuedDate?.year }
        set {
            if let newValue {
                var date = metadata.issuedDate ?? BibliographicDate()
                date.year = newValue
                metadata.issuedDate = date
            } else if metadata.issuedDate?.sourceText == nil {
                metadata.issuedDate = nil
            } else {
                metadata.issuedDate?.year = nil
            }
        }
    }

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

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : title
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

    var searchableMetadataValues: [String] {
        var values = [displayTitle, originalFileName]
        values.append(contentsOf: metadata.creators.compactMap(\.displayName))
        if let sourceText = metadata.issuedDate?.sourceText { values.append(sourceText) }
        if let year { values.append(String(year)) }
        if let containerTitle = metadata.containerTitle { values.append(containerTitle) }
        if let url = metadata.url { values.append(url) }
        for identifier in metadata.identifiers {
            values.append(identifier.displayValue)
            values.append(identifier.comparisonValue)
        }
        return values
    }

    /// 只暴露来源类型和数量，不显示路径、Zotero key 或 server ID。
    var importSourceSummary: String {
        let folderCount = importSources.reduce(into: 0) { count, source in
            if case .folder = source { count += 1 }
        }
        let zoteroCount = importSources.count - folderCount
        switch (folderCount, zoteroCount) {
        case (0, 0): return "手动导入"
        case (_, 0): return "文件夹导入 · \(folderCount) 个来源"
        case (0, _): return "Zotero 迁移 · \(zoteroCount) 个来源"
        default: return "文件夹与 Zotero · \(importSources.count) 个来源"
        }
    }

    /// 导入与迁移共用：标题以文件名起步，等待一次性自动补全或用户编辑。
    init(
        id: UUID = UUID(),
        identity: FileIdentity,
        bookmarkData: Data,
        initialTitle: String,
        originalFileName: String? = nil,
        dateAdded: Date = Date(),
        lastOpenedAt: Date? = nil,
        lastPageIndex: Int = 0,
        readingStatus: ReadingStatus = .unread,
        collectionIDs: [UUID] = [],
        metadata: BibliographicMetadata? = nil,
        attachmentLabel: String? = nil,
        contentFingerprint: PDFContentFingerprint? = nil,
        importSources: [ImportSourceIdentity] = [],
        lastImportedMetadata: BibliographicMetadata? = nil
    ) {
        self.id = id
        self.volumeUUID = identity.volumeUUID
        self.documentIdentifier = identity.documentIdentifier
        self.bookmarkData = bookmarkData
        self.fallbackPath = identity.fallbackPath
        self.originalFileName = originalFileName ?? initialTitle
        self.metadata = metadata ?? BibliographicMetadata(title: initialTitle)
        self.attachmentLabel = attachmentLabel
        self.contentFingerprint = contentFingerprint
        self.importSources = Array(Set(importSources)).sorted(by: ImportSourceOrdering.less)
        self.lastImportedMetadata = lastImportedMetadata
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
        title = trimmed
        manuallyEditedFields.insert(.title)
    }

    mutating func setManualAuthors(_ newValue: String?) {
        let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        authors = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // 清空同样是用户决定，之后不得被自动结果复活。
        manuallyEditedFields.remove(.authors)
        manuallyEditedFields.insert(.creators)
    }

    mutating func setManualYear(_ newValue: Int?) {
        year = newValue
        manuallyEditedFields.remove(.year)
        manuallyEditedFields.insert(.issuedDate)
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
        let creatorsWereEdited = manuallyEditedFields.contains(.creators)
            || manuallyEditedFields.contains(.authors)
        if !creatorsWereEdited, authors == nil,
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
