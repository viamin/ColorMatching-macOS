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

    // MARK: - Wire contract (pinned for the generated-client migration)
    //
    // The tests in this section pin the observable HTTP behavior of
    // `PaletteAPIClient`. When the client is migrated onto the OpenAPI-generated
    // typed client (issue #39), these must keep passing unchanged: the
    // per-server/profile disk cache and offline-stale fallback sit downstream
    // of exactly these requests and decodes.

    func testFetchPrinterProfilesRequestsExpectedEndpointAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var seenURLs: [URL] = []
        let client = makeClient { request in
            lock.lock()
            seenURLs.append(request.url!)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(seenURLs.map(\.path), ["/api/v1/printer_profiles"])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
    }

    func testFetchColorsBuildsExpectedRequestAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var seenURLs: [URL] = []
        let client = makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            lock.lock()
            seenURLs.append(request.url!)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)

        XCTAssertEqual(seenURLs.count, 1)
        XCTAssertEqual(seenURLs.first?.path, "/api/v1/colors")
        let query = URLComponents(url: try XCTUnwrap(seenURLs.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "printer_profile_id", value: "42")),
                      "expected printer_profile_id=42 in \(query)")

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.colors.first?.hex, "#C64A35")
        XCTAssertEqual(fetched.profile?.id, 7)
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testMalformedBodyThrowsMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testOmitsAuthorizationHeaderWhenTokenIsAbsentOrBlank() async throws {
        for token in [nil, "   "] {
            let lock = NSLock()
            var headers: [String?] = []
            let client = makeClient(token: token) { request in
                lock.lock()
                headers.append(request.value(forHTTPHeaderField: "Authorization"))
                lock.unlock()
                return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
            }

            _ = try await client.fetchPrinterProfiles()

            XCTAssertEqual(headers, [nil], "token \(token ?? "nil") must not produce an Authorization header")
        }
    }

    /// The published OpenAPI spec requires `printer_profile` inside the
    /// colors envelope, but the client deliberately tolerates its absence so
    /// partial server responses still yield servable colors. The offline cache
    /// stores the profile as optional for the same reason.
    func testFetchColorsToleratesEnvelopeWithoutPrinterProfile() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data(
                #"{"colors":[{"id":1,"name":"Red","hex":"#FF0000","palette_id":1,"sort_order":0,"responses":{}}]}"#.utf8
            ))
        }

        let fetched = try await client.fetchColors(printerProfileID: 1)

        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.count, 1)
    }

    func testTestConnectionSucceedsOn2xxAndMaps401ToUnauthorized() async {
        let reachable = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data())
        }
        await XCTAssertNoThrowAsync(try await reachable.testConnection())

        let denied = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await denied.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
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

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson",
            "paper_type": "Matte",
            "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123,
              "name": "Red 12",
              "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5,
              "palette_name": "Default",
              "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87},
                "lps": {"brightness": 0.52}
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

private func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expected no error, but got \(error)", file: file, line: line)
    }
}
