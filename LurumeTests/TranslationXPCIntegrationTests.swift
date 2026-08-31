import Foundation
import XCTest
@testable import Lurume

final class TranslationXPCIntegrationTests: XCTestCase {
    func testEmbeddedServiceStartsAndRepliesToPing() throws {
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }

        XCTAssertEqual(try client.ping(timeout: 3), "ready")
    }

    func testStreamingResponseTraversesEmbeddedXPC() throws {
        let endpoint = try fakeEndpoint(path: "/stream")
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }

        let result = try client.translate(endpoint: endpoint, streamsResponse: true)

        XCTAssertEqual(result.text, "分块译文")
        XCTAssertEqual(result.terminalKind, "completed")
    }

    func testNonStreamingResponseTraversesEmbeddedXPC() throws {
        let endpoint = try fakeEndpoint(path: "/nonstream")
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }

        let result = try client.translate(endpoint: endpoint, streamsResponse: false)

        XCTAssertEqual(result.text, "一次性译文")
        XCTAssertEqual(result.terminalKind, "completed")
    }

    func testHTTPErrorIsClassifiedWithoutEchoingResponseBody() throws {
        let endpoint = try fakeEndpoint(path: "/error/429")
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }

        let result = try client.translate(endpoint: endpoint, streamsResponse: false)

        XCTAssertEqual(result.terminalKind, "failed")
        XCTAssertEqual(result.errorCode, "http")
        XCTAssertEqual(result.message, "请求过于频繁（HTTP 429），请稍后重试。")
        XCTAssertFalse(result.message?.contains("fixture-private-detail") ?? true)
    }

    func testCancellationStopsActiveXPCRequest() throws {
        let endpoint = try fakeEndpoint(path: "/slow-stream")
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }

        let result = try client.translate(
            endpoint: endpoint,
            streamsResponse: true,
            cancelAfterFirstDelta: true
        )

        XCTAssertEqual(result.text, "部分")
        XCTAssertEqual(result.terminalKind, "cancelled")
        XCTAssertEqual(result.errorCode, "cancelled")
    }

    @MainActor
    func testSettingsConnectionTestUsesEmbeddedServiceAndFixedFixture() async throws {
        guard let root = ProcessInfo.processInfo.environment["LURUME_TRANSLATION_FAKE_SERVER"],
              root.hasPrefix("http://127.0.0.1:")
        else {
            throw XCTSkip("Set LURUME_TRANSLATION_FAKE_SERVER to run localhost XPC integration tests.")
        }
        let controller = ModelTranslationSettingsController(
            keyStore: EmptyTranslationAPIKeyStore(),
            requestSender: TranslationXPCClient()
        )
        controller.draftBaseURL = root + "/v1/chat/completions"
        controller.draftModel = "fixture-model"
        controller.draftPrompt = ModelTranslationConfiguration.defaultPrompt
        controller.draftStreamsResponse = true

        controller.startConnectionTest(
            sourceLanguageIdentifier: TranslationSourceLanguageOption.englishID,
            targetLanguageIdentifier: "zh-Hans"
        )

        for _ in 0..<200 {
            switch controller.connectionState {
            case let .succeeded(model, response):
                XCTAssertEqual(model, "fixture-model")
                XCTAssertEqual(response, "connection ok")
                return
            case let .failed(message):
                XCTFail("Connection test failed: \(message)")
                return
            case .idle, .testing:
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTFail("Connection test timed out")
    }

    private func fakeEndpoint(path: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["LURUME_TRANSLATION_FAKE_SERVER"],
              root.hasPrefix("http://127.0.0.1:"),
              let url = URL(string: root + path)
        else {
            throw XCTSkip("Set LURUME_TRANSLATION_FAKE_SERVER to run localhost XPC integration tests.")
        }
        return url
    }
}

private struct EmptyTranslationAPIKeyStore: TranslationAPIKeyStoring {
    func read() async throws -> String? { nil }
    func save(_ apiKey: String) async throws {}
    func delete() async throws {}
}

private struct TranslationXPCTestResult {
    let text: String
    let terminalKind: String
    let errorCode: String?
    let message: String?
}

private final class TranslationXPCTestClient: NSObject, TranslationXPCClientProtocol, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var requestID: String?
    private var text = ""
    private var terminalEvent: TranslationXPCEvent?
    private var terminalSemaphore = DispatchSemaphore(value: 0)
    private var cancelAfterFirstDelta = false
    private var didCancel = false

    override init() {
        connection = NSXPCConnection(serviceName: TranslationXPCConstants.serviceName)
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: TranslationXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: TranslationXPCClientProtocol.self)
        connection.exportedObject = self
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func ping(timeout: TimeInterval) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedString()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            semaphore.signal()
        }) as? TranslationXPCServiceProtocol else {
            throw TranslationXPCTestError.proxyUnavailable
        }
        proxy.ping { value in
            result.set(value)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success,
              let value = result.get()
        else {
            throw TranslationXPCTestError.timeout
        }
        return value
    }

    func translate(
        endpoint: URL,
        streamsResponse: Bool,
        cancelAfterFirstDelta: Bool = false
    ) throws -> TranslationXPCTestResult {
        let requestID = UUID().uuidString
        lock.lock()
        self.requestID = requestID
        text = ""
        terminalEvent = nil
        terminalSemaphore = DispatchSemaphore(value: 0)
        self.cancelAfterFirstDelta = cancelAfterFirstDelta
        didCancel = false
        lock.unlock()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.terminalSemaphore.signal()
        }) as? TranslationXPCServiceProtocol else {
            throw TranslationXPCTestError.proxyUnavailable
        }
        let request = TranslationXPCRequest(
            requestID: requestID,
            endpoint: endpoint.absoluteString,
            model: "fixture-model",
            systemPrompt: "Translate the selected text.",
            selectedText: "fixture selection only",
            apiKey: nil,
            streamsResponse: streamsResponse
        )
        let accepted = DispatchSemaphore(value: 0)
        let acceptance = LockedBool()
        proxy.start(request) { value in
            acceptance.set(value)
            accepted.signal()
        }
        guard accepted.wait(timeout: .now() + 3) == .success,
              acceptance.get() == true
        else {
            throw TranslationXPCTestError.notAccepted
        }
        guard terminalSemaphore.wait(timeout: .now() + 8) == .success else {
            throw TranslationXPCTestError.timeout
        }

        lock.lock()
        defer { lock.unlock() }
        guard let terminalEvent else {
            throw TranslationXPCTestError.connectionInvalidated
        }
        return TranslationXPCTestResult(
            text: text,
            terminalKind: terminalEvent.kind,
            errorCode: terminalEvent.errorCode,
            message: terminalEvent.message
        )
    }

    func receive(_ event: TranslationXPCEvent) {
        lock.lock()
        guard event.requestID == requestID else {
            lock.unlock()
            return
        }
        if event.kind == "delta", let delta = event.text {
            text += delta
            if cancelAfterFirstDelta, !didCancel {
                didCancel = true
                lock.unlock()
                (connection.remoteObjectProxy as? TranslationXPCServiceProtocol)?
                    .cancel(requestID: event.requestID)
                return
            }
        }
        if ["completed", "failed", "cancelled"].contains(event.kind) {
            terminalEvent = event
            lock.unlock()
            terminalSemaphore.signal()
            return
        }
        lock.unlock()
    }
}

private final class LockedString: @unchecked Sendable {
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

private final class LockedBool: @unchecked Sendable {
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

private enum TranslationXPCTestError: Error {
    case proxyUnavailable
    case notAccepted
    case timeout
    case connectionInvalidated
}
