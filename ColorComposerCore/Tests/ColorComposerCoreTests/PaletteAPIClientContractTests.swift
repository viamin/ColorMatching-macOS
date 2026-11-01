import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract tests for `PaletteAPIClient` against the `color_matching`
/// `/api/v1` JSON shapes as published in the server's OpenAPI schemas
/// (issue #39).
///
/// When `PaletteAPIClient` is migrated onto the generated OpenAPI client
/// (swift-openapi-generator), these tests are the behavioral contract that
/// must keep passing unchanged: endpoint URLs, bearer-token handling, status
/// mapping, snake_case decoding, and tolerance for schema evolution. The disk
/// cache / offline-stale layers sit on top of this contract and are covered by
/// `ProfileColorCacheTests`.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: Happy paths

    func testFetchPrinterProfilesDecodesServerShape() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, 1)
        XCTAssertEqual(profile.printerMakeModel, "Epson ET-8550")
        XCTAssertEqual(profile.paperType, "Premium Matte")
        XCTAssertEqual(profile.inkType, "Pigment")
    }

    func testFetchColorsBuildsQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=3")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(fetched.profile?.id, 3)
        XCTAssertEqual(fetched.colors.count, 2)
        XCTAssertEqual(fetched.colors[0].id, 123)
        XCTAssertEqual(fetched.colors[0].hex, "#C64A35")
        XCTAssertEqual(fetched.colors[0].rgb?.r, 198)
        XCTAssertEqual(fetched.colors[0].rgb?.g, 74)
        XCTAssertEqual(fetched.colors[0].rgb?.b, 53)
        XCTAssertEqual(fetched.colors[0].responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.colors[0].responses["lps"]?.brightness, 0.52)
        XCTAssertNil(fetched.colors[0].responses["green"], "missing measurement is absent, not zero")
        XCTAssertEqual(fetched.colors[1].id, 124)
        XCTAssertEqual(fetched.colors[1].responses.count, 0, "response-less colors stay in the list; the solver excludes them")

        let domain = try XCTUnwrap(fetched.colors[0].toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
        XCTAssertNil(domain.brightness(for: .green))
        XCTAssertEqual(domain.rgb, RGBColor(red: 198, green: 74, blue: 53))
    }

    func testFetchColorsFallsBackToHexWhenRGBOmitted() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.hexFallbackColorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertNil(fetched.profile)
        let domain = try XCTUnwrap(fetched.colors.first?.toDomain())
        XCTAssertEqual(domain.rgb, RGBColor(hex: "#112233"))
        XCTAssertEqual(domain.brightness(for: .lps), 0.5)
    }

    // MARK: Forward compatibility

    /// The server evolves its OpenAPI schema independently of this client; new
    /// response fields (or new light-source keys) must not break decoding.
    func testUnknownEnvelopeAndColorFieldsDoNotBreakDecoding() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBodyWithExtras)
        }

        let fetched = try await client.fetchColors(printerProfileID: 1)

        XCTAssertEqual(fetched.colors.first?.id, 9)
        XCTAssertEqual(fetched.colors.first?.responses["ultraviolet"]?.brightness, 0.9)
        XCTAssertNil(fetched.colors.first?.toDomain()?.brightness(for: .blue), "unknown light sources are dropped in domain conversion")
    }

    // MARK: Error mapping

    func testNonSuccessStatusMapsToBadStatus() async {
        for status in [404, 422, 500, 503] {
            let client = makeClient { request in
                (.init(statusCode: status, url: request.url!), Data())
            }

            await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
                XCTAssertEqual(error as? PaletteAPIError, .badStatus(status))
            }
        }
    }

    func testMalformedJSONMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("<html>gateway error</html>".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testEnvelopeMissingRequiredKeyMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("{}".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchColorsUnauthorizedMapsToUnauthorized() async {
        let client = makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tk")
            return (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: testConnection

    func testConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testConnectionThrowsUnauthorizedOn401() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: Fixtures

    private static let printerProfilesBody: Data = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Epson ET-8550",
          "paper_type": "Premium Matte",
          "ink_type": "Pigment"
        }
      ]
    }
    """.data(using: .utf8)!

    /// Mirrors the server `ColorsResponse` schema, including fields the server
    /// requires (`name`, `palette_id`, `sort_order`) and a response-less color.
    private static let colorsBody: Data = """
    {
      "printer_profile": {
        "id": 3,
        "printer_make_model": "Epson ET-8550",
        "paper_type": "Premium Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 123,
          "name": "Red 12",
          "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5,
          "palette_name": "Default",
          "sort_order": 12,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null},
            "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
          }
        },
        {
          "id": 124,
          "name": "Unmeasured Swatch",
          "hex": "#101010",
          "palette_id": 5,
          "palette_name": null,
          "sort_order": 13,
          "responses": {}
        }
      ]
    }
    """.data(using: .utf8)!

    private static let hexFallbackColorsBody: Data = """
    {
      "printer_profile": null,
      "colors": [
        {
          "id": 7,
          "name": "No RGB Swatch",
          "hex": "#112233",
          "palette_id": 2,
          "sort_order": 3,
          "responses": {
            "lps": {"brightness": 0.5}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBodyWithExtras: Data = """
    {
      "printer_profile": null,
      "metamer_pairs": [],
      "colors": [
        {
          "id": 9,
          "name": "Future Color",
          "hex": "#ABCDEF",
          "lab": {"l": 73, "a": -20, "b": -38},
          "spectral": "https://example.com/spectral/9.json",
          "responses": {
            "ultraviolet": {"brightness": 0.9}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: " tk ", session: session)
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
    convenience init(statusCode: Int, url: URL?) {
        self.init(url: url ?? URL(string: "http://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
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
