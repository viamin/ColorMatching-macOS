import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract guards for `PaletteAPIClient` against `/api/v1`.
///
/// The server now publishes an OpenAPI 3 spec at `GET /api/v1/openapi.json`
/// (viamin/color_matching#110) and this package migrates `PaletteAPIClient`
/// onto a generated client. These tests pin the externally observable wire
/// behavior that migration must preserve — endpoint paths, query, headers,
/// envelope decoding (including tolerance to additive spec fields), error
/// mapping, and the client→disk-cache seam that powers the offline-stale
/// fallback — so the generated-client change cannot silently alter any of it.
///
/// They intentionally assert only what the app depends on, not how the client
/// is implemented (e.g. they do not pin `httpMethod`, which a generated client
/// sets explicitly).
final class PaletteAPIClientWireContractTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIWireContract-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        MockTransport.handler = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    // MARK: - Endpoints and headers

    func testFetchPrinterProfilesRequestsTheVersionedEndpoint() async throws {
        let request = try await captureRequest {
            _ = try await makeClient().fetchPrinterProfiles()
        }

        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "No token configured: no Authorization header")
    }

    func testFetchColorsRequestsTheVersionedEndpointWithProfileQuery() async throws {
        let request = try await captureRequest {
            _ = try await makeClient().fetchColors(printerProfileID: 7)
        }

        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testWhitespaceOnlyTokenOmitsTheAuthorizationHeader() async throws {
        let request = try await captureRequest {
            _ = try await makeClient(token: "   ").fetchPrinterProfiles()
        }

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "A whitespace-only token must not produce an Authorization header")
    }

    // MARK: - Envelope decoding

    func testFetchPrinterProfilesDecodesTheEnvelope() async throws {
        stub(200, printerProfilesBody())

        let profiles = try await makeClient().fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchColorsDecodesColorsAndProfileEnvelope() async throws {
        stub(200, colorsBody())

        let fetched = try await makeClient().fetchColors(printerProfileID: 1)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.profile?.id, 1)

        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(color.responses["red"]?.source, "measurement")
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)
        XCTAssertNil(color.responses["green"],
                     "A channel with no measurement must be absent, never zero")
    }

    /// The OpenAPI spec is allowed to grow additively; unknown envelope and
    /// response fields (and unknown light-source keys) must not break the
    /// client. The domain conversion drops light sources outside the
    /// canonical set.
    func testDecodingToleratesAdditiveSpecFieldsAndUnknownLightSources() async throws {
        stub(200, """
        {
          "colors": [{
            "id": 9, "hex": "#112233",
            "rgb": {"r": 17, "g": 34, "b": 51},
            "responses": {
              "red": {"brightness": 0.5},
              "ultraviolet": {"brightness": 0.9}
            },
            "new_spec_field": {"nested": true}
          }],
          "printer_profile": null,
          "new_envelope_field": 42
        }
        """.data(using: .utf8)!)

        let fetched = try await makeClient().fetchColors(printerProfileID: 1)

        let domain = try XCTUnwrap(fetched.colors.first?.toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.5)
        XCTAssertNil(domain.brightness(for: .white),
                     "Unknown light sources must be dropped, not treated as measurements")
    }

    // MARK: - Error mapping

    func testServerErrorMapsToBadStatus() async {
        stub(503, Data())

        await XCTAssertThrowsErrorAsync(try await makeClient().fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableSuccessBodyMapsToMalformedResponse() async {
        stub(200, Data("not json".utf8))

        await XCTAssertThrowsErrorAsync(try await makeClient().fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testUnauthorizedAppliesToColorsFetchToo() async {
        stub(401, Data())

        await XCTAssertThrowsErrorAsync(try await makeClient().fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Connection test

    func testTestConnectionSucceedsOn2xx() async throws {
        stub(200, printerProfilesBody())

        try await makeClient().testConnection()
    }

    func testTestConnectionThrowsOn401() async {
        stub(401, Data())

        await XCTAssertThrowsErrorAsync(try await makeClient().testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Offline fallback seam

    /// The disk cache stores the wire DTOs exactly as the client fetched
    /// them, keyed per server and profile, and serves them back as solver-
    /// ready domain colors when the server is unreachable. Whatever the
    /// generated-client migration changes internally, its outputs must keep
    /// feeding this seam unchanged.
    func testFetchedColorsRoundTripThroughTheDiskCacheForOfflineFallback() async throws {
        stub(200, colorsBody())
        let baseURL = URL(string: "https://api.example.com")!

        let fetched = try await makeClient().fetchColors(printerProfileID: 1)

        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: baseURL.absoluteString,
            profileId: 1,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let cached = try XCTUnwrap(cache.entry(for: 1, serverBaseUrl: baseURL.absoluteString))

        XCTAssertEqual(cached.colors, fetched.colors)
        XCTAssertEqual(cached.profile, fetched.profile)
        XCTAssertTrue(cached.hasServableColors)

        let domain = try XCTUnwrap(cached.domainColors.first)
        XCTAssertEqual(domain.id, 123)
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
        XCTAssertNil(domain.brightness(for: .green),
                     "Cached unmeasured channels must stay absent, never zero — the offline palette behaves exactly like the live one")
    }

    // MARK: - Internals

    private func makeClient(token: String? = nil) -> PaletteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTransport.self]
        return PaletteAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func stub(_ statusCode: Int, _ body: Data) {
        MockTransport.handler = { request in
            (.init(statusCode: statusCode, url: request.url!), body)
        }
    }

    private func captureRequest(
        _ perform: @escaping () async throws -> Void
    ) async throws -> URLRequest {
        let lock = NSLock()
        var captured: URLRequest?
        MockTransport.handler = { request in
            lock.lock()
            captured = request
            lock.unlock()
            // Decodes for both endpoints so the capture helper is endpoint-agnostic.
            let body = "{\"printer_profiles\": [], \"colors\": [], \"printer_profile\": null}"
            return (.init(statusCode: 200, url: request.url!), Data(body.utf8))
        }

        try await perform()

        return try XCTUnwrap(captured, "No request was captured")
    }

    private func printerProfilesBody() -> Data {
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 2, "printer_make_model": "Other Printer", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """.data(using: .utf8)!
    }

    private func colorsBody() -> Data {
        """
        {
          "printer_profile": {
            "id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"
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
        """.data(using: .utf8)!
    }
}

private final class MockTransport: URLProtocol, @unchecked Sendable {
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
