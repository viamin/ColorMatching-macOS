import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Migration contract for the `/api/v1` palette API client.
///
/// `PaletteAPIClient` is being migrated onto a typed client generated from
/// the `color_matching` OpenAPI document (viamin/color_matching#110, served
/// at `GET /api/v1/openapi.json`) via `swift-openapi-generator`. These tests
/// pin the externally observable behavior the migration must preserve so the
/// disk-cache / offline-stale fallback flows (`ColorCatalog` +
/// `ProfileColorCache`) keep working unchanged:
///
/// - request shapes: `/api/v1` base path, `printer_profile_id` query,
///   `Accept: application/json`, normalized bearer-token `Authorization`
/// - wire decoding: snake_case envelopes, per-color response vectors keyed by
///   light source, optional/null `printer_profile`, tolerance for unknown
///   fields the spec may add
/// - error taxonomy: 401 → `.unauthorized` (drives re-auth UI), other
///   non-2xx → `.badStatus`, undecodable body → `.malformedResponse`
///
/// They pass against the hand-written client today and must remain green
/// after the generated client lands (wrap it, keep these semantics).
final class PaletteAPIClientMigrationContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    private let baseURL = URL(string: "http://api.example.com")!

    // MARK: - Request shapes

    func testFetchPrinterProfilesRequestShapeAndDecoding() async throws {
        let client = makeClient(token: " token ") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson XP-8600")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.last?.inkType, "Pigment")
    }

    func testFetchColorsRequestShapeAndDecoding() async throws {
        let client = makeClient(token: " token ") { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "http://api.example.com/api/v1/colors?printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (.init(statusCode: 200, url: url), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.first?.hex, "#C64A35")
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)

        // Missing measurements stay absent (never zero) so the solver's
        // exclusion policy keeps firing on cached data served offline.
        XCTAssertNil(fetched.colors.first?.responses["green"])
    }

    func testFetchColorsToleratesNullProfileAndUnknownFields() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBodyWithoutProfile)
        }

        let fetched = try await client.fetchColors(printerProfileID: 9)

        // A response-less envelope must not fail the fetch: the profile
        // picker falls back to cached profiles when this is nil.
        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.map(\.id), [123])

        // Unknown light sources ride along on the DTO (dropped only at domain
        // conversion) and spec-added fields must not break decoding.
        XCTAssertEqual(fetched.colors.first?.responses["ultraviolet"]?.brightness, 0.9)
        let domain = try XCTUnwrap(fetched.colors.first?.toDomain())
        XCTAssertNil(domain.brightness(for: .green))
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
    }

    func testWhitespaceOnlyTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: "   \n ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Error taxonomy (drives offline fallback and re-auth UI)

    func testFetchColorsMapsUnauthorizedToDedicatedError() async {
        let client = makeClient(token: "stale") { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("{\"colors\": [not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testConnectionCheckSucceedsOn2xxAndRejectsUnauthorized() async {
        let ok = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }
        await XCTAssertNoThrowAsync(try await ok.testConnection())

        let unauthorized = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await unauthorized.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures

    private static let printerProfilesBody = Data("""
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Dye"},
        {"id": 2, "printer_make_model": "Canon PRO-1000", "paper_type": "Glossy", "ink_type": "Pigment"}
      ],
      "schema_version": "lps-sheet-manifest/v1"
    }
    """.utf8)

    private static let colorsBody = Data("""
    {
      "printer_profile": {"id": 7, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Dye"},
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
    """.utf8)

    private static let colorsBodyWithoutProfile = Data("""
    {
      "printer_profile": null,
      "colors": [
        {
          "id": 123, "hex": "#C64A35", "rgb": {"r": 198, "g": 74, "b": 53},
          "schema_version": "lps-distance-v1",
          "responses": {
            "red": {"brightness": 0.87},
            "ultraviolet": {"brightness": 0.9}
          }
        }
      ]
    }
    """.utf8)

    // MARK: - Harness

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: baseURL, token: token, session: session)
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
        self.init(url: url ?? URL(string: "http://api.example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
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

private func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expected no error, got \(error)", file: file, line: line)
    }
}
