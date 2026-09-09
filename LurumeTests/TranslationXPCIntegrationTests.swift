import Foundation
import Combine
import XCTest
@testable import Lurume

final class TranslationXPCIntegrationTests: XCTestCase {
    @MainActor
    func testTranslationLatencyBreakdown() async throws {
        guard let root = ProcessInfo.processInfo.environment["LURUME_TRANSLATION_FAKE_SERVER"],
              root.hasPrefix("http://127.0.0.1:") else {
            throw XCTSkip("Requires localhost translation fixture")
        }
        let configuration = try ModelTranslationConfigurationValidator.validate(
            baseURL: root + "/v1", model: "fixture-model", streamsResponse: true,
            prompt: ModelTranslationConfiguration.defaultPrompt)
        var results: [[String: Any]] = []
        let sender = LatencyRecordingSender()
        for both in [false, true] {
            for automatic in [false, true] {
                for iteration in 0..<5 {
                    let controller = TranslationController(
                        keyStore: EmptyTranslationAPIKeyStore(), modelRequestSender: sender)
                    let preferences = TranslationRequestPreferences(
                        engine: both ? .both : .customModel, sourceLanguageIdentifier: "en",
                        targetLanguageIdentifier: "zh-Hans", modelConfiguration: configuration,
                        modelOriginIsConfirmed: true)
                    let start = ProcessInfo.processInfo.systemUptime
                    var firstDisplay: Double?
                    let subscription = controller.$translatedText.sink { text in
                        if text != nil, firstDisplay == nil {
                            firstDisplay = ProcessInfo.processInfo.systemUptime
                        }
                    }
                    controller.receiveSelection(PDFSelectionEvent(rawText: "fixture selection only", pageIndex: 0),
                                                paperID: UUID(), paperName: "Latency fixture",
                                                automaticTranslation: automatic, preferences: preferences)
                    if !automatic { controller.requestTranslation(preferences: preferences) }
                    for _ in 0..<5000 {
                        if controller.state == .success { break }
                        if case .failed = controller.state { break }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    let end = ProcessInfo.processInfo.systemUptime
                    XCTAssertEqual(controller.state, .success)
                    let sent = try XCTUnwrap(sender.sentAt)
                    let received = try XCTUnwrap(sender.firstDeltaAt)
                    let displayed = try XCTUnwrap(firstDisplay)
                    results.append([
                        "both": both, "automatic": automatic, "iteration": iteration,
                        "preparation_ms": (sent - start) * 1000,
                        "xpc_http_first_delta_ms": (received - sent) * 1000,
                        "dispatch_display_ms": (displayed - received) * 1000,
                        "first_display_ms": (displayed - start) * 1000,
                        "completion_ms": (end - start) * 1000
                    ])
                    subscription.cancel()
                    controller.clear()
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print("TRANSLATION_LATENCY_JSON: " + String(decoding: data, as: UTF8.self))
    }

    func testNativeMessagesStreamsAndCompletesThroughXPC() throws {
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }
        let result = try client.translate(
            endpoint: fakeEndpoint(path: "/anthropic/stream"), streamsResponse: true, apiFormat: .anthropic
        )
        XCTAssertEqual(result.text, "native translation")
        XCTAssertEqual(result.terminalKind, "completed")
    }

    func testNativeMessagesNonStreamingThroughXPC() throws {
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }
        let result = try client.translate(
            endpoint: fakeEndpoint(path: "/anthropic/nonstream"), streamsResponse: false, apiFormat: .anthropic
        )
        XCTAssertEqual(result.text, "native translation")
        XCTAssertEqual(result.terminalKind, "completed")
    }

    func testNativeMessagesPreservesTruncatedTextInBothModes() throws {
        for streaming in [true, false] {
            let client = TranslationXPCTestClient()
            defer { client.invalidate() }
            let result = try client.translate(
                endpoint: fakeEndpoint(path: "/anthropic/truncated"), streamsResponse: streaming, apiFormat: .anthropic
            )
            XCTAssertEqual(result.text, "native translation")
            XCTAssertEqual(result.terminalKind, "failed")
            XCTAssertEqual(result.errorCode, "output_truncated")
        }
    }

    func testNativeMessagesEarlyEOFIsNotSuccess() throws {
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }
        let result = try client.translate(
            endpoint: fakeEndpoint(path: "/anthropic/early-eof"), streamsResponse: true, apiFormat: .anthropic
        )
        XCTAssertEqual(result.text, "native translation")
        XCTAssertEqual(result.terminalKind, "failed")
        XCTAssertEqual(result.errorCode, "stream_ended_early")
    }

    func testNativeMessagesCanBeCancelledThroughXPC() throws {
        let client = TranslationXPCTestClient()
        defer { client.invalidate() }
        let result = try client.translate(
            endpoint: fakeEndpoint(path: "/anthropic/slow"), streamsResponse: true,
            cancelAfterFirstDelta: true, apiFormat: .anthropic
        )
        XCTAssertEqual(result.text, "native translation")
        XCTAssertEqual(result.terminalKind, "cancelled")
    }

    func testLateInvalidationOrInterruptionCannotFailNewConnection() throws {
        let factory = StubConnectionFactory()
        let client = TranslationXPCClient(idleTimeout: 0, makeConnection: { factory.make() })
        let events = StubEventRecorder()
        let first = stubRequest("first")
        try client.start(first) { events.append($0) }
        let old = try XCTUnwrap(factory.connections.first)
        let delayedInvalidation = old.invalidationHandler
        let delayedInterruption = old.interruptionHandler
        client.receive(TranslationXPCEvent(requestID: "first", kind: "completed"))
        try client.start(stubRequest("second")) { events.append($0) }
        delayedInvalidation?()
        delayedInterruption?()
        XCTAssertTrue(client.hasActiveConnectionForTesting)
        XCTAssertEqual(events.kinds, ["completed"])
        client.receive(TranslationXPCEvent(requestID: "second", kind: "completed"))
        XCTAssertEqual(events.kinds, ["completed", "completed"])
    }

    func testIdleConnectionIsReusedThenReleasedAndRecreated() async throws {
        let factory = StubConnectionFactory()
        let client = TranslationXPCClient(idleTimeout: 0.05, makeConnection: { factory.make() })
        try client.start(stubRequest("reuse-1")) { _ in }
        client.receive(.init(requestID: "reuse-1", kind: "completed"))
        XCTAssertTrue(client.hasActiveConnectionForTesting)
        try client.start(stubRequest("reuse-2")) { _ in }
        XCTAssertEqual(factory.connections.count, 1)
        // The first request's idle timer cannot close an active second request.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(client.hasActiveConnectionForTesting)
        client.receive(.init(requestID: "reuse-2", kind: "completed"))
        for _ in 0..<100 {
            if !client.hasActiveConnectionForTesting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(client.hasActiveConnectionForTesting)
        try client.start(stubRequest("reuse-3")) { _ in }
        XCTAssertEqual(factory.connections.count, 2)
        client.cancel(requestID: "reuse-3")
    }

    private func stubRequest(_ id: String) -> TranslationXPCRequest {
        TranslationXPCRequest(requestID: id, endpoint: "http://127.0.0.1:1/v1/chat/completions",
            model: "fixture", systemPrompt: "Translate", selectedText: "test", apiKey: nil,
            streamsResponse: true)
    }

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
        let requestSender = TranslationXPCClient()
        let controller = ModelTranslationSettingsController(
            keyStore: EmptyTranslationAPIKeyStore(),
            requestSender: requestSender
        )
        controller.draftBaseURL = root + "/v1/chat/completions"
        await controller.waitForAPIKeyLoad()
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
                XCTAssertTrue(requestSender.hasActiveConnectionForTesting)
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

    @MainActor
    func testControllerStreamsSelectedTextThroughEmbeddedService() async throws {
        guard let root = ProcessInfo.processInfo.environment["LURUME_TRANSLATION_FAKE_SERVER"],
              root.hasPrefix("http://127.0.0.1:")
        else {
            throw XCTSkip("Set LURUME_TRANSLATION_FAKE_SERVER to run localhost XPC integration tests.")
        }
        let configuration = try ModelTranslationConfigurationValidator.validate(
            baseURL: root + "/v1",
            model: "fixture-model",
            streamsResponse: true,
            prompt: ModelTranslationConfiguration.defaultPrompt
        )
        let preferences = TranslationRequestPreferences(
            engine: .customModel,
            sourceLanguageIdentifier: "en",
            targetLanguageIdentifier: "zh-Hans",
            modelConfiguration: configuration,
            modelOriginIsConfirmed: true
        )
        let requestSender = TranslationXPCClient()
        let controller = TranslationController(
            sourceLanguageRecognizer: IntegrationEnglishSourceRecognizer(),
            availabilityChecker: IntegrationAvailabilityChecker(),
            keyStore: EmptyTranslationAPIKeyStore(),
            modelRequestSender: requestSender
        )
        controller.receiveSelection(
            PDFSelectionEvent(rawText: "  fixture   selection\nonly  ", pageIndex: 4),
            paperID: UUID(),
            paperName: "fixture paper metadata must stay local",
            automaticTranslation: false,
            preferences: preferences
        )

        controller.requestTranslation(preferences: preferences)

        for _ in 0..<300 {
            switch controller.state {
            case .success:
                XCTAssertEqual(controller.translatedText, "connection ok")
                XCTAssertEqual(controller.resultSource, .customModel(model: "fixture-model"))
                XCTAssertNil(controller.configuration)
                XCTAssertTrue(requestSender.hasActiveConnectionForTesting)
                return
            case let .failed(message), let .interrupted(message):
                XCTFail("Controller translation failed: \(message)")
                return
            default:
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTFail("Controller translation timed out")
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

private final class StubConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StubXPCConnection] = []
    var connections: [StubXPCConnection] { lock.withLock { values } }
    func make() -> NSXPCConnection {
        let value = StubXPCConnection(serviceName: "app.lurume.test.no-service")
        lock.withLock { values.append(value) }
        return value
    }
}

private final class StubXPCConnection: NSXPCConnection, @unchecked Sendable {
    private let service = StubTranslationService()
    override func resume() {}
    override func invalidate() {}
    override var remoteObjectProxy: Any { service }
    override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any { service }
}

private final class StubTranslationService: NSObject, TranslationXPCServiceProtocol {
    func start(_ request: TranslationXPCRequest, withReply reply: @escaping (Bool) -> Void) { reply(true) }
    func cancel(requestID: String) {}
    func ping(withReply reply: @escaping (String) -> Void) { reply("ready") }
}

private final class StubEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var kinds: [String] { lock.withLock { values } }
    func append(_ event: TranslationXPCEvent) { lock.withLock { values.append(event.kind) } }
}

private struct EmptyTranslationAPIKeyStore: TranslationAPIKeyStoring {
    func read() async throws -> String? { nil }
    func save(_ apiKey: String) async throws {}
    func delete() async throws {}
}

private struct IntegrationEnglishSourceRecognizer: SourceLanguageRecognizing {
    func language(for text: String) -> Locale.Language? {
        Locale.Language(identifier: "en")
    }
}

private struct IntegrationAvailabilityChecker: TranslationAvailabilityChecking {
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        .installed
    }
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
        cancelAfterFirstDelta: Bool = false,
        apiFormat: TranslationAPIFormat = .openAI
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
            apiKey: apiFormat == .anthropic ? "native-fixture-key" : nil,
            streamsResponse: streamsResponse,
            apiFormat: apiFormat
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

private final class LatencyRecordingSender: TranslationRequestSending, @unchecked Sendable {
    private let sender = TranslationXPCClient()
    private let lock = NSLock()
    private var sent: Double?
    private var first: Double?
    var sentAt: Double? { lock.withLock { sent } }
    var firstDeltaAt: Double? { lock.withLock { first } }
    func start(_ request: TranslationXPCRequest,
               eventHandler: @escaping @Sendable (TranslationXPCEvent) -> Void) throws {
        lock.withLock { sent = ProcessInfo.processInfo.systemUptime; first = nil }
        try sender.start(request) { [self] event in
            if event.kind == "delta" {
                lock.withLock { if first == nil { first = ProcessInfo.processInfo.systemUptime } }
            }
            eventHandler(event)
        }
    }
    func cancel(requestID: String) { sender.cancel(requestID: requestID) }
}
