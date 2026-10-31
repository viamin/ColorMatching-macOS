import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Characterization tests pinning the `/api/v1` wire contract that the
/// generated OpenAPI client migration (issue #39) must preserve: request
/// shapes (method, path, query, headers — including bearer-token handling)
/// and response envelope decoding, plus the error taxonomy surfaced to the
/// app's offline-fallback logic (`unauthorized` vs `badStatus` vs
/// `malformedResponse` — only transport errors may fall back to the disk
/// cache, so these mappings are behavior, not detail).
///
/// The disk-cache/offline-stale behavior itself is covered by
/// `ProfileColorCacheTests` (per-server/profile namespacing, corrupt-file
/// misses, clear-cache) — together these files are the migration safety net.
final class PaletteAPIContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - printer_profiles

    func testFetchPrinterProfilesRequestShapeAndDecodesEnvelope() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.path, "/api/v1/printer_profiles")
            XCTAssertNil(components?.queryItems)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles[0].printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
    }

    // MARK: - colors

    func testFetchColorsSendsProfileIDQueryAndBearerToken() async throws {
        let client = makeClient(token: "sekret") { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(components?.path, "/api/v1/colors")
            XCTAssertEqual(
                components?.queryItems ?? [],
                [URLQueryItem(name: "printer_profile_id", value: "7")]
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sekret")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        _ = try await client.fetchColors(printerProfileID: 7)
    }

    func testFetchColorsDecodesColorsAndProfileEnvelope() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 2)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Epson P900")

        let first = try XCTUnwrap(fetched.colors.first { $0.id == 11 })
        XCTAssertEqual(first.name, "Metamer Red")
        XCTAssertEqual(first.rgb?.r, 160)
        XCTAssertEqual(first.paletteId, 3)

        let redResponse = try XCTUnwrap(first.responses["red"])
        XCTAssertEqual(redResponse.brightness, 0.82, accuracy: 1e-12)
        XCTAssertEqual(redResponse.source, "response")
        XCTAssertEqual(redResponse.apparentBrightness, 8)

        let lpsResponse = try XCTUnwrap(first.responses["lps"])
        XCTAssertEqual(lpsResponse.brightness, 0.41, accuracy: 1e-12)
        XCTAssertEqual(lpsResponse.source, "measurement")
        XCTAssertEqual(lpsResponse.rawValue ?? 0, 41.2, accuracy: 1e-12)
        XCTAssertEqual(lpsResponse.rawUnit, "percent")
        XCTAssertEqual(lpsResponse.testRunId, "run-7")

        let sparse = try XCTUnwrap(fetched.colors.first { $0.id == 12 })
        XCTAssertEqual(sparse.responses.keys.sorted(), ["lps"], "absent responses stay absent, never zero")
        XCTAssertNil(sparse.rgb)
    }

    func testFetchColorsDecodesEnvelopeWithoutOptionalProfile() async throws {
        let body = """
        {
          "colors": [
            {"id": 12, "hex": "#c8b04a", "responses": {"lps": {"brightness": 0.93}}}
          ]
        }
        """.data(using: .utf8)!
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), body)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertNil(fetched.profile)
    }

    func testFetchColorsWithoutUsableTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        _ = try await client.fetchColors(printerProfileID: 7)
    }

    // MARK: - Error taxonomy (drives the offline-fallback policy)

    func testUnauthorizedMapsToUnauthorizedError() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testServerErrorCodeMapsToBadStatus() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUnparseableBodyMapsToMalformedResponse() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data("{".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testWrongShapedBodyMapsToMalformedResponse() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data("{\"nope\": 1}".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Reachability probe

    func testTestConnectionAcceptsEmpty2xxBody() async throws {
        let client = makeClient(token: nil) { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    // MARK: - Fixtures

    private static let printerProfilesBody: Data = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Example Printer",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        },
        {
          "id": 2,
          "printer_make_model": "Other Printer",
          "paper_type": "Glossy",
          "ink_type": "Dye"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody: Data = """
    {
      "colors": [
        {
          "id": 11,
          "name": "Metamer Red",
          "hex": "#a03325",
          "rgb": {"r": 160, "g": 51, "b": 37},
          "palette_id": 3,
          "palette_name": "LPS set",
          "sort_order": 1,
          "responses": {
            "red": {
              "brightness": 0.82,
              "source": "response",
              "apparent_brightness": 8
            },
            "lps": {
              "brightness": 0.41,
              "source": "measurement",
              "raw_value": 41.2,
              "raw_unit": "percent",
              "measured_at": "2026-01-05T10:00:00Z",
              "test_run_id": "run-7"
            }
          }
        },
        {
          "id": 12,
          "name": "Sodium Yellow",
          "hex": "#c8b04a",
          "responses": {
            "lps": {"brightness": 0.93}
          }
        }
      ],
      "printer_profile": {
        "id": 7,
        "printer_make_model": "Epson P900",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      }
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String?,
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
