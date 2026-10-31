import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Observable behavior contract of `PaletteAPIClient` (issue #39).
///
/// These tests pin what the client's callers observe — request shapes against
/// `/api/v1`, bearer-token handling, status-to-error mapping, and the decoded
/// wire types — so the migration to the generated OpenAPI client
/// (swift-openapi-generator; viamin/color_matching#110) can replace or wrap
/// the transport without changing anything downstream. The literal JSON below
/// also pins the current `/api/v1` response shapes: any divergence between
/// them and the published OpenAPI document found during the migration is
/// recorded in `docs/openapi-client-migration-notes.md` and the PR body.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractURLProtocol.handler = nil
    }

    private func makeClient(
        baseURL: String = "http://example.com",
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: baseURL)!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    // MARK: Request shapes

    func testFetchPrinterProfilesRequestsTheVersionedEndpointWithJSONAcceptAndBearer() async throws {
        let client = makeClient(token: "  tok  ") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            return (.init(statusCode: 200, url: request.url!), printerProfilesJSON)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
    }

    func testFetchColorsRequestsTheProfileScopedEndpoint() async throws {
        let client = makeClient(token: "tok") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), colorsJSON)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.profile?.id, 1)
        XCTAssertFalse(fetched.profile?.displayName.isEmpty ?? true)
    }

    func testWhitespaceOnlyTokenOmitsTheAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), printerProfilesJSON)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testBaseURLPathPrefixIsPreservedInEndpoints() async throws {
        let client = makeClient(baseURL: "http://example.com/prefix") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/prefix/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), printerProfilesJSON)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: Wire envelope

    /// Pins the full `/api/v1/colors` color-response shape — including the
    /// provenance fields (`raw_value`, `raw_unit`, `apparent_brightness`,
    /// `measured_at`, `test_run_id`) — against drift while the generated
    /// client lands. They feed display and the disk cache, so they must
    /// survive the migration.
    func testColorsWireEnvelopeCarriesEveryResponseProvenanceField() async throws {
        let client = makeClient { _ in (.init(statusCode: 200, url: colorsURL), colorsJSON) }

        let fetched = try await client.fetchColors(printerProfileID: 7)
        let response = try XCTUnwrap(fetched.colors.first?.responses["red"])

        XCTAssertEqual(response.brightness, 0.87, accuracy: 1e-12)
        XCTAssertEqual(response.source, "measurement")
        XCTAssertEqual(response.rawValue, 12.4)
        XCTAssertEqual(response.rawUnit, "cd/m2")
        XCTAssertEqual(response.apparentBrightness, 7)
        XCTAssertEqual(response.measuredAt, "2026-01-02T03:04:05Z")
        XCTAssertEqual(response.testRunId, "run-42")
    }

    // MARK: Error mapping

    func testRejectedTokenSurfacesUnauthorizedOnColorsFetch() async {
        let client = makeClient { request in (.init(statusCode: 401, url: request.url!), Data()) }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testServerFailureSurfacesBadStatus() async {
        let client = makeClient { request in (.init(statusCode: 503, url: request.url!), Data()) }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableBodySurfacesMalformedResponse() async {
        let client = makeClient { request in (.init(statusCode: 200, url: request.url!), Data("not json".utf8)) }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xxAndSurfacesUnauthorizedOn401() async throws {
        let reachable = makeClient { request in (.init(statusCode: 200, url: request.url!), Data("[]".utf8)) }
        try await reachable.testConnection()

        let rejected = makeClient { request in (.init(statusCode: 401, url: request.url!), Data()) }
        await XCTAssertThrowsErrorAsync(try await rejected.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

}

private let colorsURL = URL(string: "http://example.com/api/v1/colors?printer_profile_id=7")!

private let printerProfilesJSON = """
{"printer_profiles":[{"id":1,"printer_make_model":"Example Printer","paper_type":"Matte","ink_type":"Pigment"}]}
""".data(using: .utf8)!

private let colorsJSON = """
{
  "printer_profile": {"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
  "colors": [
    {
      "id": 123, "name": "Red 12", "hex": "#C64A35",
      "rgb": {"r": 198, "g": 74, "b": 53},
      "palette_id": 5, "palette_name": "Default", "sort_order": 12,
      "responses": {
        "red": {
          "brightness": 0.87, "source": "measurement",
          "raw_value": 12.4, "raw_unit": "cd/m2", "apparent_brightness": 7,
          "measured_at": "2026-01-02T03:04:05Z", "test_run_id": "run-42"
        }
      }
    }
  ]
}
""".data(using: .utf8)!

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
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
