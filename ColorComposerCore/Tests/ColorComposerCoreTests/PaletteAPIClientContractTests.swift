#if canImport(Darwin)
import Foundation
import XCTest
@testable import ColorComposerCore

/// Wire-behavior contract for the palette client.
///
/// The client is being migrated onto a generated OpenAPI client. The generated
/// code is an implementation detail; the *contract* is not: the app must keep
/// requesting the documented `/api/v1` endpoints with the documented
/// parameters, keep mapping transport and HTTP failures onto the same error
/// cases (the app decides what to show and whether to fall back to the disk
/// cache from them), and keep handing fetched colors to the cache in the shape
/// the offline fallback expects.
///
/// These checks pin that contract so the migration cannot quietly change it.
///
/// The whole file is Apple-only because `PaletteAPIClient` is excluded from the
/// portable Foundation subset the Linux lint harness builds.
final class PaletteAPIClientContractTests: XCTestCase {
    private let server = "http://example.com"
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIClientContractTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        ContractMockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    // MARK: - Requests

    /// Printer profiles are fetched from the documented endpoint, with the
    /// bearer token the server expects.
    func testPrinterProfilesRequestUsesTheDocumentedEndpointAndBearerToken() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesResponse)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            try XCTUnwrap(request.url).absoluteString,
            "http://example.com/api/v1/printer_profiles"
        )
        XCTAssertEqual(
            try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")),
            "Bearer test-token"
        )
    }

    /// Colors are fetched per printer profile through the documented query
    /// parameter.
    func testColorsRequestCarriesTheRequiredPrinterProfileQueryParameter() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.colorsResponse)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(colors.map(\.id), [11])
        XCTAssertEqual(profile?.id, 7)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/colors")
        XCTAssertEqual(try XCTUnwrap(url.query), "printer_profile_id=7")
    }

    /// The documented envelopes decode into the domain models the solver uses.
    func testDocumentedResponseEnvelopesDecodeIntoDomainModels() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsResponse)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(profile?.paperType, "Matte")
        XCTAssertEqual(profile?.inkType, "Pigment")

        let color = try XCTUnwrap(colors.first)
        XCTAssertEqual(color.name, "Cyan")
        XCTAssertEqual(color.hex, "#00FFFF")
        XCTAssertEqual(color.paletteId, 3)
        XCTAssertEqual(color.sortOrder, 2)
        XCTAssertEqual(try XCTUnwrap(color.responses["red"]?.brightness), 0.5)

        let domain = try XCTUnwrap(color.toDomain())
        XCTAssertEqual(domain.rgb, RGBColor(red: 0, green: 255, blue: 255))
        XCTAssertEqual(try XCTUnwrap(domain.brightness(for: .red)), 0.5)
        XCTAssertNil(domain.brightness(for: .lps), "an unmeasured channel stays absent, never zero")
    }

    // MARK: - Errors

    /// A rejected token stays distinguishable from every other failure: the
    /// app offers re-authentication for it and only falls back to the cache
    /// for transport failures.
    func testUnauthorizedResponseIsReportedAsUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertPaletteErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testServerErrorResponseIsReportedAsBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertPaletteErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testMalformedBodyIsReportedAsMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertPaletteErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Offline cache handoff

    /// Fetched colors are stored per server and profile and read back as
    /// solver-ready colors with the original fetch date — the date the
    /// offline-stale badge shows.
    func testFetchedColorsRoundTripThroughTheOfflineCache() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsResponse)
        }
        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: 7,
            profile: profile,
            colors: colors,
            fetchedAt: fetchedAt
        ))

        let cached = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: server))
        XCTAssertEqual(cached.fetchedAt, fetchedAt, "the offline badge shows the original fetch date")
        XCTAssertEqual(cached.domainColors.map(\.hex), ["#00FFFF"])
        XCTAssertTrue(cached.hasServableColors)
    }

    /// One server's cached palette is never served for another server's
    /// same-id profile.
    func testCachedColorsAreScopedToTheServerThatFetchedThem() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsResponse)
        }
        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: 7,
            profile: profile,
            colors: colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        XCTAssertNil(cache.entry(for: 7, serverBaseUrl: "http://other.example.com"))
        XCTAssertTrue(cache.allEntries(serverBaseUrl: "http://other.example.com").isEmpty)
    }

    /// The cached profile list is what the picker offers when the server
    /// cannot be reached at all.
    func testCachedProfilesAreListedForTheServerThatFetchedThem() throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(cachedEntry(profileID: 7))
        try cache.store(cachedEntry(profileID: 3))

        let entries = cache.allEntries(serverBaseUrl: server)

        XCTAssertEqual(entries.map(\.profileId), [3, 7])
        XCTAssertEqual(entries.map { $0.profile?.id }, [3, 7])
        XCTAssertTrue(cache.allEntries(serverBaseUrl: "http://other.example.com").isEmpty)
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: server)!, token: "test-token", session: session)
    }

    private func cachedEntry(profileID: Int) throws -> CachedProfileColors {
        CachedProfileColors(
            serverBaseUrl: server,
            profileId: profileID,
            profile: PrinterProfileDTO(
                id: profileID,
                printerMakeModel: "Example Printer",
                paperType: "Matte",
                inkType: "Pigment"
            ),
            colors: [try Self.colorDTO()],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func colorDTO() throws -> PaletteColorDTO {
        let json = """
        {
          "id": 11,
          "name": "Cyan",
          "hex": "#00FFFF",
          "rgb": {"r": 0, "g": 255, "b": 255},
          "palette_id": 3,
          "palette_name": "Core",
          "sort_order": 2,
          "responses": {"red": {"brightness": 0.5}}
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
    }

    private static let printerProfilesResponse = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Example Printer",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        }
      ]
    }
    """

    private static let colorsResponse = """
    {
      "printer_profile": {
        "id": 7,
        "printer_make_model": "Example Printer",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 11,
          "name": "Cyan",
          "hex": "#00FFFF",
          "rgb": {"r": 0, "g": 255, "b": 255},
          "palette_id": 3,
          "palette_name": "Core",
          "sort_order": 2,
          "responses": {"red": {"brightness": 0.5}}
        }
      ]
    }
    """
}

/// Records the requests the client sends.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class ContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func XCTAssertPaletteErrorAsync<T>(
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
#endif
