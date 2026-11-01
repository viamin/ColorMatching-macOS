import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins `PaletteAPIClient`'s wire contract to the published `color_matching`
/// OpenAPI 3 spec (viamin/color_matching#110 / #113, served at
/// `GET /api/v1/openapi.json`).
///
/// The spec fixture committed beside this test is transcribed from the
/// server's `open_api_spex` definitions for the two endpoints the client
/// consumes. These tests document, in executable form, what the generated
/// `swift-openapi-runtime` client (issue #39) must keep true:
///
/// - the endpoints and the `printer_profile_id` query parameter the client
///   sends are the ones the spec declares,
/// - every field the spec marks `required` is a field this client decodes, so
///   spec-conformant responses always decode (the client is deliberately a
///   tolerant superset: it treats several spec-required fields as optional),
/// - the `responses` map is free-form in the spec, so its per-entry shape
///   (`brightness`, `source`, …) is a client/server convention, not spec law.
final class OpenAPISpecConformanceTests: XCTestCase {
    private var recordedRequests: RecordedRequests!

    override func setUp() {
        super.setUp()
        recordedRequests = RecordedRequests()
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Document shape

    func testSpecServesTheEndpointsTheClientUses() throws {
        let spec = try loadSpec()
        XCTAssertTrue((spec["openapi"] as? String)?.hasPrefix("3.") == true, "not an OpenAPI 3 document")
        XCTAssertNotNil(components(spec)["bearerAuth"], "bearer auth scheme missing")
        XCTAssertNotNil(getOperation("/api/v1/printer_profiles", in: spec), "printer_profiles GET missing")
        XCTAssertNotNil(getOperation("/api/v1/colors", in: spec), "colors GET missing")
    }

    func testColorsOperationTakesThePrinterProfileIDQueryTheClientSends() throws {
        let spec = try loadSpec()
        let operation = try XCTUnwrap(getOperation("/api/v1/colors", in: spec), "colors GET missing")
        let parameters = array(operation["parameters"])

        let requiredQueryNames = Set(parameters.filter { ($0["required"] as? Bool) == true }
            .filter { ($0["in"] as? String) == "query" }
            .compactMap { $0["name"] as? String })

        XCTAssertEqual(requiredQueryNames, ["printer_profile_id"])
        let profileID = try XCTUnwrap(parameters.first { $0["name"] as? String == "printer_profile_id" })
        XCTAssertEqual(dictionary(profileID["schema"])["type"] as? String, "integer")
    }

    // MARK: - Required-field coverage

    /// Everything the spec promises the server will always send on
    /// `GET /printer_profiles` must be a field the client decodes.
    func testPrinterProfileRequiredFieldsAreClientDecodable() throws {
        let schema = try resolveResponseSchema("/api/v1/printer_profiles", named: "PrinterProfilesResponse")
        let itemSchema = try arrayItemSchema(of: schema, property: "printer_profiles")

        assertRequired(itemSchema, coveredByClientWireKeys: Self.printerProfileWireKeys)
        XCTAssertEqual(Set(dictionary(itemSchema["properties"]).keys), Self.printerProfileWireKeys)
    }

    /// Everything the spec promises for each color item on `GET /colors` must
    /// be client-decodable — the migration target for the generated client.
    func testColorItemRequiredFieldsAreClientDecodable() throws {
        let schema = try resolveResponseSchema("/api/v1/colors", named: "ColorsResponse")
        let itemSchema = try arrayItemSchema(of: schema, property: "colors")

        assertRequired(itemSchema, coveredByClientWireKeys: Self.paletteColorWireKeys)
        XCTAssertEqual(Set(dictionary(itemSchema["properties"]).keys), Self.paletteColorWireKeys)
        XCTAssertEqual(
            dictionary(dictionary(itemSchema["properties"])["palette_name"])["nullable"] as? Bool, true,
            "palette_name is the one declared-nullable field"
        )
    }

    /// The per-illuminant `responses` map is `additionalProperties: true` in
    /// the spec: its entry shape is convention, not contract. Recorded as a
    /// migration finding — the generated client will type it loosely.
    func testResponsesMapIsFreeFormInTheSpec() throws {
        let schema = try resolveResponseSchema("/api/v1/colors", named: "ColorsResponse")
        let itemSchema = try arrayItemSchema(of: schema, property: "colors")
        let responses = dictionary(itemSchema["properties"])["responses"]

        XCTAssertEqual(dictionary(responses)["additionalProperties"] as? Bool, true)
    }

    // MARK: - Client round-trip against spec-conformant payloads

    /// End-to-end: payloads carrying every spec-required field decode through
    /// `PaletteAPIClient` unchanged. Whatever sits behind these endpoints after
    /// the generated-client migration must keep these green.
    func testClientDecodesSpecConformantPrinterProfilesPayload() async throws {
        let client = makeClient(response: (200, specConformantProfilesBody()))

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(recordedRequests.paths, ["/api/v1/printer_profiles"])
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testClientDecodesSpecConformantColorsPayload() async throws {
        let client = makeClient(response: (200, specConformantColorsBody()))

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(recordedRequests.paths, ["/api/v1/colors"])
        XCTAssertEqual(recordedRequests.queryItems["printer_profile_id"], "7")
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.colors.first?.name, "Red 12")
        XCTAssertEqual(fetched.colors.first?.paletteId, 5)
        XCTAssertEqual(fetched.colors.first?.sortOrder, 12)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.colors.first?.toDomain()?.brightness(for: .red), 0.87)
    }

