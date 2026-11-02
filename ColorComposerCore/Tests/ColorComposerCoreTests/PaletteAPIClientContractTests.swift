import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract of `PaletteAPIClient` against `/api/v1`, pinned for the
/// generated OpenAPI client migration (#39). Whichever mechanism ends up
/// issuing requests — a `swift-openapi-runtime` generated client or a
/// wrapper around it — these observable behaviors must stay unchanged:
///
/// - endpoints and the `printer_profile_id` query parameter
/// - `Accept`/`Authorization` headers (token trimming, omission without token)
/// - snake_case envelope decoding, including response-less colors
/// - error mapping: 401 → `unauthorized`, other non-2xx → `badStatus`,
///   undecodable 2xx body → `malformedResponse`
/// - fetched DTOs keep flowing into the offline disk cache unchanged
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsRequestsTheProfileScopedEndpointAndDecodesTheEnvelope() async throws {
        let lock = NSLock()
        var capturedRequests: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            capturedRequests.append(request)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsEnvelope())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

        XCTAssertEqual(fetched.colors.map(\.id), [123, 124])
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Epson P700")

        let measured = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(measured.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(measured.responses["red"]?.source, "measurement")
        XCTAssertEqual(measured.responses["lps"]?.apparentBrightness, 5)

        // A color with no measurement for the profile is response-less and
        // must decode with empty responses (the solver excludes it later).
        let unmeasured = try XCTUnwrap(fetched.colors.last)
        XCTAssertTrue(unmeasured.responses.isEmpty)
    }

    func testFetchColorsOmitsAuthorizationWhenNoTokenIsConfigured() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), #"{"colors":[]}"#.data(using: .utf8)!)
        }

        let fetched = try await client.fetchColors(printerProfileID: 1)

        XCTAssertTrue(fetched.colors.isEmpty)
        XCTAssertNil(fetched.profile)
    }

    func testFetchColorsMapsNonSuccessStatusToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesDecodesTheEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson P700")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.last?.inkType, "Dye")
    }

    // MARK: - Connection probe

    func testTestConnectionSucceedsOnAny2xxStatus() async throws {
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

    // MARK: - Offline disk-cache compatibility

    /// The offline-stale fallback stores exactly the DTOs the client returns
    /// and badges them with their fetch date; whatever the generated-client
    /// migration changes underneath, fetched results must keep flowing into
    /// `ProfileColorCache` unchanged.
    func testFetchedColorDTOsRoundTripThroughTheOfflineDiskCache() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsEnvelope())
        }
        let fetched = try await client.fetchColors(printerProfileID: 7)

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIClientContractTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://example.com",
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let cached = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: "http://example.com"))

        XCTAssertEqual(cached.domainColors.map(\.id), [123, 124])
        XCTAssertEqual(cached.domainColors.first?.brightness(for: .lps), 0.52)
        XCTAssertTrue(cached.hasServableColors)
    }

    // MARK: - Fixtures

    private func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson P700", "paper_type": "Matte", "ink_type": "Pigment"
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
              "id": 124, "name": "Unmeasured", "hex": "#010203", "responses": {}
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Epson P700", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 2, "printer_make_model": "Canon Pro-300", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """.data(using: .utf8)!
    }

    private func makeClient(
        token: String? = "test-token",
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
