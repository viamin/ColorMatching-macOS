import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavior of `PaletteAPIClient` that the generated OpenAPI client
/// migration (issue #39) must preserve exactly.
///
/// These exercise the *public* client surface — endpoint paths, query shape,
/// headers, envelope decoding, error mapping — so the migration can swap the
/// innards for the generated typed client while these stay green. The
/// disk-cache and offline-stale layers sit on top of this surface
/// (`ProfileColorCacheTests`, `ColorCatalog`) and are untouched by it.
final class PaletteAPIClientMigrationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MigrationMockURLProtocol.handler = nil
    }

    // MARK: - printer_profiles endpoint

    func testFetchPrinterProfilesRequestsV1ProfilesEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/printer_profiles",
                "endpoint path must stay /api/v1/printer_profiles"
            )
            XCTAssertEqual(request.httpMethod ?? "GET", "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(
                request.value(forHTTPHeaderField: "Authorization"),
                "no Authorization header when no token is configured"
            )
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles, [
            PrinterProfileDTO(id: 1, printerMakeModel: "Epson P900", paperType: "Matte", inkType: "Pigment"),
            PrinterProfileDTO(id: 2, printerMakeModel: "Canon Pro-300", paperType: "Glossy", inkType: "Dye")
        ])
    }

    // MARK: - colors endpoint

    func testFetchColorsRequestsV1ColorsEndpointWithProfileQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/colors?printer_profile_id=7",
                "endpoint must stay GET /api/v1/colors?printer_profile_id=N"
            )
            XCTAssertEqual(request.httpMethod ?? "GET", "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.profile?.id, 7)
    }

    func testFetchColorsDecodesResponsesIntoSolverInputs() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let color = try XCTUnwrap(try await client.fetchColors(printerProfileID: 7).colors.first)

        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.rgb?.g, 74)
        XCTAssertEqual(color.rgb?.b, 53)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)
        XCTAssertNil(color.responses["green"], "unmeasured channels must be absent, not zero")

        let domain = try XCTUnwrap(color.toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
        XCTAssertNil(domain.brightness(for: .green))
        XCTAssertEqual(domain.rgb, RGBColor(red: 198, green: 74, blue: 53))
    }

    // MARK: - Error mapping

    func testFetchColorsMapsServerErrorStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsMalformedBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Fixtures

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MigrationMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MigrationMockURLProtocol.self]
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, session: URLSession(configuration: configuration))
    }

    private static let printerProfilesBody = Data(
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 2, "printer_make_model": "Canon Pro-300", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """.utf8
    )

    /// Wire shape from the server's OpenAPI `ColorsResponse` schema: an
    /// envelope of `colors` plus the (spec-required) `printer_profile`.
    private static let colorsBody = Data(
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Pigment"
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
            }
          ]
        }
        """.utf8
    )

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
}

private final class MigrationMockURLProtocol: URLProtocol, @unchecked Sendable {
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
