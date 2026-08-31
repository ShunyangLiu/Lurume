import Foundation

enum TranslationXPCConstants {
    static let serviceName = "app.lurume.Lurume.TranslationService"
}

@objc(LurumeTranslationXPCServiceProtocol)
protocol TranslationXPCServiceProtocol {
    func start(_ request: TranslationXPCRequest, withReply reply: @escaping (Bool) -> Void)
    func cancel(requestID: String)
    func ping(withReply reply: @escaping (String) -> Void)
}

@objc(LurumeTranslationXPCClientProtocol)
protocol TranslationXPCClientProtocol {
    func receive(_ event: TranslationXPCEvent)
}

@objc(LurumeTranslationXPCRequest)
final class TranslationXPCRequest: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let requestID: String
    let endpoint: String
    let model: String
    let systemPrompt: String
    let selectedText: String
    let apiKey: String?
    let streamsResponse: Bool

    init(
        requestID: String,
        endpoint: String,
        model: String,
        systemPrompt: String,
        selectedText: String,
        apiKey: String?,
        streamsResponse: Bool
    ) {
        self.requestID = requestID
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.selectedText = selectedText
        self.apiKey = apiKey
        self.streamsResponse = streamsResponse
    }

    required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID") as String?,
              let endpoint = coder.decodeObject(of: NSString.self, forKey: "endpoint") as String?,
              let model = coder.decodeObject(of: NSString.self, forKey: "model") as String?,
              let systemPrompt = coder.decodeObject(of: NSString.self, forKey: "systemPrompt") as String?,
              let selectedText = coder.decodeObject(of: NSString.self, forKey: "selectedText") as String?
        else {
            return nil
        }

        self.requestID = requestID
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.selectedText = selectedText
        self.apiKey = coder.decodeObject(of: NSString.self, forKey: "apiKey") as String?
        self.streamsResponse = coder.decodeBool(forKey: "streamsResponse")
    }

    func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(endpoint as NSString, forKey: "endpoint")
        coder.encode(model as NSString, forKey: "model")
        coder.encode(systemPrompt as NSString, forKey: "systemPrompt")
        coder.encode(selectedText as NSString, forKey: "selectedText")
        if let apiKey {
            coder.encode(apiKey as NSString, forKey: "apiKey")
        }
        coder.encode(streamsResponse, forKey: "streamsResponse")
    }
}

@objc(LurumeTranslationXPCEvent)
final class TranslationXPCEvent: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let requestID: String
    let kind: String
    let text: String?
    let errorCode: String?
    let message: String?

    init(
        requestID: String,
        kind: String,
        text: String? = nil,
        errorCode: String? = nil,
        message: String? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.text = text
        self.errorCode = errorCode
        self.message = message
    }

    required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID") as String?,
              let kind = coder.decodeObject(of: NSString.self, forKey: "kind") as String?
        else {
            return nil
        }

        self.requestID = requestID
        self.kind = kind
        self.text = coder.decodeObject(of: NSString.self, forKey: "text") as String?
        self.errorCode = coder.decodeObject(of: NSString.self, forKey: "errorCode") as String?
        self.message = coder.decodeObject(of: NSString.self, forKey: "message") as String?
    }

    func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(kind as NSString, forKey: "kind")
        if let text {
            coder.encode(text as NSString, forKey: "text")
        }
        if let errorCode {
            coder.encode(errorCode as NSString, forKey: "errorCode")
        }
        if let message {
            coder.encode(message as NSString, forKey: "message")
        }
    }
}
