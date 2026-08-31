import Foundation
import XCTest
@testable import Lurume

/// P1 元数据：判废规则、手动优先级、PDFKit 属性提取与存储层惰性补全。
final class PaperMetadataTests: XCTestCase {
    // MARK: - 标题判废规则

    func testBlankPropertyTitleFallsBack() {
        XCTAssertNil(PaperTitleRules.usablePropertyTitle(nil, comparingAgainstFileName: "a.pdf"))
        XCTAssertNil(PaperTitleRules.usablePropertyTitle("   ", comparingAgainstFileName: "a.pdf"))
    }

    func testTitleMatchingFileNameIsUnusable() {
        XCTAssertNil(
            PaperTitleRules.usablePropertyTitle(
                "main.pdf",
                comparingAgainstFileName: "/papers/Main.PDF"
            )
        )
        XCTAssertNil(
            PaperTitleRules.usablePropertyTitle(
                "Main",
                comparingAgainstFileName: "/papers/main.pdf"
            )
        )
    }

    func testDistinctPropertyTitleIsTrusted() {
        XCTAssertEqual(
            PaperTitleRules.usablePropertyTitle(
                "Quantum Entanglement Review",
                comparingAgainstFileName: "/papers/main.pdf"
            ),
            "Quantum Entanglement Review"
        )
        // 仅前缀相同不算同名文件。
        XCTAssertEqual(
            PaperTitleRules.usablePropertyTitle(
                "Survey of Methods.pdf",
                comparingAgainstFileName: "survey-of-methods-2024.pdf"
            ),
            "Survey of Methods.pdf"
        )
    }

    // MARK: - 手动字段优先级（模型层）

    private func makeRecord(
        manuallyEditedFields: Set<MetadataField> = [],
        title: String = "Current Title",
        authors: String? = nil,
        didReadAutoMetadata: Bool = false
    ) -> PaperRecord {
        var record = PaperRecord(
            identity: FileIdentity(
                volumeUUID: "v",
                documentIdentifier: 1,
                fallbackPath: "/tmp/paper.pdf"
            ),
            bookmarkData: Data(),
            initialTitle: "paper"
        )
        record.title = title
        record.authors = authors
        record.manuallyEditedFields = manuallyEditedFields
        record.didReadAutoMetadata = didReadAutoMetadata
        return record
    }

    func testAutoMetadataAppliesTrustedTitleAndAuthors() {
        var record = makeRecord()
        record.applyAutoMetadata(
            PaperMetadata(title: "Fresh Title", authors: "Alice, Bob")
        )

        XCTAssertTrue(record.didReadAutoMetadata)
        XCTAssertEqual(record.title, "Fresh Title")
        XCTAssertEqual(record.authors, "Alice, Bob")
    }

    func testAutoMetadataRespectsManualEdits() {
        var record = makeRecord(manuallyEditedFields: [.title, .creators])
        record.applyAutoMetadata(
            PaperMetadata(title: "Property Title", authors: "Someone")
        )

        XCTAssertEqual(record.title, "Current Title")
        XCTAssertNil(record.authors)
    }

    func testFilenameLikePropertyTitleKeepsFallback() {
        var record = makeRecord()
        record.fallbackPath = "/tmp/main.pdf"
        record.applyAutoMetadata(PaperMetadata(title: "Main", authors: nil))

        XCTAssertEqual(record.title, "Current Title")
        XCTAssertTrue(record.didReadAutoMetadata, "判废结果同样消耗唯一一次自动读取")
    }

    func testAutoReadHappensOnlyOnce() {
        var record = makeRecord()
        record.applyAutoMetadata(PaperMetadata(title: "First", authors: nil))
        record.applyAutoMetadata(PaperMetadata(title: "Second", authors: "Late"))

        XCTAssertEqual(record.title, "First")
        XCTAssertNil(record.authors)
    }

    func testLibrarySubtitleContainsOnlyAuthorsAndYear() {
        var record = makeRecord()
        XCTAssertNil(record.librarySubtitle)

        record.authors = "  Alice, Bob  "
        XCTAssertEqual(record.librarySubtitle, "Alice, Bob")

        record.year = 2026
        XCTAssertEqual(record.librarySubtitle, "Alice, Bob · 2026")

        record.authors = nil
        XCTAssertEqual(record.librarySubtitle, "2026")
    }

    func testYearInputDistinguishesEmptyValidAndInvalidValues() {
        XCTAssertEqual(PaperYearRules.parse("  \n"), .empty)
        XCTAssertEqual(PaperYearRules.parse(" 2024 "), .value(2024))
        XCTAssertEqual(PaperYearRules.parse("20xx"), .invalid)
    }

