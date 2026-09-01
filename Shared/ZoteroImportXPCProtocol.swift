import Foundation

enum ZoteroImportXPCConstants {
    static let serviceName = "app.lurume.Lurume.ZoteroImportService"
}

@objc(LurumeZoteroImportXPCServiceProtocol)
protocol ZoteroImportXPCServiceProtocol {
    func start(_ request: ZoteroImportXPCRequest, withReply reply: @escaping (Bool) -> Void)
    func cancel(requestID: String)
    func ping(withReply reply: @escaping (String) -> Void)
}

@objc(LurumeZoteroImportXPCClientProtocol)
protocol ZoteroImportXPCClientProtocol {
    func receive(_ event: ZoteroImportXPCEvent)
}

enum ZoteroImportRequestKind: String, Codable, Sendable {
    case probe
    case libraries
    case collections
    case items
    case attachmentURL
}

@objc(LurumeZoteroImportXPCRequest)
final class ZoteroImportXPCRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let requestID: String
    let kind: String
    let libraryType: String?
    let libraryID: Int
    let itemKey: String?
    let startIndex: Int
    let limit: Int
    let serverID: String?
    let testingOrigin: String?

    init(
        requestID: String,
        kind: ZoteroImportRequestKind,
        libraryType: String? = nil,
        libraryID: Int = 0,
        itemKey: String? = nil,
        startIndex: Int = 0,
        limit: Int = 100,
        serverID: String? = nil,
        testingOrigin: String? = nil
    ) {
        self.requestID = requestID
        self.kind = kind.rawValue
        self.libraryType = libraryType
        self.libraryID = libraryID
        self.itemKey = itemKey
        self.startIndex = startIndex
        self.limit = limit
        self.serverID = serverID
        self.testingOrigin = testingOrigin
    }

    required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID") as String?,
              let kind = coder.decodeObject(of: NSString.self, forKey: "kind") as String? else {
            return nil
        }
        self.requestID = requestID
        self.kind = kind
        self.libraryType = coder.decodeObject(of: NSString.self, forKey: "libraryType") as String?
        self.libraryID = coder.decodeInteger(forKey: "libraryID")
        self.itemKey = coder.decodeObject(of: NSString.self, forKey: "itemKey") as String?
        self.startIndex = coder.decodeInteger(forKey: "startIndex")
        self.limit = coder.decodeInteger(forKey: "limit")
        self.serverID = coder.decodeObject(of: NSString.self, forKey: "serverID") as String?
        self.testingOrigin = coder.decodeObject(of: NSString.self, forKey: "testingOrigin") as String?
    }

    func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(kind as NSString, forKey: "kind")
        if let libraryType { coder.encode(libraryType as NSString, forKey: "libraryType") }
        coder.encode(libraryID, forKey: "libraryID")
        if let itemKey { coder.encode(itemKey as NSString, forKey: "itemKey") }
        coder.encode(startIndex, forKey: "startIndex")
        coder.encode(limit, forKey: "limit")
        if let serverID { coder.encode(serverID as NSString, forKey: "serverID") }
        if let testingOrigin { coder.encode(testingOrigin as NSString, forKey: "testingOrigin") }
    }
}

@objc(LurumeZoteroImportXPCEvent)
final class ZoteroImportXPCEvent: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let requestID: String
    let kind: String
    let payload: Data?
    let errorCode: String?
    let message: String?

    init(
        requestID: String,
        kind: String,
        payload: Data? = nil,
        errorCode: String? = nil,
        message: String? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.payload = payload
        self.errorCode = errorCode
        self.message = message
    }

    required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID") as String?,
              let kind = coder.decodeObject(of: NSString.self, forKey: "kind") as String? else {
            return nil
        }
        self.requestID = requestID
        self.kind = kind
        self.payload = coder.decodeObject(of: NSData.self, forKey: "payload") as Data?
        self.errorCode = coder.decodeObject(of: NSString.self, forKey: "errorCode") as String?
        self.message = coder.decodeObject(of: NSString.self, forKey: "message") as String?
    }

    func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(kind as NSString, forKey: "kind")
        if let payload { coder.encode(payload as NSData, forKey: "payload") }
        if let errorCode { coder.encode(errorCode as NSString, forKey: "errorCode") }
        if let message { coder.encode(message as NSString, forKey: "message") }
    }
}

struct ZoteroServicePayload: Codable, Equatable, Sendable {
    var probe: ZoteroServiceProbe?
    var libraries: [ZoteroServiceLibrary]?
    var collections: [ZoteroServiceCollection]?
    var items: [ZoteroServiceItem]?
    var attachmentURL: String?
    var totalResults: Int?
}

struct ZoteroServiceProbe: Codable, Equatable, Sendable {
    var apiVersion: Int
    var schemaVersion: Int
    var serverID: String
}

struct ZoteroServiceLibrary: Codable, Equatable, Identifiable, Sendable {
    var type: String
    var id: Int
    var name: String
    var version: Int?

    var stableID: String { "\(type):\(id)" }
}

struct ZoteroServiceCollection: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var version: Int
    var name: String
    var parentCollection: String?

    var id: String { key }
}

struct ZoteroServiceCreator: Codable, Equatable, Sendable {
    var creatorType: String
    var firstName: String?
    var lastName: String?
    var name: String?
}

struct ZoteroServiceItem: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var version: Int
    var itemType: String
    var title: String
    var creators: [ZoteroServiceCreator]
    var date: String?
    var parsedYear: Int?
    var publicationTitle: String?
    var conferenceName: String?
    var proceedingsTitle: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var DOI: String?
    var ISBN: String?
    var ISSN: String?
    var extra: String?
    var publisher: String?
    var place: String?
    var edition: String?
    var url: String?
    var language: String?
    var abstractNote: String?
    var collections: [String]
    var parentItem: String?
    var contentType: String?
    var filename: String?
    var linkMode: String?
    var ignoredTagCount: Int
    var ignoredRelationCount: Int

    var id: String { key }
}
