import XCTest

final class AnthropicMessagesTests: XCTestCase {
    func testNativeRequestUsesMessagesBodyAndKeyHeader() throws {
        let request = nativeRequest(maximumOutputTokens: 1_024, disablesThinking: true)
        let urlRequest = try OpenAIChatCompletionRequestBuilder.makeURLRequest(from: request)
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "Translate the selected text.")
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "fixture selection only"]])
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
    }

    func testNativeRequestStillHasRequiredTokenBudgetWhenTuningIsOff() throws {
        let request = try OpenAIChatCompletionRequestBuilder.makeURLRequest(from: nativeRequest())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 8_192)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["thinking"])
    }

    func testNativeRequestRejectsHeaderInjection() {
        XCTAssertThrowsError(try OpenAIChatCompletionRequestBuilder.makeURLRequest(
            from: nativeRequest(apiKey: "fixture\r\nInjected: value")
        ))
    }

    func testSecureCodingRoundTripPreservesDialectAndThinkingOption() throws {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: nativeRequest(disablesThinking: true), requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: TranslationXPCRequest.self, from: archive))
        XCTAssertEqual(decoded.apiFormat, .anthropic)
        XCTAssertTrue(decoded.disablesThinking)
    }

    func testNativeNonStreamingIgnoresThinkingAndJoinsTextBlocks() throws {
        let data = Data(#"{"type":"message","content":[{"type":"thinking","thinking":"not translation"},{"type":"text","text":"译文"},{"type":"text","text":"正文"}],"stop_reason":"end_turn"}"#.utf8)
        let result = try OpenAIChatCompletionResponseParser.parse(from: data, apiFormat: .anthropic)
        XCTAssertEqual(result.text, "译文正文")
        XCTAssertNil(result.error)
    }

    func testNativeNonStreamingPreservesPartialOnFailure() throws {
        for (reason, expected) in [("max_tokens", TranslationServiceError.outputTruncated), ("refusal", .contentFiltered), ("tool_use", .invalidResponse)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "message", "content": [["type": "text", "text": "partial"]], "stop_reason": reason
            ])
            let result = try OpenAIChatCompletionResponseParser.parse(from: data, apiFormat: .anthropic)
            XCTAssertEqual(result.text, "partial")
            XCTAssertEqual(result.error, expected)
        }
    }

    func testNativeStreamHandlesSplitUTF8FramesAndRequiresMessageStop() throws {
        var parser = OpenAIChatCompletionSSEParser(apiFormat: .anthropic)
        let data = frame(["type": "message_start", "message": ["type": "message"]])
            + frame(["type": "content_block_start", "content_block": ["type": "text", "text": ""]])
            + frame(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "private fixture"]])
            + frame(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "分块译文"]])
            + frame(["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        var events: [OpenAIStreamEvent] = []
        for byte in data { events += try parser.append(Data([byte])) }
        XCTAssertEqual(events, [.delta("分块译文")])
        XCTAssertFalse(parser.receivedCompletionMarker)
        XCTAssertThrowsError(try parser.finish()) {
            XCTAssertEqual($0 as? TranslationServiceError, .streamEndedEarly)
        }
        XCTAssertEqual(try parser.append(frame(["type": "message_stop"])), [.finished])
        XCTAssertNoThrow(try parser.finish())
    }

    func testNativeStreamRejectsMissingStopReasonAndOpenAIDoneMarker() throws {
        for data in [frame(["type": "message_stop"]), Data("data: [DONE]\n\n".utf8)] {
            var parser = OpenAIChatCompletionSSEParser(apiFormat: .anthropic)
            XCTAssertThrowsError(try parser.append(data))
            XCTAssertFalse(parser.receivedCompletionMarker)
        }
    }

    func testNativeStreamReportsTruncationAndSafeErrors() throws {
        var parser = OpenAIChatCompletionSSEParser(apiFormat: .anthropic)
        XCTAssertEqual(try parser.append(frame([
            "type": "message_delta", "delta": ["stop_reason": "max_tokens"]
        ])), [.failed(.outputTruncated)])
        parser.reset()
        XCTAssertEqual(try parser.append(frame([
            "type": "error", "error": ["message": "private fixture must not cross XPC"]
        ])), [.failed(.connection)])
    }

    func testNativePingAndUnknownEventDoNotSatisfyFirstResponseDeadline() throws {
        var parser = OpenAIChatCompletionSSEParser(apiFormat: .anthropic)
        XCTAssertEqual(try parser.append(frame(["type": "ping"])), [])
        XCTAssertEqual(try parser.append(frame(["type": "future_event"])), [])
        XCTAssertEqual(parser.acceptedDataFrameCount, 0)
        XCTAssertThrowsError(try parser.finish())
    }

    func testNativeStreamRejectsMalformedTextDelta() throws {
        var parser = OpenAIChatCompletionSSEParser(apiFormat: .anthropic)
        XCTAssertThrowsError(try parser.append(frame([
            "type": "content_block_delta", "delta": ["type": "text_delta", "text": 123]
        ])))
    }

    private func frame(_ object: [String: Any]) -> Data {
        Data("data: ".utf8) + (try! JSONSerialization.data(withJSONObject: object)) + Data("\n\n".utf8)
    }

    private func nativeRequest(
        maximumOutputTokens: Int? = nil, disablesThinking: Bool = false, apiKey: String = "fixture-key"
    ) -> TranslationXPCRequest {
        TranslationXPCRequest(
            requestID: "native-fixture", endpoint: "https://example.test/v1/messages", model: "fixture-model",
            systemPrompt: "Translate the selected text.", selectedText: "fixture selection only",
            apiKey: apiKey, streamsResponse: true, maximumOutputTokens: maximumOutputTokens,
            apiFormat: .anthropic, disablesThinking: disablesThinking
        )
    }
}
