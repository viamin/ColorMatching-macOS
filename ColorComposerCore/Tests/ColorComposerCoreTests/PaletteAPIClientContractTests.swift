import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire behavior `PaletteAPIClient` relies on: endpoint
/// paths, the `printer_profile_id` query, JSON `Accept`, absent-token
/// requests, snake_case response envelopes, missing-measurement absence, and
/// HTTP status → error mapping (issue #39).
///
/// These are the contracts the generated OpenAPI client must keep satisfying
/// after the migration — the disk cache and offline-stale behavior consume
/// exactly these DTOs (see `ProfileColorCacheTests`).
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    func testFetchPrinterProfilesHitsAPIV1EndpointWithoutToken() async throws {
        let requests = RequestLog()
        let client = makeClient(token: nil, requests: requests) { request in
            (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 4)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson XP-8600")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")

        let request = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no token configured → no Authorization header")
        XCTAssertNil(request.url?.query, "profile listing carries no query")
    }

    func testFetchColorsSendsPrinterProfileIDQueryAndDecodesEnvelope() async throws {
        let requests = RequestLog()
        let client = makeClient(token: nil, requests: requests) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 4)

        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.id, 9)
        XCTAssertEqual(colors.first?.hex, "#A0522D")
        XCTAssertEqual(colors.first?.responses["red"]?.brightness ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(colors.first?.responses["lps"]?.brightness ?? -1, 0.125, accuracy: 1e-12)
        XCTAssertNil(colors.first?.responses["white"], "unmeasured conditions are absent, never zero")
        XCTAssertNil(colors.first?.responses["green"])
        XCTAssertEqual(profile?.id, 4)

        let url = try XCTUnwrap(requests.values.first?.url)
        XCTAssertEqual(url.path, "/api/v1/colors")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first?.name, "printer_profile_id")
        XCTAssertEqual(query.first?.value, "4")
    }

    func testFetchColorsMapsServiceUnavailableToBadStatus() async throws {
        let client = makeClient(token: nil, requests: RequestLog()) { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsMalformedBodyToMalformedResponse() async throws {
        let client = makeClient(token: nil, requests: RequestLog()) { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient(token: nil, requests: RequestLog()) { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        await XCTAssertNoThrowAsync(try await client.testConnection())
    }

    func testTestConnectionRejectsNon2xx() async throws {
        let client = makeClient(token: nil, requests: RequestLog()) { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    // MARK: - Fixtures

    private static let printerProfilesBody = """
    {
      "printer_profiles": [
        {"id": 4, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Pigment"}
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "printer_profile": {
        "id": 4, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 9, "name": "Sienna", "hex": "#A0522D",
          "rgb": {"r": 160, "g": 82, "b": 45},
          "palette_id": 2, "palette_name": "Default", "sort_order": 3,
          "responses": {
            "red": {"brightness": 0.5, "source": "response", "apparent_brightness": 5,
                    "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null},
            "lps": {"brightness": 0.125, "source": "measurement", "apparent_brightness": null,
                    "raw_value": 12.5, "raw_unit": "percent", "measured_at": null, "test_run_id": null}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String?,
        requests: RequestLog,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        requests.reset()
        MockURLProtocol.handler = { request in
            requests.append(request)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }
}

/// Thread-safe request capture for `@Sendable` mock handlers.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }

    var values: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func reset() {
        lock.lock()
        stored = []
        lock.unlock()
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