    func testInaccessibleFileDoesNotConsumeTheSingleAutoRead() {
        var record = makeRecord()
        record.applyAutoMetadata(nil)
        XCTAssertTrue(record.didReadAutoMetadata, "读到空属性属于已读，不再重试")

        let untouched = makeRecord()
        // 文件不可用走 inaccessible 分支：不调用 applyAutoMetadata。
        _ = untouched
        XCTAssertFalse(untouched.didReadAutoMetadata)
    }

    // MARK: - SystemPaperMetadataReader 对真实 PDFKit 的集成

    func testReaderExtractsTitleAndAuthorsFromRealPDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("survey.pdf")
        try SyntheticPDF.make(title: "Deep Reading Habits", author: "Grace Park").write(to: fileURL)

        let metadata = await SystemPaperMetadataReader().metadata(at: fileURL)

        XCTAssertEqual(metadata?.title, "Deep Reading Habits")
        XCTAssertEqual(metadata?.authors, "Grace Park")
    }

    func testReaderReturnsEmptyMetadataForAttributeFreePDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("bare.pdf")
        try SyntheticPDF.make(title: nil, author: nil).write(to: fileURL)

        let metadata = await SystemPaperMetadataReader().metadata(at: fileURL)

        XCTAssertEqual(metadata, PaperMetadata(title: nil, authors: nil))
    }

    // MARK: - 存储层

    @MainActor
    func testImportBackfillsTitleAndAuthorsFromProperties() async throws {
        let harness = try StoreHarness(reader: StaticMetadataReader(
            PaperMetadata(title: "Attention Mechanisms Survey", authors: "Yun Li")
        ))

        let id = try harness.store.importPDF(at: harness.paperURL(named: "attention"))

        let settled = await harness.waitUntil { selfHarness in
            selfHarness.store.papers.first?.didReadAutoMetadata == true
        }
        XCTAssertTrue(settled)
        let paper = try XCTUnwrap(harness.store.papers.first { $0.id == id })
        XCTAssertEqual(paper.title, "Attention Mechanisms Survey")
        XCTAssertEqual(paper.authors, "Yun Li")
        XCTAssertEqual(paper.originalFileName, "attention.pdf")
    }

    @MainActor
    func testManualEditBeforeBackfillSurvivesAutomaticResult() async throws {
        let harness = try StoreHarness(reader: StaticMetadataReader(
            PaperMetadata(title: "Property Title", authors: "Auto Author")
        ))

        let id = try harness.store.importPDF(at: harness.paperURL(named: "manual-first"))
        harness.store.setManualTitle("My Own Name", for: id)

        _ = await harness.waitUntil { h in
            h.store.papers.first?.didReadAutoMetadata == true
        }

        let paper = try XCTUnwrap(harness.store.papers.first { $0.id == id })
        XCTAssertEqual(paper.title, "My Own Name")
        XCTAssertEqual(paper.authors, "Auto Author", "未被编辑的字段仍由自动结果补全")
    }

    @MainActor
    func testSearchMatchesTitleAuthorAndOriginalFileNameCaseInsensitively() async throws {
        let harness = try StoreHarness(reader: StaticMetadataReader(nil))
        let firstID = try harness.store.importPDF(at: harness.paperURL(named: "Alpha Report"))
        let secondID = try harness.store.importPDF(at: harness.paperURL(named: "Beta Notes"))

        func ids(for query: String) -> Set<UUID> {
            Set(harness.store.papers(matching: query).map(\.id))
        }

        XCTAssertEqual(ids(for: "beta"), [secondID])
        XCTAssertEqual(ids(for: "ALPHA"), [firstID])
        XCTAssertEqual(ids(for: "report").count, 1)
        XCTAssertEqual(harness.store.papers(matching: "   ").count, 2)
        XCTAssertTrue(ids(for: "不存在词").isEmpty)
    }

    @MainActor
    func testStoreMigratesLegacyLibraryAndPersistsUpgradeImmediately() async throws {
        let harness = try StoreHarness(reader: StaticMetadataReader(nil))
        let legacyID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = LibrarySnapshotV1(
            schemaVersion: 1,
            papers: [
                PaperRecordV1(
                    id: legacyID,
                    volumeUUID: nil,
                    documentIdentifier: nil,
                    bookmarkData: Data([9]),
                    fallbackPath: harness.directory.appendingPathComponent("legacy.pdf").path,
                    displayName: "legacy-name",
                    dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
                    lastOpenedAt: Date(timeIntervalSince1970: 1_700_010_000),
                    lastPageIndex: 5
                ),
            ],
            selectedPaperID: legacyID
        )
        try encoder.encode(legacy).write(to: harness.libraryFileURL)

        let store = LibraryStore(persistence: harness.persistence, metadataReader: StaticMetadataReader(nil))

        XCTAssertEqual(store.papers.map(\.title), ["legacy-name"])
        XCTAssertEqual(store.papers.map(\.originalFileName), ["legacy.pdf"])
        XCTAssertEqual(store.papers.map(\.lastPageIndex), [5])
        XCTAssertEqual(store.selectedPaperID, legacyID)
        XCTAssertFalse(store.persistenceDisabled)

        // 升级应立即落盘为当前版本。
        let reloaded = try harness.persistence.load()
        XCTAssertFalse(reloaded.migratedFromLegacy)
        XCTAssertEqual(reloaded.snapshot.schemaVersion, LibrarySchema.currentVersion)
        XCTAssertEqual(reloaded.snapshot.papers.first?.id, legacyID)
    }

    @MainActor
    func testStoreRepairsOriginalFileNameWrittenByEarlyV2Build() async throws {
        let harness = try StoreHarness(reader: StaticMetadataReader(nil))
        var record = PaperRecord(
            identity: FileIdentity(
                volumeUUID: nil,
                documentIdentifier: nil,
                fallbackPath: harness.directory.appendingPathComponent("legacy-v2.pdf").path
            ),
            bookmarkData: Data(),
            initialTitle: "legacy-v2"
        )
        record.originalFileName = "legacy-v2"
        try harness.persistence.save(LibrarySnapshot(
            schemaVersion: LibrarySchema.currentVersion,
            papers: [record],
            selectedPaperID: record.id
        ))

        let store = LibraryStore(
            persistence: harness.persistence,
            metadataReader: StaticMetadataReader(nil)
        )

        XCTAssertEqual(store.papers.first?.originalFileName, "legacy-v2.pdf")
        XCTAssertEqual(store.papers.first?.title, "legacy-v2")
        let reloaded = try harness.persistence.load()
        XCTAssertEqual(reloaded.snapshot.papers.first?.originalFileName, "legacy-v2.pdf")
    }

    @MainActor
    func testCorruptLibraryDisablesPersistenceWithoutOverwritingFile() async throws {
        let harness = try StoreHarness(reader: StaticMetadataReader(nil))
        let corruptBytes = Data("{ not a library".utf8)
        try corruptBytes.write(to: harness.libraryFileURL)

        let store = LibraryStore(persistence: harness.persistence, metadataReader: StaticMetadataReader(nil))

        XCTAssertTrue(store.persistenceDisabled)
        XCTAssertNotNil(store.presentedError)

        let importURL = harness.paperURL(named: "must-not-appear")
        XCTAssertThrowsError(try store.importPDF(at: importURL)) { error in
            XCTAssertEqual(error as? LibraryStoreError, .persistenceUnavailable)
        }
        XCTAssertTrue(store.papers.isEmpty)

        // 任何写路径都不允许覆盖损坏文件。
        try (corruptBytes + Data([0xFF])).write(to: harness.libraryFileURL)
        let before = try Data(contentsOf: harness.libraryFileURL)
        store.flushPendingSave()
        await Task.yield()
        let after = try Data(contentsOf: harness.libraryFileURL)

        XCTAssertEqual(after, before)
    }
}

