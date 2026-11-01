import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract net for the `/api/v1` API as consumed by `PaletteAPIClient`.
///
/// These tests pin the observable HTTP contract — URL shapes, headers, the
/// snake_case response envelopes, and the error taxonomy — that the OpenAPI
/// document (published at `GET /api/v1/openapi.json`, viamin/color_matching#110)
/// formalizes. When `PaletteAPIClient` migrates to a swift-openapi-generated
/// client (or a wrapper around one), every test here must stay green without
/// edits; a failure means the migration changed behavior the app relies on.
///
/// The disk-cache and offline-fallback behavior layered on top of this client
/// is covered by `ProfileColorCacheTests`.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsSendsCanonicalRequestAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(request.url?.query, "printer_profile_id=7")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(profile?.id, 7)
        XCTAssertEqual(profile?.printerMakeModel, "Epson")
        XCTAssertEqual(colors.count, 2)

        let first = try XCTUnwrap(colors.first)
        XCTAssertEqual(first.id, 123)
        XCTAssertEqual(first.hex, "#C64A35")
        XCTAssertEqual(first.rgb?.r, 198)
        XCTAssertEqual(first.responses["red"]?.brightness, 0.87)

        // The wire DTOs must convert to solver-ready domain colors, keeping
        // measured channels and absent (never zero) channels distinct.
        let domain = try XCTUnwrap(first.toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
        XCTAssertEqual(domain.brightness(for: .lps), 0.52)
        XCTAssertNil(domain.brightness(for: .green))

        // A color with no `rgb` object falls back to its hex.
        let hexOnly = try XCTUnwrap(colors.last?.toDomain())
        XCTAssertEqual(hexOnly.rgb, RGBColor(hex: "#112233"))
    }

    func testFetchColorsWithoutTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "A blank token must not produce an Authorization header")
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope)
        }

        let (colors, _) = try await client.fetchColors(printerProfileID: 7)
        XCTAssertEqual(colors.count, 2)
    }

    func testFetchColorsMapsUnauthorizedToDistinctError() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized,
                           "401 must surface as .unauthorized to drive re-authentication")
        }
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesSendsCanonicalRequestAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.profilesEnvelope)
        }

        let profiles = try await client.fetchPrinterProfiles()
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.last?.paperType, nil, "Optional fields must decode when absent")
    }

    // MARK: - testConnection

    func testTestConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }
        try await client.testConnection()
    }

    func testTestConnectionMapsFailureStatusToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    // MARK: - Fixtures

    private static let colorsEnvelope = """
    {
      "printer_profile": {
        "id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5, "palette_name": "Default", "sort_order": 12,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement"},
            "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5}
          }
        },
        {
          "id": 9, "name": "Blue 03", "hex": "#112233",
          "responses": {"blue": {"brightness": 0.25}}
        }
      ]
    }
    """.data(using: .utf8)!

    private static let profilesEnvelope = """
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Pigment"},
        {"id": 2, "printer_make_model": "Canon"}
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String? = "secret-token",
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
