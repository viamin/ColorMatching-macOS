import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavior pins for the `PaletteAPIClient` → generated-OpenAPI-client
/// migration (#39).
///
/// `PaletteAPIClient` (or its generated-client wrapper) must keep this exact
/// observable contract: `/api/v1` endpoints, snake_case wire envelopes, the
/// trimmed bearer token, the 401/non-2xx/malformed error mapping, and the
/// ability to round-trip fetched colors through `ProfileColorCache` so the
/// offline-stale and cached-profile-fallback behaviors survive the migration.
final class PaletteAPIClientContractTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIClientContractTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        RecordingURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    // MARK: - Endpoints and wire shape

    func testFetchPrinterProfilesRequestsTheV1EndpointAndDecodesTheEnvelope() async throws {
        let body = printerProfilesBody()
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/printer_profiles"
            )
            return (.init(statusCode: 200, url: request.url!), body)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 4])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.last?.inkType, "Dye")
    }

    func testFetchColorsRequestsTheV1EndpointWithTheProfileQueryAndDecodesTheEnvelope() async throws {
        let body = colorsBody()
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/colors?printer_profile_id=7"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), body)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [11, 12])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.25)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Epson P800")
    }

    func testClientWithoutTokenSendsNoAuthorizationHeader() async throws {
        let body = printerProfilesBody()
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), body)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Error mapping

    func testFetchColorsMapsHTTP500ToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsMapsUnparseableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionHitsTheV1EndpointAndRejectsNon2xx() async {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            return (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    // MARK: - Disk cache / offline fallback integration

    /// A successful fetch must remain storeable through `ProfileColorCache`
    /// such that: the offline-stale path serves the same colors with the
    /// original fetch date (badged stale), and the profile picker fallback
    /// (`allEntries`) still lists the profile when the server is unreachable.
    func testFetchedColorsRoundTripThroughDiskCacheForOfflineStaleAndProfileFallback() async throws {
        let body = colorsBody()
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), body)
        }
        let cache = ProfileColorCache(directory: cacheDirectory)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let fetched = try await client.fetchColors(printerProfileID: 7)
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://example.com",
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: fetchedAt
        ))

        // Offline-stale path: the cached entry serves the fetched colors with
        // their fetch date for the stale badge.
        let entry = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: "http://example.com"))
        XCTAssertEqual(entry.colors.map(\.id), [11, 12])
        XCTAssertEqual(entry.fetchedAt, fetchedAt)
        XCTAssertEqual(entry.domainColors.count, 2)
        XCTAssertTrue(entry.hasServableColors)

        // Cached-profile fallback: the picker lists the profile when the
        // server cannot be reached at all.
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://example.com").map(\.profileId), [7])
    }

    // MARK: - Helpers

    private func makeClient(
        token: String? = "  stale-token  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        RecordingURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    private func printerProfilesBody() -> Data {
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 4, "printer_make_model": "Other Printer", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """.data(using: .utf8)!
    }

    private func colorsBody() -> Data {
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson P800", "paper_type": "Matte", "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 11, "name": "Cyan", "hex": "#00AABB", "rgb": {"r": 0, "g": 170, "b": 187},
              "palette_id": 1, "palette_name": "Test", "sort_order": 1,
              "responses": {
                "red": {"brightness": 0.25}, "green": {"brightness": 0.5}
              }
            },
            {
              "id": 12, "name": "Magenta", "hex": "#BB00AA", "rgb": {"r": 187, "g": 0, "b": 170},
              "palette_id": 1, "palette_name": "Test", "sort_order": 2,
              "responses": {
                "red": {"brightness": 0.5}, "green": {"brightness": 0.25}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
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
