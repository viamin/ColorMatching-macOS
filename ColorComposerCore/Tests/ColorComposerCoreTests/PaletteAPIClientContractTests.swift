import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the observable HTTP contract of `PaletteAPIClient` across the
/// migration to the generated OpenAPI client (issue #39): endpoint URLs,
/// headers, auth, error mapping, and envelope decoding must be unchanged, so
/// the disk-cache / offline-stale behavior layered on top of this client keeps
/// working. These tests are transport-agnostic — they assert requests and
/// decoded results, never how the client is implemented.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        RecordingURLProtocol.handlers.removeAll()
    }

    func testFetchPrinterProfilesRequestsVersionedEndpointWithJSONAccept() async throws {
        let client = makeClient { request in
            RecordingURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetchColorsRequestsScopedQueryForProfile() async throws {
        let client = makeClient { request in
            RecordingURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testOmitsAuthorizationHeaderWhenNoTokenConfigured() async throws {
        let client = makeClient(token: nil) { request in
            RecordingURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testMapsServiceErrorsToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchColorsReturnsColorsWithCachedProfileFallbackShape() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 1)

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.profile?.id, 1, "the envelope profile feeds the cached-profile fallback")
        let domain = try XCTUnwrap(fetched.colors.first?.toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.87)
        XCTAssertNil(domain.brightness(for: .green), "missing measurements stay missing, never zero")
    }

    // MARK: - Fixtures

    private func makeClient(
        token: String? = "token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        RecordingURLProtocol.handlers.append(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private static let printerProfilesBody = Data(
        """
        {"printer_profiles":[{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"}]}
        """.utf8
    )

    private static let colorsBody = Data(
        """
        {
          "printer_profile": {"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [
            {"id": 123, "name": "Red 12", "hex": "#C64A35",
             "rgb": {"r": 198, "g": 74, "b": 53},
             "responses": {"red": {"brightness": 0.87}}}
          ]
        }
        """.utf8
    )
}

/// Records requests from concurrently registered handlers; each `makeClient`
/// call appends one handler and tearDown clears the stack.
private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handlers.last else {
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
