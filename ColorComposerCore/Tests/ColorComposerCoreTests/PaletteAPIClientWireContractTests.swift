import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract between this app and `color_matching` `/api/v1` (issue #39).
///
/// These pin the externally observable behavior of `PaletteAPIClient` —
/// endpoints, query parameters, headers, envelope decoding, and error mapping —
/// so the migration to the generated OpenAPI client cannot change what the
/// server sees or what callers get back. The disk cache and offline-stale
/// fallback sit downstream of this contract and stay untouched by it.
final class PaletteAPIClientWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    func testPrinterProfilesHitsVersionedEndpointWithJSONAccept() async throws {
        let lock = NSLock()
        var seenURL: URL?
        var seenAccept: String?
        let client = makeClient { request in
            lock.lock()
            seenURL = request.url
            seenAccept = request.value(forHTTPHeaderField: "Accept")
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(seenURL?.absoluteString, "https://api.example.com/api/v1/printer_profiles")
        XCTAssertEqual(seenAccept, "application/json")
        XCTAssertEqual(profiles.first?.id, 3)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson SC-T2100")
    }

    func testFetchColorsCarriesPrinterProfileIDQuery() async throws {
        let lock = NSLock()
        var seenURL: URL?
        let client = makeClient { request in
            lock.lock()
            seenURL = request.url
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)

        let components = URLComponents(url: try XCTUnwrap(seenURL), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/api/v1/colors")
        XCTAssertEqual(components?.queryItems?.first?.name, "printer_profile_id")
        XCTAssertEqual(components?.queryItems?.first?.value, "42")
        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.responses["lps"]?.brightness, 0.52)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    func testFetchColorsSendsTrimmedBearerToken() async throws {
        let lock = NSLock()
        var seenAuthorization: String?
        let client = makeClient { request in
            lock.lock()
            seenAuthorization = request.value(forHTTPHeaderField: "Authorization")
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        _ = try await client.fetchColors(printerProfileID: 1)

        XCTAssertEqual(seenAuthorization, "Bearer secret-token")
    }

    func testUnauthorizedSurfacesAsDistinctError() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.fetchPrinterProfiles()) {
            XCTAssertEqual($0, .unauthorized)
        }
        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 1)) {
            XCTAssertEqual($0, .unauthorized)
        }
    }

    func testNon2xxSurfacesBadStatusWithStatusCode() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.fetchPrinterProfiles()) {
            XCTAssertEqual($0, .badStatus(503))
        }
    }

    func testMalformedBodySurfacesMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("{not json".utf8))
        }

        await assertThrowsPaletteAPIError(try await client.fetchPrinterProfiles()) {
            XCTAssertEqual($0, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionThrowsOnUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.testConnection()) {
            XCTAssertEqual($0, .unauthorized)
        }
    }

    /// The re-auth flow in `ColorCatalog.withReauth` rebuilds a client from the
    /// current one's `baseURL` and reads `token`; both must stay exposed.
    func testClientExposesBaseURLAndTokenForReauth() {
        let client = PaletteAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            token: "tok"
        )

        XCTAssertEqual(client.baseURL.absoluteString, "https://api.example.com")
        XCTAssertEqual(client.token, "tok")
    }

    // MARK: - Fixtures

    private static let printerProfilesBody = """
    {
      "printer_profiles": [
        {
          "id": 3,
          "printer_make_model": "Epson SC-T2100",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "printer_profile": {
        "id": 42,
        "printer_make_model": "Epson SC-T2100",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 7,
          "name": "Red 12",
          "hex": "#C64A35",
          "rgb": { "r": 198, "g": 74, "b": 53 },
          "palette_id": 5,
          "palette_name": "Default",
          "sort_order": 12,
          "responses": {
            "red": { "brightness": 0.87, "source": "measurement" },
            "lps": { "brightness": 0.52, "source": "response", "apparent_brightness": 5 }
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            token: "  secret-token  ",
            session: session
        )
    }

    private func assertThrowsPaletteAPIError<T>(
        _ expression: @autoclosure () async throws -> T,
        _ assertions: @Sendable (PaletteAPIError) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected PaletteAPIError to be thrown", file: file, line: line)
        } catch let error as PaletteAPIError {
            assertions(error)
        } catch {
            XCTFail("Expected PaletteAPIError, got \(error)", file: file, line: line)
        }
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
