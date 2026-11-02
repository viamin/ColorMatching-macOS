import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Guards the generated OpenAPI client migration (#39).
///
/// Two layers:
///
/// 1. **New-contract tests** (`testOpenAPIDocument…`) pin what the migration
///    must add: the OpenAPI document consumed by `swift-openapi-generator`
///    must be committed under `Sources/ColorComposerCore/OpenAPI/` and
///    describe the two `/api/v1` endpoints `PaletteAPIClient` uses. These fail
///    until the migration lands.
/// 2. **Behavior-preservation tests** pin the existing `PaletteAPIClient`
///    contract the migration (or its wrapper) must keep byte-for-byte:
///    `/api/v1` URL building, `Accept`/`Authorization` header handling,
///    status mapping, and envelope decoding. These pass today and must keep
///    passing after the generated client replaces the hand-rolled transport —
///    alongside `ProfileColorCacheTests`, which pins the disk-cache and
///    offline-stale behavior fed by this client.
final class OpenAPIClientMigrationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - New contract: the committed OpenAPI document

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var candidateDocumentURLs: [URL] {
        let directory = packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI", isDirectory: true)
        return ["openapi.yaml", "openapi.yml", "openapi.json"].map {
            directory.appendingPathComponent($0)
        }
    }

    private static func committedDocumentURL() -> URL? {
        candidateDocumentURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The spec that `swift-openapi-generator` consumes must be committed so
    /// the generated client is reproducible from source.
    func testOpenAPIDocumentIsCommitted() {
        guard Self.committedDocumentURL() != nil else {
            XCTFail(
                """
                No OpenAPI document found. Commit the spec consumed by swift-openapi-generator at one of:
                \(Self.candidateDocumentURLs.map(\.path).joined(separator: "\n"))
                """
            )
            return
        }
    }

    /// The document must describe both `/api/v1` endpoints `PaletteAPIClient`
    /// depends on, with GET operations. Structural checks run for JSON; YAML
    /// is checked textually (JSON is preferred so this test can be strict).
    func testOpenAPIDocumentDescribesPaletteEndpoints() throws {
        let url = try XCTUnwrap(
            Self.committedDocumentURL(),
            "OpenAPI document not committed yet (see testOpenAPIDocumentIsCommitted)"
        )

        let requiredPaths = ["/api/v1/printer_profiles", "/api/v1/colors"]
        let data = try Data(contentsOf: url)

        if url.pathExtension == "json" {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any],
                "OpenAPI document is not a JSON object"
            )
            XCTAssertNotNil(object["openapi"], "OpenAPI document must declare its version")
            let paths = try XCTUnwrap(object["paths"] as? [String: Any], "OpenAPI document has no paths")
            for path in requiredPaths {
                let operations = try XCTUnwrap(paths[path] as? [String: Any], "Missing path \(path)")
                XCTAssertNotNil(
                    operations["get"],
                    "Path \(path) must expose a GET operation"
                )
            }
        } else {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for path in requiredPaths {
                XCTAssertTrue(
                    text.contains(path),
                    "OpenAPI document does not mention path \(path)"
                )
            }
        }
    }

    // MARK: - Preserved behavior: URL building, headers, decoding

    func testFetchPrinterProfilesRequestsV1EndpointAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchColorsRequestsV1QueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let queryItem = try XCTUnwrap(components.queryItems?.first { $0.name == "printer_profile_id" })
            XCTAssertEqual(queryItem.value, "7")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [1, 2])
        XCTAssertEqual(fetched.colors.first?.hex, "#00AABB")
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.2)
        XCTAssertEqual(fetched.printerProfile?.id, 7)
        XCTAssertEqual(fetched.printerProfile?.printerMakeModel, "Epson")
    }

    func testNon2xxResponseMapsToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableBodyMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testNilTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testWhitespaceOnlyTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: "   \n") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures and transport

    private static let printerProfilesBody = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Epson",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "printer_profile": {
        "id": 7,
        "printer_make_model": "Epson",
        "paper_type": "Matte",
        "ink_type": "Dye"
      },
      "colors": [
        {
          "id": 1,
          "name": "Cyan",
          "hex": "#00AABB",
          "rgb": {"r": 0, "g": 170, "b": 187},
          "responses": {
            "red": {"brightness": 0.2},
            "green": {"brightness": 0.6}
          }
        },
        {
          "id": 2,
          "name": "Magenta",
          "hex": "#BB00AA",
          "rgb": {"r": 187, "g": 0, "b": 170},
          "responses": {
            "lps": {"brightness": 0.4}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String? = "  token-value  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
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
