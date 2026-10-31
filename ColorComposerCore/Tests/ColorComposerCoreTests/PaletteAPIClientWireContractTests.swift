import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract tests for `PaletteAPIClient` against `/api/v1`.
///
/// The generated-OpenAPI-client migration (issue #39) must keep every behavior
/// pinned here unchanged: the exact endpoint URLs and query the client
/// requests, the `Accept`/`Authorization` headers, the snake_case response
/// envelopes (including nullable profile metadata and an optional
/// `printer_profile` inside the colors response), and the error mapping
/// (401 → `unauthorized`, other non-2xx → `badStatus`, undecodable body →
/// `malformedResponse`). Together with `PaletteAPIClientTests` and
/// `ProfileColorCacheTests`, these are the disk-cache / offline-fallback
/// behavior the migration is verified against.
final class PaletteAPIClientWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - printer_profiles

    func testFetchPrinterProfilesHitsVersionedEndpointWithoutToken() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://api.example.test/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), singleProfileResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 7)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson SC-P5000")
        XCTAssertEqual(profiles.first?.paperType, "Premium Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchPrinterProfilesToleratesNullProfileMetadata() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), nullMetadataProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertNil(profiles.first?.printerMakeModel)
        XCTAssertNil(profiles.first?.paperType)
        XCTAssertNil(profiles.first?.inkType)
        XCTAssertEqual(profiles.last?.printerMakeModel, "Canon imagePROGRAF PRO-1000")
    }

    // MARK: - colors

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://api.example.test/api/v1/colors?printer_profile_id=42"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)

        XCTAssertEqual(fetched.colors.count, 1)
        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 900)
        XCTAssertEqual(color.name, "Cadmium Red")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.rgb?.g, 74)
        XCTAssertEqual(color.rgb?.b, 53)
        XCTAssertEqual(color.paletteId, 5)
        XCTAssertEqual(color.paletteName, "Studio")
        XCTAssertEqual(color.sortOrder, 12)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(color.responses["red"]?.source, "measurement")
        XCTAssertEqual(color.responses["red"]?.rawValue, 1.62)
        XCTAssertEqual(color.responses["red"]?.rawUnit, "mV")
        XCTAssertEqual(color.responses["red"]?.testRunId, "run-7")
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)
        XCTAssertNil(color.responses["white"])

        XCTAssertEqual(fetched.profile?.id, 42)
        XCTAssertEqual(fetched.profile?.paperType, "Premium Matte")
    }

    func testFetchColorsToleratesAbsentPrinterProfileInEnvelope() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), profilelessColorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)

        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.first?.id, 901)
    }

    // MARK: - Error mapping

    func testServerErrorSurfacesAsBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testNonJSONBodySurfacesAsMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json at all".utf8))
        }

        await assertAsyncThrows(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Connection test

    func testTestConnectionAcceptsAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionMapsUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Base URL handling

    func testBaseURLWithTrailingSlashStillHitsTheVersionedEndpoint() async throws {
        let client = makeClient(baseURL: URL(string: "http://api.example.test/")!) { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://api.example.test/api/v1/printer_profiles"
            )
            return (.init(statusCode: 200, url: request.url!), singleProfileResponse())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Fixtures

    private func makeClient(
        baseURL: URL = URL(string: "http://api.example.test")!,
        token: String? = "secret-token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: baseURL, token: token, session: session)
    }

    private func singleProfileResponse() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 7,
              "printer_make_model": "Epson SC-P5000",
              "paper_type": "Premium Matte",
              "ink_type": "Pigment"
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func nullMetadataProfilesResponse() -> Data {
        """
        {
          "printer_profiles": [
            { "id": 1, "printer_make_model": null, "paper_type": null, "ink_type": null },
            { "id": 2, "printer_make_model": "Canon imagePROGRAF PRO-1000", "paper_type": "Glossy", "ink_type": "Dye" }
          ]
        }
        """.data(using: .utf8)!
    }

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 42,
            "printer_make_model": "Epson SC-P5000",
            "paper_type": "Premium Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 900,
              "name": "Cadmium Red",
              "hex": "#C64A35",
              "rgb": { "r": 198, "g": 74, "b": 53 },
              "palette_id": 5,
              "palette_name": "Studio",
              "sort_order": 12,
              "responses": {
                "red": { "brightness": 0.87, "source": "measurement", "raw_value": 1.62, "raw_unit": "mV", "apparent_brightness": null, "measured_at": "2026-01-02T03:04:05Z", "test_run_id": "run-7" },
                "lps": { "brightness": 0.52, "source": "response", "apparent_brightness": 5 }
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func profilelessColorsResponse() -> Data {
        """
        {
          "colors": [
            { "id": 901, "hex": "#112233", "rgb": { "r": 17, "g": 34, "b": 51 }, "responses": {} }
          ]
        }
        """.data(using: .utf8)!
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

private func assertAsyncThrows<T>(
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
