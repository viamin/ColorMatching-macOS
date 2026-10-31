import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

final class PaletteAPIClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    func testFetchPrinterProfilesThrowsUnauthorizedWithoutRetryHandler() async {
        let client = makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
            return (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchPrinterProfilesUsesTrimmedBearerToken() async throws {
        let lock = NSLock()
        var requests: [String?] = []
        let client = makeClient { request in
            lock.lock()
            requests.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests, ["Bearer stale-token"])
    }

    // MARK: - Wire contract (must survive the generated OpenAPI client migration, issue #39)

    /// Pins the exact request the migration must keep issuing: the versioned
    /// path, GET method, and JSON Accept header on every fetch.
    func testFetchPrinterProfilesRequestsVersionedAPIPath() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    /// The colors fetch is scoped by printer profile via the
    /// `printer_profile_id` query parameter — the one query the app makes today.
    func testFetchColorsRequestsProfileScopedColorsURL() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        _ = try await client.fetchColors(printerProfileID: 7)
    }

    func testFetchColorsDecodesEnvelopeColorsAndProfile() async throws {
        let client = makeClient { _ in
            (.init(statusCode: 200, url: URL(string: "http://example.com/api/v1/colors?printer_profile_id=7")!), colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 55)
        XCTAssertEqual(color.name, "Vermilion")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Epson SC-P900")
    }

    func testFetchColorsThrowsUnauthorizedOn401() async {
        let client = makeClient { _ in
            (.init(statusCode: 401, url: URL(string: "http://example.com/api/v1/colors?printer_profile_id=7")!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsThrowsBadStatusOn500() async {
        let client = makeClient { _ in
            (.init(statusCode: 500, url: URL(string: "http://example.com/api/v1/colors?printer_profile_id=7")!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchPrinterProfilesThrowsBadStatusOn500() async {
        let client = makeClient { _ in
            (.init(statusCode: 500, url: URL(string: "http://example.com/api/v1/printer_profiles")!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    /// A 2xx body that is not the documented envelope must surface as
    /// `malformedResponse`, not a decoder crash — the generated client must
    /// preserve that classification.
    func testFetchColorsThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { _ in
            (.init(statusCode: 200, url: URL(string: "http://example.com/api/v1/colors?printer_profile_id=7")!),
             Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchPrinterProfilesThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { _ in
            (.init(statusCode: 200, url: URL(string: "http://example.com/api/v1/printer_profiles")!),
             Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    /// "Test connection" accepts any 2xx — an empty 204 body must not be
    /// decoded — while a 401 still reports the re-authentication path.
    func testTestConnectionSucceedsOn2xxWithoutDecodingBody() async throws {
        let client = makeClient { _ in
            (.init(statusCode: 204, url: URL(string: "http://example.com/api/v1/printer_profiles")!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionThrowsUnauthorizedOn401() async {
        let client = makeClient { _ in
            (.init(statusCode: 401, url: URL(string: "http://example.com/api/v1/printer_profiles")!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    /// A blank token means no Authorization header at all — the migration
    /// must keep normalizing instead of sending `Bearer` with whitespace.
    func testNoAuthorizationHeaderSentForBlankOrMissingToken() async throws {
        let lock = NSLock()
        var headers: [String?] = []

        for token in [nil, "   "] {
            let client = makeClient(token: token) { request in
                lock.lock()
                headers.append(request.value(forHTTPHeaderField: "Authorization"))
                lock.unlock()
                return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
            }
            _ = try await client.fetchPrinterProfiles()
        }

        XCTAssertEqual(headers, [nil, nil])
    }

    private func makeClient(
        token: String? = "  stale-token  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    private func printerProfilesResponse() -> Data {
        """
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
        """.data(using: .utf8)!
    }

    /// A representative `GET /api/v1/colors?printer_profile_id=N` envelope:
    /// one color with merged response/measurement provenance plus the
    /// embedded printer profile (issue #39 pins this wire shape).
    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson SC-P900",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 55,
              "name": "Vermilion",
              "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 3,
              "palette_name": "Default",
              "sort_order": 1,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null},
                "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
              }
            }
          ]
        }
        """.data(using: .utf8)!
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
