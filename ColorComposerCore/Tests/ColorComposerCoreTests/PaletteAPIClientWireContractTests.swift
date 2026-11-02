import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire behavior of `PaletteAPIClient` — request shapes,
/// auth header handling, status-to-error mapping, and envelope decoding — so
/// the migration to the generated OpenAPI client (issue #39) must keep every
/// one of these green or deliberately account for a spec change. These
/// describe what the server contract is today; the generated client inherits
/// them from the published OpenAPI document (viamin/color_matching#110).
final class PaletteAPIClientWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        WireContractMockURLProtocol.handler = nil
    }

    private func makeClient(
        token: String? = "  wire-token  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    private func ok(_ request: URLRequest, _ body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    private func status(_ code: Int, _ request: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data())
    }

    private func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {
            "id": 3, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 11, "name": "Sienna", "hex": "#A0522D",
              "rgb": {"r": 160, "g": 82, "b": 45},
              "responses": {
                "red": {"brightness": 0.5},
                "green": {"brightness": 0.375}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsBuildsDocumentedRequestAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var captured: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            captured.append(request)
            lock.unlock()
            return self.ok(request, self.colorsEnvelope())
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?
                .sorted { $0.name < $1.name },
            [URLQueryItem(name: "printer_profile_id", value: "3")]
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wire-token")

        XCTAssertEqual(fetched.colors.map(\.id), [11])
        XCTAssertEqual(fetched.colors.first?.toDomain()?.brightness(for: .red), 0.5)
        XCTAssertEqual(fetched.profile?.id, 3)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Canon")
    }

    func testFetchColorsOmitsAuthorizationHeaderWithoutToken() async throws {
        let lock = NSLock()
        var headers: [String?] = []
        let client = makeClient(token: "   ") { request in
            lock.lock()
            headers.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return self.ok(request, self.colorsEnvelope())
        }

        _ = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(headers, [nil])
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient { request in self.status(500, request) }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 3)) { error in
            XCTAssertEqual(error, .badStatus(500))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in self.ok(request, Data("not json".utf8)) }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 3)) { error in
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient { request in
            self.ok(request, self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Canon")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
    }

    private func printerProfilesEnvelope() -> Data {
        """
        {"printer_profiles": [{"id": 1, "printer_make_model": "Canon", "paper_type": "Matte", "ink_type": "Dye"}]}
        """.data(using: .utf8)!
    }

    // MARK: - Test connection

    func testConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in self.ok(request, self.printerProfilesEnvelope()) }

        await client.testConnection()
    }

    func testConnectionSurfacesUnauthorizedOn401() async {
        let client = makeClient { request in self.status(401, request) }

        await assertThrowsPaletteAPIError(await client.testConnection()) { error in
            XCTAssertEqual(error, .unauthorized)
        }
    }
}

private func assertThrowsPaletteAPIError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ assertions: (PaletteAPIError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected a PaletteAPIError to be thrown", file: file, line: line)
    } catch let error as PaletteAPIError {
        assertions(error)
    } catch {
        XCTFail("Expected PaletteAPIError, got \(error)", file: file, line: line)
    }
}

private final class WireContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
