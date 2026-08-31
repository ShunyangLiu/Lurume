import Foundation
import XCTest

final class P7TranslationNetworkOperationTests: XCTestCase {
    func testHeartbeatCommentsCannotPreventFirstFrameTimeout() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/heartbeats"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 0.25, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "first_byte_timeout")
    }

    func testHeartbeatCommentsCannotPreventStreamIdleTimeout() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/idle-heartbeats"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 0.2, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.first?.text, "开始")
        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "stream_idle_timeout")
    }

    func testRoleOnlyFrameCannotLeaveStreamWithoutAWatchdog() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/role-heartbeats"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 0.2, nonStreamingTotal: 2)
        )

        XCTAssertNil(result.first?.text)
        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "stream_idle_timeout")
    }

    func testNonStreamingTotalTimeoutIsIndependentOfFirstFrameTimeout() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/slow-nonstream"),
            streamsResponse: false,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 0.2)
        )

        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "request_timeout")
    }

    func testFakeServerOversizedFrameHitsOneMiBLimit() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/oversized"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "frame_too_large")
    }

    func testFakeServerEarlyEOFIsClassifiedAfterPartialText() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/early-eof"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.first?.text, "partial")
        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "stream_ended_early")
    }

    private func fakeEndpoint(path: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["LURUME_TRANSLATION_FAKE_SERVER"],
              root.hasPrefix("http://127.0.0.1:"),
              let url = URL(string: root + path)
        else {
            throw XCTSkip("Set LURUME_TRANSLATION_FAKE_SERVER to run network operation tests.")
        }
        return url
    }

    private func runOperation(
        endpoint: URL,
        streamsResponse: Bool,
        policy: TranslationTimeoutPolicy
    ) throws -> [TranslationXPCEvent] {
        let recorder = TranslationEventRecorder()
        let completed = DispatchSemaphore(value: 0)
        let request = TranslationXPCRequest(
            requestID: UUID().uuidString,
            endpoint: endpoint.absoluteString,
            model: "fixture-model",
            systemPrompt: "Translate the selected text.",
            selectedText: "fixture selection only",
            apiKey: nil,
            streamsResponse: streamsResponse
        )
        let operation = TranslationRequestOperation(
            request: request,
            timeoutPolicy: policy,
            eventHandler: { event in
                recorder.append(event)
            },
            completionHandler: { _ in
                completed.signal()
            }
        )
        operation.start()
        guard completed.wait(timeout: .now() + 4) == .success else {
            operation.cancel()
            throw TranslationNetworkOperationTestError.timeout
        }
        return recorder.events
    }
}

private final class TranslationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranslationXPCEvent] = []

    var events: [TranslationXPCEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: TranslationXPCEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private enum TranslationNetworkOperationTestError: Error {
    case timeout
}
