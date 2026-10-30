import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-behavior pins for `PaletteAPIClient` that the migration to the
/// generated OpenAPI client (issue #39) must preserve unchanged: the
/// versioned `/api/v1` paths, the `printer_profile_id` query parameter,
/// bearer-token trimming and forwarding, status→error mapping (401 distinct
/// from other non-2xx), malformed-payload mapping, envelope decoding, and
/// domain conversion. Together with `ProfileColorCacheTests` (per-server
/// disk cache, offline-stale fallback) these are the executable record that
/// the generated-client migration changes no externally observable behavior.
final class PaletteAPIWireBehaviorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WireMockURLProtocol.reset()
    }

    override func tearDown() {
        super.tearDown()
        WireMockURLProtocol.handler = nil
    }

    private var recordedRequests: [URLRequest] {
        WireMockURLProtocol.recordedRequests
    }

    private func makeClient(token: String? = "  good-token  ") -> PaletteAPIClient {
        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://palette.example")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    // MARK: - fetchColors request shape

    func testFetchColorsHitsVersionedPathWithProfileIDQueryAndTrimmedToken() async throws {
        let client = makeClient()

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.sorted { $0.name < $1.name },
            [URLQueryItem(name: "printer_profile_id", value: "7")],
            "fetchColors must send printer_profile_id exactly once as a query parameter"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer good-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetchPrinterProfilesHitsVersionedPath() async throws {
        let client = makeClient()
        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
    }

    // MARK: - fetchColors envelope decoding and domain conversion

    func testFetchColorsDecodesEnvelopeProfileAndResponses() async throws {
        let client = makeClient()

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(profile?.id, 7)
        XCTAssertEqual(profile?.printerMakeModel, "Epson SC-P5000")
        XCTAssertEqual(profile?.paperType, "Velvet Matte")

        let color = try XCTUnwrap(colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 032")
        XCTAssertEqual(color.hex, "#EF3340")
        XCTAssertEqual(color.rgb?.r, 239)
        XCTAssertEqual(color.paletteId, 5)
        XCTAssertEqual(color.paletteName, "Standard")
        XCTAssertEqual(color.sortOrder, 3)
        XCTAssertEqual(color.responses["red"]?.brightness ?? 0, 0.9, accuracy: 1e-12)
        XCTAssertEqual(color.responses["red"]?.source, "response")
        XCTAssertEqual(color.responses["red"]?.apparentBrightness, 9)
        XCTAssertEqual(color.responses["lps"]?.brightness ?? 0, 0.4, accuracy: 1e-12)
        XCTAssertEqual(color.responses["lps"]?.source, "measurement")
        XCTAssertEqual(color.responses["lps"]?.rawValue ?? 0, 12.5, accuracy: 1e-12)
        XCTAssertEqual(color.responses["lps"]?.rawUnit, "lx")
        XCTAssertNil(color.responses["green"], "Unmeasured conditions must be absent, not zero")

        let domain = try XCTUnwrap(color.toDomain())
        XCTAssertEqual(domain.brightness(for: .red) ?? 0, 0.9, accuracy: 1e-12)
        XCTAssertNil(domain.brightness(for: .green))
        XCTAssertEqual(domain.rgb, RGBColor(red: 239, green: 51, blue: 64))
    }

    // MARK: - Error mapping

    func testFetchColorsMapsMalformedPayloadToMalformedResponse() async {
        let client = makeClient()
        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchColorsMapsUnauthorizedToDistinctError() async {
        let client = makeClient()
        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient()
        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsOmitsAuthorizationHeaderWithoutToken() async throws {
        let client = makeClient(token: "   ")

        _ = try await client.fetchColors(printerProfileID: 2)

        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertNil(
            request.value(forHTTPHeaderField: "Authorization"),
            "A whitespace-only token must be treated as absent, not sent as an empty bearer"
        )
    }

    // MARK: - Connection test

    func testTestConnectionAcceptsAny2xxAndRejectsNon2xx() async {
        let client = makeClient()
        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 204, url: request.url!), Data())
        }
        await XCTAssertNoThrowAsync(try await client.testConnection())

        WireMockURLProtocol.handler = { request in
            WireMockURLProtocol.record(request)
            return (.init(statusCode: 503, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    // MARK: - Fixtures

    private static func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson SC-P5000",
            "paper_type": "Velvet Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123,
              "name": "Red 032",
              "hex": "#EF3340",
              "rgb": {"r": 239, "g": 51, "b": 64},
              "palette_id": 5,
              "palette_name": "Standard",
              "sort_order": 3,
              "responses": {
                "red": {"brightness": 0.9, "source": "response", "apparent_brightness": 9},
                "lps": {"brightness": 0.4, "source": "measurement", "raw_value": 12.5, "raw_unit": "lx"}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 1,
              "printer_make_model": "Epson SC-P5000",
              "paper_type": "Velvet Matte",
              "ink_type": "Pigment"
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

/// Mock URL protocol recording every request it serves. Handlers run on
/// URLSession's internal queues, so recording goes through a lock.
private final class WireMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _recorded: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _recorded
    }

    static func record(_ request: URLRequest) {
        lock.lock()
        _recorded.append(request)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        _recorded.removeAll()
        lock.unlock()
    }

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