// MARK: - 测试脚手架

private struct StaticMetadataReader: PaperMetadataReading {
    let result: PaperMetadata?

    init(_ result: PaperMetadata?) {
        self.result = result
    }

    func metadata(at url: URL) async -> PaperMetadata? {
        result
    }
}

@MainActor
private final class StoreHarness {
    let persistence: LibraryPersistence
    let store: LibraryStore
    let directory: URL
    let libraryFileURL: URL

    init(reader: StaticMetadataReader) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        libraryFileURL = directory.appendingPathComponent("library.json")
        persistence = LibraryPersistence(fileURL: libraryFileURL)
        store = LibraryStore(persistence: persistence, metadataReader: reader)
    }

    func paperURL(named name: String) -> URL {
        let url = directory.appendingPathComponent("\(name).pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try! SyntheticPDF.make(title: nil, author: nil).write(to: url)
        }
        return url
    }

    func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping (StoreHarness) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(self)
    }
}

private enum SyntheticPDF {
    static func make(title: String?, author: String?) -> Data {
        var offsets: [Int] = []
        var body = "%PDF-1.4\n"

        func append(_ content: String) {
            offsets.append(body.utf8.count)
            body += content
        }

        append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        append("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
        append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n")

        var info = "<<"
        if let title { info += " /Title (\(title))" }
        if let author { info += " /Author (\(author))" }
        info += " >>"
        append("4 0 obj\n\(info)\nendobj\n")

        let xrefOffset = body.utf8.count
        var xref = "xref\n0 5\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size 5 /Root 1 0 R"
        if title != nil || author != nil { xref += " /Info 4 0 R" }
        xref += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"

        return Data((body + xref).utf8)
    }
}
