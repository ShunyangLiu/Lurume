import Foundation
import XCTest
@testable import Lurume

final class LibraryOrganizationTests: XCTestCase {
    private func makePaper(
        id: UUID = UUID(),
        title: String,
        authors: String? = nil,
        year: Int? = nil,
        dateAdded: TimeInterval,
        lastOpenedAt: TimeInterval? = nil,
        status: ReadingStatus = .unread
    ) -> PaperRecord {
        var paper = PaperRecord(
            id: id,
            identity: FileIdentity(
                volumeUUID: "volume",
                documentIdentifier: nil,
                fallbackPath: "/tmp/\(id.uuidString).pdf"
            ),
            bookmarkData: Data(),
            initialTitle: title,
            originalFileName: "\(title)-source.pdf",
            dateAdded: Date(timeIntervalSince1970: dateAdded),
            lastOpenedAt: lastOpenedAt.map(Date.init(timeIntervalSince1970:)),
            readingStatus: status
        )
        paper.title = title
        paper.authors = authors
        paper.year = year
        return paper
    }

    func testReadingStatusCyclesThroughAllThreeStates() {
        XCTAssertEqual(ReadingStatus.unread.next, .reading)
        XCTAssertEqual(ReadingStatus.reading.next, .finished)
        XCTAssertEqual(ReadingStatus.finished.next, .unread)
    }

    func testStatusFilterAndSearchCompose() {
        let papers = [
            makePaper(
                title: "Alpha Networks",
                authors: "Ada Lovelace",
                dateAdded: 10,
                status: .reading
            ),
            makePaper(
                title: "Beta Systems",
                authors: "Grace Hopper",
                dateAdded: 20,
                status: .finished
            ),
        ]

        XCTAssertEqual(
            LibraryQuery.apply(
                to: papers,
                searchText: "ADA",
                status: .reading,
                sort: .title
            ).map(\.title),
            ["Alpha Networks"]
        )
        XCTAssertTrue(
            LibraryQuery.apply(
                to: papers,
                searchText: "Grace",
                status: .reading,
                sort: .title
            ).isEmpty
        )
    }

    func testSearchIncludesExpandedBibliographicMetadata() {
        var paper = makePaper(title: "Opaque Title", dateAdded: 10)
        paper.metadata = BibliographicMetadata(
            itemType: .journalArticle,
            title: "Opaque Title",
            creators: [BibliographicCreator(role: .editor, literalName: "Editorial Group")],
            issuedDate: BibliographicDate(sourceText: "Spring 2025", year: 2025),
            containerTitle: "Journal of Native Reading",
            identifiers: [BibliographicIdentifier(kind: .doi, displayValue: "10.1000/LURUME")],
            publisher: "Example Press",
            url: "https://example.com/paper",
            language: "zh-Hans",
            abstractText: "A distinctive abstract phrase"
        )

        for query in ["Editorial", "Spring", "Native Reading", "10.1000/lurume", "example.com/paper"] {
            XCTAssertEqual(
                LibraryQuery.apply(to: [paper], searchText: query, status: .all, sort: .title).map(\.id),
                [paper.id],
                "Expected expanded metadata search to match \(query)"
            )
        }
        for excludedQuery in ["Example Press", "zh-Hans", "distinctive"] {
            XCTAssertTrue(
                LibraryQuery.apply(
                    to: [paper],
                    searchText: excludedQuery,
                    status: .all,
                    sort: .title
                ).isEmpty,
                "Ordinary search must not include \(excludedQuery)"
            )
        }
    }

    func testRecentlyOpenedPlacesNeverOpenedLastAndUsesDateAddedFallback() {
        let recent = makePaper(title: "Recent", dateAdded: 10, lastOpenedAt: 100)
        let older = makePaper(title: "Older", dateAdded: 50, lastOpenedAt: 90)
        let neverNew = makePaper(title: "Never New", dateAdded: 80)
        let neverOld = makePaper(title: "Never Old", dateAdded: 20)

        XCTAssertEqual(
            LibraryQuery.apply(
                to: [neverOld, older, neverNew, recent],
                searchText: "",
                status: .all,
                sort: .recentlyOpened
            ).map(\.title),
            ["Recent", "Older", "Never New", "Never Old"]
        )
    }

    func testTitleAndYearSortingFollowP3Rules() {
        let newest = makePaper(title: "Zoo", year: 2026, dateAdded: 10)
        let sameYearA = makePaper(title: "alpha", year: 2024, dateAdded: 10)
        let sameYearB = makePaper(title: "Beta", year: 2024, dateAdded: 20)
        let missingYear = makePaper(title: "No Year", dateAdded: 100)
        let papers = [missingYear, newest, sameYearB, sameYearA]

        XCTAssertEqual(
            LibraryQuery.apply(
                to: papers,
                searchText: "",
                status: .all,
                sort: .title
            ).map(\.title),
            ["alpha", "Beta", "No Year", "Zoo"]
        )
        XCTAssertEqual(
            LibraryQuery.apply(
                to: papers,
                searchText: "",
                status: .all,
                sort: .year
            ).map(\.title),
            ["Zoo", "alpha", "Beta", "No Year"]
        )
    }

    @MainActor
    func testStartupSortDefaultsPersistsWithoutChangingCurrentSession() {
        let suiteName = "LurumeTests.LibrarySort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultLibrarySortOption, .dateAdded)
        XCTAssertEqual(settings.librarySortOption, .dateAdded)
        settings.defaultLibrarySortOption = .year
        XCTAssertEqual(settings.librarySortOption, .dateAdded)

        settings.librarySortOption = .title
        let relaunchedSettings = AppSettings(defaults: defaults)

        XCTAssertEqual(relaunchedSettings.defaultLibrarySortOption, .year)
        XCTAssertEqual(relaunchedSettings.librarySortOption, .year)
    }

    @MainActor
    func testStorePersistsReadingStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = LibraryPersistence(fileURL: directory.appendingPathComponent("library.json"))
        let paper = makePaper(title: "Status", dateAdded: 10)
        try persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [paper],
            selectedPaperID: paper.id
        ))
        let store = LibraryStore(persistence: persistence)

        store.cycleReadingStatus(for: paper.id)

        XCTAssertEqual(store.papers.first?.readingStatus, .reading)
        XCTAssertEqual(try persistence.load().snapshot.papers.first?.readingStatus, .reading)
    }

    @MainActor
    func testFailedReadingStatusSaveRollsBackPublishedState() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let persistence = LibraryPersistence(fileURL: directory.appendingPathComponent("library.json"))
        let paper = makePaper(title: "Rollback", dateAdded: 10)
        try persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [paper],
            selectedPaperID: paper.id
        ))
        let store = LibraryStore(persistence: persistence)
        try FileManager.default.removeItem(at: directory)
        try Data("blocking-file".utf8).write(to: directory)

        store.setReadingStatus(.finished, for: paper.id)

        XCTAssertEqual(store.papers.first?.readingStatus, .unread)
        XCTAssertNotNil(store.presentedError)
    }

    @MainActor
    func testFilteredStatusGuardRejectsOnlyTheImmediateFollowUpClick() {
        let guardState = ReadingStatusInteractionGuard()

        XCTAssertTrue(guardState.shouldAccept(isFiltered: true, nowNanoseconds: 1_000))
        XCTAssertFalse(guardState.shouldAccept(isFiltered: true, nowNanoseconds: 200_000_000))
        XCTAssertTrue(guardState.shouldAccept(isFiltered: true, nowNanoseconds: 221_001_000))
        XCTAssertTrue(guardState.shouldAccept(isFiltered: false, nowNanoseconds: 221_001_001))
    }
}
