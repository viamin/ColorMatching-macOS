import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the observable contract of `PaletteAPIClient` so the migration to the
/// generated OpenAPI client (issue #39) keeps wire behavior bit-for-bit:
/// versioned endpoints, JSON Accept header, bearer-token handling, status-code
/// error mapping, and the snake_case `/api/v1` envelope shapes. A migration
/// that regresses any of these fails here before it can reach the disk cache
/// or offline-stale fallback layers.
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

    func testFetchPrinterProfilesRequestsVersionedJSONEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
    }

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(URLQueryItem(name: "printer_profile_id", value: "7")))
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(profile?.id, 1)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.id, 123)
        XCTAssertEqual(colors.first?.responses["red"]?.brightness ?? -1, 0.87, accuracy: 1e-12)
        XCTAssertEqual(colors.first?.responses["red"]?.source, "measurement")
        // Missing measurements are absent, never zero brightness.
        XCTAssertNil(colors.first?.responses["green"])
        XCTAssertNil(colors.first?.responses["white"])
    }

    func testFetchColorsMapsNonSuccessStatusToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableSuccessBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not an envelope".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testOmitsAuthorizationHeaderWhenTokenIsBlank() async throws {
        let lock = NSLock()
        var authHeaders: [String?] = []
        let client = makeClient(token: "   ") { request in
            lock.lock()
            authHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(authHeaders, [nil])
    }

    func testTestConnectionSucceedsOn2xxAndMaps401ToUnauthorized() async throws {
        let ok = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }
        try await ok.testConnection()

        let rejected = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await rejected.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    private func makeClient(
        baseURL: URL = URL(string: "http://example.com")!,
        token: String? = "  stale-token  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: baseURL, token: token, session: session)
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

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"}
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
