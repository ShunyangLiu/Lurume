import XCTest

final class OpenAIChatCompletionsTests: XCTestCase {
    func testRequestContainsOnlyMinimumChatCompletionsFields() throws {
        let request = TranslationXPCRequest(
            requestID: "request-1",
            endpoint: "https://example.test/v1/chat/completions",
            model: "example-model",
            systemPrompt: "Translate to Chinese.",
            selectedText: "Only this selection",
            apiKey: "test-placeholder-key",
            streamsResponse: true
        )

        let urlRequest = try OpenAIChatCompletionRequestBuilder.makeURLRequest(from: request)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any]
        )

        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream"])
        XCTAssertEqual(body["model"] as? String, "example-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [
            ["role": "system", "content": "Translate to Chinese."],
            ["role": "user", "content": "Only this selection"]
        ])
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder-key")
    }

    func testEmptyAPIKeyIsNotSentAndNonStreamingAcceptsJSON() throws {
        let request = makeRequest(apiKey: "", streamsResponse: false)
        let urlRequest = try OpenAIChatCompletionRequestBuilder.makeURLRequest(from: request)

        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testRequestBuilderRejectsUnsafeEndpointVariants() {
        let endpoints = [
            "http://example.test/v1/chat/completions",
            "https://user:pass@example.test/v1/chat/completions",
            "https://example.test/v1/chat/completions?token=value",
            "https://example.test/v1/chat/completions#fragment",
            "file:///tmp/chat/completions",
        ]

        for endpoint in endpoints {
            let request = TranslationXPCRequest(
                requestID: "request-1",
                endpoint: endpoint,
                model: "example-model",
                systemPrompt: "Translate.",
                selectedText: "Selection",
                apiKey: nil,
                streamsResponse: true
            )
            XCTAssertThrowsError(try OpenAIChatCompletionRequestBuilder.makeURLRequest(from: request)) {
                XCTAssertEqual($0 as? TranslationServiceError, .invalidRequest)
            }
        }
    }

    func testNonStreamingResponseExtractsOnlyTextContent() throws {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"译文"}}]}"#.utf8)
        XCTAssertEqual(try OpenAIChatCompletionResponseParser.parseText(from: data), "译文")
    }

    func testNonStreamingResponseRejectsNonTextContent() {
        let data = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"译文"}]}}]}"#.utf8)
        XCTAssertThrowsError(try OpenAIChatCompletionResponseParser.parseText(from: data)) { error in
            XCTAssertEqual(error as? TranslationServiceError, .nonTextResponse)
        }
    }

    func testStreamingParserHandlesArbitraryChunksCRLFAndDone() throws {
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\r\n\r\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\n"
            + "data: [DONE]\n\n"
        let bytes = Array(stream.utf8)
        var parser = OpenAIChatCompletionSSEParser()
        var events: [OpenAIStreamEvent] = []
        for byte in bytes {
            events.append(contentsOf: try parser.append(Data([byte])))
        }

        XCTAssertEqual(events, [.delta("你"), .delta("好"), .finished])
        XCTAssertTrue(parser.receivedText)
        XCTAssertTrue(parser.receivedCompletionMarker)
        XCTAssertNoThrow(try parser.finish())
    }

    func testCommentsAndEmptyHeartbeatsAreIgnored() throws {
        var parser = OpenAIChatCompletionSSEParser()
        let events = try parser.append(Data(": keep-alive\n\n\n\ndata:\n\n".utf8))

        XCTAssertEqual(events, [])
        XCTAssertEqual(parser.acceptedDataFrameCount, 0)
        XCTAssertFalse(parser.receivedText)
        XCTAssertFalse(parser.receivedCompletionMarker)
    }

    func testPrematureStreamEndIsRejected() throws {
        var parser = OpenAIChatCompletionSSEParser()
        _ = try parser.append(
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n".utf8)
        )

        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? TranslationServiceError, .streamEndedEarly)
        }
    }

    func testUnterminatedFrameOverOneMiBIsRejectedAndReleased() throws {
        var parser = OpenAIChatCompletionSSEParser()
        let oversized = Data(repeating: 0x61, count: OpenAIChatCompletionSSEParser.maximumFrameBytes + 1)

        XCTAssertThrowsError(try parser.append(oversized)) { error in
            XCTAssertEqual(error as? TranslationServiceError, .frameTooLarge)
        }
        parser.reset()
        XCTAssertEqual(
            try parser.append(Data("data: [DONE]\n\n".utf8)),
            [.finished]
        )
    }

    func testOversizedTailAfterACompleteFrameIsRejectedImmediately() throws {
        var parser = OpenAIChatCompletionSSEParser()
        var input = Data(": harmless\n\n".utf8)
        input.append(Data(repeating: 0x61, count: OpenAIChatCompletionSSEParser.maximumFrameBytes + 1))

        XCTAssertThrowsError(try parser.append(input)) { error in
            XCTAssertEqual(error as? TranslationServiceError, .frameTooLarge)
        }
    }

    func testTimeoutConstantsAreLockedForCheckpointOne() {
        XCTAssertEqual(TranslationTimeoutPolicy.production.firstByte, 30)
        XCTAssertEqual(TranslationTimeoutPolicy.production.streamIdle, 90)
        XCTAssertEqual(TranslationTimeoutPolicy.production.nonStreamingTotal, 120)
        XCTAssertEqual(OpenAIChatCompletionSSEParser.maximumFrameBytes, 1_048_576)
    }

    func testSecureCodingRoundTripDoesNotInventAPIKey() throws {
        let original = makeRequest(apiKey: nil, streamsResponse: true)
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: original,
            requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: TranslationXPCRequest.self, from: archived)
        )

        XCTAssertEqual(decoded.requestID, original.requestID)
        XCTAssertEqual(decoded.selectedText, original.selectedText)
        XCTAssertNil(decoded.apiKey)
    }

    private func makeRequest(apiKey: String?, streamsResponse: Bool) -> TranslationXPCRequest {
        TranslationXPCRequest(
            requestID: "request-1",
            endpoint: "http://127.0.0.1:8765/v1/chat/completions",
            model: "example-model",
            systemPrompt: "Translate.",
            selectedText: "Selection",
            apiKey: apiKey,
            streamsResponse: streamsResponse
        )
    }
}
