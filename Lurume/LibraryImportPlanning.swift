import Foundation

enum CollectionHierarchyIssue: Error, Equatable, Sendable {
    case missingParent(collectionID: UUID, parentID: UUID)
    case cycle(collectionID: UUID)
    case duplicateSiblingName(parentID: UUID?, name: String)
}

struct CollectionDeletionCandidate: Equatable, Sendable {
    let removedCollections: [CollectionRecord]
    let updatedPapers: [PaperRecord]
    let affectedPaperIDs: Set<UUID>

    var affectedPaperCount: Int {
        affectedPaperIDs.count
    }

    init(removedCollections: [CollectionRecord], updatedPapers: [PaperRecord], originalPapers: [PaperRecord]) {
        self.removedCollections = removedCollections
        self.updatedPapers = updatedPapers
        self.affectedPaperIDs = Set(zip(originalPapers, updatedPapers).compactMap { original, updated in
            original.collectionIDs == updated.collectionIDs ? nil : original.id
        })
    }
}

enum CollectionHierarchy {
    static func validationIssue(in collections: [CollectionRecord]) -> CollectionHierarchyIssue? {
        let byID = Dictionary(
            collections.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for collection in collections {
            if let parentID = collection.parentID, byID[parentID] == nil {
                return .missingParent(collectionID: collection.id, parentID: parentID)
            }
        }

        for collection in collections {
            var visited: Set<UUID> = [collection.id]
            var next = collection.parentID
            while let current = next {
                guard visited.insert(current).inserted else {
                    return .cycle(collectionID: collection.id)
                }
                next = byID[current]?.parentID
            }
        }

        var siblingNames: [UUID?: Set<String>] = [:]
        for collection in collections {
            let key = CollectionNameRules.comparisonKey(collection.name)
            if siblingNames[collection.parentID, default: []].contains(key) {
                return .duplicateSiblingName(parentID: collection.parentID, name: collection.name)
            }
            siblingNames[collection.parentID, default: []].insert(key)
        }
        return nil
    }

    static func descendantIDs(of collectionID: UUID, in collections: [CollectionRecord]) -> Set<UUID> {
        let children = Dictionary(grouping: collections, by: \.parentID)
        var result: Set<UUID> = []
        var pending = [collectionID]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: (children[current] ?? []).map(\.id))
        }
        return result
    }

    static func recursivePaperIDs(
        in collectionID: UUID,
        papers: [PaperRecord],
        collections: [CollectionRecord]
    ) -> Set<UUID> {
        let collectionIDs = descendantIDs(of: collectionID, in: collections)
        return Set(papers.lazy.filter { paper in
            paper.collectionIDs.contains(where: collectionIDs.contains)
        }.map(\.id))
    }

    static func canMove(
        collectionID: UUID,
        to newParentID: UUID?,
        in collections: [CollectionRecord]
    ) -> Bool {
        guard collections.contains(where: { $0.id == collectionID }) else { return false }
        guard let newParentID else { return true }
        guard collections.contains(where: { $0.id == newParentID }) else { return false }
        return !descendantIDs(of: collectionID, in: collections).contains(newParentID)
    }

    static func deletionCandidate(
        for collectionID: UUID,
        papers: [PaperRecord],
        collections: [CollectionRecord]
    ) -> CollectionDeletionCandidate? {
        guard collections.contains(where: { $0.id == collectionID }) else { return nil }
        let removedIDs = descendantIDs(of: collectionID, in: collections)
        let removed = collections.filter { removedIDs.contains($0.id) }
        let updated = papers.map { paper -> PaperRecord in
            var paper = paper
            paper.collectionIDs.removeAll(where: removedIDs.contains)
            return paper
        }
        return CollectionDeletionCandidate(
            removedCollections: removed,
            updatedPapers: updated,
            originalPapers: papers
        )
    }
}

enum ImportDuplicateReason: Equatable, Sendable {
    case source
    case fileIdentity
    case contentSHA256
}

enum ImportDisposition: Equatable, Sendable {
    case create
    case reuse(paperID: UUID, reason: ImportDuplicateReason)
    case sourceContentChanged(paperID: UUID)
}

