import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire contract `PaletteAPIClient` relies on today —
/// endpoints, query, headers, status mapping, and envelope decoding — so the
/// migration to the generated OpenAPI client (swift-openapi-generator, from
/// the spec published by viamin/color_matching#110) cannot silently change
/// behavior. Whatever wraps the generated client must keep these green; any
/// `/api/v1` shape change the spec reveals shows up here first.
final class PaletteAPIContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    // MARK: - Request shapes

    func testPrinterProfilesHitsVersionedEndpointWithJSONAccept() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString, "http://example.com/api/v1/printer_profiles",
                "endpoint must remain the versioned /api/v1 route"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "no token configured — no Authorization header")
            return (.init(testStatusCode: 200, url: request.url!), Self.printerProfilesBody)
        }
        let profiles = try await client.fetchPrinterProfiles()
        XCTAssertEqual(profiles.first?.id, 1)
    }

    func testColorsRequestCarriesPrinterProfileIDQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7",
                "colors fetch must keep the printer_profile_id query parameter"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok",
                           "a configured token must be sent as a trimmed bearer")
            return (.init(testStatusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 3, "the colors envelope carries its printer profile for the cache")
    }

    // MARK: - Status and decoding failures

    func testNon2xxMapsToBadStatus() async {
        let client = makeClient { request in
            (.init(testStatusCode: 503, url: request.url!), Data())
        }
        do {
            _ = try await client.fetchPrinterProfiles()
            XCTFail("Expected badStatus")
        } catch {
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUnparseableBodyMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(testStatusCode: 200, url: request.url!), Data("<html>not json</html>".utf8))
        }
        do {
            _ = try await client.fetchPrinterProfiles()
            XCTFail("Expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Connection check

    func testTestConnectionAcceptsAny2xxAndRejectsErrors() async {
        let ok = makeClient { request in
            (.init(testStatusCode: 204, url: request.url!), Data())
        }
        do {
            try await ok.testConnection()
        } catch {
            XCTFail("204 must count as reachable: \(error)")
        }

        let down = makeClient { request in
            (.init(testStatusCode: 500, url: request.url!), Data())
        }
        do {
            try await down.testConnection()
            XCTFail("Expected badStatus from a 500")
        } catch {
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    // MARK: - Vendored OpenAPI document (viamin/color_matching#110)

    /// The generated client is built from a committed OpenAPI document; the
    /// parity of app and server contracts starts with that document being
    /// vendored. Fails until it is committed (see docs/openapi-client.md).
    func testVendoredOpenAPIDocumentIsPresentAndCoversUsedPaths() throws {
        let root = ParityCorpus.repoRoot(filePath: #filePath)
        let candidates = Self.openAPIDocumentLocations(root)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            try Self.assertDocumentCoversUsedPaths(url)
            return
        }
        XCTFail(
            "No OpenAPI document vendored (expected from viamin/color_matching#110). Searched: "
                + candidates.map(\.path).joined(separator: ", ")
                + ". Commit one and regenerate the client per docs/openapi-client.md."
        )
    }

    private static func openAPIDocumentLocations(_ root: URL) -> [URL] {
        var explicit = [URL]()
        if let override = ProcessInfo.processInfo.environment["COLOR_MATCHING_OPENAPI_DOCUMENT"], !override.isEmpty {
            explicit = [URL(fileURLWithPath: override)]
        }
        return explicit + [
            root.appendingPathComponent("color_matching/openapi.json"),
            root.appendingPathComponent("color_matching/openapi.yaml"),
            root.appendingPathComponent("color_matching/openapi.yml"),
            root.appendingPathComponent("ColorComposerCore/openapi.json"),
            root.appendingPathComponent("ColorComposerCore/openapi.yaml")
        ]
    }

    /// When the document is JSON, also verify it describes both routes the app
    /// consumes, so the spec and `PaletteAPIClient` cannot drift apart.
    private static func assertDocumentCoversUsedPaths(_ url: URL) throws {
        guard url.pathExtension == "json" else { return }
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = document as? [String: Any], let paths = object["paths"] as? [String: Any] else {
            XCTFail("OpenAPI document at \(url.path) is not an OpenAPI-style JSON object")
            return
        }
        XCTAssertTrue(paths.keys.contains("/api/v1/printer_profiles"),
                      "spec must describe GET /api/v1/printer_profiles")
        XCTAssertTrue(paths.keys.contains("/api/v1/colors"),
                      "spec must describe GET /api/v1/colors")
    }

    // MARK: - Fixtures

    private static let printerProfilesBody = """
    {
      "printer_profiles": [
        { "id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment" }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "printer_profile": {
        "id": 3, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
      },
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": { "r": 198, "g": 74, "b": 53 },
          "palette_id": 5, "palette_name": "Default", "sort_order": 12,
          "responses": {
            "red": { "brightness": 0.87, "source": "measurement" },
            "lps": { "brightness": 0.52, "source": "response", "apparent_brightness": 5 }
          }
        }
      ]
    }
    """.data(using: .utf8)!
}

private final class ContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
    /// Named distinctly from the identical helper in PaletteAPIClientTests so
    /// the two fileprivate declarations cannot collide.
    convenience init(testStatusCode: Int, url: URL) {
        self.init(url: url, statusCode: testStatusCode, httpVersion: nil, headerFields: nil)!
    }
}
