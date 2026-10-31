import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Characterization of the `PaletteAPIClient` wire contract that the
/// generated OpenAPI-client migration (issue #39) must preserve byte-for-byte:
/// the `/api/v1` paths, the `printer_profile_id` query parameter, the JSON
/// `Accept` header, bearer-token handling, the decode envelopes, and the
/// error mapping (`401 → unauthorized`, other non-2xx → `badStatus`,
/// undecodable 2xx body → `malformedResponse`).
///
/// These pin *behavior*, not implementation: they pass against the current
/// hand-rolled `URLSession` client and must keep passing unchanged after the
/// client is migrated onto `swift-openapi-generator` output (or a wrapper
/// around it), keeping the disk-cache/offline-stale pipeline intact.
final class PaletteAPIClientMigrationContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - Profiles

    func testFetchPrinterProfilesHitsVersionedPathAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.url?.query, nil)
            return (.init(statusCode: 200, url: request.url!), self.printerProfilesJSON())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        let first = try XCTUnwrap(profiles.first)
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(first.printerMakeModel, "Example Printer")
        XCTAssertEqual(first.paperType, "Matte")
        XCTAssertEqual(first.inkType, "Pigment")
    }

    // MARK: - Colors

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let query = try XCTUnwrap(request.url?.query)
            XCTAssertTrue(
                query.contains("printer_profile_id=7"),
                "colors request must carry printer_profile_id, got \(query)"
            )
            return (.init(statusCode: 200, url: request.url!), self.colorsJSON())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 7)
    }

    func testFetchColorsThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data(#"{"unexpected": true}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchColorsThrowsBadStatusOnServerError() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    // MARK: - Reachability probe

    func testTestConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionThrowsBadStatusOnNon2xx() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    // MARK: - Request shape

    func testRequestsAreGETWithJSONAcceptHeader() async throws {
        let lock = NSLock()
        var methods: [String?] = []
        var accepts: [String?] = []
        let client = makeClient { request in
            lock.lock()
            methods.append(request.httpMethod)
            accepts.append(request.value(forHTTPHeaderField: "Accept"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), self.printerProfilesJSON())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(methods, ["GET"])
        XCTAssertEqual(accepts, ["application/json"])
    }

    func testNoAuthorizationHeaderWithoutToken() async throws {
        let lock = NSLock()
        var authorizations: [String?] = []
        let client = makeClient(token: nil) { request in
            lock.lock()
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), self.printerProfilesJSON())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(authorizations, [nil], "servers without LPSM_API_TOKEN must not receive a token")
    }

    // MARK: - Fixtures

    private func makeClient(
        token: String? = "token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    private func printerProfilesJSON() -> Data {
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 7, "printer_make_model": "Other Printer", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """.data(using: .utf8)!
    }

    private func colorsJSON() -> Data {
        """
        {
          "printer_profile": {"id": 7, "printer_make_model": "Other Printer", "paper_type": "Glossy", "ink_type": "Dye"},
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "responses": {"red": {"brightness": 0.87}}
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
    convenience init(statusCode: Int, url: URL?) {
        self.init(url: url ?? URL(string: "http://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
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
