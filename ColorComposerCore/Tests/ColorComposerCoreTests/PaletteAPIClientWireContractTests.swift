import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-level contract of `PaletteAPIClient` against the `color_matching`
/// `/api/v1` endpoints. These pin the externally observable behavior the
/// generated OpenAPI-client migration (issue #39) must preserve: endpoint
/// paths, the `printer_profile_id` query parameter, headers, bearer-token
/// normalization, response-envelope decoding, and the error taxonomy
/// (`401 → .unauthorized`, other non-2xx → .badStatus`, undecodable body →
/// `.malformedResponse`).
///
/// Companion to `PaletteAPIClientTests` (re-auth + token trimming) and
/// `APIDecodingTests` (envelope decoding details).
final class PaletteAPIClientWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        WireMockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsRequestsAPIV1PathWithProfileQueryAndAcceptHeader() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: nil)?.queryItems
            XCTAssertTrue(
                query?.contains(URLQueryItem(name: "printer_profile_id", value: "7")) == true,
                "expected printer_profile_id=7 in \(String(describing: query))"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].id, 123)
        XCTAssertEqual(colors[0].hex, "#C64A35")
        XCTAssertEqual(colors[0].responses["red"]?.brightness, 0.87)
        XCTAssertEqual(profile?.id, 3)
        XCTAssertEqual(profile?.printerMakeModel, "Epson XP-8600")
    }

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertThrowsAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertThrowsAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesRequestsAPIV1PathAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, 3)
        XCTAssertEqual(profiles[0].printerMakeModel, "Epson XP-8600")
        XCTAssertEqual(profiles[0].paperType, "Premium Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
    }

    func testFetchPrinterProfilesSendsNoAuthorizationWhenTokenEmpty() async throws {
        let client = makeClient(base: URL(string: "http://example.com")!, token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Test connection

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures

    private func makeClient(
        base: URL = URL(string: "http://example.com")!,
        token: String? = "secret",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireMockURLProtocol.self]
        return PaletteAPIClient(baseURL: base, token: token, session: URLSession(configuration: configuration))
    }

    private static func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {
            "id": 3, "printer_make_model": "Epson XP-8600",
            "paper_type": "Premium Matte", "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 3, "printer_make_model": "Epson XP-8600",
              "paper_type": "Premium Matte", "ink_type": "Pigment"
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class WireMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func assertThrowsAsync<T>(
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