enum ImportDeduplicator {
    static func classify(
        source: ImportSourceIdentity,
        identity: FileIdentity?,
        fingerprint: PDFContentFingerprint?,
        existingPapers: [PaperRecord]
    ) -> ImportDisposition {
        if let matched = existingPapers.first(where: { $0.importSources.contains(source) }) {
            if let oldSHA = matched.contentFingerprint?.sha256,
               let newSHA = fingerprint?.sha256,
               oldSHA != newSHA {
                return .sourceContentChanged(paperID: matched.id)
            }
            return .reuse(paperID: matched.id, reason: .source)
        }
        if let identity,
           let matched = existingPapers.first(where: { $0.identity.identifiesSameFile(as: identity) }) {
            return .reuse(paperID: matched.id, reason: .fileIdentity)
        }
        if let sha256 = fingerprint?.sha256,
           let matched = existingPapers.first(where: { $0.contentFingerprint?.sha256 == sha256 }) {
            return .reuse(paperID: matched.id, reason: .contentSHA256)
        }
        return .create
    }
}

struct MetadataImportPreview: Equatable, Sendable {
    var proposedMetadata: BibliographicMetadata
    var changedFields: Set<MetadataField>
    var blockedManualFields: Set<MetadataField>
}

enum MetadataImportMerger {
    static func preview(
        current: BibliographicMetadata,
        imported: BibliographicMetadata,
        manuallyEditedFields: Set<MetadataField>
    ) -> MetadataImportPreview {
        var proposed = current
        var changed: Set<MetadataField> = []
        var blocked: Set<MetadataField> = []

        apply(
            field: .itemType,
            differs: current.itemType != imported.itemType,
            isManual: manuallyEditedFields.contains(.itemType),
            changed: &changed,
            blocked: &blocked
        ) { proposed.itemType = imported.itemType }
        apply(
            field: .title,
            differs: current.title != imported.title,
            isManual: manuallyEditedFields.contains(.title),
            changed: &changed,
            blocked: &blocked
        ) { proposed.title = imported.title }
        apply(
            field: .creators,
            differs: current.creators != imported.creators,
            isManual: manuallyEditedFields.contains(.creators) || manuallyEditedFields.contains(.authors),
            changed: &changed,
            blocked: &blocked
        ) { proposed.creators = imported.creators }
        apply(
            field: .issuedDate,
            differs: current.issuedDate != imported.issuedDate,
            isManual: manuallyEditedFields.contains(.issuedDate) || manuallyEditedFields.contains(.year),
            changed: &changed,
            blocked: &blocked
        ) { proposed.issuedDate = imported.issuedDate }
        apply(field: .containerTitle, current: current.containerTitle, imported: imported.containerTitle,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.containerTitle = imported.containerTitle
        }
        apply(field: .volume, current: current.volume, imported: imported.volume,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.volume = imported.volume
        }
        apply(field: .issue, current: current.issue, imported: imported.issue,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.issue = imported.issue
        }
        apply(field: .pages, current: current.pages, imported: imported.pages,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.pages = imported.pages
        }
        apply(
            field: .identifiers,
            differs: current.identifiers != imported.identifiers,
            isManual: manuallyEditedFields.contains(.identifiers),
            changed: &changed,
            blocked: &blocked
        ) { proposed.identifiers = imported.identifiers }
        apply(field: .publisher, current: current.publisher, imported: imported.publisher,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.publisher = imported.publisher
        }
        apply(field: .place, current: current.place, imported: imported.place,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.place = imported.place
        }
        apply(field: .edition, current: current.edition, imported: imported.edition,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.edition = imported.edition
        }
        apply(field: .url, current: current.url, imported: imported.url,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.url = imported.url
        }
        apply(field: .language, current: current.language, imported: imported.language,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.language = imported.language
        }
        apply(field: .abstractText, current: current.abstractText, imported: imported.abstractText,
              manual: manuallyEditedFields, changed: &changed, blocked: &blocked) {
            proposed.abstractText = imported.abstractText
        }
        return MetadataImportPreview(
            proposedMetadata: proposed,
            changedFields: changed,
            blockedManualFields: blocked
        )
    }

