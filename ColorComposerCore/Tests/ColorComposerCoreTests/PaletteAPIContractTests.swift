import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract guards for the `/api/v1` surface `PaletteAPIClient` uses.
///
/// The client is being migrated onto a generated OpenAPI client
/// (viamin/color_matching#110, this repo's issue #39). These tests pin the
/// externally observable behavior the migration must keep intact — request
/// URLs, the bearer-token header, the `/api/v1` envelope shapes, and the
/// error taxonomy — so swapping the transport for generated code cannot
/// silently change what the app sends or how failures surface. They pass
/// against the hand-rolled client today and must stay green after the
/// migration (see also `PaletteAPIClientTests` and `APIDecodingTests`).
final class PaletteAPIContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        StubURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient { request in
            self.assertProfilesRequest(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesJSON())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 7])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
        XCTAssertEqual(profiles.last?.printerMakeModel, "Other Printer")
    }

    func testFetchPrinterProfilesMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertThrows(
            try await client.fetchPrinterProfiles(),
            equals: .badStatus(503)
        )
    }

    func testFetchPrinterProfilesMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertThrows(
            try await client.fetchPrinterProfiles(),
            equals: .malformedResponse
        )
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.colorsJSON())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 1)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    func testFetchColorsDecodesEnvelopeWithoutProfileMetadata() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsJSON(profile: false))
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertNil(fetched.profile)
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 404, url: request.url!), Data())
        }

        await assertThrows(
            try await client.fetchColors(printerProfileID: 9),
            equals: .badStatus(404)
        )
    }

    // MARK: - testConnection

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            self.assertProfilesRequest(request)
            return (.init(statusCode: 200, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionThrowsUnauthorizedOn401() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrows(try await client.testConnection(), equals: .unauthorized)
    }

    // MARK: - Base URL and token handling

    func testBaseURLSubpathKeepsVersionedAPIPath() async throws {
        let client = makeClient(baseURL: URL(string: "http://example.com/backend")!, token: nil) { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/backend/api/v1/printer_profiles"
            )
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesJSON())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testWhitespaceOnlyTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesJSON())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testNilTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesJSON())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Helpers

    private func assertProfilesRequest(_ request: URLRequest) {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    private func makeClient(
        baseURL: URL = URL(string: "http://example.com")!,
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return PaletteAPIClient(
            baseURL: baseURL,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        equals expected: PaletteAPIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as PaletteAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private static func printerProfilesJSON() -> Data {
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 7, "printer_make_model": "Other Printer", "paper_type": null, "ink_type": null}
          ]
        }
        """.data(using: .utf8)!
    }

    private static func colorsJSON(profile: Bool = true) -> Data {
        let profileJSON = profile
            ? "\"printer_profile\": {\"id\": 1, \"printer_make_model\": \"Example Printer\", \"paper_type\": \"Matte\", \"ink_type\": \"Pigment\"},"
            : ""
        return """
        {
          \(profileJSON)
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

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
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