    // MARK: - Wire keys the Swift DTOs decode (snake_case on the wire)

    /// `PrinterProfileDTO` CodingKeys under `.convertFromSnakeCase`.
    private static let printerProfileWireKeys: Set<String> = [
        "id", "printer_make_model", "paper_type", "ink_type"
    ]

    /// `PaletteColorDTO` CodingKeys under `.convertFromSnakeCase`.
    private static let paletteColorWireKeys: Set<String> = [
        "id", "name", "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses"
    ]

    private func assertRequired(
        _ schema: [String: Any],
        coveredByClientWireKeys clientKeys: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let required = strings(schema["required"])
        XCTAssertTrue(
            required.isSubset(of: clientKeys),
            "spec requires \(required.subtracting(clientKeys).sorted()) which the client does not decode",
            file: file, line: line
        )
    }

    // MARK: - Spec-conformant samples

    private func specConformantProfilesBody() -> Data {
        """
        {"printer_profiles": [
          {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"}
        ]}
        """.data(using: .utf8)!
    }

    private func specConformantColorsBody() -> Data {
        """
        {"printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
         "colors": [
           {"id": 123, "name": "Red 12", "hex": "#C64A35",
            "rgb": {"r": 198, "g": 74, "b": 53},
            "palette_id": 5, "palette_name": "Default", "sort_order": 12,
            "responses": {"red": {"brightness": 0.87, "source": "measurement"},
                          "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5}}}
         ]}
        """.data(using: .utf8)!
    }

    // MARK: - Spec plumbing

    private func spec(file: StaticString = #filePath) throws -> [String: Any] {
        try loadSpec(file: file)
    }

    private func loadSpec(file: StaticString = #filePath) throws -> [String: Any] {
        let fixtureURL = URL(fileURLWithPath: "\(file)", isDirectory: false)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openapi/v1-openapi.json", isDirectory: false)
        let data = try Data(contentsOf: fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func components(_ spec: [String: Any]) -> [String: Any] {
        dictionary(dictionary(spec["components"])["securitySchemes"])
    }

    private func getOperation(_ path: String, in spec: [String: Any]) -> [String: Any]? {
        guard let pathItem = dictionary(spec["paths"])[path] as? [String: Any],
              let operation = pathItem["get"] as? [String: Any] else { return nil }
        return operation
    }

    /// Resolves the `200` response schema of an operation to a named component.
    private func resolveResponseSchema(_ path: String, named name: String) throws -> [String: Any] {
        let operation = try XCTUnwrap(getOperation(path, in: spec()))
        let okResponse = dictionary(dictionary(operation["responses"])["200"])
        let schemaRef = dictionary(dictionary(okResponse["content"])["application/json"])["schema"]
        let resolved = resolve(dictionary(schemaRef), in: try spec())
        XCTAssertEqual(resolved["title"] as? String, name, "unexpected response schema for \(path)")
        return resolved
    }

    /// Resolves the item schema of an array-valued response property.
    private func arrayItemSchema(of schema: [String: Any], property: String) throws -> [String: Any] {
        let arraySchema = dictionary(dictionary(schema["properties"])[property])
        return resolve(dictionary(arraySchema["items"]), in: try spec())
    }

    private func resolve(_ schema: [String: Any], in spec: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String else { return schema }
        let name = ref.replacingOccurrences(of: "#/components/schemas/", with: "")
        return dictionary(dictionary(dictionary(spec["components"])["schemas"])[name])
    }

    private func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func array(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private func strings(_ value: Any?) -> Set<String> {
        Set(value as? [String] ?? [])
    }

    // MARK: - Client plumbing

    private func makeClient(response: (status: Int, body: Data)) -> PaletteAPIClient {
        MockURLProtocol.handler = { request in
            self.recordedRequests.append(request)
            let http = HTTPURLResponse(
                url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil
            )!
            return (http, response.body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            session: URLSession(configuration: configuration)
        )
    }
}

/// Thread-safe record of the requests the client issued during one test.
private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Snapshot] = []

    struct Snapshot {
        let path: String
        let queryItems: [String: String]
    }

    func append(_ request: URLRequest) {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let snapshot = Snapshot(
            path: components?.path ?? "",
            queryItems: Dictionary(
                uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )
        )
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.map(\.path)
    }

    var queryItems: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.first?.queryItems ?? [:]
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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