    private static func apply(
        field: MetadataField,
        current: String?,
        imported: String?,
        manual: Set<MetadataField>,
        changed: inout Set<MetadataField>,
        blocked: inout Set<MetadataField>,
        update: () -> Void
    ) {
        apply(
            field: field,
            differs: current != imported,
            isManual: manual.contains(field),
            changed: &changed,
            blocked: &blocked,
            update: update
        )
    }

    private static func apply(
        field: MetadataField,
        differs: Bool,
        isManual: Bool,
        changed: inout Set<MetadataField>,
        blocked: inout Set<MetadataField>,
        update: () -> Void
    ) {
        guard differs else { return }
        if isManual {
            blocked.insert(field)
        } else {
            changed.insert(field)
            update()
        }
    }
}

struct PlannedImportCollection: Equatable, Sendable {
    var source: ImportSourceIdentity
    var name: String
    var parentSource: ImportSourceIdentity?
}

struct PlannedPaperImport: Equatable, Sendable {
    var source: ImportSourceIdentity
    var identity: FileIdentity?
    var originalFileName: String
    var metadata: BibliographicMetadata
    var attachmentLabel: String?
    var fingerprint: PDFContentFingerprint?
    var collectionSources: [ImportSourceIdentity]
    var disposition: ImportDisposition
}

struct LibraryImportPlan: Equatable, Sendable {
    var collections: [PlannedImportCollection]
    var papers: [PlannedPaperImport]
}

struct FolderPDFDescriptor: Equatable, Sendable {
    var source: ImportSourceIdentity
    var identity: FileIdentity
    var originalFileName: String
    var propertyMetadata: PaperMetadata?
    var fingerprint: PDFContentFingerprint?
}

struct FolderDirectoryDescriptor: Equatable, Sendable {
    var source: ImportSourceIdentity
    var name: String
    var pdfs: [FolderPDFDescriptor]
    var children: [FolderDirectoryDescriptor]
}

enum FolderImportPlanner {
    static func plan(
        root: FolderDirectoryDescriptor,
        existingPapers: [PaperRecord]
    ) -> LibraryImportPlan {
        let result = planDirectory(root, parentSource: nil, existingPapers: existingPapers)
        return LibraryImportPlan(collections: result.collections, papers: result.papers)
    }

    private static func planDirectory(
        _ directory: FolderDirectoryDescriptor,
        parentSource: ImportSourceIdentity?,
        existingPapers: [PaperRecord]
    ) -> LibraryImportPlan {
        let childPlans = directory.children.map {
            planDirectory($0, parentSource: directory.source, existingPapers: existingPapers)
        }
        let childCollections = childPlans.flatMap(\.collections)
        let childPapers = childPlans.flatMap(\.papers)
        guard !directory.pdfs.isEmpty || !childPapers.isEmpty else {
            return LibraryImportPlan(collections: [], papers: [])
        }

        let ownPapers = directory.pdfs.map { descriptor in
            PlannedPaperImport(
                source: descriptor.source,
                identity: descriptor.identity,
                originalFileName: descriptor.originalFileName,
                metadata: candidateMetadata(for: descriptor),
                attachmentLabel: nil,
                fingerprint: descriptor.fingerprint,
                collectionSources: [directory.source],
                disposition: ImportDeduplicator.classify(
                    source: descriptor.source,
                    identity: descriptor.identity,
                    fingerprint: descriptor.fingerprint,
                    existingPapers: existingPapers
                )
            )
        }
        let ownCollection = PlannedImportCollection(
            source: directory.source,
            name: directory.name,
            parentSource: parentSource
        )
        return LibraryImportPlan(
            collections: [ownCollection] + childCollections,
            papers: ownPapers + childPapers
        )
    }

    private static func candidateMetadata(for descriptor: FolderPDFDescriptor) -> BibliographicMetadata {
        let title = PaperTitleRules.usablePropertyTitle(
            descriptor.propertyMetadata?.title,
            comparingAgainstFileName: descriptor.originalFileName
        ) ?? (descriptor.originalFileName as NSString).deletingPathExtension
        var metadata = BibliographicMetadata(title: title)
        metadata.setLegacyAuthors(descriptor.propertyMetadata?.authors)
        return metadata
    }
}

struct ZoteroCollectionDescriptor: Equatable, Sendable {
    var source: ImportSourceIdentity
    var name: String
    var parentSource: ImportSourceIdentity?
}

