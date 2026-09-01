import Foundation
import XCTest
@testable import Lurume

final class ZoteroImportXPCIntegrationTests: XCTestCase {
    private let serverID = "lurume-zotero-fixture"

    func testEmbeddedServiceStartsAndRepliesToPing() throws {
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }
        XCTAssertEqual(try client.ping(timeout: 3), "ready")
    }

    func testProbeAndPaginatedGroupPageTraverseEmbeddedXPC() throws {
        try requireFixture()
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }

        let probe = try client.perform(request(kind: .probe))
        XCTAssertEqual(probe.payload?.probe?.apiVersion, 3)
        XCTAssertEqual(probe.payload?.probe?.schemaVersion, 42)
        XCTAssertEqual(probe.payload?.probe?.serverID, serverID)

        let groups = try client.perform(request(
            kind: .libraries,
            start: 0,
            limit: 1,
            serverID: serverID
        ))
        XCTAssertEqual(groups.payload?.libraries?.map(\.name), ["研究组"])
        XCTAssertEqual(groups.payload?.totalResults, 2)
    }

    func testCollectionsItemsAndPlainTextAttachmentCandidateTraverseXPC() throws {
        try requireFixture()
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }

        let collections = try client.perform(request(
            kind: .collections,
            libraryType: "user",
            libraryID: 0,
            serverID: serverID
        ))
        XCTAssertEqual(collections.payload?.collections?.map(\.key), ["ROOT", "CHILD", "OTHER"])

        let items = try client.perform(request(
            kind: .items,
            libraryType: "user",
            libraryID: 0,
            serverID: serverID
        ))
        XCTAssertEqual(items.payload?.items?.count, 7)
        XCTAssertEqual(items.payload?.items?.first?.title, "A Fixture Paper")

        let attachment = try client.perform(request(
            kind: .attachmentURL,
            libraryType: "user",
            libraryID: 0,
            itemKey: "PDF1",
            serverID: serverID
        ))
        XCTAssertEqual(
            attachment.payload?.attachmentURL,
            "file:///fixture-does-not-exist/Zotero/storage/PDF1/paper.pdf"
        )
    }

    func test403MessageIsActionableAndDoesNotEchoFixtureBody() throws {
        try requireFixture()
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }
        let result = try client.perform(request(
            kind: .collections,
            libraryType: "group",
            libraryID: 403,
            serverID: serverID
        ))
        XCTAssertEqual(result.terminalKind, "failed")
        XCTAssertEqual(result.errorCode, "http_403")
        XCTAssertEqual(
            result.message,
            "Zotero 拒绝了本地访问。请在 Zotero 设置中允许其他应用与 Zotero 通信。"
        )
        XCTAssertFalse(result.message?.contains("fixture detail") ?? true)
    }

    func testCrossOriginRedirectIsRejectedBeforeFollowing() throws {
        try requireFixture()
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }
        let result = try client.perform(request(
            kind: .attachmentURL,
            libraryType: "user",
            libraryID: 0,
            itemKey: "CROSS",
            serverID: serverID
        ))
        XCTAssertEqual(result.terminalKind, "failed")
        XCTAssertEqual(result.errorCode, "invalid_response")
    }

    func testChangedServerIdentityIsRejectedBeforePayloadParsing() throws {
        try requireFixture()
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }
        let result = try client.perform(request(
            kind: .attachmentURL,
            libraryType: "user",
            libraryID: 0,
            itemKey: "WRONGID",
            serverID: serverID
        ))
        XCTAssertEqual(result.terminalKind, "failed")
        XCTAssertEqual(result.errorCode, "server_changed")
        XCTAssertEqual(result.message, "Zotero 实例已变化，请重新开始迁移。")
    }

    func testCancellationStopsActiveRequest() throws {
        try requireFixture()
        let client = ZoteroXPCTestClient()
        defer { client.invalidate() }
        let result = try client.perform(
            request(
                kind: .attachmentURL,
                libraryType: "user",
                libraryID: 0,
                itemKey: "SLOW",
                serverID: serverID
            ),
            cancelAfterAcceptance: true
        )
        XCTAssertEqual(result.terminalKind, "cancelled")
        XCTAssertEqual(result.errorCode, "cancelled")
    }

    @MainActor
    func testCoordinatorBuildsPreviewWithoutPublishingOrReadingFixtureFile() async throws {
        try requireFixture()
        let sender = ZoteroImportXPCClient()
        XCTAssertFalse(sender.hasActiveConnectionForTesting)
        let coordinator = ZoteroImportCoordinator(sender: sender)
        coordinator.begin(existingPapers: [])

        try await waitUntil(timeoutIterations: 300) {
            coordinator.phase == .selecting || coordinator.phase == .failed
        }
        if coordinator.phase == .failed {
            XCTFail(coordinator.failureMessage ?? "Coordinator failed")
            return
        }
        XCTAssertEqual(coordinator.libraries.map(\.name), ["我的文库", "研究组", "实验组"])
        XCTAssertEqual(coordinator.collections.count, 3)
        XCTAssertTrue(coordinator.importsWholeLibrary)

        coordinator.setImportsWholeLibrary(false)
        coordinator.setCollectionSelected(true, key: "CHILD")
        coordinator.scanSelection()
        try await waitUntil(timeoutIterations: 400) {
            coordinator.phase == .preview || coordinator.phase == .failed
        }
        if coordinator.phase == .failed {
            XCTFail(coordinator.failureMessage ?? "Coordinator failed")
            return
        }
        let preview = try XCTUnwrap(coordinator.preview)
        XCTAssertEqual(preview.pdfAttachmentCount, 1)
        XCTAssertEqual(preview.unavailableAttachmentCount, 1)
        XCTAssertEqual(preview.unsupportedAttachmentCount, 1)
        XCTAssertEqual(preview.nonPDFAttachmentCount, 1)
        XCTAssertEqual(preview.unsupportedItemCount, 1)
        XCTAssertEqual(preview.ignoredTagCount, 2)
        XCTAssertEqual(preview.ignoredRelationCount, 1)
        XCTAssertEqual(preview.parentItemsWithoutPDFCount, 0)
        XCTAssertEqual(preview.rows.first?.fileName, "paper.pdf")
        XCTAssertEqual(preview.rows.first?.title, "A Fixture Paper")
        XCTAssertEqual(preview.plan.papers.count, 1)
        XCTAssertEqual(preview.plan.collections.map(\.name), ["机器学习", "翻译"])
        XCTAssertEqual(preview.rows.first?.collectionNames, ["翻译"])
        XCTAssertEqual(
            preview.plan.papers.first?.metadata.identifiers.map(\.kind),
            [.doi, .arXiv]
        )
        XCTAssertFalse(sender.hasActiveConnectionForTesting)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for Zotero coordinator")
    }

    private func requireFixture() throws {
        guard let root = ProcessInfo.processInfo.environment["LURUME_ZOTERO_FAKE_SERVER"],
              root.hasPrefix("http://127.0.0.1:")
        else {
            throw XCTSkip("Set LURUME_ZOTERO_FAKE_SERVER to run Zotero XPC integration tests.")
        }
    }

    private func request(
        kind: ZoteroImportRequestKind,
        libraryType: String? = nil,
        libraryID: Int = 0,
        itemKey: String? = nil,
        start: Int = 0,
        limit: Int = 100,
        serverID: String? = nil
    ) -> ZoteroImportXPCRequest {
        ZoteroImportXPCRequest(
            requestID: UUID().uuidString,
            kind: kind,
            libraryType: libraryType,
            libraryID: libraryID,
            itemKey: itemKey,
            startIndex: start,
            limit: limit,
            serverID: serverID,
            testingOrigin: ProcessInfo.processInfo.environment["LURUME_ZOTERO_FAKE_SERVER"]
        )
    }
}

