import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract pins for `PaletteAPIClient`'s `/api/v1` usage (issue #39).
///
/// The generated OpenAPI client migration must keep these green so the
/// client's observable behavior — endpoint URLs, the
/// `printer_profile_id` query, headers, status-code error mapping, and
/// envelope decoding — is provably unchanged. Together with
/// `ProfileColorCacheTests` (disk cache, per-server scoping, stale markers)
/// and `APIDecodingTests` (wire shapes), they are the behavior-preservation
/// suite for the migration.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/colors?printer_profile_id=3"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 9)
    }

    func testFetchColorsThrowsBadStatusOnServerError() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 3)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchPrinterProfilesThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionHitsPrinterProfilesAndSucceedsOn2xx() async throws {
        let lock = NSLock()
        var paths: [String] = []
        let client = makeClient { request in
            lock.lock()
            paths.append(request.url!.path)
            lock.unlock()
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()

        XCTAssertEqual(paths, ["/api/v1/printer_profiles"])
    }

    func testTestConnectionThrowsBadStatusWhenServiceUnavailable() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    // MARK: - Fixtures

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!, token: "token", session: session
        )
    }

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 9, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
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
