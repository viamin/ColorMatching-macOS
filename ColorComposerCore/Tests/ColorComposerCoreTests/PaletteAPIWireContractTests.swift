import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Observable wire contract of `PaletteAPIClient` against the published
/// `/api/v1` OpenAPI shapes (viamin/color_matching#113).
///
/// These tests pin the behavior the swift-openapi-generator migration
/// (issue #39) must preserve whether the generated client replaces or wraps
/// `PaletteAPIClient`: the `/api/v1` paths, the `printer_profile_id` query,
/// JSON `Accept` + bearer authorization headers, 401-vs-5xx-vs-malformed
/// error mapping, and decoding of spec-shaped envelopes — including colors
/// where every OpenAPI-required field is present
/// (`id`, `name`, `hex`, `palette_id`, `sort_order`, `responses`) and
/// `palette_name` is explicitly nullable.
final class PaletteAPIWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        WireContractMockURLProtocol.handler = nil
    }

    // MARK: - Paths, query, headers

    func testFetchPrinterProfilesHitsAPIV1PathWithJSONAcceptAndBearer() async throws {
        let recorder = RecordingHandler.responding(with: (.ok, printerProfilesBody()))
        let client = makeClient(token: "secret", handler: recorder.handler)

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(recorder.recorded.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testFetchColorsSendsPrinterProfileIDQuery() async throws {
        let recorder = RecordingHandler.responding(with: (.ok, colorsBody()))
        let client = makeClient(token: "secret", handler: recorder.handler)

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(recorder.recorded.first)
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "printer_profile_id", value: "7")), "got \(query)")
    }

    // MARK: - Spec-shaped payload decoding

    func testFetchColorsDecodesSpecShapedEnvelope() async throws {
        let client = makeClient(handler: StaticHandler.responding(with: (.ok, colorsBody())))

        let result = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(result.profile?.id, 7)
        XCTAssertEqual(result.profile?.printerMakeModel, "Epson SC-P700")
        XCTAssertEqual(result.colors.count, 2)

        let measured = try XCTUnwrap(result.colors.first { $0.id == 123 })
        // Fields the published spec marks required must survive decoding.
        XCTAssertEqual(measured.name, "Red 12")
        XCTAssertEqual(measured.paletteId, 5)
        XCTAssertEqual(measured.sortOrder, 12)
        XCTAssertEqual(measured.hex, "#C64A35")
        XCTAssertEqual(measured.rgb?.r, 198)
        // `palette_name` is nullable in the spec; null decodes as nil.
        XCTAssertNil(measured.paletteName)
        // Response provenance round-trips.
        XCTAssertEqual(measured.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(measured.responses["red"]?.rawValue, 41.2)
        XCTAssertEqual(measured.responses["red"]?.rawUnit, "percent")
        XCTAssertEqual(measured.responses["red"]?.measuredAt, "2026-10-01T12:00:00Z")
        // Measured zero is present and distinct from a missing measurement.
        XCTAssertEqual(measured.responses["lps"]?.brightness, 0.0)
        XCTAssertNotNil(measured.responses["lps"])

        // Response-less colors (no measurement for this profile) come back
        // with an empty map and are excluded by the solver, not the client.
        let unmeasured = try XCTUnwrap(result.colors.first { $0.id == 124 })
        XCTAssertEqual(unmeasured.paletteName, "Default")
        XCTAssertTrue(unmeasured.responses.isEmpty)
    }

    func testFetchedColorsConvertToDomainForTheSolver() async throws {
        let client = makeClient(handler: StaticHandler.responding(with: (.ok, colorsBody())))

        let result = try await client.fetchColors(printerProfileID: 7)

        let domain = try XCTUnwrap(result.colors.first { $0.id == 123 }.flatMap { try? $0.toDomain() })
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
        XCTAssertEqual(domain.brightness(for: .lps), 0.0)
        XCTAssertNil(domain.brightness(for: .green))
        XCTAssertEqual(domain.rgb, RGBColor(red: 198, green: 74, blue: 53))
    }

    // MARK: - Error mapping

    func testFetchColorsThrowsUnauthorizedOn401() async {
        let client = makeClient(handler: StaticHandler.responding(with: (.unauthorized, Data())))

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchPrinterProfilesThrowsBadStatusOn500() async {
        let client = makeClient(handler: StaticHandler.responding(with: (.serverError, Data())))

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsThrowsMalformedResponseOnInvalidJSON() async {
        let client = makeClient(handler: StaticHandler.responding(with: (.ok, Data("not json".utf8))))

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Connection test

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient(handler: StaticHandler.responding(with: (.ok, printerProfilesBody())))
        try await client.testConnection()
    }

    func testTestConnectionThrowsUnauthorizedOn401() async {
        let client = makeClient(handler: StaticHandler.responding(with: (.unauthorized, Data())))

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures

    /// Sample `GET /api/v1/colors?printer_profile_id=7` response shaped to
    /// the published OpenAPI schema (every required color field present).
    private func colorsBody() -> Data {
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson SC-P700",
            "paper_type": "Matte", "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": null, "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement", "raw_value": 41.2, "raw_unit": "percent", "apparent_brightness": null, "measured_at": "2026-10-01T12:00:00Z", "test_run_id": "run-9"},
                "lps": {"brightness": 0.0, "source": "response", "apparent_brightness": 0, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
              }
            },
            {
              "id": 124, "name": "Unmeasured Base", "hex": "#FFFFFF",
              "rgb": {"r": 255, "g": 255, "b": 255},
              "palette_id": 5, "palette_name": "Default", "sort_order": 13,
              "responses": {}
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func printerProfilesBody() -> Data {
        """
        {"printer_profiles": [{"id": 7, "printer_make_model": "Epson SC-P700", "paper_type": "Matte", "ink_type": "Pigment"}]}
        """.data(using: .utf8)!
    }

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireContractMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }
}

// MARK: - Mock transport

private typealias Response = (status: Int, body: Data)

private enum StaticHandler {
    static let ok = 200
    static let unauthorized = 401
    static let serverError = 500

    static func responding(with response: Response) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in (HTTPURLResponse(status: response.status, url: request.url!), response.body) }
    }
}

private final class RecordingHandler {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private(set) var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))!

    static func responding(with response: Response) -> RecordingHandler {
        let recorder = RecordingHandler()
        recorder.handler = { request in
            recorder.record(request)
            return (HTTPURLResponse(status: response.status, url: request.url!), response.body)
        }
        return recorder
    }

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
    }
}

private final class WireContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
    convenience init(status: Int, url: URL) {
        self.init(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
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