private struct ZoteroXPCTestResult {
    var terminalKind: String
    var payload: ZoteroServicePayload?
    var errorCode: String?
    var message: String?
}

private final class ZoteroXPCTestClient: NSObject, ZoteroImportXPCClientProtocol, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var activeRequestID: String?
    private var terminalEvent: ZoteroImportXPCEvent?
    private var terminalSemaphore = DispatchSemaphore(value: 0)

    override init() {
        connection = NSXPCConnection(serviceName: ZoteroImportXPCConstants.serviceName)
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: ZoteroImportXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ZoteroImportXPCClientProtocol.self)
        connection.exportedObject = self
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func ping(timeout: TimeInterval) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let value = LockedZoteroString()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in semaphore.signal() })
            as? ZoteroImportXPCServiceProtocol
        else { throw ZoteroXPCTestError.proxyUnavailable }
        proxy.ping { response in
            value.set(response)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success,
              let response = value.get() else { throw ZoteroXPCTestError.timeout }
        return response
    }

    func perform(
        _ request: ZoteroImportXPCRequest,
        cancelAfterAcceptance: Bool = false
    ) throws -> ZoteroXPCTestResult {
        lock.lock()
        activeRequestID = request.requestID
        terminalEvent = nil
        terminalSemaphore = DispatchSemaphore(value: 0)
        lock.unlock()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.terminalSemaphore.signal()
        }) as? ZoteroImportXPCServiceProtocol else {
            throw ZoteroXPCTestError.proxyUnavailable
        }
        let accepted = DispatchSemaphore(value: 0)
        let acceptance = LockedZoteroBool()
        proxy.start(request) { value in
            acceptance.set(value)
            accepted.signal()
        }
        guard accepted.wait(timeout: .now() + 3) == .success,
              acceptance.get() == true else { throw ZoteroXPCTestError.notAccepted }
        if cancelAfterAcceptance { proxy.cancel(requestID: request.requestID) }
        guard terminalSemaphore.wait(timeout: .now() + 8) == .success else {
            throw ZoteroXPCTestError.timeout
        }

        lock.lock()
        defer { lock.unlock() }
        guard let terminalEvent else { throw ZoteroXPCTestError.connectionInvalidated }
        let payload = terminalEvent.payload.flatMap {
            try? JSONDecoder().decode(ZoteroServicePayload.self, from: $0)
        }
        return ZoteroXPCTestResult(
            terminalKind: terminalEvent.kind,
            payload: payload,
            errorCode: terminalEvent.errorCode,
            message: terminalEvent.message
        )
    }

    func receive(_ event: ZoteroImportXPCEvent) {
        lock.lock()
        guard event.requestID == activeRequestID,
              ["completed", "failed", "cancelled"].contains(event.kind) else {
            lock.unlock()
            return
        }
        terminalEvent = event
        lock.unlock()
        terminalSemaphore.signal()
    }
}

private final class LockedZoteroString: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedZoteroBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum ZoteroXPCTestError: Error {
    case proxyUnavailable
    case notAccepted
    case timeout
    case connectionInvalidated
}
