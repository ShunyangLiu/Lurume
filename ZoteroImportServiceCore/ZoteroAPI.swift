import Foundation

enum ZoteroServiceError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case unsupportedAPIVersion
    case serverChanged
    case http(status: Int)
    case firstByteTimeout
    case idleTimeout
    case requestTimeout
    case connection
    case cancelled

    var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidResponse: "invalid_response"
        case .responseTooLarge: "response_too_large"
        case .unsupportedAPIVersion: "unsupported_api_version"
        case .serverChanged: "server_changed"
        case let .http(status): "http_\(status)"
        case .firstByteTimeout: "first_byte_timeout"
        case .idleTimeout: "idle_timeout"
        case .requestTimeout: "request_timeout"
        case .connection: "connection"
        case .cancelled: "cancelled"
        }
    }

    var safeMessage: String {
        switch self {
        case .invalidRequest:
            "Zotero 导入请求无效。"
        case .invalidResponse:
            "Zotero 返回了无法验证的响应。"
        case .responseTooLarge:
            "Zotero 返回的数据超过安全上限。"
        case .unsupportedAPIVersion:
            "当前 Zotero Local API 版本不受支持。"
        case .serverChanged:
            "Zotero 实例已变化，请重新开始迁移。"
        case let .http(status):
            switch status {
            case 403:
                "Zotero 拒绝了本地访问。请在 Zotero 设置中允许其他应用与 Zotero 通信。"
            case 404:
                "Zotero 中找不到请求的文献或附件。"
            case 412:
                "Zotero 实例已变化，请重新开始迁移。"
            case 429:
                "Zotero 暂时限制了请求，请稍后重试。"
            case 500...599:
                "Zotero Local API 暂时不可用（HTTP \(status)）。"
            default:
                "Zotero Local API 返回 HTTP \(status)。"
            }
        case .firstByteTimeout:
            "等待 Zotero 开始响应超时。"
        case .idleTimeout:
            "Zotero 响应长时间没有继续。"
        case .requestTimeout:
            "Zotero 请求超时。"
        case .connection:
            "无法连接 Zotero。请确认 Zotero 正在运行。"
        case .cancelled:
            "Zotero 迁移已停止。"
        }
    }
}

struct ZoteroEndpointPolicy: Equatable, Sendable {
    static let production = ZoteroEndpointPolicy(
        origin: URL(string: "http://127.0.0.1:23119")!,
        permitsTestingPort: false
    )

    let origin: URL
    private let permitsTestingPort: Bool

    private init(origin: URL, permitsTestingPort: Bool) {
        self.origin = origin
        self.permitsTestingPort = permitsTestingPort
    }

#if DEBUG
    static func testing(origin: URL) -> Self {
        Self(origin: origin, permitsTestingPort: true)
    }
#endif

    func makeURLRequest(from request: ZoteroImportXPCRequest) throws -> URLRequest {
        guard isAllowedOrigin(origin),
              let kind = ZoteroImportRequestKind(rawValue: request.kind),
              UUID(uuidString: request.requestID) != nil,
              (1...100).contains(request.limit),
              (0...1_000_000).contains(request.startIndex),
              request.serverID.map(isBoundedHeaderValue) ?? true
        else {
            throw ZoteroServiceError.invalidRequest
        }

        var path: String
        switch kind {
        case .probe:
            guard request.libraryType == nil, request.itemKey == nil else {
                throw ZoteroServiceError.invalidRequest
            }
            path = "/api/"
        case .libraries:
            guard request.libraryType == nil, request.itemKey == nil else {
                throw ZoteroServiceError.invalidRequest
            }
            path = "/api/users/0/groups"
        case .collections, .items, .attachmentURL:
            let libraryPath = try validatedLibraryPath(
                type: request.libraryType,
                id: request.libraryID
            )
            path = "/api/\(libraryPath)"
            switch kind {
            case .collections:
                guard request.itemKey == nil else { throw ZoteroServiceError.invalidRequest }
                path += "/collections"
            case .items:
                guard request.itemKey == nil else { throw ZoteroServiceError.invalidRequest }
                path += "/items"
            case .attachmentURL:
                guard let key = request.itemKey, isValidKey(key) else {
                    throw ZoteroServiceError.invalidRequest
                }
                path += "/items/\(key)/file/view/url"
            default:
                throw ZoteroServiceError.invalidRequest
            }
        }

        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw ZoteroServiceError.invalidRequest
        }
        components.path = path
        if kind != .probe && kind != .attachmentURL {
            components.queryItems = [
                URLQueryItem(name: "start", value: String(request.startIndex)),
                URLQueryItem(name: "limit", value: String(request.limit))
            ]
            if kind == .items {
                components.queryItems?.append(URLQueryItem(name: "include", value: "data"))
            }
        }
        guard let url = components.url else { throw ZoteroServiceError.invalidRequest }

