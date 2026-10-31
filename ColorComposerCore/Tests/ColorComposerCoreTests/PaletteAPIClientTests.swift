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

    /// Pins the request the server's published OpenAPI document describes
    /// (viamin/color_matching#113): `GET /api/v1/printer_profiles` accepting JSON.
    func testFetchPrinterProfilesRequestsTheDocumentedEndpoint() async throws {
        let lock = NSLock()
        var captured: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            captured.append(request)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
    }

    /// `GET /api/v1/colors?printer_profile_id=N` — the profile scoping the
    /// disk cache keys on, so the generated client must keep sending it.
    func testFetchColorsRequestsTheDocumentedProfileScopedEndpoint() async throws {
        let lock = NSLock()
        var captured: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            captured.append(request)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsResponse(withProfile: true))
        }

        _ = try await client.fetchColors(printerProfileID: 4)

        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "printer_profile_id" }?.value, "4")
    }

    func testFetchColorsDecodesEnvelopeWithPrinterProfile() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsResponse(withProfile: true))
        }

        let fetched = try await client.fetchColors(printerProfileID: 4)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 4)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    /// The server spec marks `printer_profile` as required in the colors
    /// envelope; the client stays lenient so an older deployment omitting it
    /// still loads colors (the profile is display metadata only).
    func testFetchColorsToleratesAnEnvelopeWithoutPrinterProfile() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsResponse(withProfile: false))
        }

        let fetched = try await client.fetchColors(printerProfileID: 4)

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertNil(fetched.profile)
    }

    func testFetchColorsThrowsUnauthorizedOn401() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 4)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsThrowsBadStatusOnServerError() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 4)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 4)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testOmitsAuthorizationHeaderWhenNoTokenIsSet() async throws {
        let lock = NSLock()
        var authorizations: [String?] = []
        let client = makeClient(token: nil) { request in
            lock.lock()
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(authorizations, [nil])
    }

    func testOmitsAuthorizationHeaderForWhitespaceOnlyToken() async throws {
        let lock = NSLock()
        var authorizations: [String?] = []
        let client = makeClient(token: "   \n") { request in
            lock.lock()
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(authorizations, [nil])
    }

    func testConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        _ = try await client.testConnection()
    }

    func testConnectionThrowsUnauthorizedOn401() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
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

    private func colorsResponse(withProfile: Bool) -> Data {
        let profile = withProfile
            ? "\"printer_profile\": {\"id\": 4, \"printer_make_model\": \"Epson\", \"paper_type\": \"Matte\", \"ink_type\": \"Dye\"},"
            : ""
        return """
        {
          \(profile)
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
