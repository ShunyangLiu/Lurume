import XCTest

final class ZoteroImportServiceCoreTests: XCTestCase {
    func testProductionOriginIsFixedLoopback() throws {
        let request = try ZoteroEndpointPolicy.production.makeURLRequest(from: makeRequest(kind: .probe))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:23119/api/")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Zotero-API-Version"), "3")
    }

    func testItemsEndpointIsConstructedFromValidatedFields() throws {
        let request = try ZoteroEndpointPolicy.production.makeURLRequest(from: makeRequest(
            kind: .items,
            libraryType: "group",
            libraryID: 42,
            start: 200,
            limit: 50,
            serverID: "server-fixture"
        ))
        XCTAssertEqual(request.url?.path, "/api/groups/42/items")
        XCTAssertEqual(
            Set(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []),
            Set([
                URLQueryItem(name: "start", value: "200"),
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "include", value: "data")
            ])
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Zotero-Server-ID"), "server-fixture")
    }

    func testRejectsUnknownLibraryTypeAndUnsafeKey() {
        XCTAssertThrowsError(try ZoteroEndpointPolicy.production.makeURLRequest(from: makeRequest(
            kind: .collections,
            libraryType: "organization",
            libraryID: 1
        )))
        XCTAssertThrowsError(try ZoteroEndpointPolicy.production.makeURLRequest(from: makeRequest(
            kind: .attachmentURL,
            libraryType: "user",
            libraryID: 0,
            itemKey: "../secret"
        )))
    }

    func testRejectsNonLoopbackAndHostnameOrigins() {
        for value in ["http://localhost:23119", "http://192.168.1.5:23119", "https://127.0.0.1:23119"] {
            let policy = ZoteroEndpointPolicy.testing(origin: URL(string: value)!)
            XCTAssertThrowsError(try policy.makeURLRequest(from: makeRequest(kind: .probe)))
        }
    }

    func testProbeRequiresVersionAndServerHeaders() throws {
        let response = httpResponse(headers: [
            "Zotero-API-Version": "3",
            "Zotero-Schema-Version": "42",
            "Zotero-Server-ID": "fixture-server"
        ])
        let payload = try ZoteroResponseParser.parse(
            data: Data(),
            response: response,
            kind: .probe,
            requestLimit: 100
        )
        XCTAssertEqual(
            payload.probe,
            ZoteroServiceProbe(apiVersion: 3, schemaVersion: 42, serverID: "fixture-server")
        )
    }

    func testProbeRejectsUnsupportedAPIVersion() {
        let response = httpResponse(headers: [
            "Zotero-API-Version": "4",
            "Zotero-Schema-Version": "42",
            "Zotero-Server-ID": "fixture-server"
        ])
        XCTAssertThrowsError(try ZoteroResponseParser.parse(
            data: Data(),
            response: response,
            kind: .probe,
            requestLimit: 100
        )) { error in
            XCTAssertEqual(error as? ZoteroServiceError, .unsupportedAPIVersion)
        }
    }

    func testProbeTreatsMissingSchemaAsInvalidResponse() {
        let response = httpResponse(headers: [
            "Zotero-API-Version": "3",
            "Zotero-Server-ID": "fixture-server"
        ])
        XCTAssertThrowsError(try ZoteroResponseParser.parse(
            data: Data(),
            response: response,
            kind: .probe,
            requestLimit: 100
        )) { error in
            XCTAssertEqual(error as? ZoteroServiceError, .invalidResponse)
        }
    }

    func testParsesSanitizedCollectionPage() throws {
        let data = Data(#"[{"key":"COLL1","version":7,"data":{"name":"研究","parentCollection":false}}]"#.utf8)
        let payload = try ZoteroResponseParser.parse(
            data: data,
            response: httpResponse(headers: ["Total-Results": "1"]),
            kind: .collections,
            requestLimit: 100
        )
        XCTAssertEqual(payload.collections, [
            ZoteroServiceCollection(key: "COLL1", version: 7, name: "研究", parentCollection: nil)
        ])
        XCTAssertEqual(payload.totalResults, 1)
    }

    func testParsesItemWithoutPassingUnknownResponseFields() throws {
        let data = Data(#"[{"key":"ITEM1","version":2,"data":{"itemType":"journalArticle","title":"Paper","creators":[{"creatorType":"author","firstName":"Ada","lastName":"Lovelace"}],"date":"2024-01-01","collections":["COLL1"],"unknownSecret":"must-not-cross-xpc"}}]"#.utf8)
        let payload = try ZoteroResponseParser.parse(
            data: data,
            response: httpResponse(headers: ["Total-Results": "1"]),
            kind: .items,
            requestLimit: 100
        )
        XCTAssertEqual(payload.items?.first?.title, "Paper")
        XCTAssertEqual(payload.items?.first?.parsedYear, 2024)
        XCTAssertFalse(String(data: try JSONEncoder().encode(payload), encoding: .utf8)!.contains("unknownSecret"))
    }

    func testParsesAttachmentAndNoteWithFieldsMissingBySchema() throws {
        let data = Data(#"[{"key":"PDF1","version":2,"data":{"itemType":"attachment","title":"PDF","parentItem":false,"contentType":"application/pdf","filename":"paper.pdf","linkMode":"linked_file"}},{"key":"NOTE1","version":1,"data":{"itemType":"note"}}]"#.utf8)
        let payload = try ZoteroResponseParser.parse(
            data: data,
            response: httpResponse(headers: ["Total-Results": "2"]),
            kind: .items,
            requestLimit: 100
        )
        XCTAssertEqual(payload.items?.count, 2)
        XCTAssertEqual(payload.items?.first?.creators, [])
        XCTAssertNil(payload.items?.first?.parentItem)
        XCTAssertEqual(payload.items?.last?.title, "")
    }

    func testRejectsPresentOptionalFieldWithWrongType() {
        let data = Data(#"[{"key":"ITEM1","version":1,"data":{"itemType":"book","title":"Book","creators":[],"collections":[],"date":2024}}]"#.utf8)
        XCTAssertThrowsError(try ZoteroResponseParser.parse(
            data: data,
            response: httpResponse(headers: ["Total-Results": "1"]),
            kind: .items,
            requestLimit: 100
        ))
    }

    func testRejectsPageLargerThanRequestedLimit() {
        let object = #"{"key":"COLL1","version":1,"data":{"name":"A"}}"#
        let data = Data("[\(object),\(object)]".utf8)
        XCTAssertThrowsError(try ZoteroResponseParser.parse(
            data: data,
            response: httpResponse(headers: ["Total-Results": "2"]),
            kind: .collections,
            requestLimit: 1
        ))
    }

    func testAttachmentCandidateMustBeLocalFileURL() throws {
        let valid = try ZoteroResponseParser.parse(
            data: Data("file:///Users/test/Zotero/storage/ABC/paper.pdf\n".utf8),
            response: httpResponse(),
            kind: .attachmentURL,
            requestLimit: 100
        )
        XCTAssertEqual(valid.attachmentURL, "file:///Users/test/Zotero/storage/ABC/paper.pdf")
        XCTAssertThrowsError(try ZoteroResponseParser.parse(
            data: Data("https://example.com/paper.pdf".utf8),
            response: httpResponse(),
            kind: .attachmentURL,
            requestLimit: 100
        ))
    }

    func testConnectionRequirementPinsMainBundleAndTeam() {
        let requirement = ZoteroImportXPCConnectionPolicy.codeSigningRequirement(teamIdentifier: "TEAM123")
        XCTAssertTrue(requirement.contains("identifier \"app.lurume.Lurume\""))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"TEAM123\""))
    }

    private func makeRequest(
        kind: ZoteroImportRequestKind,
        libraryType: String? = nil,
        libraryID: Int = 0,
        itemKey: String? = nil,
        start: Int = 0,
        limit: Int = 100,
        serverID: String? = nil
    ) -> ZoteroImportXPCRequest {
        ZoteroImportXPCRequest(
            requestID: UUID().uuidString,
            kind: kind,
            libraryType: libraryType,
            libraryID: libraryID,
            itemKey: itemKey,
            startIndex: start,
            limit: limit,
            serverID: serverID
        )
    }

    private func httpResponse(headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:23119/api/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
