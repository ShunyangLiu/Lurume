import XCTest
@testable import Lurume

@MainActor
final class LocalTranslationAPIKeyStoreTests: XCTestCase {
    func testLocalRoundTripIsolationDeletionAndPermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("credentials/keys.json")
        let first = LocalTranslationAPIKeyStore(scope: "first", fileURL: url)
        let second = LocalTranslationAPIKeyStore(scope: "second", fileURL: url)
        var value = try await first.read()
        XCTAssertNil(value)
        async let saveFirst: Void = first.save("first-fixture")
        async let saveSecond: Void = second.save("second-fixture")
        _ = try await (saveFirst, saveSecond)
        value = try await first.read()
        XCTAssertEqual(value, "first-fixture")
        value = try await second.read()
        XCTAssertEqual(value, "second-fixture")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try await first.delete()
        value = try await first.read()
        XCTAssertNil(value)
        value = try await second.read()
        XCTAssertEqual(value, "second-fixture")
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["keys.json"])
    }

    func testCorruptAndFutureFilesAreNeverOverwritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("keys.json")
        let store = LocalTranslationAPIKeyStore(scope: "fixture", fileURL: url)
        for content in ["not-json", #"{"version":99,"keys":{"fixture":"old-fixture"}}"#] {
            let original = Data(content.utf8)
            try original.write(to: url)
            do { try await store.save("replacement-fixture"); XCTFail("Must reject invalid file") } catch {}
            do { try await store.delete(); XCTFail("Must reject invalid file") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testRejectsSymlinkFileAndDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        let original = Data(#"{"version":1,"keys":{}}"#.utf8)
        try original.write(to: target)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = LocalTranslationAPIKeyStore(scope: "fixture", fileURL: link)
        do { try await store.save("fixture"); XCTFail("Must reject symlink") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), original)
        let directoryLink = directory.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        let linkedStore = LocalTranslationAPIKeyStore(scope: "fixture", fileURL: directoryLink.appendingPathComponent("new.json"))
        do { try await linkedStore.save("fixture"); XCTFail("Must reject symlink directory") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.json").path))
    }

    func testRejectsInvalidKeysWithoutCreatingAFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalTranslationAPIKeyStore(scope: "fixture", fileURL: directory.appendingPathComponent("keys.json"))
        for value in ["", "fixture\r\nInjected: header", String(repeating: "x", count: 16_385)] {
            do { try await store.save(value); XCTFail("Must reject invalid key") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalKeyStoreTests-\(UUID().uuidString)")
    }
}
