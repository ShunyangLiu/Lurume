import Foundation
import XCTest
@testable import Lurume

final class P8ImportPlanningTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func folderSource(_ path: String) -> ImportSourceIdentity {
        .folder(FolderImportSource(
            rootVolumeUUID: "root-volume",
            rootDocumentIdentifier: 99,
            relativePath: path
        ))
    }

    private func identity(_ number: Int, path: String? = nil) -> FileIdentity {
        FileIdentity(
            volumeUUID: "volume",
            documentIdentifier: number,
            fallbackPath: path ?? "/fixture/\(number).pdf"
        )
    }

    private func fingerprint(_ character: Character) -> PDFContentFingerprint {
        PDFContentFingerprint(
            sha256: String(repeating: character, count: 64),
            byteCount: 1_024,
            modificationDate: fixedDate
        )
    }

    private func existingPaper(
        source: ImportSourceIdentity,
        identity: FileIdentity,
        fingerprint: PDFContentFingerprint
    ) -> PaperRecord {
        PaperRecord(
            identity: identity,
            bookmarkData: Data(),
            initialTitle: "Existing",
            contentFingerprint: fingerprint,
            importSources: [source]
        )
    }

    func testDeduplicationUsesSourceThenIdentityThenHashAndNeverMetadataOnly() {
        let sourceMatch = existingPaper(
            source: folderSource("source.pdf"),
            identity: identity(1),
            fingerprint: fingerprint("a")
        )
        let identityMatch = existingPaper(
            source: folderSource("identity-old.pdf"),
            identity: identity(2),
            fingerprint: fingerprint("b")
        )
        let hashMatch = existingPaper(
            source: folderSource("hash-old.pdf"),
            identity: identity(3),
            fingerprint: fingerprint("c")
        )
        let existing = [sourceMatch, identityMatch, hashMatch]

        XCTAssertEqual(
            ImportDeduplicator.classify(
                source: folderSource("source.pdf"),
                identity: identity(2),
                fingerprint: fingerprint("d"),
                existingPapers: existing
            ),
            .sourceContentChanged(paperID: sourceMatch.id)
        )
        XCTAssertEqual(
            ImportDeduplicator.classify(
                source: folderSource("identity-new.pdf"),
                identity: identity(2),
                fingerprint: fingerprint("c"),
                existingPapers: existing
            ),
            .reuse(paperID: identityMatch.id, reason: .fileIdentity)
        )
        XCTAssertEqual(
            ImportDeduplicator.classify(
                source: folderSource("hash-new.pdf"),
                identity: identity(4),
                fingerprint: fingerprint("c"),
                existingPapers: existing
            ),
            .reuse(paperID: hashMatch.id, reason: .contentSHA256)
        )
        XCTAssertEqual(
            ImportDeduplicator.classify(
                source: folderSource("new.pdf"),
                identity: identity(5),
                fingerprint: fingerprint("e"),
                existingPapers: existing
            ),
            .create
        )
    }

    func testFolderPlannerPrunesEmptyBranchesAndKeepsDirectMembership() throws {
        let rootSource = folderSource("")
        let usefulSource = folderSource("Useful")
        let emptySource = folderSource("Empty")
        let pdfSource = folderSource("Useful/paper.pdf")
        let descriptor = FolderDirectoryDescriptor(
            source: rootSource,
            name: "Library Root",
            pdfs: [],
            children: [
                FolderDirectoryDescriptor(
                    source: usefulSource,
                    name: "Useful",
                    pdfs: [
                        FolderPDFDescriptor(
                            source: pdfSource,
                            identity: identity(10),
                            originalFileName: "paper.pdf",
                            propertyMetadata: PaperMetadata(
                                title: "A Trusted PDF Title",
                                authors: "Research Team"
                            ),
                            fingerprint: fingerprint("f")
                        ),
                    ],
                    children: []
                ),
                FolderDirectoryDescriptor(
                    source: emptySource,
                    name: "Empty",
                    pdfs: [],
                    children: []
                ),
            ]
        )

        let plan = FolderImportPlanner.plan(root: descriptor, existingPapers: [])

        XCTAssertEqual(plan.collections.map(\.source), [rootSource, usefulSource])
        XCTAssertEqual(plan.collections[1].parentSource, rootSource)
        let paper = try XCTUnwrap(plan.papers.first)
        XCTAssertEqual(paper.metadata.title, "A Trusted PDF Title")
        XCTAssertEqual(paper.metadata.creators, [
            BibliographicCreator(role: .author, literalName: "Research Team"),
        ])
        XCTAssertEqual(paper.collectionSources, [usefulSource])
        XCTAssertEqual(paper.disposition, .create)
    }

    func testFolderPlannerRejectsFilenameLikePropertyTitleAndFallsBackToStem() throws {
        let source = folderSource("")
        let descriptor = FolderDirectoryDescriptor(
            source: source,
            name: "Root",
            pdfs: [
                FolderPDFDescriptor(
                    source: folderSource("Same Name.pdf"),
                    identity: identity(11),
                    originalFileName: "Same Name.pdf",
                    propertyMetadata: PaperMetadata(title: "same name", authors: nil),
                    fingerprint: nil
                ),
            ],
            children: []
        )

        let plan = FolderImportPlanner.plan(root: descriptor, existingPapers: [])

        XCTAssertEqual(try XCTUnwrap(plan.papers.first).metadata.title, "Same Name")
    }

    func testZoteroPlannerCreatesOnePaperPerPDFAttachmentAndInheritsParentMetadata() {
        let library = ZoteroLibraryIdentity(type: "user", id: 0)
        let root: ImportSourceIdentity = .zoteroCollection(
            library: library,
            collectionKey: "ROOT",
            serverID: "server-a"
        )
        let child: ImportSourceIdentity = .zoteroCollection(
            library: library,
            collectionKey: "CHILD",
            serverID: "server-a"
        )
        let first: ImportSourceIdentity = .zoteroAttachment(
            library: library,
            parentItemKey: "ITEM",
            attachmentKey: "PDF1",
            serverID: "server-a"
        )
        let second: ImportSourceIdentity = .zoteroAttachment(
            library: library,
            parentItemKey: "ITEM",
            attachmentKey: "PDF2",
            serverID: "server-a"
        )
        let parentDTO = ZoteroItemMetadataDescriptor(
            itemType: "journalArticle",
            title: "Shared Article",
            creators: [ZoteroCreatorDescriptor(
                creatorType: "author",
                firstName: "Ada",
                lastName: "Lovelace",
                name: nil
            )],
            dateText: "2026-03",
            parsedYear: 2026,
            containerTitle: "Journal",
            volume: "3",
            issue: "2",
            pages: "10-20",
            identifiers: [BibliographicIdentifier(kind: .doi, displayValue: "10.1/example")],
            publisher: "Publisher",
            place: nil,
            edition: nil,
            url: "https://example.test/paper",
            language: "en",
            abstractText: "Abstract"
        )
        let plan = ZoteroImportPlanner.plan(
            collections: [
                ZoteroCollectionDescriptor(source: root, name: "Root", parentSource: nil),
                ZoteroCollectionDescriptor(source: child, name: "Child", parentSource: root),
            ],
            items: [
                ZoteroItemDescriptor(
                    metadata: parentDTO,
                    collectionSources: [child],
                    attachments: [
                        ZoteroAttachmentDescriptor(
                            source: first,
                            identity: identity(20),
                            originalFileName: "accepted.pdf",
                            label: "Accepted manuscript",
                            propertyMetadata: PaperMetadata(title: "Must Not Win", authors: nil),
                            fingerprint: fingerprint("1")
                        ),
                        ZoteroAttachmentDescriptor(
                            source: second,
                            identity: identity(21),
                            originalFileName: "supplement.pdf",
                            label: "Supplement",
                            propertyMetadata: nil,
                            fingerprint: fingerprint("2")
                        ),
                    ]
                ),
            ],
            existingPapers: []
        )

        XCTAssertEqual(plan.collections.map(\.source), [root, child])
        XCTAssertEqual(plan.papers.count, 2)
        XCTAssertEqual(plan.papers.map(\.metadata), [parentDTO.mappedMetadata(), parentDTO.mappedMetadata()])
        XCTAssertEqual(plan.papers.map(\.attachmentLabel), ["Accepted manuscript", "Supplement"])
        XCTAssertEqual(plan.papers.map(\.collectionSources), [[child], [child]])
        XCTAssertNotEqual(plan.papers[0].source, plan.papers[1].source)
    }

    func testStandaloneZoteroAttachmentUsesLabelBeforeFilename() throws {
        let library = ZoteroLibraryIdentity(type: "group", id: 42)
        let source: ImportSourceIdentity = .zoteroAttachment(
            library: library,
            parentItemKey: nil,
            attachmentKey: "STANDALONE",
            serverID: nil
        )
        let plan = ZoteroImportPlanner.plan(
            collections: [],
            items: [
                ZoteroItemDescriptor(
                    metadata: nil,
                    collectionSources: [],
                    attachments: [
                        ZoteroAttachmentDescriptor(
                            source: source,
                            identity: nil,
                            originalFileName: "file.pdf",
                            label: "Standalone label",
                            propertyMetadata: nil,
                            fingerprint: nil
                        ),
                    ]
                ),
            ],
            existingPapers: []
        )

        XCTAssertEqual(try XCTUnwrap(plan.papers.first).metadata.title, "Standalone label")
    }

    func testZoteroMetadataMappingPreservesUnknownCreatorRoleAndInvalidDateText() {
        let descriptor = ZoteroItemMetadataDescriptor(
            itemType: "dataset",
            title: "Unusual Item",
            creators: [ZoteroCreatorDescriptor(
                creatorType: "reviewedAuthor",
                firstName: nil,
                lastName: nil,
                name: "Research Consortium"
            )],
            dateText: "forthcoming, maybe",
            parsedYear: nil,
            containerTitle: nil,
            volume: nil,
            issue: nil,
            pages: nil,
            identifiers: [],
            publisher: nil,
            place: nil,
            edition: nil,
            url: nil,
            language: nil,
            abstractText: nil
        )

        let metadata = descriptor.mappedMetadata()

        XCTAssertEqual(metadata.itemType.rawValue, "dataset")
        XCTAssertEqual(metadata.creators.first?.role.rawValue, "reviewedAuthor")
        XCTAssertEqual(metadata.creators.first?.literalName, "Research Consortium")
        XCTAssertEqual(metadata.issuedDate?.sourceText, "forthcoming, maybe")
        XCTAssertNil(metadata.issuedDate?.year)
    }

    func testMetadataReimportReportsManualConflictsAndOnlyAppliesUnlockedFields() {
        let current = BibliographicMetadata(
            title: "My Title",
            creators: [BibliographicCreator(role: .author, literalName: "My Author")],
            issuedDate: BibliographicDate(sourceText: "2024", year: 2024),
            containerTitle: "Old Journal"
        )
        let imported = BibliographicMetadata(
            title: "Remote Title",
            creators: [BibliographicCreator(role: .author, literalName: "Remote Author")],
            issuedDate: BibliographicDate(sourceText: "2026", year: 2026),
            containerTitle: "New Journal"
        )

        let preview = MetadataImportMerger.preview(
            current: current,
            imported: imported,
            manuallyEditedFields: [.title, .creators]
        )

        XCTAssertEqual(preview.blockedManualFields, [.title, .creators])
        XCTAssertEqual(preview.changedFields, [.issuedDate, .containerTitle])
        XCTAssertEqual(preview.proposedMetadata.title, "My Title")
        XCTAssertEqual(preview.proposedMetadata.authorsDisplay, "My Author")
        XCTAssertEqual(preview.proposedMetadata.issuedDate?.year, 2026)
        XCTAssertEqual(preview.proposedMetadata.containerTitle, "New Journal")
    }
}
