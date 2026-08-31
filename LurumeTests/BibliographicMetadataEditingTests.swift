import Foundation
import XCTest
@testable import Lurume

final class BibliographicMetadataEditingTests: XCTestCase {
    func testDraftRoundTripPreservesUnknownTypesRolesAndRawDate() throws {
        let original = BibliographicMetadata(
            itemType: BibliographicItemType(rawValue: "dataset"),
            title: "Dataset",
            creators: [BibliographicCreator(
                role: BibliographicCreatorRole(rawValue: "reviewedAuthor"),
                literalName: "Consortium"
            )],
            issuedDate: BibliographicDate(sourceText: "forthcoming", year: nil),
            identifiers: [BibliographicIdentifier(
                kind: BibliographicIdentifierKind(rawValue: "pmid"),
                displayValue: "12345"
            )]
        )

        let result = try BibliographicMetadataDraft(metadata: original).result(comparedWith: original)

        XCTAssertEqual(result.metadata, original)
        XCTAssertTrue(result.changedFields.isEmpty)
        XCTAssertNil(result.attachmentLabel)
    }

    func testDraftReportsEveryChangedAtomicFieldAndNormalizesDOI() throws {
        let original = BibliographicMetadata(title: "Old")
        var draft = BibliographicMetadataDraft(metadata: original)
        draft.title = "  New  "
        draft.creators = [BibliographicCreatorDraft()]
        draft.creators[0].givenName = "Ada"
        draft.creators[0].familyName = "Lovelace"
        draft.dateText = " 2026-03 "
        draft.yearText = "2026"
        draft.containerTitle = " Journal "
        draft.identifiers = [BibliographicIdentifierDraft()]
        draft.identifiers[0].value = "https://doi.org/10.1000/ABC"
        draft.abstractText = " Abstract "

        let result = try draft.result(comparedWith: original)

        XCTAssertEqual(
            result.changedFields,
            [.title, .creators, .issuedDate, .containerTitle, .identifiers, .abstractText]
        )
        XCTAssertEqual(result.metadata.title, "New")
        XCTAssertEqual(result.metadata.authorsDisplay, "Ada Lovelace")
        XCTAssertEqual(result.metadata.identifiers.first?.comparisonValue, "10.1000/abc")
    }

    func testDraftRejectsInvalidYearEmptyCreatorAndEmptyIdentifier() {
        let original = BibliographicMetadata(title: "Paper")
        var invalidYear = BibliographicMetadataDraft(metadata: original)
        invalidYear.yearText = "twenty"
        XCTAssertThrowsError(try invalidYear.result(comparedWith: original)) {
            XCTAssertEqual($0 as? BibliographicMetadataDraftError, .invalidYear)
        }

        var emptyCreator = BibliographicMetadataDraft(metadata: original)
        emptyCreator.creators = [BibliographicCreatorDraft()]
        XCTAssertThrowsError(try emptyCreator.result(comparedWith: original)) {
            XCTAssertEqual($0 as? BibliographicMetadataDraftError, .emptyCreator)
        }

        var emptyIdentifier = BibliographicMetadataDraft(metadata: original)
        emptyIdentifier.identifiers = [BibliographicIdentifierDraft()]
        XCTAssertThrowsError(try emptyIdentifier.result(comparedWith: original)) {
            XCTAssertEqual($0 as? BibliographicMetadataDraftError, .emptyIdentifier)
        }
    }

    func testDraftRejectsInvalidDOIAndURLWithoutChangingOriginal() {
        let original = BibliographicMetadata(title: "Paper")
        var invalidDOI = BibliographicMetadataDraft(metadata: original)
        invalidDOI.identifiers = [BibliographicIdentifierDraft()]
        invalidDOI.identifiers[0].value = "not-a-doi"
        XCTAssertThrowsError(try invalidDOI.result(comparedWith: original)) {
            XCTAssertEqual($0 as? BibliographicMetadataDraftError, .invalidDOI)
        }

        var invalidURL = BibliographicMetadataDraft(metadata: original)
        invalidURL.url = "example.com/paper"
        XCTAssertThrowsError(try invalidURL.result(comparedWith: original)) {
            XCTAssertEqual($0 as? BibliographicMetadataDraftError, .invalidURL)
        }
        XCTAssertEqual(original, BibliographicMetadata(title: "Paper"))
    }

    func testDraftReturnsNormalizedAttachmentLabel() throws {
        let original = BibliographicMetadata(title: "Paper")
        var draft = BibliographicMetadataDraft(metadata: original, attachmentLabel: " Draft ")

        let result = try draft.result(comparedWith: original)
        XCTAssertEqual(result.attachmentLabel, "Draft")

        draft.attachmentLabel = "   "
        XCTAssertNil(try draft.result(comparedWith: original).attachmentLabel)
    }

    func testSafeSourceSummaryNeverContainsStoredKeysOrPaths() {
        let library = ZoteroLibraryIdentity(type: "user", id: 0)
        let paper = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: 1,
                fallbackPath: "/private/secret/paper.pdf"
            ),
            bookmarkData: Data(),
            initialTitle: "Paper",
            importSources: [
                .folder(FolderImportSource(
                    rootVolumeUUID: "volume",
                    rootDocumentIdentifier: 9,
                    relativePath: "private/subfolder"
                )),
                .zoteroAttachment(
                    library: library,
                    parentItemKey: "PARENT-SECRET",
                    attachmentKey: "ATTACHMENT-SECRET",
                    serverID: "SERVER-SECRET"
                ),
            ]
        )

        XCTAssertEqual(paper.importSourceSummary, "文件夹与 Zotero · 2 个来源")
        XCTAssertFalse(paper.importSourceSummary.contains("secret"))
        XCTAssertFalse(paper.importSourceSummary.contains("PARENT"))
        XCTAssertFalse(paper.importSourceSummary.contains("SERVER"))
    }
}
