import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract tests binding `PaletteAPIClient` to the OpenAPI document the
/// `color_matching` server publishes (viamin/color_matching#110, served at
/// `GET /api/v1/openapi.json`).
///
/// The contract snapshot this suite enforces is committed at
/// `Fixtures/openapi/v1/openapi.json` and covers exactly the two operations the
/// app consumes. When the client migrates to a generated `swift-openapi-runtime`
/// client (issue #39), these tests are the migration harness: every request and
/// response shape asserted here must survive the migration byte-for-byte, and
/// `testPackageShipsOpenAPIDocumentForCodegen` fails until the package actually
/// carries the OpenAPI document and generator configuration.
final class PaletteAPIContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - Committed OpenAPI document

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/openapi/v1/openapi.json")

    private func loadDocument(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let document = object as? [String: Any] else {
            XCTFail("OpenAPI fixture is not a valid JSON object", file: file, line: line)
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    /// The fixture must document both consumed operations as authenticated GETs
    /// with JSON responses, and `printer_profile_id` must stay a required query
    /// parameter — the app's palette fetch depends on it.
    func testDocumentCoversBothConsumedOperations() throws {
        let document = try loadDocument()
        let paths = try XCTUnwrap(document["paths"] as? [String: Any])

        let profilesGet = try XCTUnwrap(
            ((paths["/api/v1/printer_profiles"] as? [String: Any])?["get"] as? [String: Any])
        )
        XCTAssertEqual(profilesGet["operationId"] as? String, "ColorMatchingWeb.ColorPaletteController.printer_profiles")
        XCTAssertTrue(usesBearerAuth(profilesGet), "printer_profiles must document bearerAuth security")

        let colorsGet = try XCTUnwrap((paths["/api/v1/colors"] as? [String: Any])?["get"] as? [String: Any])
        XCTAssertEqual(colorsGet["operationId"] as? String, "ColorMatchingWeb.ColorPaletteController.colors")
        XCTAssertTrue(usesBearerAuth(colorsGet), "colors must document bearerAuth security")

        let parameters = try XCTUnwrap(colorsGet["parameters"] as? [[String: Any]])
        let profileIDParameter = try XCTUnwrap(parameters.first { ($0["name"] as? String) == "printer_profile_id" })
        XCTAssertEqual(profileIDParameter["in"] as? String, "query")
        XCTAssertEqual(profileIDParameter["required"] as? Bool, true)

        for operation in [profilesGet, colorsGet] {
            let responses = try XCTUnwrap(operation["responses"] as? [String: Any])
            let ok = try XCTUnwrap(responses["200"] as? [String: Any])
            XCTAssertNotNil(((ok["content"] as? [String: Any])?["application/json"] as? [String: Any])?["schema"])
            XCTAssertNotNil(responses["401"], "Both operations document their bearer-token rejection")
        }
    }

    private func usesBearerAuth(_ operation: [String: Any]) -> Bool {
        guard let security = operation["security"] as? [[String: Any]] else { return false }
        return security.contains { $0["bearerAuth"] != nil }
    }

    /// Pins the response schemas the server commits to (translated 1:1 from the
    /// upstream `ApiSchemas`). These `required` lists are the contract the
    /// generated client will be typed against — and they are *stricter* than
    /// the hand-rolled DTO's optional decoding, which is recorded in
    /// `docs/solver-parity-corpus.md` as a migration finding.
    func testDocumentPinsRequiredResponseFields() throws {
        let document = try loadDocument()
        let schemas = try XCTUnwrap(
            ((document["components"] as? [String: Any])?["schemas"] as? [String: Any])
        )

        func required(of schemaName: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
            let schema = try XCTUnwrap(schemas[schemaName] as? [String: Any], "Missing schema \(schemaName)", file: file, line: line)
            return try XCTUnwrap(schema["required"] as? [String], "Schema \(schemaName) has no required list", file: file, line: line)
        }

        XCTAssertEqual(Set(try required(of: "PrinterProfilesResponse")), ["printer_profiles"])
        XCTAssertEqual(Set(try required(of: "PrinterProfile")), ["id", "printer_make_model", "paper_type", "ink_type"])
        XCTAssertEqual(Set(try required(of: "ColorsResponse")), ["printer_profile", "colors"])

        let colors = try XCTUnwrap(schemas["ColorsResponse"] as? [String: Any])
        let colorItem = try XCTUnwrap(
            ((colors["properties"] as? [String: Any])?["colors"] as? [String: Any])?["items"] as? [String: Any]
        )
        XCTAssertEqual(Set(try XCTUnwrap(colorItem["required"] as? [String])), ["id", "name", "hex", "palette_id", "sort_order", "responses"])

        // The server explicitly marks palette_name nullable.
        let colorProperties = try XCTUnwrap(colorItem["properties"] as? [String: Any])
        XCTAssertEqual((colorProperties["palette_name"] as? [String: Any])?["nullable"] as? Bool, true)
    }

    /// Issue #39 deliverable: the package must ship the OpenAPI document the
    /// generated client is built from, plus the `swift-openapi-generator`
    /// plugin and `swift-openapi-runtime` dependency in `Package.swift`.
    ///
    /// This is the red-phase marker for the generated-client migration: it
    /// fails until the implementation lands and stays green afterwards.
    func testPackageShipsOpenAPIDocumentForCodegen() throws {
        // #filePath …/ColorComposerCore/Tests/ColorComposerCoreTests/<this file>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ColorComposerCore (package root)
        let manifest = packageRoot.appendingPathComponent("Package.swift")

        let manifestText = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertTrue(
            manifestText.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator plugin (issue #39)"
        )
        XCTAssertTrue(
            manifestText.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime dependency (issue #39)"
        )

        let conventionalDocumentPaths = [
            "openapi.yaml",
            "openapi.yml",
            "openapi.json",
            "openapi/openapi.yaml",
            "openapi/openapi.json",
            "Sources/ColorComposerCore/OpenAPI/openapi.yaml",
            "Sources/ColorComposerCore/OpenAPI/openapi.json",
        ]
        let shipped = conventionalDocumentPaths
            .map { packageRoot.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertNotNil(
            shipped,
            "The package must commit the OpenAPI document for codegen at a conventional path (openapi.yaml at the package root, or Sources/ColorComposerCore/OpenAPI/)"
        )
    }

    // MARK: - Request conformance (client → server)

    func testPrinterProfilesRequestMatchesDocumentedOperation() async throws {
        let request = try await recordedRequest(for: .printerProfiles)

        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer example-token")
    }

    func testColorsRequestCarriesDocumentedQueryParameter() async throws {
        let request = try await recordedRequest(for: .colors(profileID: 42))

        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "printer_profile_id", value: "42")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Response conformance (server → client)

    /// A payload carrying every field the OpenAPI schema marks required must
    /// decode through the client into the app's profile model.
    func testClientDecodesSpecConformingPrinterProfilesPayload() async throws {
        let client = makeClient(response: specPrinterProfilesPayload(), status: 200)
        let profiles = try await client.fetchPrinterProfiles()

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, 3)
        XCTAssertEqual(profile.printerMakeModel, "Epson SC-P700")
        XCTAssertEqual(profile.paperType, "Ultra Premium Matte")
        XCTAssertEqual(profile.inkType, "Pigment")
    }

    /// A `ColorsResponse` payload that satisfies the committed schema (required
    /// `id`/`name`/`hex`/`palette_id`/`sort_order`/`responses`, nullable
    /// `palette_name`, optional `rgb`) must survive the client and domain
    /// conversion — with missing measurements absent, never zero.
    func testClientDecodesSpecConformingColorsPayload() async throws {
        let client = makeClient(response: specColorsPayload(), status: 200)
        let fetched = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(fetched.profile?.id, 3)
        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 12)
        XCTAssertEqual(color.name, "Sodium Rose")
        XCTAssertEqual(color.paletteId, 5)
        XCTAssertEqual(color.paletteName, nil)
        XCTAssertEqual(color.sortOrder, 2)
        XCTAssertEqual(color.responses["lps"]?.brightness ?? -1, 0.75, accuracy: 1e-12)

        let domain = try XCTUnwrap(color.toDomain())
        XCTAssertEqual(domain.brightness(for: .lps), 0.75)
        XCTAssertNil(domain.brightness(for: .white), "Unmeasured conditions must stay missing, not zero")
    }

    func testUnauthorizedMapsToUnauthorizedError() async {
        let client = makeClient(response: Data("{\"errors\":{}}".utf8), status: 401)

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testNon2xxMapsToBadStatus() async {
        let client = makeClient(response: Data("{\"errors\":{}}".utf8), status: 503)

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableSuccessBodyMapsToMalformedResponse() async {
        let client = makeClient(response: Data("not json".utf8), status: 200)

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Helpers

    private enum Endpoint {
        case printerProfiles
        case colors(profileID: Int)

        /// A success body each endpoint's envelope can decode.
        var successBody: Data {
            switch self {
            case .printerProfiles:
                return Data("{\"printer_profiles\":[]}".utf8)
            case .colors:
                return Data("{\"colors\":[],\"printer_profile\":null}".utf8)
            }
        }

        fileprivate static func successBody(for endpoint: Endpoint) -> Data {
            endpoint.successBody
        }
    }

    private func makeClient(response: Data, status: Int) -> PaletteAPIClient {
        MockURLProtocol.handler = { request in
            (.init(statusCode: status, url: request.url!), response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: "example-token",
            session: URLSession(configuration: configuration)
        )
    }

    private func recordedRequest(for endpoint: Endpoint) async throws -> URLRequest {
        let lock = NSLock()
        var recorded: URLRequest?
        MockURLProtocol.handler = { request in
            lock.lock()
            recorded = request
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Endpoint.successBody(for: endpoint))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: "example-token",
            session: URLSession(configuration: configuration)
        )

        switch endpoint {
        case .printerProfiles: _ = try await client.fetchPrinterProfiles()
        case .colors(let profileID): _ = try await client.fetchColors(printerProfileID: profileID)
        }
        return try XCTUnwrap(recorded, "The client did not issue a request")
    }

    /// Minimal payload satisfying the committed `PrinterProfilesResponse`
    /// schema: every required field present.
    private func specPrinterProfilesPayload() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 3,
              "printer_make_model": "Epson SC-P700",
              "paper_type": "Ultra Premium Matte",
              "ink_type": "Pigment"
            }
          ]
        }
        """.data(using: .utf8)!
    }

    /// Minimal payload satisfying the committed `ColorsResponse` schema,
    /// including the explicitly nullable `palette_name`.
    private func specColorsPayload() -> Data {
        """
        {
          "printer_profile": {
            "id": 3,
            "printer_make_model": "Epson SC-P700",
            "paper_type": "Ultra Premium Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 12,
              "name": "Sodium Rose",
              "hex": "#C64A35",
              "palette_id": 5,
              "palette_name": null,
              "sort_order": 2,
              "responses": {
                "lps": {"brightness": 0.75},
                "red": {"brightness": 0.5}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

// MARK: - Shared test doubles (per-file, matching PaletteAPIClientTests)

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension HTTPURLResponse {
    convenience init(statusCode: Int, url: URL) {
        self.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ assertions: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        assertions(error)
    }
}
