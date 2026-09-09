import Foundation
import XCTest

final class P7TranslationNetworkOperationTests: XCTestCase {
    func testSharedTransportReusesSocketWithoutReusingAuthorization() throws {
        let endpoint = try fakeEndpoint(path: "/connection-reuse")
        let pool = TranslationSessionPool()
        defer { pool.invalidate() }
        var ports: [String] = []
        for index in 0..<4 {
            let key = index == 2 ? nil : "fixture-\(index)"
            let result = try runOperation(endpoint: endpoint, streamsResponse: index % 2 == 0,
                policy: .production, sessionPool: pool, apiKey: key)
            XCTAssertEqual(result.last?.kind, "completed")
            let parts = result.compactMap(\.text).joined().split(separator: ":", omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 2)
            guard parts.count == 2 else { return }
            ports.append(String(parts[0]))
            XCTAssertEqual(String(parts[1]), key.map { "Bearer " + $0 } ?? "")
        }
        XCTAssertEqual(Set(ports).count, 1, "Sequential requests should reuse the same TCP connection")
    }

    func testSharedTransportSurvivesTimeoutAndStillRejectsCrossOriginRedirect() throws {
        let pool = TranslationSessionPool()
        defer { pool.invalidate() }
        let timeout = try runOperation(endpoint: fakeEndpoint(path: "/slow-nonstream"), streamsResponse: false,
            policy: .init(firstByte: 1, streamIdle: 1, nonStreamingTotal: 0.1), sessionPool: pool)
        XCTAssertEqual(timeout.last?.errorCode, "request_timeout")
        let redirected = try runOperation(endpoint: fakeEndpoint(path: "/redirect/cross-origin"), streamsResponse: true,
            policy: .production, sessionPool: pool)
        XCTAssertEqual(redirected.last?.errorCode, "invalid_response")
        let success = try runOperation(endpoint: fakeEndpoint(path: "/nonstream"), streamsResponse: false,
            policy: .production, sessionPool: pool)
        XCTAssertEqual(success.last?.kind, "completed")
    }

    func testCancellingOnePooledRequestDoesNotCancelAnother() throws {
        let pool = TranslationSessionPool()
        defer { pool.invalidate() }
        let slowURL = try fakeEndpoint(path: "/slow-stream")
        let otherURL = try fakeEndpoint(path: "/slow-nonstream")
        let partial = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let cancelled = TranslationEventRecorder()
        let surviving = TranslationEventRecorder()
        func request(_ endpoint: URL, stream: Bool) -> TranslationXPCRequest {
            TranslationXPCRequest(requestID: UUID().uuidString, endpoint: endpoint.absoluteString,
                model: "fixture-model", systemPrompt: "Translate the selected text.",
                selectedText: "fixture selection only", apiKey: nil, streamsResponse: stream)
        }
        let first = TranslationRequestOperation(request: request(slowURL, stream: true), sessionPool: pool,
            eventHandler: { event in
                cancelled.append(event)
                if event.kind == "delta" { partial.signal() }
            }, completionHandler: { _ in })
        let second = TranslationRequestOperation(request: request(otherURL, stream: false), sessionPool: pool,
            eventHandler: { surviving.append($0) }, completionHandler: { _ in completed.signal() })
        first.start()
        second.start()
        XCTAssertEqual(partial.wait(timeout: .now() + 2), .success)
        first.cancel()
        XCTAssertEqual(completed.wait(timeout: .now() + 4), .success)
        XCTAssertEqual(cancelled.events.last?.kind, "cancelled")
        XCTAssertEqual(surviving.events.last?.kind, "completed")
    }

    func testTruncatedResponsesRetainTextAndNeverEmitCompleted() throws {
        for (path, streaming) in [("/truncated-stream", true), ("/truncated-nonstream", false)] {
            let result = try runOperation(endpoint: fakeEndpoint(path: path), streamsResponse: streaming,
                policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2))
            XCTAssertEqual(result.compactMap(\.text).joined(), "partial")
            XCTAssertEqual(result.last?.errorCode, "output_truncated")
            XCTAssertFalse(result.contains { $0.kind == "completed" })
        }
    }

    func testFinalFrameWithoutSeparatorStillDeliversText() throws {
        let result = try runOperation(endpoint: fakeEndpoint(path: "/final-frame-stream"), streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2))
        XCTAssertEqual(result.compactMap(\.text).joined(), "final text")
        XCTAssertEqual(result.last?.kind, "completed")
    }

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

    func testSameOriginRedirectCanComplete() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/redirect/same-origin"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.compactMap(\.text).joined(), "分块译文")
        XCTAssertEqual(result.last?.kind, "completed")
    }

    func testCrossOriginRedirectIsRejectedBeforeFollowing() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/redirect/cross-origin"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "invalid_response")
    }

    func testStreamingHTTPErrorFinishesWithoutWaitingForBodyEOF() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/error/429-hang"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "http")
        XCTAssertTrue(result.last?.message?.contains("HTTP 429") == true)
    }

    func testSameOriginRedirectLoopIsRejectedAtLocalHopLimit() throws {
        let result = try runOperation(
            endpoint: fakeEndpoint(path: "/redirect/loop"),
            streamsResponse: true,
            policy: TranslationTimeoutPolicy(firstByte: 1, streamIdle: 1, nonStreamingTotal: 2)
        )

        XCTAssertEqual(result.last?.kind, "failed")
        XCTAssertEqual(result.last?.errorCode, "invalid_response")
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
        policy: TranslationTimeoutPolicy,
        sessionPool: TranslationSessionPool? = nil,
        apiKey: String? = nil
    ) throws -> [TranslationXPCEvent] {
        let recorder = TranslationEventRecorder()
        let completed = DispatchSemaphore(value: 0)
        let request = TranslationXPCRequest(
            requestID: UUID().uuidString,
            endpoint: endpoint.absoluteString,
            model: "fixture-model",
            systemPrompt: "Translate the selected text.",
            selectedText: "fixture selection only",
            apiKey: apiKey,
            streamsResponse: streamsResponse
        )
        let operation = TranslationRequestOperation(
            request: request,
            sessionPool: sessionPool,
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
