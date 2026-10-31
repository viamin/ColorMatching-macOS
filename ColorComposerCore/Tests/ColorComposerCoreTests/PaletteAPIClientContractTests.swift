import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract between this app and the `color_matching` `/api/v1` API.
///
/// These tests pin the exact requests `PaletteAPIClient` issues and the errors
/// it surfaces. When the client is migrated onto the generated OpenAPI client
/// (viamin/color_matching#110), these are the guarantees the migration must
/// keep: same endpoints, same query parameters, same headers, same error
/// mapping — with the disk-cache/offline-stale behavior layered on top
/// (see `ProfileColorCacheTests`).
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - Requests

    func testFetchPrinterProfilesRequestShape() async throws {
        let received = RequestRecorder()
        let client = makeClient(token: nil, recorder: received) {
            (HTTPURLResponse(statusCode: 200, url: $0.url!), Data(#"{"printer_profiles":[]}"#.utf8))
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertTrue(profiles.isEmpty)
        let request = try XCTUnwrap(received.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.test/api/v1/printer_profiles")
        XCTAssertTrue(request.httpMethod == nil || request.httpMethod == "GET", "profiles must be fetched with GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no token means no Authorization header")
    }

    func testFetchColorsRequestCarriesPrinterProfileIDQuery() async throws {
        let received = RequestRecorder()
        let client = makeClient(token: nil, recorder: received) {
            (HTTPURLResponse(statusCode: 200, url: $0.url!), Data(#"{"colors":[],"printer_profile":null}"#.utf8))
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertTrue(fetched.colors.isEmpty)
        XCTAssertNil(fetched.profile)
        let request = try XCTUnwrap(received.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://api.example.test/api/v1/colors?printer_profile_id=7"
        )
    }

    func testFetchColorsDecodesEnvelopeWithProfileAndResponses() async throws {
        let client = makeClient(token: nil) { request in
            let body = """
            {
              "colors": [
                {
                  "id": 123, "name": "Red 12", "hex": "#C64A35",
                  "rgb": {"r": 198, "g": 74, "b": 53},
                  "responses": {"red": {"brightness": 0.87}}
                }
              ],
              "printer_profile": {
                "id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
              }
            }
            """
            return (HTTPURLResponse(statusCode: 200, url: request.url!), Data(body.utf8))
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    func testBaseURLPathPrefixAndTrailingSlashArePreservedInRequests() async throws {
        let received = RequestRecorder()
        let client = makeClient(
            baseURL: URL(string: "http://gateway.test/prefix/")!, token: nil, recorder: received
        ) {
            (HTTPURLResponse(statusCode: 200, url: $0.url!), Data(#"{"printer_profiles":[]}"#.utf8))
        }

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(received.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://gateway.test/prefix/api/v1/printer_profiles"
        )
    }

    func testBlankTokenOmitsAuthorizationHeader() async throws {
        let received = RequestRecorder()
        let client = makeClient(token: "   ", recorder: received) {
            (HTTPURLResponse(statusCode: 200, url: $0.url!), Data(#"{"printer_profiles":[]}"#.utf8))
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(received.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Errors

    func testUnauthorizedSurfacesAsDistinctError() async {
        let client = makeClient(token: "stale-token") {
            (HTTPURLResponse(statusCode: 401, url: $0.url!), Data())
        }

        await assertThrowsAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testNon2xxSurfacesBadStatus() async {
        let client = makeClient(token: nil) {
            (HTTPURLResponse(statusCode: 500, url: $0.url!), Data())
        }

        await assertThrowsAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testUnparseableBodySurfacesMalformedResponse() async {
        let client = makeClient(token: nil) {
            (HTTPURLResponse(statusCode: 200, url: $0.url!), Data("not json".utf8))
        }

        await assertThrowsAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xxAndSurfacesServerErrors() async {
        // The mock handler is process-global; install and exercise one at a time.
        let unavailable = makeClient(token: nil) {
            (HTTPURLResponse(statusCode: 503, url: $0.url!), Data())
        }
        await assertThrowsAsync(try await unavailable.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }

        let reachable = makeClient(token: nil) {
            (HTTPURLResponse(statusCode: 204, url: $0.url!), Data())
        }
        do {
            try await reachable.testConnection()
        } catch {
            XCTFail("2xx from /api/v1/printer_profiles should count as reachable: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeClient(
        baseURL: URL = URL(string: "http://api.example.test")!,
        token: String?,
        recorder: RequestRecorder? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = { request in
            recorder?.record(request)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: baseURL,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }
}

/// Collects requests issued through the mock protocol so assertions can run
/// on the test flow instead of the protocol thread.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class ContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