struct ZoteroAttachmentDescriptor: Equatable, Sendable {
    var source: ImportSourceIdentity
    var identity: FileIdentity?
    var originalFileName: String
    var label: String?
    var propertyMetadata: PaperMetadata?
    var fingerprint: PDFContentFingerprint?
}

struct ZoteroCreatorDescriptor: Equatable, Sendable {
    var creatorType: String
    var firstName: String?
    var lastName: String?
    var name: String?
}

struct ZoteroItemMetadataDescriptor: Equatable, Sendable {
    var itemType: String
    var title: String
    var creators: [ZoteroCreatorDescriptor]
    var dateText: String?
    var parsedYear: Int?
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

    func mappedMetadata() -> BibliographicMetadata {
        BibliographicMetadata(
            itemType: BibliographicItemType(rawValue: itemType),
            title: title,
            creators: creators.map {
                BibliographicCreator(
                    role: BibliographicCreatorRole(rawValue: $0.creatorType),
                    givenName: $0.firstName,
                    familyName: $0.lastName,
                    literalName: $0.name
                )
            },
            issuedDate: (dateText == nil && parsedYear == nil)
                ? nil
                : BibliographicDate(sourceText: dateText, year: parsedYear),
            containerTitle: containerTitle,
            volume: volume,
            issue: issue,
            pages: pages,
            identifiers: identifiers,
            publisher: publisher,
            place: place,
            edition: edition,
            url: url,
            language: language,
            abstractText: abstractText
        )
    }
}

struct ZoteroItemDescriptor: Equatable, Sendable {
    var metadata: ZoteroItemMetadataDescriptor?
    var collectionSources: [ImportSourceIdentity]
    var attachments: [ZoteroAttachmentDescriptor]
}

enum ZoteroImportPlanner {
    static func plan(
        collections: [ZoteroCollectionDescriptor],
        items: [ZoteroItemDescriptor],
        existingPapers: [PaperRecord]
    ) -> LibraryImportPlan {
        let papers = items.flatMap { item in
            item.attachments.map { attachment in
                PlannedPaperImport(
                    source: attachment.source,
                    identity: attachment.identity,
                    originalFileName: attachment.originalFileName,
                    metadata: metadata(for: attachment, parent: item.metadata),
                    attachmentLabel: normalized(attachment.label),
                    fingerprint: attachment.fingerprint,
                    collectionSources: Array(Set(item.collectionSources)).sorted(by: ImportSourceOrdering.less),
                    disposition: ImportDeduplicator.classify(
                        source: attachment.source,
                        identity: attachment.identity,
                        fingerprint: attachment.fingerprint,
                        existingPapers: existingPapers
                    )
                )
            }
        }
        let needed = neededCollectionSources(for: papers, collections: collections)
        return LibraryImportPlan(
            collections: collections.filter { needed.contains($0.source) }.map {
                PlannedImportCollection(source: $0.source, name: $0.name, parentSource: $0.parentSource)
            },
            papers: papers
        )
    }

    private static func metadata(
        for attachment: ZoteroAttachmentDescriptor,
        parent: ZoteroItemMetadataDescriptor?
    ) -> BibliographicMetadata {
        if let parent { return parent.mappedMetadata() }
        let title = PaperTitleRules.usablePropertyTitle(
            attachment.propertyMetadata?.title,
            comparingAgainstFileName: attachment.originalFileName
        ) ?? normalized(attachment.label)
            ?? (attachment.originalFileName as NSString).deletingPathExtension
        var metadata = BibliographicMetadata(title: title)
        metadata.setLegacyAuthors(attachment.propertyMetadata?.authors)
        return metadata
    }

    private static func neededCollectionSources(
        for papers: [PlannedPaperImport],
        collections: [ZoteroCollectionDescriptor]
    ) -> Set<ImportSourceIdentity> {
        let parents = Dictionary(
            collections.map { ($0.source, $0.parentSource) },
            uniquingKeysWith: { first, _ in first }
        )
        var needed = Set(papers.flatMap(\.collectionSources))
        var pending = Array(needed)
        while let source = pending.popLast(), let parent = parents[source] ?? nil {
            if needed.insert(parent).inserted { pending.append(parent) }
        }
        return needed
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
