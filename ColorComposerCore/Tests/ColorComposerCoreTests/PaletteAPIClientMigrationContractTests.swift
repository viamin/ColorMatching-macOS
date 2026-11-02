import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Migration contract for issue #39: the exact observable behavior of
/// `PaletteAPIClient` that must survive the move to the generated OpenAPI
/// client (wrapping or replacing the hand-rolled transport). These tests are
/// green against the current implementation; the migrated client must keep
/// them green, proving no `/api/v1` consumer-visible behavior changed —
/// including compatibility with the offline disk cache.
final class PaletteAPIClientMigrationContractTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIClientMigrationContractTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        MockTransport.handler = nil
        super.tearDown()
    }

    // MARK: - Endpoints & headers

    func testFetchPrinterProfilesRequestsV1EndpointWithJSONAcceptAndBearerToken() async throws {
        let client = makeClient(token: "  sekrit  ") { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sekrit")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesJSON)
        }

        let profiles = try await client.fetchPrinterProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson SC-P700")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchColorsRequestsProfileScopedQueryAndDecodesEnvelope() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no token configured — no Authorization header")
            return (.init(statusCode: 200, url: request.url!), Self.colorsJSON)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.count, 2)

        let sienna = try XCTUnwrap(fetched.colors.first { $0.id == 101 })
        XCTAssertEqual(sienna.name, "Sienna")
        XCTAssertEqual(sienna.hex, "#A0522D")
        XCTAssertEqual(sienna.rgb?.r, 160)
        XCTAssertEqual(sienna.rgb?.g, 82)
        XCTAssertEqual(sienna.rgb?.b, 45)
        XCTAssertEqual(sienna.paletteId, 3)
        XCTAssertEqual(sienna.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(sienna.responses["red"]?.source, "measurement")

        let slate = try XCTUnwrap(fetched.colors.first { $0.id == 102 })
        XCTAssertEqual(slate.responses["lps"]?.brightness, 0.5)
        XCTAssertEqual(slate.responses["lps"]?.apparentBrightness, 5)
    }

    /// Missing measurements must stay absent from the wire DTO — never
    /// coerced to zero — so the solver's exclusion policy keeps working.
    func testFetchColorsKeepsMissingMeasurementsAbsent() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsJSON)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)
        let sienna = try XCTUnwrap(fetched.colors.first { $0.id == 101 })

        XCTAssertNotNil(sienna.responses["red"])
        for missing in ["white", "green", "blue", "lps"] {
            XCTAssertNil(sienna.responses[missing], "\(missing) was not measured and must be absent, not zero")
        }
    }

    // MARK: - Error mapping

    func testUnauthorizedMapsToUnauthorizedError() async {
        let client = makeClient(token: "stale") { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testServerErrorMapsToBadStatus() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 500, url: request.url!), Data("boom".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testUndecodableSuccessBodyMapsToMalformedResponse() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data("<html>not json</html>".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOnAnySuccessStatus() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        _ = try await client.testConnection()
    }

    // MARK: - Disk-cache compatibility (offline fallback)

    /// Whatever the client returns after the migration must remain storable
    /// in — and readable from — the offline disk cache with the staleness
    /// marker intact: per-(server, profile) caching and offline-stale serving
    /// depend on it.
    func testFetchedColorsRoundTripThroughDiskCacheForOfflineFallback() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsJSON)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)
        let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let entry = CachedProfileColors(
            serverBaseUrl: "http://example.com",
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: fetchedAt
        )

        let cache = ProfileColorCache(directory: temporaryDirectory)
        try cache.store(entry)

        let restored = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: "http://example.com"))
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(restored.fetchedAt, fetchedAt, "the offline-stale badge date must survive the cache round trip")
        XCTAssertEqual(restored.profile?.id, 7, "the cached profile fallback must survive the cache round trip")

        let domainColors = restored.domainColors
        XCTAssertEqual(domainColors.count, 2, "cached colors must stay convertible to solver-ready domain colors")
        let sienna = try XCTUnwrap(domainColors.first { $0.id == 101 })
        XCTAssertEqual(sienna.brightness(for: .red), 0.87)
        XCTAssertNil(sienna.brightness(for: .green))
        XCTAssertEqual(domainColors.first { $0.id == 102 }?.brightness(for: .lps), 0.5)
    }

    // MARK: - Fixtures

    private static let printerProfilesJSON = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Epson SC-P700",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsJSON = """
    {
      "printer_profile": {
        "id": 7,
        "printer_make_model": "Epson SC-P700",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 101,
          "name": "Sienna",
          "hex": "#A0522D",
          "rgb": {"r": 160, "g": 82, "b": 45},
          "palette_id": 3,
          "palette_name": "Default",
          "sort_order": 1,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null}
          }
        },
        {
          "id": 102,
          "name": "Slate Gray",
          "hex": "#708090",
          "palette_id": 3,
          "sort_order": 2,
          "responses": {
            "lps": {"brightness": 0.5, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String?,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockTransport.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTransport.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }
}

/// URLProtocol-backed request capture, mirroring `PaletteAPIClientTests`.
private final class MockTransport: URLProtocol, @unchecked Sendable {
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