        var result = URLRequest(url: url)
        result.httpMethod = "GET"
        result.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        result.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        result.setValue(
            kind == .attachmentURL ? "text/plain" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        if let serverID = request.serverID {
            result.setValue(serverID, forHTTPHeaderField: "Zotero-Server-ID")
        }
        return result
    }

    func isSameOrigin(_ url: URL) -> Bool {
        normalizedOrigin(url) == normalizedOrigin(origin)
    }

    private func validatedLibraryPath(type: String?, id: Int) throws -> String {
        switch type {
        case "user" where id == 0:
            "users/0"
        case "group" where id > 0:
            "groups/\(id)"
        default:
            throw ZoteroServiceError.invalidRequest
        }
    }

    private func isAllowedOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "127.0.0.1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let port = url.port,
              port == 23_119 || (permitsTestingPort && (1...65_535).contains(port))
        else {
            return false
        }
        return true
    }

    private func normalizedOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let port = url.port
        else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    private func isValidKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
                    .contains($0)
            }
    }

    private func isBoundedHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

enum ZoteroResponseParser {
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumStringBytes = 32 * 1_024
    static let maximumJSONDepth = 12
    static let maximumPageItems = 100
    static let maximumTotalResults = 1_000_000

    static func parse(
        data: Data,
        response: HTTPURLResponse,
        kind: ZoteroImportRequestKind,
        requestLimit: Int
    ) throws -> ZoteroServicePayload {
        guard data.count <= maximumResponseBytes else {
            throw ZoteroServiceError.responseTooLarge
        }
        if kind == .probe {
            return try parseProbe(response: response)
        }
        if kind == .attachmentURL {
            return try parseAttachmentURL(data: data)
        }
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data),
              let array = root as? [Any],
              array.count <= min(maximumPageItems, requestLimit)
        else {
            throw ZoteroServiceError.invalidResponse
        }
        try validateJSON(root, depth: 0)
        let total = try totalResults(from: response, pageCount: array.count)

