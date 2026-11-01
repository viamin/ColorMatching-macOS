import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract characterization for `PaletteAPIClient` (issue #39).
///
/// The generated OpenAPI client migration must preserve these behaviors
/// exactly — endpoint paths under `/api/v1`, the `printer_profile_id` query
/// parameter, bearer-token handling, snake_case envelope decoding, and the
/// error mapping the offline-fallback UI depends on. They are green today and
/// guard the refactor; a failure here means the migration changed the wire
/// contract, not just its implementation.
final class PaletteAPIClientMigrationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MigrationMockURLProtocol.handler = nil
    }

    func testFetchColorsSendsPrinterProfileIDUnderApiV1AndDecodesEnvelope() async throws {
        let lock = NSLock()
        var capturedURLs: [URL] = []
        let client = makeClient { request in
            lock.lock()
            capturedURLs.append(request.url!)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let url = try XCTUnwrap(capturedURLs.first)
        XCTAssertEqual(url.path, "/api/v1/colors", "fetchColors must stay on /api/v1/colors")
        let queryItems = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(
            queryItems.contains { $0.name == "printer_profile_id" && $0.value == "7" },
            "fetchColors must keep sending printer_profile_id as a query parameter"
        )

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
    }

    func testFetchColorsMapsHTTP500ToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await assertThrowsAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertThrowsAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchPrinterProfilesDecodesMultipleSnakeCaseProfiles() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].id, 1)
        XCTAssertEqual(profiles[0].printerMakeModel, "Epson XP-8600")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[1].id, 2)
        XCTAssertNil(profiles[1].paperType, "A null paper_type must decode as nil, not an error")
    }

    func testTestConnectionSucceedsOn2xxAndSendsJSONAccept() async throws {
        let lock = NSLock()
        var acceptHeaders: [String?] = []
        let client = makeClient { request in
            lock.lock()
            acceptHeaders.append(request.value(forHTTPHeaderField: "Accept"))
            lock.unlock()
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()

        XCTAssertEqual(acceptHeaders, ["application/json"])
    }

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil, handler: { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        })

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Fixtures

    private func makeClient(
        token: String? = "token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MigrationMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MigrationMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!, token: token, session: session
        )
    }

    private static func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "responses": {
                "red": {"brightness": 0.87},
                "lps": {"brightness": 0.52}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 2, "printer_make_model": "Canon Pro-300", "paper_type": null, "ink_type": "Dye"}
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class MigrationMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func assertThrowsAsync<T>(
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
