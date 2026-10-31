import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract for the `/api/v1` endpoints `PaletteAPIClient` consumes,
/// pinned against the OpenAPI 3 document the `color_matching` server
/// publishes at `GET /api/v1/openapi.json` (viamin/color_matching#110,
/// landed in #113). Fixture payloads in this file conform to that spec's
/// `PrinterProfilesResponse` and `ColorsResponse` schemas.
///
/// These tests are the migration safety net for adopting a generated
/// OpenAPI client (issue #39): whatever transport/decoding layer
/// `PaletteAPIClient` uses underneath, requests, error mapping, and decoded
/// DTOs must keep agreeing with the assertions here — including the cache
/// round-trip, because the offline fallback stores these DTOs verbatim.
final class PaletteAPIContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesDecodesSpecConformantPayload() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesPayload)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsSendsProfileQueryAndDecodesSpecConformantPayload() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "printer_profile_id" }?.value,
                "7"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.colorsPayload)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(profile?.id, 7)
        XCTAssertEqual(colors.first?.hex, "#C64A35")
        XCTAssertEqual(colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(colors.first?.responses["lps"]?.apparentBrightness, 5)
    }

    /// The spec leaves `rgb` off the color item's required list; the client
    /// must keep accepting such payloads and fall back to `hex` when
    /// converting for the solver.
    func testFetchColorsAcceptsColorsWithoutRGBAndFallsBackToHex() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.rgblessColorsPayload)
        }

        let (colors, _) = try await client.fetchColors(printerProfileID: 7)
        let domain = try XCTUnwrap(colors.first?.toDomain())

        XCTAssertEqual(domain.rgb, RGBColor(hex: "#112233"))
    }

    /// The spec types `palette_name` as nullable.
    func testFetchColorsAcceptsNullPaletteName() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.nullPaletteNamePayload)
        }

        let (colors, _) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertNil(colors.first?.paletteName)
        XCTAssertEqual(colors.first?.toDomain()?.paletteName, nil)
    }

    // MARK: - Authorization

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let (client, log) = makeClientCapturingAuthorization(token: nil)

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(log.values, [nil])
    }

    func testBlankTokenSendsNoAuthorizationHeader() async throws {
        let (client, log) = makeClientCapturingAuthorization(token: "   ")

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(log.values, [nil])
    }

    func testTokenIsSentTrimmedAsBearer() async throws {
        let (client, log) = makeClientCapturingAuthorization(token: "  token-1  ")

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(log.values, ["Bearer token-1"])
    }

    // MARK: - Error mapping

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    /// A 2xx body that does not conform to the envelope schema (here: the
    /// wrapped `data`/`errors` error shape other endpoints use) must surface
    /// as `malformedResponse`, never as a crash or a silently empty palette.
    func testFetchColorsMapsNonConformantBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data(#"{"errors":{"detail":"nope"}}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Connection test

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.printerProfilesPayload)
        }

        try await client.testConnection()
    }

    func testTestConnectionThrowsOnServiceUnavailable() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    // MARK: - Offline fallback (issue #39 exit criterion)

    /// Colors fetched over the wire must survive the per-server/profile disk
    /// cache verbatim, because offline mode re-serves exactly those DTOs as
    /// offline-stale. The generated-client migration may not change the DTOs
    /// written into — or readable back from — this cache.
    func testFetchedColorsSurviveDiskCacheRoundTripForOfflineFallback() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsPayload)
        }
        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIContractTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://example.com",
            profileId: 7,
            profile: profile,
            colors: colors,
            fetchedAt: fetchedAt
        ))

        let restored = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: "http://example.com"))
        XCTAssertEqual(restored.colors, colors)
        XCTAssertEqual(restored.profile, profile)
        XCTAssertEqual(restored.fetchedAt, fetchedAt)
        XCTAssertEqual(restored.domainColors.map(\.id), colors.compactMap(\.id))
        XCTAssertTrue(restored.hasServableColors)
        // The cache is scoped per server: another server's same-id profile
        // must not see this fetch.
        XCTAssertNil(cache.entry(for: 7, serverBaseUrl: "http://elsewhere.example"))
    }

    // MARK: - Fixtures

    /// Conforms to the spec's `PrinterProfilesResponse`.
    private static let printerProfilesPayload = Data(
        """
        {"printer_profiles":[
          {"id":1,"printer_make_model":"Example Printer","paper_type":"Matte","ink_type":"Pigment"},
          {"id":2,"printer_make_model":"Other Printer","paper_type":"Glossy","ink_type":"Dye"}
        ]}
        """.utf8
    )

    /// Conforms to the spec's `ColorsResponse` (`printer_profile` and
    /// `colors` required; each color carries the required `id`, `name`,
    /// `hex`, `palette_id`, `sort_order`, `responses`).
    private static let colorsPayload = Data(
        """
        {"printer_profile":{"id":7,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"},
         "colors":[
          {"id":123,"name":"Red 12","hex":"#C64A35","rgb":{"r":198,"g":74,"b":53},
           "palette_id":5,"palette_name":"Default","sort_order":12,
           "responses":{
             "red":{"brightness":0.87,"source":"measurement","raw_value":null,"raw_unit":null,
                    "apparent_brightness":null,"measured_at":null,"test_run_id":null},
             "lps":{"brightness":0.52,"source":"response","raw_value":null,"raw_unit":null,
                    "apparent_brightness":5,"measured_at":null,"test_run_id":null}}},
          {"id":124,"name":"Blue 3","hex":"#3355AA","rgb":{"r":51,"g":85,"b":170},
           "palette_id":5,"palette_name":"Default","sort_order":13,
           "responses":{
             "blue":{"brightness":0.41,"source":"response","raw_value":null,"raw_unit":null,
                     "apparent_brightness":4,"measured_at":null,"test_run_id":null}}}
        ]}
        """.utf8
    )

    /// `rgb` is optional in the spec — a color without it must still decode
    /// and convert through `hex`.
    private static let rgblessColorsPayload = Data(
        """
        {"printer_profile":{"id":7,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"},
         "colors":[
          {"id":1,"name":"Hex Only","hex":"#112233","palette_id":5,"palette_name":null,"sort_order":1,
           "responses":{"red":{"brightness":0.5}}}
        ]}
        """.utf8
    )

    private static let nullPaletteNamePayload = rgblessColorsPayload

    // MARK: - Plumbing

    private func makeClient(
        token: String? = "token-1",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    /// A client whose every request appends its `Authorization` header to a
    /// lock-guarded log and is answered with a spec-conformant profiles
    /// payload.
    private func makeClientCapturingAuthorization(
        token: String?
    ) -> (client: PaletteAPIClient, log: AuthorizationHeaderLog) {
        let log = AuthorizationHeaderLog()
        let client = makeClient(token: token) { request in
            log.record(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesPayload)
        }
        return (client, log)
    }
}

private final class AuthorizationHeaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String?] = []

    func record(_ header: String?) {
        lock.lock()
        headers.append(header)
        lock.unlock()
    }

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return headers
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
