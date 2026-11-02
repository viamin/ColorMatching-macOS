import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the externally observable wire contract of `PaletteAPIClient`.
///
/// The migration to the generated OpenAPI client (issue #39) must keep every
/// behavior asserted here — endpoint paths, query parameters, headers, the
/// `PaletteAPIError` mapping, and the decoded DTO shapes that feed
/// `ProfileColorCache`. These tests are written against the current
/// hand-rolled client; they are the acceptance contract the generated-client
/// wrapper has to keep satisfying. See `docs/openapi-generated-client.md`.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - printer profiles

    func testFetchPrinterProfilesRequestsTheVersionedPath() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod ?? "GET", "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
    }

    // MARK: - colors

    func testFetchColorsSendsThePrinterProfileIDQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let query = request.url?.query?.split(separator: "&").sorted()
            XCTAssertEqual(query, ["printer_profile_id=7"])
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 7)
    }

    /// Colors with no measurement for the profile come back response-less:
    /// "missing" must stay distinguishable from "measured zero" so the
    /// solver's exclusion policy keeps working on cached data.
    func testFetchColorsKeepsResponselessColorsResponseless() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.responselessColorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 1)

        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertTrue(color.responses.isEmpty)
        XCTAssertEqual(color.id, 42)
    }

    // MARK: - authorization

    func testOmitsAuthorizationHeaderWhenNoTokenIsConfigured() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testSendsBearerTokenWithWhitespaceTrimmed() async throws {
        let client = makeClient(token: "  tok-123  \n") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    /// An all-whitespace token is treated as absent, not sent as an empty
    /// bearer credential.
    func testBlankTokenIsTreatedAsAbsent() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - error mapping

    func testUnauthorizedStatusMapsToUnauthorizedError() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThatFetchColorsThrows(.unauthorized, from: client)
    }

    func testServerErrorStatusMapsToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await assertThatFetchColorsThrows(.badStatus(500), from: client)
    }

    func testUndecodableSuccessBodyMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("<html>not json</html>".utf8))
        }

        await assertThatFetchColorsThrows(.malformedResponse, from: client)
    }

    // MARK: - test connection

    func testTestConnectionAcceptsAnySuccessStatus() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        _ = try await client.testConnection()
    }

    func testTestConnectionReportsUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThatTestConnectionThrows(.unauthorized, from: client)
    }

    // MARK: - Helpers

    private func makeClient(
        token: String? = "token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func assertThatFetchColorsThrows(
        _ expected: PaletteAPIError,
        from client: PaletteAPIClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.fetchColors(printerProfileID: 1)
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PaletteAPIError, expected, file: file, line: line)
        }
    }

    private func assertThatTestConnectionThrows(
        _ expected: PaletteAPIError,
        from client: PaletteAPIClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await client.testConnection()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PaletteAPIError, expected, file: file, line: line)
        }
    }

    private static let printerProfilesBody = """
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"}
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
      "colors": [
        {"id": 123, "name": "Red 12", "hex": "#C64A35",
         "rgb": {"r": 198, "g": 74, "b": 53},
         "responses": {"red": {"brightness": 0.87, "source": "measurement"}}}
      ]
    }
    """.data(using: .utf8)!

    private static let responselessColorsBody = """
    {
      "colors": [
        {"id": 42, "name": "Unmeasured", "hex": "#101010", "rgb": {"r": 16, "g": 16, "b": 16}, "responses": {}}
      ]
    }
    """.data(using: .utf8)!
}

private final class ContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
