import Foundation

enum TranslationServiceError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case nonTextResponse
    case http(status: Int)
    case frameTooLarge
    case streamEndedEarly
    case firstByteTimeout
    case streamIdleTimeout
    case requestTimeout
    case connection
    case cancelled

    var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidResponse: "invalid_response"
        case .nonTextResponse: "non_text_response"
        case .http: "http"
        case .frameTooLarge: "frame_too_large"
        case .streamEndedEarly: "stream_ended_early"
        case .firstByteTimeout: "first_byte_timeout"
        case .streamIdleTimeout: "stream_idle_timeout"
        case .requestTimeout: "request_timeout"
        case .connection: "connection"
        case .cancelled: "cancelled"
        }
    }

    var safeMessage: String {
        switch self {
        case .invalidRequest:
            "翻译请求无效。"
        case .invalidResponse:
            "服务返回了无法解析的响应。"
        case .nonTextResponse:
            "服务没有返回文本译文。"
        case let .http(status):
            switch status {
            case 401, 403:
                "认证失败（HTTP \(status)），请检查 API Key。"
            case 404:
                "找不到翻译端点或模型（HTTP 404）。"
            case 408:
                "翻译服务等待请求超时（HTTP 408）。"
            case 409:
                "翻译请求与服务当前状态冲突（HTTP 409）。"
            case 429:
                "请求过于频繁（HTTP 429），请稍后重试。"
            case 500...599:
                "翻译服务暂时不可用（HTTP \(status)）。"
            default:
                "翻译服务返回 HTTP \(status)。"
            }
        case .frameTooLarge:
            "服务返回的单个流式事件超过 1 MiB 上限。"
        case .streamEndedEarly:
            "流式响应在完成前中断。"
        case .firstByteTimeout:
            "等待服务开始响应超时。"
        case .streamIdleTimeout:
            "流式响应长时间没有产生新文本。"
        case .requestTimeout:
            "翻译请求超时。"
        case .connection:
            "无法连接翻译服务。"
        case .cancelled:
            "翻译已停止。"
        }
    }
}

struct OpenAIChatCompletionRequestBuilder {
    static func makeURLRequest(from request: TranslationXPCRequest) throws -> URLRequest {
        guard let components = URLComponents(string: request.endpoint),
              let url = components.url,
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              (scheme == "https" || scheme == "http"),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme != "http" || ["localhost", "127.0.0.1", "::1"].contains(
                  rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
              ),
              !request.model.isEmpty,
              !request.systemPrompt.isEmpty,
              !request.selectedText.isEmpty
        else {
            throw TranslationServiceError.invalidRequest
        }

        let body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.selectedText]
            ],
            "stream": request.streamsResponse
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            request.streamsResponse ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        if let apiKey = request.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }
}

struct OpenAIChatCompletionResponseParser {
    static func parseText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw TranslationServiceError.invalidResponse
        }
        guard let content = message["content"] as? String else {
            throw TranslationServiceError.nonTextResponse
        }
        guard !content.isEmpty else {
            throw TranslationServiceError.nonTextResponse
        }
        return content
    }

}

enum OpenAIStreamEvent: Equatable {
    case delta(String)
    case finished
}

struct OpenAIChatCompletionSSEParser {
    static let maximumFrameBytes = 1_048_576

    private var buffer = Data()
    private(set) var receivedText = false
    private(set) var receivedCompletionMarker = false
    private(set) var acceptedDataFrameCount = 0

    mutating func append(_ data: Data) throws -> [OpenAIStreamEvent] {
        buffer.append(data)
        guard buffer.count <= Self.maximumFrameBytes || nextBoundary(in: buffer) != nil else {
            buffer.removeAll(keepingCapacity: false)
            throw TranslationServiceError.frameTooLarge
        }

        var result: [OpenAIStreamEvent] = []
        while let boundary = nextBoundary(in: buffer) {
            let frame = buffer.prefix(boundary.lowerBound)
            buffer.removeSubrange(..<boundary.upperBound)
            guard frame.count <= Self.maximumFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw TranslationServiceError.frameTooLarge
            }
            result.append(contentsOf: try parseFrame(Data(frame)))
        }
        guard buffer.count <= Self.maximumFrameBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw TranslationServiceError.frameTooLarge
        }
        return result
    }

    mutating func finish() throws -> [OpenAIStreamEvent] {
        if !buffer.isEmpty {
            guard buffer.count <= Self.maximumFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw TranslationServiceError.frameTooLarge
            }
            let finalFrame = buffer
            buffer.removeAll(keepingCapacity: false)
            let events = try parseFrame(finalFrame)
            if receivedCompletionMarker {
                return events
            }
        }
        guard receivedCompletionMarker else {
            throw TranslationServiceError.streamEndedEarly
        }
        return []
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        receivedText = false
        receivedCompletionMarker = false
        acceptedDataFrameCount = 0
    }

    private func nextBoundary(in data: Data) -> Range<Data.Index>? {
        let lf = Data([0x0A, 0x0A])
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lfRange = data.range(of: lf)
        let crlfRange = data.range(of: crlf)
        return switch (lfRange, crlfRange) {
        case let (lhs?, rhs?): lhs.lowerBound <= rhs.lowerBound ? lhs : rhs
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private mutating func parseFrame(_ data: Data) throws -> [OpenAIStreamEvent] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranslationServiceError.invalidResponse
        }
        var dataLines: [String] = []
        text.enumerateLines { line, _ in
            guard !line.hasPrefix(":"), line.hasPrefix("data:") else { return }
            var value = String(line.dropFirst(5))
            if value.first == " " {
                value.removeFirst()
            }
            dataLines.append(value)
        }
        guard !dataLines.isEmpty else { return [] }

        let payload = dataLines.joined(separator: "\n")
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" {
            acceptedDataFrameCount += 1
            receivedCompletionMarker = true
            return [.finished]
        }
        guard let payloadData = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first
        else {
            throw TranslationServiceError.invalidResponse
        }
        acceptedDataFrameCount += 1

        var events: [OpenAIStreamEvent] = []
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            receivedText = true
            events.append(.delta(content))
        }
        if let finishReason = first["finish_reason"], !(finishReason is NSNull) {
            receivedCompletionMarker = true
        }
        return events
    }
}
