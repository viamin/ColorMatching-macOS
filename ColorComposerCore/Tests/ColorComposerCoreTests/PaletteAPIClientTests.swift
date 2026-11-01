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

    // MARK: - Wire contract (must survive the generated OpenAPI client migration, #39)

    /// The migration to the generated OpenAPI client (#39) must keep hitting
    /// the same versioned paths with the same headers and query parameters,
    /// and keep decoding the same envelopes — these tests pin that wire
    /// behavior against a mock transport.

    func testFetchPrinterProfilesRequestsTheAPIV1PrinterProfilesPath() async throws {
        let lock = NSLock()
        var paths: [String] = []
        let client = makeClient { request in
            lock.lock()
            paths.append(request.url?.path ?? "")
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(paths, ["/api/v1/printer_profiles"])
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
    }

    func testFetchColorsSendsPrinterProfileIDQueryAndJSONAcceptUnderAPIV1() async throws {
        let lock = NSLock()
        var received: [(path: String, query: [URLQueryItem]?, accept: String?)] = []
        let client = makeClient { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            lock.lock()
            received.append((request.url?.path ?? "", components?.queryItems, request.value(forHTTPHeaderField: "Accept")))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.path, "/api/v1/colors")
        XCTAssertEqual(received.first?.query, [URLQueryItem(name: "printer_profile_id", value: "7")])
        XCTAssertEqual(received.first?.accept, "application/json")
        XCTAssertEqual(fetched.colors.first?.id, 9)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 2)
    }

    func testFetchColorsSurfacesNon2xxAsBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsSurfacesUndecodableBodyAsMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testAbsentTokenOmitsAuthorizationHeader() async throws {
        let lock = NSLock()
        var headers: [String?] = []
        let client = makeClient(token: nil) { request in
            lock.lock()
            headers.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(headers, [nil as String?])
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("{}".utf8))
        }

        try await client.testConnection()
    }

    func testTestConnectionSurfacesNon2xxAsBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 2, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 9, "name": "Sepia", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 3,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"},
                "lps": {"brightness": 0.52}
              }
            }
          ]
        }
        """.data(using: .utf8)!
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
