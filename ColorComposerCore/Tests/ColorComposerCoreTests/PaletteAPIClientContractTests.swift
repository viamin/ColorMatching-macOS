import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavioral contract of `PaletteAPIClient` that the generated OpenAPI
/// client migration (issue #39) must preserve: versioned URLs, optional
/// bearer auth, envelope decoding (missing measurements absent — never
/// zero), and the error taxonomy that drives re-auth and offline fallback.
///
/// Together with `ProfileColorCacheTests` (per-server/profile disk cache,
/// offline-stale badges, cached profile fallback) these pin the migration.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        StubURLProtocol.handler = nil
    }

    // MARK: - Requests

    func testFetchColorsBuildsVersionedQueryWithOptionalAuth() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(request.url?.query, "printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.ok(request.url!), Self.colorsEnvelope)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.hex, "#C64A35")
        XCTAssertEqual(profile?.id, 1)
    }

    func testFetchColorsSendsTrimmedBearerToken() async throws {
        let client = makeClient(token: "  tok-123  ") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
            return (.ok(request.url!), Self.colorsEnvelope)
        }

        _ = try await client.fetchColors(printerProfileID: 1)
    }

    // MARK: - Decoding

    func testFetchColorsKeepsMissingMeasurementsAbsentNotZero() async throws {
        let client = makeClient { request in
            (.ok(request.url!), Self.colorsEnvelope)
        }

        let (colors, _) = try await client.fetchColors(printerProfileID: 1)
        let color = try XCTUnwrap(colors.first)

        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(color.responses["lps"]?.brightness, 0.52)
        XCTAssertNil(color.responses["white"], "unmeasured conditions must stay absent")
        XCTAssertNil(color.responses["green"])
        XCTAssertNil(color.responses["blue"])
    }

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.ok(request.url!), Self.profilesEnvelope)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.displayName, "Epson P700 · Matte · Pigment")
    }

    // MARK: - Error taxonomy

    func testFetchColorsMapsUnauthorizedDistinctly() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.ok(request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xxAndFailsOnBadStatus() async throws {
        let ok = makeClient { request in (.ok(request.url!), Data("{}".utf8)) }
        try await ok.testConnection()

        let down = makeClient { request in (.init(statusCode: 500, url: request.url!), Data()) }
        await XCTAssertThrowsErrorAsync(try await down.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    // MARK: - Fixtures

    private static let colorsEnvelope = Data(
        """
        {
          "printer_profile": {"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Pigment"},
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87},
                "lps": {"brightness": 0.52}
              }
            }
          ]
        }
        """.utf8
    )

    private static let profilesEnvelope = Data(
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Epson P700", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 2, "printer_make_model": "Canon Pro-300", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """.utf8
    )

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
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
    convenience init(statusCode: Int, url: URL?) {
        let resolved = url ?? URL(string: "http://example.com")!
        self.init(url: resolved, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    static func ok(_ url: URL?) -> HTTPURLResponse {
        .init(statusCode: 200, url: url)
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