        switch kind {
        case .libraries:
            return ZoteroServicePayload(
                libraries: try array.map(parseLibrary),
                totalResults: total
            )
        case .collections:
            return ZoteroServicePayload(
                collections: try array.map(parseCollection),
                totalResults: total
            )
        case .items:
            return ZoteroServicePayload(
                items: try array.map(parseItem),
                totalResults: total
            )
        default:
            throw ZoteroServiceError.invalidResponse
        }
    }

    private static func parseProbe(response: HTTPURLResponse) throws -> ZoteroServicePayload {
        guard let rawAPIVersion = response.value(forHTTPHeaderField: "Zotero-API-Version"),
              let apiVersion = Int(rawAPIVersion)
        else {
            throw ZoteroServiceError.invalidResponse
        }
        guard apiVersion == 3 else {
            throw ZoteroServiceError.unsupportedAPIVersion
        }
        guard
              let rawSchemaVersion = response.value(forHTTPHeaderField: "Zotero-Schema-Version"),
              let schemaVersion = Int(rawSchemaVersion),
              schemaVersion > 0,
              let serverID = response.value(forHTTPHeaderField: "Zotero-Server-ID"),
              !serverID.isEmpty,
              serverID.utf8.count <= 256
        else {
            throw ZoteroServiceError.invalidResponse
        }
        return ZoteroServicePayload(
            probe: ZoteroServiceProbe(
                apiVersion: apiVersion,
                schemaVersion: schemaVersion,
                serverID: serverID
            )
        )
    }

    private static func parseAttachmentURL(data: Data) throws -> ZoteroServicePayload {
        guard data.count <= 8_192,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= maximumStringBytes,
              let url = URL(string: raw),
              url.isFileURL,
              url.host == nil || url.host?.isEmpty == true
        else {
            throw ZoteroServiceError.invalidResponse
        }
        return ZoteroServicePayload(attachmentURL: raw)
    }

    private static func parseLibrary(_ value: Any) throws -> ZoteroServiceLibrary {
        let object = try dictionary(value)
        let data = try dictionary(object["data"])
        let id = int(data["id"]) ?? int(object["id"])
        guard let id, id > 0,
              let name = nonemptyString(data["name"]),
              let version = nonnegativeInt(object["version"] ?? data["version"])
        else { throw ZoteroServiceError.invalidResponse }
        return ZoteroServiceLibrary(type: "group", id: id, name: name, version: version)
    }

    private static func parseCollection(_ value: Any) throws -> ZoteroServiceCollection {
        let object = try dictionary(value)
        let data = try dictionary(object["data"])
        guard let key = validKey(object["key"] ?? data["key"]),
              let version = nonnegativeInt(object["version"] ?? data["version"]),
              let name = nonemptyString(data["name"])
        else { throw ZoteroServiceError.invalidResponse }
        let parent = try optionalStringField(data, key: "parentCollection", permitsFalse: true)
        if let parent, validKey(parent) == nil { throw ZoteroServiceError.invalidResponse }
        return ZoteroServiceCollection(
            key: key,
            version: version,
            name: name,
            parentCollection: parent
        )
    }

    private static func parseItem(_ value: Any) throws -> ZoteroServiceItem {
        let object = try dictionary(value)
        let data = try dictionary(object["data"])
        guard let key = validKey(object["key"] ?? data["key"]),
              let version = nonnegativeInt(object["version"] ?? data["version"]),
              let itemType = nonemptyString(data["itemType"])
        else { throw ZoteroServiceError.invalidResponse }

        let title = try optionalStringField(data, key: "title") ?? ""
        let rawCreators: [Any]
        if let value = data["creators"] {
            guard let values = value as? [Any], values.count <= 256 else {
                throw ZoteroServiceError.invalidResponse
            }
            rawCreators = values
        } else {
            rawCreators = []
        }
        let rawCollections: [Any]
        if let value = data["collections"] {
            guard let values = value as? [Any], values.count <= 1_024 else {
                throw ZoteroServiceError.invalidResponse
            }
            rawCollections = values
        } else {
            rawCollections = []
        }

        let creators = try rawCreators.map { raw -> ZoteroServiceCreator in
            let creator = try dictionary(raw)
            guard let type = nonemptyString(creator["creatorType"]) else {
                throw ZoteroServiceError.invalidResponse
            }
            let firstName = try optionalStringField(creator, key: "firstName")
            let lastName = try optionalStringField(creator, key: "lastName")
            let name = try optionalStringField(creator, key: "name")
            guard name != nil || firstName != nil || lastName != nil else {
                throw ZoteroServiceError.invalidResponse
            }
            return ZoteroServiceCreator(
                creatorType: type,
                firstName: firstName,
                lastName: lastName,
                name: name
            )
        }
        let collections = try rawCollections.map { value -> String in
            guard let key = validKey(value) else { throw ZoteroServiceError.invalidResponse }
            return key
        }
        let parentItem = try optionalStringField(data, key: "parentItem", permitsFalse: true)
        if let parentItem, validKey(parentItem) == nil { throw ZoteroServiceError.invalidResponse }

        return ZoteroServiceItem(
            key: key,
            version: version,
            itemType: itemType,
            title: title,
            creators: creators,
            date: try optionalStringField(data, key: "date"),
            parsedYear: parsedYear(from: try optionalStringField(data, key: "date")),
            publicationTitle: try optionalStringField(data, key: "publicationTitle"),
            conferenceName: try optionalStringField(data, key: "conferenceName"),
            proceedingsTitle: try optionalStringField(data, key: "proceedingsTitle"),
            volume: try optionalStringField(data, key: "volume"),
            issue: try optionalStringField(data, key: "issue"),
            pages: try optionalStringField(data, key: "pages"),
            DOI: try optionalStringField(data, key: "DOI"),
            ISBN: try optionalStringField(data, key: "ISBN"),
            ISSN: try optionalStringField(data, key: "ISSN"),
            extra: try optionalStringField(data, key: "extra"),
            publisher: try optionalStringField(data, key: "publisher"),
            place: try optionalStringField(data, key: "place"),
            edition: try optionalStringField(data, key: "edition"),
            url: try optionalStringField(data, key: "url"),
            language: try optionalStringField(data, key: "language"),
            abstractNote: try optionalStringField(data, key: "abstractNote"),
            collections: collections,
            parentItem: parentItem,
            contentType: try optionalStringField(data, key: "contentType"),
            filename: try optionalStringField(data, key: "filename"),
            linkMode: try optionalStringField(data, key: "linkMode"),
            ignoredTagCount: try optionalArrayCount(data, key: "tags", maximum: 1_024),
            ignoredRelationCount: try optionalObjectCount(data, key: "relations", maximum: 1_024)
        )
    }

    private static func totalResults(from response: HTTPURLResponse, pageCount: Int) throws -> Int {
        guard let value = response.value(forHTTPHeaderField: "Total-Results") else {
            return pageCount
        }
        guard let total = Int(value), total >= pageCount, total <= maximumTotalResults else {
            throw ZoteroServiceError.invalidResponse
        }
        return total
    }

    private static func validateJSON(_ value: Any, depth: Int) throws {
        guard depth <= maximumJSONDepth else { throw ZoteroServiceError.invalidResponse }
        switch value {
        case let string as String:
            guard string.utf8.count <= maximumStringBytes else {
                throw ZoteroServiceError.responseTooLarge
            }
        case let array as [Any]:
            for element in array { try validateJSON(element, depth: depth + 1) }
        case let object as [String: Any]:
            for (key, element) in object {
                guard key.utf8.count <= maximumStringBytes else {
                    throw ZoteroServiceError.responseTooLarge
                }
                try validateJSON(element, depth: depth + 1)
            }
        case _ as NSNumber, _ as NSNull:
            break
        default:
            throw ZoteroServiceError.invalidResponse
        }
    }

    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw ZoteroServiceError.invalidResponse
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= maximumStringBytes else { return nil }
        return value
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let result = string(value), !result.isEmpty else { return nil }
        return result
    }

    private static func optionalStringField(
        _ object: [String: Any],
        key: String,
        permitsFalse: Bool = false
    ) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        if permitsFalse,
           let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID(),
           number.boolValue == false {
            return nil
        }
        guard let result = string(value) else { throw ZoteroServiceError.invalidResponse }
        return result
    }

    private static func optionalArrayCount(
        _ object: [String: Any],
        key: String,
        maximum: Int
    ) throws -> Int {
        guard let value = object[key] else { return 0 }
        guard let array = value as? [Any], array.count <= maximum else {
            throw ZoteroServiceError.invalidResponse
        }
        return array.count
    }

    private static func optionalObjectCount(
        _ object: [String: Any],
        key: String,
        maximum: Int
    ) throws -> Int {
        guard let value = object[key] else { return 0 }
        guard let dictionary = value as? [String: Any], dictionary.count <= maximum else {
            throw ZoteroServiceError.invalidResponse
        }
        return dictionary.count
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.intValue
        return number.doubleValue == Double(result) ? result : nil
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let result = int(value), result >= 0 else { return nil }
        return result
    }

    private static func validKey(_ value: Any?) -> String? {
        guard let result = nonemptyString(value), result.utf8.count <= 64,
              result.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
                      .contains($0)
              })
        else { return nil }
        return result
    }

    private static func parsedYear(from value: String?) -> Int? {
        guard let value,
              let match = value.range(of: #"(?<!\d)(1\d{3}|20\d{2}|2100)(?!\d)"#, options: .regularExpression),
              let year = Int(value[match])
        else { return nil }
        return year
    }
}
