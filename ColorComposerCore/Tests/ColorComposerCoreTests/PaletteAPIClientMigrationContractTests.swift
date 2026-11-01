import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Migration contract for issue #39: `PaletteAPIClient` is being re-based on
/// a client generated from the server's OpenAPI document. These tests pin the
/// externally observable behavior that the migration must preserve exactly —
/// endpoint paths, query parameters, headers, error mapping, and decoded
/// payloads — independent of which HTTP/decoding stack sits underneath.
///
/// Disk-cache and offline-stale behavior (unchanged by the migration) is
/// covered by `ProfileColorCacheTests` and `ColorCatalog` (app target).
final class PaletteAPIClientMigrationContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesRequestsVersionedJSONEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.url?.query, nil, "profiles list takes no query parameters")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()
        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson P900")
    }

    func testFetchPrinterProfilesMapsServerErrorToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchPrinterProfilesMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/colors?printer_profile_id=N

    func testFetchColorsSendsRequiredQueryParameterAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(request.url?.query, "printer_profile_id=42", "printer_profile_id is required by the OpenAPI contract")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
    }

    func testFetchColorsMapsNotFoundToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 404, url: request.url!), Data(#"{"errors":{"detail":"missing"}}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 99)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(404))
        }
    }

    // MARK: - Bearer token handling

    func testWhitespaceOnlyTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testMissingTokenStillFetchesAgainstUnauthenticatedServer() async throws {
        let client = makeClient { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()
        XCTAssertEqual(profiles.count, 2)
    }

    // MARK: - Reachability probe

    func testConnectionSucceedsOnAnySuccessStatusWithoutBody() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        _ = try await client.testConnection()
    }

    func testConnectionMapsUnauthorizedDistinctly() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures

    private static let printerProfilesBody: Data = """
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Pigment"},
        {"id": 2, "printer_make_model": "Canon Pro-300", "paper_type": "Glossy", "ink_type": "Dye"}
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody: Data = """
    {
      "printer_profile": {"id": 7, "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Pigment"},
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5, "palette_name": null, "sort_order": 12,
          "responses": {"red": {"brightness": 0.87, "source": "measurement"}}
        }
      ]
    }
    """.data(using: .utf8)!
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
