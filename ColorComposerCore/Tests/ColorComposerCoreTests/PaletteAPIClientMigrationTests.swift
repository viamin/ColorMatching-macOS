import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins every `PaletteAPIClient` behavior that must survive the migration to
/// the generated OpenAPI client (issue #39): endpoint paths, query, headers,
/// token handling, envelope decoding, and error mapping. Whether the client is
/// replaced by generated code or wraps it, these observations must not change
/// — `ColorCatalog`'s per-server/profile disk cache and offline-stale
/// fallback depend on them.
final class PaletteAPIClientMigrationTests: XCTestCase {
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

    // MARK: - GET /api/v1/colors

    func testFetchColorsRequestsVersionedEndpointWithProfileQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/colors?printer_profile_id=42",
                "colors must keep hitting the versioned endpoint with the profile query"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.emptyColorsResponse)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 42)

        XCTAssertTrue(colors.isEmpty)
        XCTAssertNil(profile)
    }

    func testFetchColorsDecodesColorsAndProfile() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsResponse)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(profile?.id, 3)
        XCTAssertEqual(profile?.printerMakeModel, "Epson XP-8600")
        XCTAssertEqual(profile?.paperType, "Matte")
        XCTAssertEqual(profile?.inkType, "Pigment")

        let measured = colors[0]
        XCTAssertEqual(measured.id, 123)
        XCTAssertEqual(measured.hex, "#C64A35")
        XCTAssertEqual(measured.rgb?.r, 198)
        XCTAssertEqual(measured.rgb?.g, 74)
        XCTAssertEqual(measured.rgb?.b, 53)
        XCTAssertEqual(measured.paletteId, 5)
        XCTAssertEqual(measured.paletteName, "Default")
        XCTAssertEqual(measured.sortOrder, 12)
        XCTAssertEqual(measured.responses["red"]?.brightness ?? -1, 0.87, accuracy: 1e-12)
        XCTAssertEqual(measured.responses["lps"]?.apparentBrightness, 5)

        let unmeasured = colors[1]
        XCTAssertEqual(unmeasured.id, 124)
        XCTAssertNotNil(unmeasured.responses["red"])
        XCTAssertNil(unmeasured.responses["green"], "unmeasured conditions stay absent, never zero")
    }

    func testFetchColorsMapsUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsMalformedBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), Self.profilesResponse)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 9)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Canon PRO-1000")
        XCTAssertEqual(profiles.first?.paperType, "Glossy")
        XCTAssertEqual(profiles.first?.inkType, "Dye")
    }

    // MARK: - Token handling

    func testOmitsAuthorizationHeaderWithoutToken() async throws {
        let client = makeClient { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "no Authorization header may be sent when no token is configured")
            return (.init(statusCode: 200, url: request.url!), Self.profilesResponse)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Fixtures

    private static let emptyColorsResponse = #"{ "colors": [], "printer_profile": null }"#.data(using: .utf8)!

    private static let colorsResponse = """
    {
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": { "r": 198, "g": 74, "b": 53 },
          "palette_id": 5, "palette_name": "Default", "sort_order": 12,
          "responses": {
            "red": { "brightness": 0.87, "source": "measurement" },
            "lps": { "brightness": 0.52, "source": "response", "apparent_brightness": 5 }
          }
        },
        {
          "id": 124, "name": "Muted Green", "hex": "#3A5F3A",
          "rgb": { "r": 58, "g": 95, "b": 58 },
          "responses": {
            "red": { "brightness": 0.11 },
            "lps": { "brightness": 0.4 }
          }
        }
      ],
      "printer_profile": {
        "id": 3, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Pigment"
      }
    }
    """.data(using: .utf8)!

    private static let profilesResponse = """
    {
      "printer_profiles": [
        { "id": 9, "printer_make_model": "Canon PRO-1000", "paper_type": "Glossy", "ink_type": "Dye" }
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
