import Foundation

enum BibliographicMetadataDraftError: LocalizedError, Equatable {
    case emptyItemType
    case invalidYear
    case emptyCreator
    case emptyIdentifier
    case invalidDOI
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .emptyItemType: "条目类型不能为空。"
        case .invalidYear: "年份必须是整数，或留空。"
        case .emptyCreator: "每位创作者至少需要姓名或团体名称。"
        case .emptyIdentifier: "标识符的类型和值都不能为空。"
        case .invalidDOI: "DOI 格式无效。"
        case .invalidURL: "URL 必须是有效的 HTTP 或 HTTPS 地址。"
        }
    }
}

struct BibliographicCreatorDraft: Identifiable, Equatable {
    let id: UUID
    var role: String
    var givenName: String
    var familyName: String
    var literalName: String

    init(id: UUID = UUID(), creator: BibliographicCreator? = nil) {
        self.id = id
        self.role = creator?.role.rawValue ?? BibliographicCreatorRole.author.rawValue
        self.givenName = creator?.givenName ?? ""
        self.familyName = creator?.familyName ?? ""
        self.literalName = creator?.literalName ?? ""
    }

    func creator() throws -> BibliographicCreator {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = BibliographicCreator(
            role: BibliographicCreatorRole(rawValue: role.isEmpty ? "other" : role),
            givenName: givenName,
            familyName: familyName,
            literalName: literalName
        )
        guard creator.displayName != nil else {
            throw BibliographicMetadataDraftError.emptyCreator
        }
        return creator
    }
}

struct BibliographicIdentifierDraft: Identifiable, Equatable {
    let id: UUID
    var kind: String
    var value: String

    init(id: UUID = UUID(), identifier: BibliographicIdentifier? = nil) {
        self.id = id
        self.kind = identifier?.kind.rawValue ?? BibliographicIdentifierKind.doi.rawValue
        self.value = identifier?.displayValue ?? ""
    }

    func identifier() throws -> BibliographicIdentifier {
        let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !value.isEmpty else {
            throw BibliographicMetadataDraftError.emptyIdentifier
        }
        let identifier = BibliographicIdentifier(
            kind: BibliographicIdentifierKind(rawValue: kind),
            displayValue: value
        )
        if identifier.kind == .doi {
            let normalized = identifier.comparisonValue
            let range = normalized.range(
                of: #"^10\.\d{4,9}/\S+$"#,
                options: .regularExpression
            )
            guard range?.lowerBound == normalized.startIndex,
                  range?.upperBound == normalized.endIndex else {
                throw BibliographicMetadataDraftError.invalidDOI
            }
        }
        return identifier
    }
}

struct BibliographicMetadataEditResult: Equatable {
    var metadata: BibliographicMetadata
    var attachmentLabel: String?
    var changedFields: Set<MetadataField>
}

enum BibliographicMetadataChanges {
    static func fields(
        from original: BibliographicMetadata,
        to updated: BibliographicMetadata
    ) -> Set<MetadataField> {
        var fields: Set<MetadataField> = []
        if original.itemType != updated.itemType { fields.insert(.itemType) }
        if original.title != updated.title { fields.insert(.title) }
        if original.creators != updated.creators { fields.insert(.creators) }
        if original.issuedDate != updated.issuedDate { fields.insert(.issuedDate) }
        if original.containerTitle != updated.containerTitle { fields.insert(.containerTitle) }
        if original.volume != updated.volume { fields.insert(.volume) }
        if original.issue != updated.issue { fields.insert(.issue) }
        if original.pages != updated.pages { fields.insert(.pages) }
        if original.identifiers != updated.identifiers { fields.insert(.identifiers) }
        if original.publisher != updated.publisher { fields.insert(.publisher) }
        if original.place != updated.place { fields.insert(.place) }
        if original.edition != updated.edition { fields.insert(.edition) }
        if original.url != updated.url { fields.insert(.url) }
        if original.language != updated.language { fields.insert(.language) }
        if original.abstractText != updated.abstractText { fields.insert(.abstractText) }
        return fields
    }
}

struct BibliographicMetadataDraft: Equatable {
    var itemType: String
    var title: String
    var creators: [BibliographicCreatorDraft]
    var dateText: String
    var yearText: String
    var containerTitle: String
    var volume: String
    var issue: String
    var pages: String
    var identifiers: [BibliographicIdentifierDraft]
    var publisher: String
    var place: String
    var edition: String
    var url: String
    var language: String
    var abstractText: String
    var attachmentLabel: String

    init(metadata: BibliographicMetadata, attachmentLabel: String? = nil) {
        itemType = metadata.itemType.rawValue
        title = metadata.title
        creators = metadata.creators.map { BibliographicCreatorDraft(creator: $0) }
        dateText = metadata.issuedDate?.sourceText ?? ""
        yearText = metadata.issuedDate?.year.map(String.init) ?? ""
        containerTitle = metadata.containerTitle ?? ""
        volume = metadata.volume ?? ""
        issue = metadata.issue ?? ""
        pages = metadata.pages ?? ""
        identifiers = metadata.identifiers.map { BibliographicIdentifierDraft(identifier: $0) }
        publisher = metadata.publisher ?? ""
        place = metadata.place ?? ""
        edition = metadata.edition ?? ""
        url = metadata.url ?? ""
        language = metadata.language ?? ""
        abstractText = metadata.abstractText ?? ""
        self.attachmentLabel = attachmentLabel ?? ""
    }

    func result(comparedWith original: BibliographicMetadata) throws -> BibliographicMetadataEditResult {
        let normalizedItemType = itemType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedItemType.isEmpty else {
            throw BibliographicMetadataDraftError.emptyItemType
        }
        let year: Int?
        switch PaperYearRules.parse(yearText) {
        case .empty: year = nil
        case let .value(value): year = value
        case .invalid: throw BibliographicMetadataDraftError.invalidYear
        }
        let mappedCreators = try creators.map { try $0.creator() }
        let mappedIdentifiers = try identifiers.map { try $0.identifier() }
        let normalizedDate = optional(dateText)
        let normalizedURL = optional(url)
        if let normalizedURL {
            guard let components = URLComponents(string: normalizedURL),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host?.isEmpty == false else {
                throw BibliographicMetadataDraftError.invalidURL
            }
        }
        let metadata = BibliographicMetadata(
            itemType: BibliographicItemType(rawValue: normalizedItemType),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            creators: mappedCreators,
            issuedDate: (normalizedDate == nil && year == nil)
                ? nil
                : BibliographicDate(sourceText: normalizedDate, year: year),
            containerTitle: optional(containerTitle),
            volume: optional(volume),
            issue: optional(issue),
            pages: optional(pages),
            identifiers: mappedIdentifiers,
            publisher: optional(publisher),
            place: optional(place),
            edition: optional(edition),
            url: normalizedURL,
            language: optional(language),
            abstractText: optional(abstractText)
        )
        return BibliographicMetadataEditResult(
            metadata: metadata,
            attachmentLabel: optional(attachmentLabel),
            changedFields: BibliographicMetadataChanges.fields(from: original, to: metadata)
        )
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
